extends Camera3D

## The node the camera follows (assign the Player).
@export var target_path: NodePath
## Camera position relative to the target (keeps the angled view).
@export var offset: Vector3 = Vector3(0.0, 12.0, 16.0)
## How far above the target's origin to aim the camera.
@export var look_height: float = 1.5
## Higher = the camera catches up to the player faster.
@export var follow_speed: float = 6.0

var _target: Node3D

func _ready() -> void:
	_target = get_node_or_null(target_path)
	# Snap straight to the target on the first frame so we don't glide in from origin.
	if _target:
		global_position = _target.global_position + offset

func _physics_process(delta: float) -> void:
	if _target == null:
		return
	# Framerate-independent smoothing toward the desired position.
	var desired := _target.global_position + offset
	var weight := 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(desired, weight)
	look_at(_target.global_position + Vector3(0.0, look_height, 0.0), Vector3.UP)
