extends CharacterBody3D

## Ground movement speed in meters per second.
@export var speed: float = 6.0
## Upward velocity applied when jumping. ~8 clears roughly 3.3m — enough to land
## on the crates/plateau (2m) and the platform (3m).
@export var jump_velocity: float = 8.0
## How quickly the model turns to face its movement direction (higher = snappier).
@export var turn_speed: float = 12.0
## How fast the character spins while holding the left mouse button (radians/sec).
@export var spin_speed: float = 3.0
## Extra yaw applied to the model, in degrees. Set to 180 if the character runs backwards.
@export var model_yaw_offset_deg: float = 0.0
## Node whose horizontal facing defines "forward" for movement (the camera pivot).
@export var camera_pivot_path: NodePath = ^"CameraPivot"
## Pivot holding the character models; rotates to face the movement direction.
@export var model_path: NodePath = ^"ModelRoot"
## The running model (shown while moving).
@export var run_model_path: NodePath = ^"ModelRoot/RunModel"
## The standing/idle model (shown while still).
@export var idle_model_path: NodePath = ^"ModelRoot/IdleModel"
## Area3D that reports whether the player is standing in a shadow zone.
@export var shadow_detector_path: NodePath = ^"ShadowDetector"
## Optional on-screen label used for the hide/shadow hints.
@export var status_label_path: NodePath

var _cam_pivot: Node3D
var _model: Node3D
var _run_model: Node3D
var _idle_model: Node3D
var _shadow_detector: Area3D
var _label: Label
var _hidden: bool = false

func _ready() -> void:
	_cam_pivot = get_node_or_null(camera_pivot_path)
	_model = get_node_or_null(model_path)
	_run_model = get_node_or_null(run_model_path)
	_idle_model = get_node_or_null(idle_model_path)
	_shadow_detector = get_node_or_null(shadow_detector_path)
	_label = get_node_or_null(status_label_path)
	# Loop-and-play both models' clips continuously; we just toggle which is shown.
	_setup_loop(_run_model)
	_setup_loop(_idle_model)
	_update_locomotion(false)

# Finds the AnimationPlayer inside `model`, loops its first real clip, and plays it.
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
	# Handle hide/appear first so E is always responsive.
	_handle_hide()

	# While hidden, the character is locked in place at the hide spot — no moving,
	# jumping, or spinning. Only the camera may still orbit. Pressing E reappears
	# you exactly where you hid.
	if _hidden:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity += get_gravity() * delta
		move_and_slide()
		return

	# Apply gravity while airborne.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Jump when grounded.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var left_held := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var right_held := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

	if left_held:
		_spin_mode(delta, input_dir)
	elif right_held:
		_strafe_mode(input_dir)
	else:
		_default_mode(delta, input_dir)

	move_and_slide()

# LEFT mouse held: A/D spin the character in place, W/S drive along its facing.
func _spin_mode(delta: float, input_dir: Vector2) -> void:
	if _model and absf(input_dir.x) > 0.01:
		_model.rotation.y -= input_dir.x * spin_speed * delta

	# Drive forward/back along the model's own facing (its +Z is forward).
	var direction := Vector3.ZERO
	if _model and absf(input_dir.y) > 0.01:
		var facing := _model.global_transform.basis.z
		facing.y = 0.0
		direction = facing.normalized() * -input_dir.y

	_apply_planar_velocity(direction)
	_update_locomotion(direction != Vector3.ZERO)

# RIGHT mouse held: move camera-relative WITHOUT turning the model (strafe).
func _strafe_mode(input_dir: Vector2) -> void:
	var direction := _camera_relative_direction(input_dir)
	_apply_planar_velocity(direction)
	_update_locomotion(direction != Vector3.ZERO)

# No button: camera-relative movement, model turns to face the travel direction.
func _default_mode(delta: float, input_dir: Vector2) -> void:
	var direction := _camera_relative_direction(input_dir)
	if direction != Vector3.ZERO and _model:
		var target_yaw := atan2(direction.x, direction.z) + deg_to_rad(model_yaw_offset_deg)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, turn_speed * delta)
	_apply_planar_velocity(direction)
	_update_locomotion(direction != Vector3.ZERO)

# Sets horizontal velocity toward `direction`, or decelerates to a stop if zero.
func _apply_planar_velocity(direction: Vector3) -> void:
	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

# Converts 2D WASD input into a world direction based on the camera pivot's yaw,
# flattened onto the ground plane.
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
	# input_dir.y is -1 for "up"/W, so negate it to move forward.
	return (forward * -input_dir.y + right * input_dir.x).normalized()

# Shows the run model while moving, the idle model while standing still.
func _update_locomotion(moving: bool) -> void:
	if _idle_model == null:
		# No separate idle model available; just keep the run model shown.
		if _run_model:
			_run_model.visible = true
		return
	if _run_model:
		_run_model.visible = moving
	_idle_model.visible = not moving

# --- Hide-in-shadow mechanic ---

func _handle_hide() -> void:
	var in_shadow := _is_in_shadow()
	if Input.is_action_just_pressed("hide"):
		if _hidden:
			_set_hidden(false)      # E again -> reappear
		elif in_shadow:
			_set_hidden(true)       # E while in a shadow -> vanish
	_update_status_label(in_shadow)

func _is_in_shadow() -> bool:
	# No detector configured -> allow hiding anywhere (fail-open).
	if _shadow_detector == null:
		return true
	return not _shadow_detector.get_overlapping_areas().is_empty()

func _set_hidden(value: bool) -> void:
	_hidden = value
	if _model:
		_model.visible = not value

func _update_status_label(in_shadow: bool) -> void:
	if _label == null:
		return
	if _hidden:
		_label.text = "Hidden in the shadows — press E to reappear"
	elif in_shadow:
		_label.text = "In shadow — press E to hide"
	else:
		_label.text = "Find a shadow and press E to hide"
