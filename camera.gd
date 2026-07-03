extends Node3D

# Third-person camera rig on a "CameraPivot" parented to the player. The mouse
# orbits the pivot (yaw + pitch). In multiplayer, the player script enables this
# pivot's input and captures the mouse ONLY for the local (authority) player.

## Mouse look sensitivity (radians per pixel of mouse movement).
@export var mouse_sensitivity: float = 0.005
## Pitch limits in radians. More negative = camera higher / looking further down.
@export var min_pitch: float = -1.2
@export var max_pitch: float = 0.3

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
