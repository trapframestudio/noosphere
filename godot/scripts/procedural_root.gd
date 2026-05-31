@tool
class_name ProceduralRoot
extends Node3D

# Stable script ref for `.new()` and enum access in @tool context —
# bare `ProceduralExclusionZone.new()` can fail after script reloads
# if the global class_name registry hasn't re-cached. See the same
# const block in `tree_scatter.gd`.
const _ExclusionZoneRef := preload("res://scripts/procedural_exclusion_zone.gd")

## High-level coordinator for all procedurally-generated content in
## the scene — vegetation (trees + ground cover), rocks / boulders,
## props (trash, signage, decorations, etc.). Provides master enable
## / density / view-distance levers that propagate to per-type
## subnodes.
##
## **Scene tree convention** — children grouped by content type:
##
##   Procedural (this script)
##     Vegetation (Node3D, holds TreeScatter, GroundCoverScatter,
##                 TreeCoverageBaker)
##     Rocks      (Node3D, future — rock / boulder scatter)
##     Props      (Node3D, future — trash / road / city decoration scatter)
##
## Per-type subnodes can be enabled / disabled wholesale via the
## `enable_*` exports below. The cascade reaches into each child
## scatter and sets `editor_preview = false`, which clears its baked
## tiles and stops `_process` work — same pathway the per-scatter
## inspector toggle uses, just driven from a single master.
##
## Master density / view-distance multipliers compose with each
## scatter's own per-biome settings — a master `0.5` density setting
## halves what the scatter would otherwise place; setting the master
## back to `1.0` restores baseline.
##
## **Why @tool**: cascading happens in the editor too, so artists can
## flip toggles and see the result without entering play mode.
## Bakers (TreeCoverageBaker) are unaffected by the enable cascade —
## they're one-shot tools, not runtime scatters; their `Bake now`
## button stays usable regardless.

# PackedStringArray initialiser isn't a `const` expression in
# GDScript 4 — using `static var` (write-once-effectively-const).
static var _GROUP_NAMES: PackedStringArray = PackedStringArray(
	["Vegetation", "Rocks", "Props"])

@export_group("Master enables")
## Toggle the entire vegetation subgroup. When false, every
## TreeScatter / GroundCoverScatter under `Vegetation/` has its
## `editor_preview` flipped off → tiles cleared, `_process` short-
## circuits, runtime cost drops to ~zero.
@export var enable_vegetation: bool = true: set = _set_enable_vegetation
## Toggle rocks / boulders subgroup. No-op until rock scatters land
## under `Rocks/`. Reserved so the API surface stays stable across
## the upcoming rock / boulder integration.
@export var enable_rocks: bool = true: set = _set_enable_rocks
## Toggle trash / decoration props subgroup. No-op until prop
## scatters land under `Props/`. Reserved for the upcoming city /
## road decoration pass.
@export var enable_props: bool = true: set = _set_enable_props

@export_group("Master density")
## Global density multiplier composed on top of each scatter's own
## per-biome density. 1.0 = scatters use their baseline densities;
## 0.5 = half density across all procedural systems; 2.0 = double.
## Useful as a "performance preset" knob — a single drag scales
## the whole world's procedural-content density at once.
@export_range(0.0, 4.0, 0.05) var global_density: float = 1.0: \
	set = _set_global_density

@export_group("Master view distance")
## Multiplier on each scatter's `active_radius_m`. <1 trims render
## distance (CPU/GPU savings, content fades in closer); >1 extends
## (more visible content, heavier). Combine with `global_density`
## for a coarse "low / med / high" quality preset.
@export_range(0.1, 4.0, 0.05) var global_view_distance: float = 1.0: \
	set = _set_global_view_distance

