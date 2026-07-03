extends CharacterBody3D

## Ground movement speed in meters per second.
@export var speed: float = 6.0
## Upward velocity applied when jumping.
@export var jump_velocity: float = 4.5
## How quickly the model turns to face its movement direction (higher = snappier).
@export var turn_speed: float = 12.0
## Extra yaw applied to the model, in degrees. Set to 180 if the character runs backwards.
@export var model_yaw_offset_deg: float = 0.0
## Node whose horizontal facing defines "forward" for movement (the camera pivot).
@export var camera_pivot_path: NodePath = ^"CameraPivot"
## The visual model that rotates to face the movement direction.
@export var model_path: NodePath = ^"CharacterModel"

# Located at runtime so this works no matter what the GLB's internal nodes are called.
var _anim: AnimationPlayer
var _move_anim: String = ""
var _cam_pivot: Node3D
var _model: Node3D

func _ready() -> void:
	_cam_pivot = get_node_or_null(camera_pivot_path)
	_model = get_node_or_null(model_path)
	_anim = _find_animation_player(self)
	if _anim:
		# Use the first "real" clip (skip Godot's auto-generated RESET track).
		for anim_name in _anim.get_animation_list():
			if anim_name != "RESET":
				_move_anim = anim_name
				break
		# Make the movement clip loop so running cycles continuously.
		if _move_anim != "":
			_anim.get_animation(_move_anim).loop_mode = Animation.LOOP_LINEAR

func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null

func _physics_process(delta: float) -> void:
	# Apply gravity while airborne.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Jump when grounded.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# WASD relative to where the camera is looking.
	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var direction := _camera_relative_direction(input_dir)
	var moving := direction != Vector3.ZERO

	if moving:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		# Rotate the model (not the body) to face the way it's running.
		if _model:
			var target_yaw := atan2(direction.x, direction.z) + deg_to_rad(model_yaw_offset_deg)
			_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, turn_speed * delta)
	else:
		# Decelerate to a stop when no keys are held.
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	_update_animation(moving)
	move_and_slide()

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

func _update_animation(moving: bool) -> void:
	if _anim == null or _move_anim == "":
		return
	if moving:
		# Play the run cycle (resume it if it was paused).
		if not _anim.is_playing() or _anim.current_animation != _move_anim:
			_anim.play(_move_anim)
	elif _anim.is_playing():
		# Freeze the run cycle when standing still.
		_anim.pause()
