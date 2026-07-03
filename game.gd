extends Node3D
class_name HideSeekGame

# =====================================================================
# Hide & Seek — peer-to-peer match manager (host is also a player).
#
# Networking model: Godot high-level multiplayer over ENet. One peer is the
# host (peer id 1) and authority for match state; others are clients. Match
# state (phase/timer/roles/caught/winner) is authored by the host and streamed
# to everyone by the GameSync MultiplayerSynchronizer. Players are spawned by
# the host via the PlayerSpawner (MultiplayerSpawner) and each is owned by its
# peer. The only client->host message is request_catch (a seeker tagging).
# =====================================================================

enum Phase { LOBBY, HIDING, SEEKING, ENDED }
enum Role { HIDER, SEEKER }
enum Mode { CLASSIC, INFECTION }  # INFECTION: caught hiders become seekers

const PLAYER_SCENE := preload("res://player.tscn")
const PORT := 24565
const MAX_CLIENTS := 7  # + host = 8 players

## Seconds hiders get to hide before seekers are released.
@export var hide_time: float = 15.0
## Seconds seekers have to catch everyone.
@export var seek_time: float = 90.0

# --- Networked match state (authored by host, synced by GameSync) ---
var phase: int = Phase.LOBBY
var time_left: float = 0.0
var winner: int = 0                # 0 = none, 1 = hiders, 2 = seekers
var roles: Dictionary = {}         # peer_id -> Role
var caught: Array = []             # peer_ids of caught hiders
var mode: int = Mode.CLASSIC       # game mode (host picks in lobby)
var scores: Dictionary = {}        # peer_id -> points, kept across the series

@onready var _players: Node3D = $Players
@onready var _spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _spawn_points: Node3D = $SpawnPoints
@onready var _menu_camera: Camera3D = $MenuCamera

# HUD nodes
@onready var _lobby: Control = $HUD/Lobby
@onready var _host_btn: Button = $HUD/Lobby/Menu/HostButton
@onready var _join_btn: Button = $HUD/Lobby/Menu/JoinButton
@onready var _ip_edit: LineEdit = $HUD/Lobby/Menu/IpEdit
@onready var _lobby_status: Label = $HUD/Lobby/Menu/StatusLabel
@onready var _count_label: Label = $HUD/Lobby/Menu/CountLabel
@onready var _start_btn: Button = $HUD/Lobby/Menu/StartButton
@onready var _mode_btn: Button = $HUD/Lobby/Menu/ModeButton
@onready var _scoreboard: Label = $HUD/Scoreboard
@onready var _timer_label: Label = $HUD/TimerLabel
@onready var _role_label: Label = $HUD/RoleLabel
@onready var _announce: Label = $HUD/Announce
@onready var _result: Control = $HUD/Result
@onready var _winner_label: Label = $HUD/Result/Box/WinnerLabel
@onready var _rematch_btn: Button = $HUD/Result/Box/RematchButton
@onready var _world_env: WorldEnvironment = $WorldEnvironment
@onready var _pause_menu: Control = $HUD/PauseMenu
@onready var _good_btn: Button = $HUD/PauseMenu/Center/Box/GoodButton
@onready var _best_btn: Button = $HUD/PauseMenu/Center/Box/BestButton
@onready var _ultra_btn: Button = $HUD/PauseMenu/Center/Box/UltraButton
@onready var _current_label: Label = $HUD/PauseMenu/Center/Box/CurrentLabel
@onready var _resume_btn: Button = $HUD/PauseMenu/Center/Box/ResumeButton

var _net_active: bool = false
var _last_announced_phase: int = -1
var _spawn_index: int = 0
var _announce_text: String = ""
var _announce_timer: float = 0.0
var _prev_roles: Dictionary = {}  # last round's roles, so the next round can swap
var _start_hiders: int = 0        # hiders at round start (for the seeker-win check)
var _menu_open: bool = false      # Esc graphics menu
var _quality: int = 2             # 0 Good, 1 Best, 2 Ultra

func _ready() -> void:
	randomize()
	add_to_group("game")
	_spawner.spawn_function = _spawn_player
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_host_btn.pressed.connect(host)
	_join_btn.pressed.connect(func(): join(_ip_edit.text))
	_start_btn.pressed.connect(start_match)
	_rematch_btn.pressed.connect(start_match)
	_mode_btn.pressed.connect(toggle_mode)
	_good_btn.pressed.connect(apply_quality.bind(0))
	_best_btn.pressed.connect(apply_quality.bind(1))
	_ultra_btn.pressed.connect(apply_quality.bind(2))
	_resume_btn.pressed.connect(_close_menu)
	apply_quality(2)
	_update_hud()