@export_group("Exclusion zone helper")
## Drop a `ProceduralExclusionZone` at the editor viewport camera's
## current look-at point (projected forward `add_zone_distance_m`,
## ground-snapped to the terrain heightmap if available). Saves the
## "spawned at world origin, now I have to drag it across the entire
## map" pain when carving out POIs. The new zone is created as a
## child of this `Procedural` node, selected in the editor for
## immediate editing, and pre-configured with the multiplier defaults
## below.
@export_tool_button("Add exclusion zone at view target", "Add") \
	var add_zone_action: Callable = _add_zone_at_view_target
## How far in front of the editor camera to place the new zone.
## Smaller = closer to camera (good when zoomed in on a POI);
## larger = further out (good when surveying the map from height).
@export_range(2.0, 200.0, 1.0) var add_zone_distance_m: float = 25.0
## Default world-space size for the spawned zone (X × Y × Z meters).
## Applied as `transform.scale` on the new node — the zone is a unit
## primitive (1×1×1 cube / inscribed cylinder) sized exclusively by
## its own transform. Default `(60, 16, 60)` = a 60 m diameter
## cylinder, 16 m tall.
@export var add_zone_size_m: Vector3 = Vector3(60.0, 16.0, 60.0)
@export_subgroup("Default density multipliers")
## Defaults applied to the spawned zone's per-system density mults.
## 0 = full exclusion; 1 = no suppression. Default is full clearance
## across all three so the zone is a clean canvas for hand-placed
## detail (buildings, hand-scattered ground cover, etc.). If you
## want a "town with auto-grass" zone, bump `add_zone_ground_cover_mul`
## to 0.3-0.6 BEFORE clicking Add.
@export_range(0.0, 1.0, 0.05) var add_zone_tree_mul: float = 0.0
@export_range(0.0, 1.0, 0.05) var add_zone_rock_mul: float = 0.0
@export_range(0.0, 1.0, 0.05) var add_zone_ground_cover_mul: float = 0.0


func _ready() -> void:
	# Push current state to children on scene load so they pick up
	# the cascade even if the user authored values in the inspector
	# before adding child scatters.
	_propagate_all()


func _set_enable_vegetation(v: bool) -> void:
	enable_vegetation = v
	if is_inside_tree():
		_propagate_enable("Vegetation", v)


func _set_enable_rocks(v: bool) -> void:
	enable_rocks = v
	if is_inside_tree():
		_propagate_enable("Rocks", v)


func _set_enable_props(v: bool) -> void:
	enable_props = v
	if is_inside_tree():
		_propagate_enable("Props", v)


func _set_global_density(v: float) -> void:
	global_density = v
	if is_inside_tree():
		_propagate_density()


func _set_global_view_distance(v: float) -> void:
	global_view_distance = v
	if is_inside_tree():
		_propagate_view_distance()


func _propagate_all() -> void:
	_propagate_enable("Vegetation", enable_vegetation)
	_propagate_enable("Rocks", enable_rocks)
	_propagate_enable("Props", enable_props)
	_propagate_density()
	_propagate_view_distance()


func _propagate_enable(group_name: String, enabled: bool) -> void:
	var group: Node = get_node_or_null(group_name)
	if group == null:
		return
	for child in group.get_children():
		# Only runtime scatters expose editor_preview — bakers (one-
		# shot tools) don't, and shouldn't be toggled.
		if "editor_preview" in child:
			child.editor_preview = enabled


func _propagate_density() -> void:
	for group_name in _GROUP_NAMES:
		var group: Node = get_node_or_null(group_name)
		if group == null:
			continue
		for child in group.get_children():
			# Each scatter exposes its own density_multiplier; the
			# master is composed on top via simple multiply.
			# Scatters re-bake on density change via their existing
			# property setters / _process gates.
			if "density_multiplier" in child:
				child.density_multiplier = global_density


func _propagate_view_distance() -> void:
	for group_name in _GROUP_NAMES:
		var group: Node = get_node_or_null(group_name)
		if group == null:
			continue
		for child in group.get_children():
			# Scatters keep a `_base_active_radius_m` baseline (set
			# at first encounter) and the master scales it. If the
			# scatter doesn't expose this it just keeps its
			# author-set radius — the master is a no-op for that one.
			if "active_radius_m" in child and "_base_active_radius_m" in child:
				if child._base_active_radius_m <= 0.0:
					child._base_active_radius_m = child.active_radius_m
				child.active_radius_m = (
					child._base_active_radius_m * global_view_distance)


