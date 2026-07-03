extends CharacterBody3D

# Networked player. Each instance is named after its owner's peer id and is
# controlled only by that peer (the authority). Movement/facing/hidden/anim are
# authored by the authority and replicated by the MultiplayerSynchronizer.

## Walking speed in meters per second (default movement).
@export var walk_speed: float = 4.0
## Running speed while holding Shift.
@export var run_speed: float = 8.5
## Upward velocity applied when jumping.
@export var jump_velocity: float = 8.0
## Mid-air steering. 0 = keep takeoff momentum (no walking/running in the air),
## 1 = full ground-like control. Low values feel like a committed, realistic jump.
@export var air_control: float = 0.0
## How quickly the model turns to face its movement direction.
@export var turn_speed: float = 12.0
## How fast the character spins while holding the left mouse button (radians/sec).
@export var spin_speed: float = 3.0
## Extra yaw applied to the model, in degrees. Set to 180 if it runs backwards.
@export var model_yaw_offset_deg: float = 0.0

# --- Replicated state (authored by the authority) ---
var net_hidden: bool = false
var net_loco: int = 0  # 0 idle, 1 walk, 2 run

@onready var _model: Node3D = $ModelRoot
@onready var _run_model: Node3D = $ModelRoot/RunModel
@onready var _walk_model: Node3D = $ModelRoot/WalkModel
@onready var _idle_model: Node3D = $ModelRoot/IdleModel
@onready var _cam_pivot: Node3D = $CameraPivot
@onready var _camera: Camera3D = $CameraPivot/Camera3D
@onready var _shadow_detector: Area3D = $ShadowDetector
@onready var _tag_area: Area3D = $TagArea
@onready var _nametag: Label3D = $Nametag

var _game: HideSeekGame
var _hint_label: Label
var _hidden: bool = false
var _hide_cam_rotation: Vector3 = Vector3.ZERO
var _prev_phase: int = -1
var _spawn_pos: Vector3

func _enter_tree() -> void:
	# The node is named after the owning peer id; claim authority from it.
	set_multiplayer_authority(str(name).to_int())

func _ready() -> void:
	_game = get_tree().get_first_node_in_group("game") as HideSeekGame
	_hint_label = get_tree().get_first_node_in_group("hint_label")
	_setup_loop(_run_model)
	_setup_loop(_walk_model)
	_setup_loop(_idle_model)

	_spawn_pos = position
	var local := is_multiplayer_authority()
	_camera.current = local
	# Only the local player orbits; actual orbiting is gated by the captured mouse,
	# which game.gd manages (captured in-match, free in menus/lobby).
	_cam_pivot.set_process_unhandled_input(local)
	_apply_visuals()

func _setup_loop(model: Node) -> void:
	if model == null:
		return
	var ap := _find_animation_player(model)
	if ap == null:
		return
	for anim_name in ap.get_animation_list():
		if anim_name != "RESET":
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
			ap.play(anim_name)
			break

func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null

func _physics_process(delta: float) -> void:
	_handle_phase_change()
	if not is_multiplayer_authority():
		# Remote players: visuals are driven purely by replicated state.
		_apply_visuals()
		return

	_update_hint_and_hide()

	if not _can_move():
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity += get_gravity() * delta
		net_loco = 0
		move_and_slide()
		_apply_visuals()
		return

	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var left_held := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var right_held := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var running := Input.is_key_pressed(KEY_SHIFT)
	var move_speed := run_speed if running else walk_speed

	if left_held:
		_spin_mode(delta, input_dir, move_speed, running)
	elif right_held:
		_strafe_mode(input_dir, move_speed, running)
	else:
		_default_mode(delta, input_dir, move_speed, running)

	# Airborne: stop the walk/run leg cycle so it doesn't look like air-walking.
	if not is_on_floor():
		net_loco = 0

	_seeker_try_tag()
	move_and_slide()
	_apply_visuals()

# --- Movement modes ---------------------------------------------------

func _spin_mode(delta: float, input_dir: Vector2, move_speed: float, running: bool) -> void:
	if _model and absf(input_dir.x) > 0.01:
		_model.rotation.y -= input_dir.x * spin_speed * delta
	var direction := Vector3.ZERO
	if _model and absf(input_dir.y) > 0.01:
		var facing := _model.global_transform.basis.z
		facing.y = 0.0
		direction = facing.normalized() * -input_dir.y
	_apply_planar_velocity(direction, move_speed)
	_set_loco(direction != Vector3.ZERO, running)

func _strafe_mode(input_dir: Vector2, move_speed: float, running: bool) -> void:
	var direction := _camera_relative_direction(input_dir)
	_apply_planar_velocity(direction, move_speed)
	_set_loco(direction != Vector3.ZERO, running)

func _default_mode(delta: float, input_dir: Vector2, move_speed: float, running: bool) -> void:
	var direction := _camera_relative_direction(input_dir)
	if direction != Vector3.ZERO and _model:
		var target_yaw := atan2(direction.x, direction.z) + deg_to_rad(model_yaw_offset_deg)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, turn_speed * delta)
	_apply_planar_velocity(direction, move_speed)
	_set_loco(direction != Vector3.ZERO, running)

func _apply_planar_velocity(direction: Vector3, move_speed: float) -> void:
	var target_x := direction.x * move_speed
	var target_z := direction.z * move_speed
	if is_on_floor():
		# Grounded: snappy, direct control (instant start/stop/turn).
		velocity.x = target_x
		velocity.z = target_z
	else:
		# Airborne: keep momentum, allow only limited steering. You can't start
		# walking/running or stop on a dime while jumping.
		var accel := run_speed * air_control * get_physics_process_delta_time()
		velocity.x = move_toward(velocity.x, target_x, accel)
		velocity.z = move_toward(velocity.z, target_z, accel)

