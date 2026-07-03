extends Node3D

# Third-person camera rig. Lives on a "CameraPivot" node parented to the player,
# with a Camera3D sitting behind it. The mouse orbits the pivot (yaw + pitch);
# because it's parented to the player it follows position automatically.

## Mouse look sensitivity (radians per pixel of mouse movement).
@export var mouse_sensitivity: float = 0.005
## Pitch limits in radians. More negative = camera higher / looking further down.
@export var min_pitch: float = -1.2
@export var max_pitch: float = 0.3

func _ready() -> void:
	# Capture the mouse for look control (Esc releases it).
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * mouse_sensitivity
		rotation.x = clamp(rotation.x - event.relative.y * mouse_sensitivity, min_pitch, max_pitch)
	elif event.is_action_pressed("ui_cancel"):
		# Esc frees the cursor so you can leave the window.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		# Click back in the window to resume mouse-look.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