func _unhandled_input(event: InputEvent) -> void:
	# Esc toggles the graphics menu while connected.
	if _net_active and event.is_action_pressed("ui_cancel"):
		_menu_open = not _menu_open
		get_viewport().set_input_as_handled()

func _close_menu() -> void:
	_menu_open = false

func menu_open() -> bool:
	return _menu_open

# Applies a graphics preset live (0 Good, 1 Best, 2 Ultra).
func apply_quality(preset: int) -> void:
	_quality = preset
	var env: Environment = _world_env.environment
	var vp := get_viewport()
	if preset == 0:      # Good — fastest
		env.sdfgi_enabled = false
		env.ssr_enabled = false
		env.ssil_enabled = false
		env.ssao_enabled = true
		env.volumetric_fog_enabled = false
		vp.msaa_3d = Viewport.MSAA_DISABLED
	elif preset == 1:    # Best — balanced
		env.sdfgi_enabled = false
		env.ssr_enabled = false
		env.ssil_enabled = true
		env.ssao_enabled = true
		env.volumetric_fog_enabled = true
		vp.msaa_3d = Viewport.MSAA_2X
	else:                # Ultra — everything
		env.sdfgi_enabled = true
		env.ssr_enabled = true
		env.ssil_enabled = true
		env.ssao_enabled = true
		env.volumetric_fog_enabled = true
		vp.msaa_3d = Viewport.MSAA_4X
	if _current_label:
		_current_label.text = "Current: %s" % ["Good", "Best", "Ultra"][preset]

func toggle_mode() -> void:
	if not multiplayer.is_server():
		return
	if phase != Phase.LOBBY and phase != Phase.ENDED:
		return
	mode = Mode.INFECTION if mode == Mode.CLASSIC else Mode.CLASSIC

# --- Connection setup -------------------------------------------------

func host() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		_lobby_status.text = "Host failed (error %d)" % err
		return
	multiplayer.multiplayer_peer = peer
	_net_active = true
	_lobby_status.text = "Hosting on port %d" % PORT
	_add_player(1)  # the host is also a player
	_update_hud()

func join(ip: String) -> void:
	ip = ip.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		_lobby_status.text = "Join failed (error %d)" % err
		return
	multiplayer.multiplayer_peer = peer
	_net_active = true
	_lobby_status.text = "Connecting to %s..." % ip
	_update_hud()

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_add_player(id)

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		var node := _players.get_node_or_null(str(id))
		if node:
			node.queue_free()
		roles.erase(id)
		caught.erase(id)

func _on_connected_to_server() -> void:
	_lobby_status.text = "Connected!"

func _on_connection_failed() -> void:
	_net_active = false
	multiplayer.multiplayer_peer = null
	_lobby_status.text = "Connection failed."
	_update_hud()

func _on_server_disconnected() -> void:
	_net_active = false
	multiplayer.multiplayer_peer = null
	phase = Phase.LOBBY
	_lobby_status.text = "Host disconnected."
	_update_hud()

# --- Spawning ---------------------------------------------------------

func _add_player(id: int) -> void:
	# Server-only. Spawns a player for peer `id`; the spawner replicates it.
	# Use a monotonic index (get_child_count() lags behind queued spawns and
	# would land two quick joiners on the same spawn marker).
	var idx := _spawn_index
	_spawn_index += 1
	_spawner.spawn({"id": id, "pos": _spawn_position(idx)})

func _spawn_player(data: Dictionary) -> Node:
	# Runs on every peer (invoked by the MultiplayerSpawner).
	var p := PLAYER_SCENE.instantiate()
	p.name = str(data["id"])
	p.position = data["pos"]
	return p

func _spawn_position(idx: int) -> Vector3:
	var count := _spawn_points.get_child_count()
	if count == 0:
		return Vector3(0, 1, 0)
	var marker := _spawn_points.get_child(idx % count) as Node3D
	return marker.global_position

# --- Match flow (host authoritative) ---------------------------------

