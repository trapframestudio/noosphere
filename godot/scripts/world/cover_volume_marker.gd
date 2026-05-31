@tool
class_name CoverVolumeMarker3D
extends Node3D

## Designer-placed cover volume for the penetration system. Set
## `half_extents` to define the cover geometry dimensions, or point
## `mesh_source_path` at a nearby MeshInstance3D to derive from AABB.
##
## Material type drives projectile penetration: concrete stops all
## small arms, glass is concealment only, wood depends on thickness.
##
## See `docs/book/src/planning/sim-overhaul-plan.md` Phase 3.

enum CoverMaterial {
	CONCRETE,
	BRICK,
	STEEL_THICK,
	STEEL_THIN,
	WOOD_THICK,
	WOOD_THIN,
	SANDBAG,
	EARTH,
	GLASS,
	VEGETATION,
	VEHICLE_BODY,
}

enum CoverHeight {
	LOW,       ## Crouch/prone only (~0.9m)
	HIGH,      ## Standing (~1.5m)
	FULL,      ## Full body (~1.8m+)
}

enum ShapeSource {
	PRIMITIVE, ## Use child CollisionShape3D
	MESH,      ## Use referenced MeshInstance3D AABB
}

@export var material: CoverMaterial = CoverMaterial.CONCRETE: set = _set_material
@export var height: CoverHeight = CoverHeight.HIGH
@export var shape_source: ShapeSource = ShapeSource.PRIMITIVE

## Half-extents of the cover volume in meters. Used directly when
## shape_source == PRIMITIVE. When MESH, derived from the referenced
## MeshInstance3D's AABB.
@export var half_extents: Vector3 = Vector3(1.0, 1.0, 0.3): set = _set_half_extents

## Path to a MeshInstance3D when shape_source == MESH.
@export var mesh_source_path: NodePath = NodePath("")

## Material thickness in mm for penetration calculation.
@export var thickness_mm: float = 300.0

## Can this cover be destroyed by projectile damage?
@export var destructible: bool = false

## HP if destructible.
@export var health: float = 100.0

@export_group("Debug visual")
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"cover_volumes"
const _DEBUG_ALPHA: float = 0.35

const _MATERIAL_NAMES: Array[String] = [
	"Concrete", "Brick", "SteelThick", "SteelThin",
	"WoodThick", "WoodThin", "Sandbag", "Earth",
	"Glass", "Vegetation", "VehicleBody",
]

var _debug_box: MeshInstance3D = null
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


func _set_half_extents(v: Vector3) -> void:
	half_extents = Vector3(maxf(v.x, 0.1), maxf(v.y, 0.1), maxf(v.z, 0.1))
	if is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()


func _set_material(v: CoverMaterial) -> void:
	material = v
	if is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


func material_name() -> String:
	if material >= 0 and material < _MATERIAL_NAMES.size():
		return _MATERIAL_NAMES[material]
	return "Unknown"


func material_color() -> Color:
	match material:
		CoverMaterial.CONCRETE:
			return Color(0.6, 0.6, 0.6, _DEBUG_ALPHA)
		CoverMaterial.BRICK:
			return Color(0.7, 0.35, 0.25, _DEBUG_ALPHA)
		CoverMaterial.STEEL_THICK, CoverMaterial.STEEL_THIN:
			return Color(0.4, 0.5, 0.6, _DEBUG_ALPHA)
		CoverMaterial.WOOD_THICK, CoverMaterial.WOOD_THIN:
			return Color(0.55, 0.40, 0.25, _DEBUG_ALPHA)
		CoverMaterial.SANDBAG:
			return Color(0.6, 0.55, 0.4, _DEBUG_ALPHA)
		CoverMaterial.EARTH:
			return Color(0.45, 0.35, 0.25, _DEBUG_ALPHA)
		CoverMaterial.GLASS:
			return Color(0.7, 0.85, 0.95, _DEBUG_ALPHA)
		CoverMaterial.VEGETATION:
			return Color(0.3, 0.6, 0.25, _DEBUG_ALPHA)
		CoverMaterial.VEHICLE_BODY:
			return Color(0.35, 0.4, 0.35, _DEBUG_ALPHA)
	return Color(0.5, 0.5, 0.5, _DEBUG_ALPHA)


## Get the AABB half-extents for this cover volume.
func get_half_extents() -> Vector3:
	if shape_source == ShapeSource.PRIMITIVE:
		return half_extents
	elif shape_source == ShapeSource.MESH:
		if not mesh_source_path.is_empty():
			var mesh_node := get_node_or_null(mesh_source_path)
			if mesh_node is MeshInstance3D and mesh_node.mesh != null:
				var aabb: AABB = mesh_node.mesh.get_aabb()
				return aabb.size * 0.5
	return half_extents


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if shape_source == ShapeSource.PRIMITIVE:
		if half_extents.length() < 0.2:
			warnings.append("half_extents is very small — set the cover dimensions.")
	elif shape_source == ShapeSource.MESH:
		if mesh_source_path.is_empty():
			warnings.append("Shape source is MESH but mesh_source_path is empty.")
		else:
			var n := get_node_or_null(mesh_source_path)
			if n == null or not (n is MeshInstance3D):
				warnings.append("mesh_source_path doesn't point to a MeshInstance3D.")
	return warnings


func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not show_debug_visual:
		return
	if not is_inside_tree():
		return

	var he := get_half_extents()
	var tint := material_color()

	_debug_box = MeshInstance3D.new()
	_debug_box.name = "_CoverDebugBox"
	var box_mesh := BoxMesh.new()
	box_mesh.size = he * 2.0
	_debug_box.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_debug_box.material_override = mat
	add_child(_debug_box, false, Node.INTERNAL_MODE_BACK)

	_debug_label = Label3D.new()
	_debug_label.name = "_CoverDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, he.y + 0.5, 0.0)
	_debug_label.font_size = 16
	_debug_label.outline_size = 4
	var destr_str := " [DESTR]" if destructible else ""
	_debug_label.text = "%s %dmm%s" % [material_name(), int(thickness_mm), destr_str]
	_debug_label.modulate = Color(tint.r, tint.g, tint.b, 1.0)
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)


func _clear_debug_visual() -> void:
	if _debug_box != null:
		_debug_box.queue_free()
		_debug_box = null
	if _debug_label != null:
		_debug_label.queue_free()
		_debug_label = null