# --- Exclusion-zone helper -----------------------------------------

func _add_zone_at_view_target() -> void:
	if not Engine.is_editor_hint():
		push_warning("[procedural] Add zone is editor-only.")
		return
	var target: Vector3 = _editor_view_target()
	var zone := _ExclusionZoneRef.new()
	# Sequential default name — `Zone`, `Zone2`, `Zone3`… so the user
	# doesn't have to dismiss a name collision dialog.
	var idx: int = 1
	var base_name := "Zone"
	while get_node_or_null(base_name) != null:
		idx += 1
		base_name = "Zone%d" % idx
	zone.name = base_name
	zone.shape = _ExclusionZoneRef.Shape.CYLINDER
	zone.tree_density_mul = add_zone_tree_mul
	zone.rock_density_mul = add_zone_rock_mul
	zone.ground_cover_density_mul = add_zone_ground_cover_mul
	zone.zone_name = base_name
	add_child(zone)
	# Owner = scene root so the zone serializes into the .tscn instead
	# of disappearing on next scene load.
	var scene_root: Node = get_tree().edited_scene_root
	if scene_root != null:
		zone.owner = scene_root
	# Set position + size AFTER adding to tree so global_position
	# resolves cleanly. Size lives on the transform basis (the zone
	# is a unit primitive scaled by its transform).
	zone.global_position = target
	zone.scale = add_zone_size_m
	# Auto-select the new zone for immediate radius / position tweaking.
	var sel: EditorSelection = EditorInterface.get_selection()
	if sel != null:
		sel.clear()
		sel.add_node(zone)
	print("[procedural] dropped %s at %v (size %v m)"
		% [zone.name, target, add_zone_size_m])


# Compute a world-space target point ~`add_zone_distance_m` in front
# of the editor camera, ground-snapped to terrain heightmap (via the
# Terrain3D node if present in the scene). Falls back to the raw
# forward projection if no terrain reference is available.
func _editor_view_target() -> Vector3:
	var vp = EditorInterface.get_editor_viewport_3d()
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		# Fallback: this node's own origin.
		return global_position
	var origin: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z.normalized()
	var target: Vector3 = origin + fwd * add_zone_distance_m
	# Ground-snap: prefer Terrain3D `data.get_height()` if a Terrain3D
	# node is reachable from the scene root, otherwise leave the Y as
	# the camera projection (user can drag down).
	var t3d: Node = _find_terrain3d()
	if t3d != null and t3d.has_method("get") and t3d.get("data") != null:
		var h: float = t3d.data.get_height(Vector3(target.x, 0.0, target.z))
		if not is_nan(h):
			target.y = h
	return target


func _find_terrain3d() -> Node:
	# Walk siblings + scene tree looking for a Terrain3D-typed node.
	# Cheap O(N) scan that runs once per button click.
	var root: Node = get_tree().edited_scene_root
	if root == null:
		root = get_tree().root
	return _find_node_by_type_string(root, "Terrain3D")


func _find_node_by_type_string(n: Node, type_name: String) -> Node:
	if n.get_class() == type_name:
		return n
	for c in n.get_children():
		var found: Node = _find_node_by_type_string(c, type_name)
		if found != null:
			return found
	return null


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	for group_name in _GROUP_NAMES:
		if get_node_or_null(group_name) == null:
			continue
		var group: Node = get_node(group_name)
		var has_scatter: bool = false
		for child in group.get_children():
			if "editor_preview" in child:
				has_scatter = true
				break
		if not has_scatter and group.get_child_count() > 0:
			warnings.append(("%s group has children but none expose"
				+ " `editor_preview` — enable cascade won't reach them."
				) % group_name)
	return warnings
