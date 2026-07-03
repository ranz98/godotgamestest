extends CharacterBody3D

## Ground movement speed in meters per second.
@export var speed: float = 6.0
## Upward velocity applied when jumping.
@export var jump_velocity: float = 4.5
## How quickly the character turns to face its movement direction (higher = snappier).
@export var turn_speed: float = 12.0

# The AnimationPlayer found inside the imported character model, plus the name
# of the movement clip baked into it. Located at runtime so this works no matter
# what the GLB's internal nodes are called.
var _anim: AnimationPlayer
var _move_anim: String = ""

func _ready() -> void:
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

	# WASD -> a direction on the ground (XZ) plane. W (move_up) is forward (-Z).
	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var direction := Vector3(input_dir.x, 0.0, input_dir.y).normalized()
	var moving := direction != Vector3.ZERO

	if moving:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		# Smoothly rotate the body to face the way it's running.
		var target_yaw := atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, turn_speed * delta)
	else:
		# Decelerate to a stop when no keys are held.
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	_update_animation(moving)
	move_and_slide()

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
