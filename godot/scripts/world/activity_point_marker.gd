@tool
class_name ActivityPointMarker3D
extends Marker3D

## Designer-placed activity point for the smart terrain system.
## NPCs compete for slots based on faction, distance, personality,
## and capacity. Drop one in the editor, set `kind` + `faction`,
## and the sim's squad planner will route NPCs here.
##
## Replaces the narrower `InteractionAreaMarker3D` for NPC goals
## (interaction areas remain for player-facing use). See
## `docs/book/src/planning/sim-overhaul-plan.md` Phase 2.

enum ActivityKind {
	GUARD_STATIC,
	GUARD_PERIMETER,
	PATROL_WAYPOINT,
	REST_SPOT,
	LOOKOUT,
	CAMPFIRE,
	WORKBENCH,
	STASH,
	SNIPER_NEST,
	AMBUSH_POINT,
}

@export var kind: ActivityKind = ActivityKind.GUARD_STATIC: set = _set_kind

## Perimeter/patrol waypoints sharing this id form a closed route.
## Empty for static points.
@export var loop_id: String = ""

## Static-post facing hint (degrees, clockwise from +Z).
@export var facing_yaw_deg: float = 0.0

## Restrict to a faction name (must match factions.toml ids).
## Empty = any faction.
@export var faction: String = "": set = _set_faction

## Arrival tolerance in meters.
@export var radius_m: float = 2.0: set = _set_radius

## Max NPCs that can use this point simultaneously.
@export var capacity: int = 1

## Higher = more desirable for NPC selection scoring.
@export var priority: int = 0

@export_group("Debug visual")
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"activity_points"
const _DEBUG_ALPHA: float = 0.6

const _COLOR_GUARD: Color = Color(0.85, 0.25, 0.25, _DEBUG_ALPHA)
const _COLOR_PATROL: Color = Color(0.55, 0.35, 0.85, _DEBUG_ALPHA)
const _COLOR_REST: Color = Color(0.40, 0.85, 0.45, _DEBUG_ALPHA)
const _COLOR_LOOKOUT: Color = Color(0.90, 0.80, 0.25, _DEBUG_ALPHA)
const _COLOR_CAMPFIRE: Color = Color(0.95, 0.55, 0.20, _DEBUG_ALPHA)
const _COLOR_WORKBENCH: Color = Color(0.55, 0.55, 0.70, _DEBUG_ALPHA)
const _COLOR_STASH: Color = Color(0.70, 0.50, 0.30, _DEBUG_ALPHA)
const _COLOR_SNIPER: Color = Color(0.30, 0.30, 0.30, _DEBUG_ALPHA)
const _COLOR_AMBUSH: Color = Color(0.60, 0.15, 0.15, _DEBUG_ALPHA)

var _debug_ring: MeshInstance3D = null
var _debug_label: Label3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if show_debug_visual:
		_rebuild_debug_visual()


func _ready() -> void:
	if not Engine.is_editor_hint():
		_snap_to_terrain()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


func _snap_to_terrain() -> void:
	var root := get_tree().current_scene if get_tree() else null
	if root == null: return
	var t3d := root.get_node_or_null("Terrain3D")
	if t3d == null: return
	var data = t3d.get("data")
	if data == null or not data.has_method("get_height"): return
	var h := float(data.call("get_height", Vector3(global_position.x, 0.0, global_position.z)))
	if not (is_nan(h) or is_inf(h)):
		global_position.y = h + 0.1


func _set_kind(v: ActivityKind) -> void:
	kind = v
	if is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()


func _set_faction(v: String) -> void:
	faction = v
	update_configuration_warnings()


func _set_radius(v: float) -> void:
	radius_m = maxf(v, 0.5)
	if is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if kind == ActivityKind.GUARD_PERIMETER and loop_id.strip_edges().is_empty():
		warnings.append("GUARD_PERIMETER needs a loop_id to form a route.")
	if kind == ActivityKind.PATROL_WAYPOINT and loop_id.strip_edges().is_empty():
		warnings.append("PATROL_WAYPOINT needs a loop_id to chain waypoints.")
	return warnings


func kind_name() -> String:
	match kind:
		ActivityKind.GUARD_STATIC: return "GUARD"
		ActivityKind.GUARD_PERIMETER: return "PERIMETER"
		ActivityKind.PATROL_WAYPOINT: return "PATROL"
		ActivityKind.REST_SPOT: return "REST"
		ActivityKind.LOOKOUT: return "LOOKOUT"
		ActivityKind.CAMPFIRE: return "CAMPFIRE"
		ActivityKind.WORKBENCH: return "WORKBENCH"
		ActivityKind.STASH: return "STASH"
		ActivityKind.SNIPER_NEST: return "SNIPER"
		ActivityKind.AMBUSH_POINT: return "AMBUSH"
	return "?"


func kind_color() -> Color:
	match kind:
		ActivityKind.GUARD_STATIC, ActivityKind.GUARD_PERIMETER:
			return _COLOR_GUARD
		ActivityKind.PATROL_WAYPOINT:
			return _COLOR_PATROL
		ActivityKind.REST_SPOT:
			return _COLOR_REST
		ActivityKind.LOOKOUT:
			return _COLOR_LOOKOUT
		ActivityKind.CAMPFIRE:
			return _COLOR_CAMPFIRE
		ActivityKind.WORKBENCH:
			return _COLOR_WORKBENCH
		ActivityKind.STASH:
			return _COLOR_STASH
		ActivityKind.SNIPER_NEST:
			return _COLOR_SNIPER
		ActivityKind.AMBUSH_POINT:
			return _COLOR_AMBUSH
	return Color.WHITE


func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not show_debug_visual:
		return
	if not is_inside_tree():
		return

	var tint := kind_color()

	_debug_ring = MeshInstance3D.new()
	_debug_ring.name = "_ActivityDebugRing"
	var torus := TorusMesh.new()
	torus.inner_radius = radius_m - 0.05
	torus.outer_radius = radius_m + 0.05
	torus.rings = 32
	torus.ring_segments = 8
	_debug_ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_debug_ring.material_override = mat
	add_child(_debug_ring, false, Node.INTERNAL_MODE_BACK)

	_debug_label = Label3D.new()
	_debug_label.name = "_ActivityDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, 1.2, 0.0)
	_debug_label.font_size = 20
	_debug_label.outline_size = 4
	_debug_label.text = kind_name()
	_debug_label.modulate = Color(tint.r, tint.g, tint.b, 1.0)
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)


func _clear_debug_visual() -> void:
	if _debug_ring != null:
		_debug_ring.queue_free()
		_debug_ring = null
	if _debug_label != null:
		_debug_label.queue_free()
		_debug_label = null
