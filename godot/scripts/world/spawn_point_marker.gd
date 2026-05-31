@tool
class_name SpawnPointMarker3D
extends Marker3D

## Designer-placed spawn point. Controls which faction spawns here,
## at what rate, and with what squad configuration. The sim checks
## authored spawn points before falling back to PopulationTargets.
##
## See `docs/book/src/planning/sim-overhaul-plan.md` Phase 2G.

## Which faction spawns here. Must match a factions.toml id.
@export var faction: String = "": set = _set_faction

## Squads per minute. 0 = one-shot (spawn once on region attach).
@export var spawn_rate: float = 1.0

## Max alive squads from this spawner at once.
@export var max_concurrent: int = 3

@export var squad_size_min: int = 3
@export var squad_size_max: int = 5

## Spawn jitter radius around the marker position (meters).
@export var spread_radius_m: float = 15.0: set = _set_spread

## Toggle without deleting the marker.
@export var enabled: bool = true

## Delay before first spawn (seconds, converted to ticks at registration).
@export var initial_delay_s: float = 0.0

## 0 = faction default. 1-5 = specific gear tier.
@export var loadout_tier: int = 0

@export_group("Debug visual")
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"spawn_points"
const _DEBUG_ALPHA: float = 0.4
const _COLOR_SPAWN: Color = Color(0.2, 0.8, 1.0, _DEBUG_ALPHA)

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
		global_position.y = h


func _set_faction(v: String) -> void:
	faction = v
	if is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()
	update_configuration_warnings()


func _set_spread(v: float) -> void:
	spread_radius_m = maxf(v, 1.0)
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
	if faction.strip_edges().is_empty():
		warnings.append("faction is empty — no NPCs will spawn.")
	if squad_size_min > squad_size_max:
		warnings.append("squad_size_min > squad_size_max.")
	if squad_size_min < 1:
		warnings.append("squad_size_min must be >= 1.")
	return warnings


func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not show_debug_visual:
		return
	if not is_inside_tree():
		return

	_debug_ring = MeshInstance3D.new()
	_debug_ring.name = "_SpawnDebugRing"
	var torus := TorusMesh.new()
	torus.inner_radius = spread_radius_m - 0.1
	torus.outer_radius = spread_radius_m + 0.1
	torus.rings = 32
	torus.ring_segments = 8
	_debug_ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _COLOR_SPAWN
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_debug_ring.material_override = mat
	add_child(_debug_ring, false, Node.INTERNAL_MODE_BACK)

	_debug_label = Label3D.new()
	_debug_label.name = "_SpawnDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, 1.5, 0.0)
	_debug_label.font_size = 18
	_debug_label.outline_size = 4
	var rate_str := "one-shot" if spawn_rate <= 0.0 else "%.1f/min" % spawn_rate
	_debug_label.text = "SPAWN [%s] %s" % [faction.to_upper() if faction else "?", rate_str]
	_debug_label.modulate = Color(0.2, 0.8, 1.0, 1.0)
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)


func _clear_debug_visual() -> void:
	if _debug_ring != null:
		_debug_ring.queue_free()
		_debug_ring = null
	if _debug_label != null:
		_debug_label.queue_free()
		_debug_label = null
