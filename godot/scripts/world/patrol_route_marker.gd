@tool
class_name PatrolRouteMarker3D
extends Path3D

## Designer-drawn patrol route. Each Curve3D control point becomes a
## patrol waypoint. NPCs walk the curve in order (looping or
## out-and-back). Drop one in the editor, draw a path with the
## Path3D gizmo, and set faction + route_id.
##
## See `docs/book/src/planning/sim-overhaul-plan.md` Phase 2B.

## Unique route identifier. Multiple routes with the same id in
## different regions are independent.
@export var route_id: String = "": set = _set_route_id

## Restrict to a faction name. Empty = any.
@export var faction: String = ""

## Closed loop (true) or out-and-back (false).
@export var loop_route: bool = true

## Higher = more desirable for NPC selection scoring.
@export var priority: int = 0

@export_group("Debug visual")
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"patrol_routes"
const _ROUTE_COLOR: Color = Color(0.55, 0.35, 0.85, 0.8)

var _debug_label: Label3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


func _set_route_id(v: String) -> void:
	route_id = v
	if Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	update_configuration_warnings()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if route_id.strip_edges().is_empty():
		warnings.append("route_id is empty — set a unique identifier.")
	if curve == null or curve.point_count < 2:
		warnings.append("Route needs at least 2 curve control points.")
	return warnings


func get_waypoints() -> PackedVector3Array:
	var pts := PackedVector3Array()
	if curve == null:
		return pts
	for i in range(curve.point_count):
		pts.append(to_global(curve.get_point_position(i)))
	return pts


func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return

	_debug_label = Label3D.new()
	_debug_label.name = "_PatrolRouteLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, 2.0, 0.0)
	_debug_label.font_size = 18
	_debug_label.outline_size = 4
	var mode_str := "LOOP" if loop_route else "OUT-AND-BACK"
	_debug_label.text = "PATROL [%s] %s" % [route_id if route_id else "?", mode_str]
	_debug_label.modulate = _ROUTE_COLOR
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)


func _clear_debug_visual() -> void:
	if _debug_label != null:
		_debug_label.queue_free()
		_debug_label = null