func _camera_relative_direction(input_dir: Vector2) -> Vector3:
	if input_dir == Vector2.ZERO:
		return Vector3.ZERO
	var basis := _cam_pivot.global_transform.basis if _cam_pivot else global_transform.basis
	var forward := -basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := basis.x
	right.y = 0.0
	right = right.normalized()
	return (forward * -input_dir.y + right * input_dir.x).normalized()

func _set_loco(moving: bool, running: bool) -> void:
	if not moving:
		net_loco = 0
	elif running:
		net_loco = 2
	else:
		net_loco = 1

# --- Roles / phase helpers -------------------------------------------

# Reacts to match phase changes: resets per-round state and manages mouse
# capture for the local player (so lobby/result menus stay clickable).
func _handle_phase_change() -> void:
	if _game == null:
		return
	var ph: int = _game.phase
	if ph == _prev_phase:
		return
	_prev_phase = ph
	if not is_multiplayer_authority():
		return
	if ph == HideSeekGame.Phase.HIDING:
		# Fresh round: reveal, return to spawn, stop moving.
		_set_hidden(false)
		position = _spawn_pos
		velocity = Vector3.ZERO

func _my_id() -> int:
	return get_multiplayer_authority()

func _is_seeker() -> bool:
	return _game != null and _game.get_role(_my_id()) == HideSeekGame.Role.SEEKER

func _can_move() -> bool:
	if _hidden:
		return false
	if _game == null:
		return true
	if _game.is_caught(_my_id()):
		return false
	match _game.phase:
		HideSeekGame.Phase.LOBBY:
			return true
		HideSeekGame.Phase.HIDING:
			return _game.get_role(_my_id()) == HideSeekGame.Role.HIDER
		HideSeekGame.Phase.SEEKING:
			return true
		_:
			return false

# --- Hiding (hiders only) --------------------------------------------

func _update_hint_and_hide() -> void:
	if _is_seeker():
		if _hidden:
			_set_hidden(false)  # an infected hider un-hides when they turn seeker
		if _hint_label:
			_hint_label.text = "You are a SEEKER — find and tag the hiders!"
		return

	# Caught hiders are revealed and can't re-hide.
	if _game and _game.is_caught(_my_id()):
		if _hidden:
			_set_hidden(false)
		if _hint_label:
			_hint_label.text = "Caught! Spectating..."
		return

	var in_shadow := _is_in_shadow()
	var phase_ok := _game == null or _game.phase == HideSeekGame.Phase.HIDING or _game.phase == HideSeekGame.Phase.SEEKING
	if Input.is_action_just_pressed("hide") and phase_ok:
		if _hidden:
			_set_hidden(false)
		elif in_shadow:
			_set_hidden(true)

	if _hint_label:
		if _hidden:
			_hint_label.text = "Hidden — look around; press E to reappear where you hid"
		elif in_shadow:
			_hint_label.text = "In shadow — press E to hide"
		else:
			_hint_label.text = "Find a shadow and press E to hide"

func _is_in_shadow() -> bool:
	if _shadow_detector == null:
		return true
	return not _shadow_detector.get_overlapping_areas().is_empty()

func _set_hidden(value: bool) -> void:
	_hidden = value
	net_hidden = value
	if value:
		if _cam_pivot:
			_hide_cam_rotation = _cam_pivot.rotation
	else:
		if _cam_pivot:
			_cam_pivot.rotation = _hide_cam_rotation

# --- Seeker tagging ---------------------------------------------------

func _seeker_try_tag() -> void:
	if _game == null:
		return
	if not _is_seeker():
		return
	if _game.phase != HideSeekGame.Phase.SEEKING:
		return
	for body in _tag_area.get_overlapping_bodies():
		if body == self or not body.is_in_group("player"):
			continue
		var target_id := str(body.name).to_int()
		if _game.get_role(target_id) != HideSeekGame.Role.HIDER:
			continue
		if _game.is_caught(target_id):
			continue
		# Register the catch on the host (call directly when we ARE the host,
		# since an rpc_id-to-self on a call_remote RPC would not fire).
		if multiplayer.is_server():
			_game.request_catch(target_id)
		else:
			_game.request_catch.rpc_id(1, target_id)

# --- Visuals (run on every peer) -------------------------------------

func _apply_visuals() -> void:
	if _model:
		_model.visible = not net_hidden
	_update_locomotion(net_loco)
	_update_nametag()

func _update_locomotion(loco: int) -> void:
	var run_on := loco == 2
	var walk_on := loco == 1
	var idle_on := loco == 0
	if walk_on and _walk_model == null:
		walk_on = false
		run_on = true
	if idle_on and _idle_model == null:
		idle_on = false
		run_on = true
	if _run_model:
		_run_model.visible = run_on
	if _walk_model:
		_walk_model.visible = walk_on
	if _idle_model:
		_idle_model.visible = idle_on

func _update_nametag() -> void:
	if _nametag == null:
		return
	var id := _my_id()
	var local := is_multiplayer_authority()
	if _game and _game.is_caught(id):
		_nametag.visible = not local
		_nametag.text = "CAUGHT"
		_nametag.modulate = Color(0.7, 0.7, 0.7)
	elif _game and _game.get_role(id) == HideSeekGame.Role.SEEKER:
		# Mark the seeker so everyone can see/avoid them (hiders stay unlabeled).
		_nametag.visible = not local
		_nametag.text = "SEEKER"
		_nametag.modulate = Color(1, 0.4, 0.35)
	else:
		_nametag.visible = false
