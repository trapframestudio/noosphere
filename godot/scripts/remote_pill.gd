extends Node3D
## Visual-only representation of a remote peer's pill.
##
## `GameSession` spawns one of these per remote peer on the current map.
## Incoming state messages call `set_remote_state(pos, yaw)`; the node
## interpolates toward the target in `_process` to smooth out the 20Hz
## update rate.

@export var interp_speed: float = 12.0

var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _has_target: bool = false


## Tint the pill so multiple peers are distinguishable. Called by
## GameSession right after instantiation. Both clients hash the same
## Steam ID and pick the same color, so a given peer looks consistent
## across all viewers.
func set_peer_color(steam_id: int) -> void:
	var mesh: MeshInstance3D = get_node_or_null("MeshInstance3D")
	if mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = FactionColors.for_id(steam_id)
	mat.roughness = 0.6
	mesh.material_override = mat


func set_remote_state(pos: Vector3, yaw: float) -> void:
	_target_pos = pos
	_target_yaw = yaw
	if not _has_target:
		# First update: snap to avoid a slide from origin.
		global_position = pos
		rotation.y = yaw
		_has_target = true


func _process(delta: float) -> void:
	if not _has_target:
		return
	var t: float = clampf(interp_speed * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)
