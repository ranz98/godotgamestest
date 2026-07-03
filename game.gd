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
@onready var _timer_label: Label = $HUD/TimerLabel
@onready var _role_label: Label = $HUD/RoleLabel
@onready var _announce: Label = $HUD/Announce
@onready var _result: Control = $HUD/Result
@onready var _winner_label: Label = $HUD/Result/Box/WinnerLabel
@onready var _rematch_btn: Button = $HUD/Result/Box/RematchButton

var _net_active: bool = false
var _last_announced_phase: int = -1

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
	_update_hud()

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
	var idx := _players.get_child_count()
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
	caught = []
	winner = 0
	phase = Phase.HIDING
	time_left = hide_time

func _assign_roles(ids: Array) -> void:
	roles = {}
	for id in ids:
		roles[id] = Role.HIDER
	# Need at least two players for a seeker; solo = hider (for testing).
	if ids.size() >= 2:
		var num_seekers: int = max(1, ids.size() / 4)
		var shuffled := ids.duplicate()
		shuffled.shuffle()
		for i in range(num_seekers):
			roles[shuffled[i]] = Role.SEEKER

func _process(delta: float) -> void:
	if multiplayer.is_server():
		_server_tick(delta)
	_update_hud()

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
	caught = caught + [hider_id]  # reassign so the synchronizer sees the change
	_check_seeker_win()

func _check_seeker_win() -> void:
	var hiders := _hider_ids()
	if hiders.is_empty():
		return
	for id in hiders:
		if id not in caught:
			return
	_end_match(2)  # all hiders caught -> seekers win

func _end_match(who: int) -> void:
	phase = Phase.ENDED
	winner = who
	time_left = 0.0

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
	if phase == Phase.LOBBY:
		_count_label.text = "Players: %d" % _players.get_child_count()
		_lobby_status.text = "In lobby"
		# Only the host can start, and only with at least one player.
		_start_btn.visible = multiplayer.is_server()
		_start_btn.disabled = _players.get_child_count() < 1

	_timer_label.visible = in_match
	_role_label.visible = in_match
	_announce.visible = in_match or ended
	_result.visible = ended
	_rematch_btn.visible = ended and multiplayer.is_server()

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

		# Big transient announcement on phase changes.
		if phase != _last_announced_phase:
			_last_announced_phase = phase
			if phase == Phase.HIDING:
				_announce.text = "HIDE!  Seekers are frozen..."
			elif phase == Phase.SEEKING:
				_announce.text = "SEEKERS RELEASED!"
		elif phase == Phase.SEEKING:
			_announce.text = ""

		if is_caught(my_id):
			_announce.text = "You were caught! Spectating..."

	if ended:
		_last_announced_phase = -1
		var msg := "HIDERS WIN!" if winner == 1 else "SEEKERS WIN!"
		_winner_label.text = msg
		_announce.text = ""

func _format_time(t: float) -> String:
	var s: int = int(max(0.0, ceil(t)))
	return "%d:%02d" % [s / 60, s % 60]