func start_match() -> void:
	if not multiplayer.is_server():
		return
	if phase != Phase.LOBBY and phase != Phase.ENDED:
		return
	var ids := _player_ids()
	if ids.is_empty():
		return
	_assign_roles(ids)
	_start_hiders = 0
	for id in ids:
		if roles[id] == Role.HIDER:
			_start_hiders += 1
	caught = []
	winner = 0
	phase = Phase.HIDING
	time_left = hide_time

func _assign_roles(ids: Array) -> void:
	var new_roles: Dictionary = {}
	if _prev_roles.is_empty():
		# First match: random assignment (1 seeker for a pair, ~1/4 otherwise).
		for id in ids:
			new_roles[id] = Role.HIDER
		if ids.size() >= 2:
			var num_seekers: int = max(1, ids.size() / 4)
			var shuffled := ids.duplicate()
			shuffled.shuffle()
			for i in range(num_seekers):
				new_roles[shuffled[i]] = Role.SEEKER
	else:
		# Rematch: swap everyone's role. Anyone who joined since last round
		# defaults to previously-a-seeker so they become a HIDER this round.
		for id in ids:
			var prev: int = _prev_roles.get(id, Role.SEEKER)
			new_roles[id] = Role.HIDER if prev == Role.SEEKER else Role.SEEKER
		_ensure_split(ids, new_roles)
	roles = new_roles
	_prev_roles = new_roles.duplicate()

# Guarantees at least one seeker and one hider when there are 2+ players
# (a swap can otherwise leave everyone on the same side).
func _ensure_split(ids: Array, r: Dictionary) -> void:
	if ids.size() < 2:
		return
	var seekers := 0
	var hiders := 0
	for id in ids:
		if r[id] == Role.SEEKER:
			seekers += 1
		else:
			hiders += 1
	if seekers == 0:
		for id in ids:
			if r[id] == Role.HIDER:
				r[id] = Role.SEEKER
				return
	elif hiders == 0:
		for id in ids:
			if r[id] == Role.SEEKER:
				r[id] = Role.HIDER
				return

func _process(delta: float) -> void:
	if multiplayer.is_server():
		_server_tick(delta)
	_announce_timer = max(0.0, _announce_timer - delta)
	_update_mouse_and_menu()
	_update_hud()

# Single source of truth for the mouse cursor + pause-menu visibility.
func _update_mouse_and_menu() -> void:
	_pause_menu.visible = _menu_open
	if not _net_active:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _menu_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif phase == Phase.HIDING or phase == Phase.SEEKING:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _server_tick(delta: float) -> void:
	if phase == Phase.HIDING:
		time_left -= delta
		if time_left <= 0.0:
			phase = Phase.SEEKING
			time_left = seek_time
	elif phase == Phase.SEEKING:
		time_left -= delta
		if time_left <= 0.0:
			_end_match(1)  # time up -> hiders win
		else:
			# Re-check each tick so a hider disconnecting also resolves the win.
			_check_seeker_win()

# Called by seekers (client -> host) when their tag area overlaps a hider.
@rpc("any_peer", "call_remote", "reliable")
func request_catch(hider_id: int) -> void:
	if not multiplayer.is_server():
		return
	if phase != Phase.SEEKING:
		return
	if get_role(hider_id) != Role.HIDER:
		return
	if hider_id in caught:
		return
	# Credit the catcher (get_remote_sender_id() is 0 for the host's own call).
	var seeker_id := multiplayer.get_remote_sender_id()
	if seeker_id == 0:
		seeker_id = multiplayer.get_unique_id()
	scores[seeker_id] = int(scores.get(seeker_id, 0)) + 1
	if mode == Mode.INFECTION:
		roles[hider_id] = Role.SEEKER  # infected -> joins the seekers, keeps playing
	else:
		caught = caught + [hider_id]  # reassign so the synchronizer sees the change
	_check_seeker_win()

func _check_seeker_win() -> void:
	# Seekers win once no uncaught hiders remain (works for both modes:
	# classic marks them caught, infection converts them to seekers).
	if _start_hiders <= 0:
		return
	for id in _player_ids():
		if get_role(id) == Role.HIDER and not is_caught(id):
			return
	_end_match(2)

