@tool
class_name NavObstacleMarker3D
extends Node3D

## A scene-authored nav obstacle: an AABB the sim stamps into its
## `GridNavQuery` at region-attach time so NPCs path around it.
## Drop one in via **Add Node → search "NavObstacleMarker3D"**, set
## `extents` to the half-size of the footprint you want to block,
## and pick `override_kind`.
##
## **Phase B of `sim-iteration-5-13` (the nav pipeline iteration).**
## Designer-paintable nav lives in the Terrain3D slot system (slots
## 14 / 15 → `nav_mask.r8`, Phase A). This node covers the
## complementary case: **hand-placed obstacles** with bounded
## footprints — buildings, fences, jersey barriers, dropped trucks,
## prop bundles. The sim stamps these into the in-memory grid at
## attach time without persisting them to disk; deleting the marker
## removes the override on the next region attach.
##
## **Why a dedicated node instead of `PoiMarker3D` or
## `LootContainerMarker3D`?** This carries a different kind of data
## (per-AABB nav override) and gets routed by the bridge to
## `GridNavQuery::apply_obstacles` rather than the POI / container
## tables. Keeping it separate also keeps the marker enumeration
## cheap (filter by group, not by polymorphic dispatch).
##
## **Merge with Terrain3D nav paint** (`Heightmap::nav_override_at`):
## the painter wins. POI `block` doesn't downgrade a painter
## `ForceWalkable` (designer intent is the more deliberate signal).
## POI `walkable` is permitted but rare — mainly for catwalks
## attached to placed structures. See
## `crates/simn-sim/src/nav.rs::GridNavQuery::apply_obstacles`
## for the resolver.

## What this obstacle does to overlapping nav cells.
##
## - `BLOCK` — cells inside the AABB flip to impassable (unless
##   the painter declared `ForceWalkable` for them, which wins).
##   The common case: buildings, fences.
## - `WALKABLE` — cells inside the AABB flip to passable
##   regardless of slope / `FeatureClass`. Rare; for catwalk-on-
##   cliff overlays or scripted-route carve-throughs paired with
##   a placed prop.
enum OverrideKind {
	BLOCK,
	WALKABLE,
}

## AABB half-size on each axis. Sim consumes only XZ (`x`, `z`);
## Y is the editor gizmo's box height for readability. Default
## 1×1 m (so `Vector3(1, 1, 1)` covers a 2 m square footprint).
@export var extents: Vector3 = Vector3(1.0, 1.0, 1.0): set = _set_extents

## What overlapping nav cells become. Default BLOCK matches the
## "drop a building, it blocks NPCs" expected case.
@export var override_kind: OverrideKind = OverrideKind.BLOCK:
	set = _set_override_kind

@export_group("Debug visual")
## Toggle the wireframe gizmo + label in the editor. Off in builds
## (the sim's `GridNavQuery::apply_obstacles` is the runtime
## consumer; this node is purely an authoring + visualization
## surface).
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"nav_obstacle_markers"
const _DEBUG_ALPHA: float = 0.55

# Color tints per kind so a glance at the editor view tells you
# whether a marker is blocking or carving.
const _COLOR_BLOCK: Color = Color(0.95, 0.35, 0.30, _DEBUG_ALPHA)
const _COLOR_WALKABLE: Color = Color(0.30, 0.85, 0.45, _DEBUG_ALPHA)

var _debug_box: MeshInstance3D = null
var _debug_label: Label3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


# --- Setters ----------------------------------------------------

func _set_extents(v: Vector3) -> void:
	# Clamp to a sane minimum so the gizmo never collapses to a
	# zero-volume box (Godot warns + the wireframe disappears).
	extents = Vector3(maxf(v.x, 0.05), maxf(v.y, 0.05), maxf(v.z, 0.05))
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()
	update_configuration_warnings()


func _set_override_kind(v: OverrideKind) -> void:
	override_kind = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


# --- Configuration warnings -------------------------------------

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	# Anything smaller than the sim's nav cell (2 m default) won't
	# overlap any cell center reliably, so the obstacle becomes a
	# no-op. Authors hitting this are usually misreading the gizmo
	# as marking the corner instead of the center.
	const NAV_CELL_M: float = 2.0
	if extents.x * 2.0 < NAV_CELL_M or extents.z * 2.0 < NAV_CELL_M:
		warnings.append(
			"extents XZ footprint is smaller than one nav cell (%.1f m). "
				% NAV_CELL_M
				+ "The obstacle may not overlap any cell center and "
				+ "become a runtime no-op. Increase extents.x / extents.z."
		)
	return warnings


# --- Debug visual -----------------------------------------------

func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return
	_debug_box = MeshInstance3D.new()
	_debug_box.name = "_NavObstacleDebugBox"
	var box := BoxMesh.new()
	# Box size = full extent on each axis (extents is half-size).
	box.size = extents * 2.0
	_debug_box.mesh = box
	add_child(_debug_box, false, Node.INTERNAL_MODE_BACK)

	_debug_label = Label3D.new()
	_debug_label.name = "_NavObstacleDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	# Match NPC `StateLabel`'s world-scaling sizing — `fixed_size =
	# true` rendered the label at constant screen size so distant
	# markers stamped huge text across the viewport.
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, extents.y + 0.5, 0.0)
	_debug_label.font_size = 22
	_debug_label.outline_size = 4
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)

	_apply_debug_appearance()


func _clear_debug_visual() -> void:
	if _debug_box != null:
		_debug_box.queue_free()
		_debug_box = null
	if _debug_label != null:
		_debug_label.queue_free()
		_debug_label = null


func _apply_debug_appearance() -> void:
	if _debug_box == null and _debug_label == null:
		return
	var tint := _COLOR_BLOCK if override_kind == OverrideKind.BLOCK else _COLOR_WALKABLE
	if _debug_box != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = false
		# Wireframe-ish read: backside cull off + slight emissive so
		# the box reads through other geometry at editor distance.
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.emission_enabled = true
		mat.emission = tint
		mat.emission_energy_multiplier = 0.35
		_debug_box.material_override = mat
	if _debug_label != null:
		var text := "NAV BLOCK" if override_kind == OverrideKind.BLOCK else "NAV WALKABLE"
		_debug_label.text = text
		_debug_label.modulate = Color(tint.r, tint.g, tint.b, 1.0)