func _end_match(who: int) -> void:
	phase = Phase.ENDED
	winner = who
	time_left = 0.0
	if who == 1:
		# Hiders win on timeout -> reward every hider still standing.
		for id in _player_ids():
			if get_role(id) == Role.HIDER and not is_caught(id):
				scores[id] = int(scores.get(id, 0)) + 1

# --- Queries used by players ------------------------------------------

func get_role(id: int) -> int:
	return roles.get(id, Role.HIDER)

func is_caught(id: int) -> bool:
	return id in caught

func _player_ids() -> Array:
	var ids: Array = []
	for c in _players.get_children():
		ids.append(str(c.name).to_int())
	return ids

func _hider_ids() -> Array:
	var ids: Array = []
	for id in _player_ids():
		if get_role(id) == Role.HIDER:
			ids.append(id)
	return ids

# --- HUD --------------------------------------------------------------

func _update_hud() -> void:
	# Before connecting: show the host/join menu, menu camera active.
	if not _net_active:
		_lobby.visible = true
		_host_btn.visible = true
		_join_btn.visible = true
		_ip_edit.visible = true
		_start_btn.visible = false
		_count_label.visible = false
		_result.visible = false
		_timer_label.visible = false
		_role_label.visible = false
		_announce.visible = false
		_mode_btn.visible = false
		_scoreboard.visible = false
		_menu_camera.current = true
		return

	var in_match := phase == Phase.HIDING or phase == Phase.SEEKING
	var ended := phase == Phase.ENDED

	# Lobby (waiting) panel: connected but match not started.
	_lobby.visible = (phase == Phase.LOBBY)
	_host_btn.visible = false
	_join_btn.visible = false
	_ip_edit.visible = false
	_count_label.visible = (phase == Phase.LOBBY)
	_mode_btn.visible = (phase == Phase.LOBBY)
	if phase == Phase.LOBBY:
		_count_label.text = "Players: %d" % _players.get_child_count()
		_lobby_status.text = "In lobby"
		# Only the host can start, and only with at least one player.
		_start_btn.visible = multiplayer.is_server()
		_start_btn.disabled = _players.get_child_count() < 1
		_mode_btn.disabled = not multiplayer.is_server()
		_mode_btn.text = "Mode: %s" % ("Infection" if mode == Mode.INFECTION else "Classic")

	_timer_label.visible = in_match
	_role_label.visible = in_match
	_announce.visible = in_match or ended
	_result.visible = ended
	_rematch_btn.visible = ended and multiplayer.is_server()
	_scoreboard.visible = in_match or ended
	if _scoreboard.visible:
		_scoreboard.text = _scoreboard_text()

	var my_id := multiplayer.get_unique_id()

	if in_match:
		_timer_label.text = _format_time(time_left)
		var my_role := get_role(my_id)
		if my_role == Role.SEEKER:
			_role_label.text = "You are: SEEKER"
			_role_label.modulate = Color(1, 0.5, 0.4)
		else:
			_role_label.text = "You are: HIDER"
			_role_label.modulate = Color(0.5, 0.7, 1)

		# Big transient announcement on phase changes (shown for a few seconds).
		if phase != _last_announced_phase:
			_last_announced_phase = phase
			if phase == Phase.HIDING:
				_announce_text = "HIDE!  Seekers are frozen..."
				_announce_timer = 4.0
			elif phase == Phase.SEEKING:
				_announce_text = "SEEKERS RELEASED!"
				_announce_timer = 3.0

		if is_caught(my_id):
			_announce.text = "You were caught! Spectating..."
		elif _announce_timer > 0.0:
			_announce.text = _announce_text
		else:
			_announce.text = ""

	if ended:
		_last_announced_phase = -1
		var msg := "HIDERS WIN!" if winner == 1 else "SEEKERS WIN!"
		_winner_label.text = msg
		_announce.text = ""

func _format_time(t: float) -> String:
	var s: int = int(max(0.0, ceil(t)))
	return "%d:%02d" % [s / 60, s % 60]

func _scoreboard_text() -> String:
	var ids := _player_ids()
	ids.sort()
	var lines: Array = ["— Scores —"]
	for id in ids:
		var tag := "Hider"
		if is_caught(id):
			tag = "Caught"
		elif get_role(id) == Role.SEEKER:
			tag = "Seeker"
		var who := "Host" if id == 1 else "Player %d" % id
		lines.append("%s (%s): %d" % [who, tag, int(scores.get(id, 0))])
	return "\n".join(lines)
