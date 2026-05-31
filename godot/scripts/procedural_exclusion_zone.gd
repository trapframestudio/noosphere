@tool
class_name ProceduralExclusionZone
extends Node3D

## Marks a 3D volume where procedural systems (TreeScatter,
## RockScatter, GroundCoverScatter, TreeCoverageBaker,
## TreeClusterScatter, TrashScatter) test placements. Drop one over a
## POI you intend to hand-detail — buildings, hand-decorated landmarks,
## ruins, road junctions — and the procedural pipeline carves a
## clean hole around it (or boosts trash density, depending on the
## per-system multiplier the zone declares).
##
## **Sizing.** The zone is a unit primitive (1×1×1 bounding box,
## centered at the node's origin), sized entirely via the node's own
## `transform.scale`. Set `scale = (W, H, D)` and the zone's world
## bounding-box is W × H × D meters. The X/Y/Z components are
## independent — a `(100, 5, 50)` scale makes a flat-ish rectangular
## (or elliptical) volume.
##
## **Shape modes** — pick the right footprint for the POI:
##
## - `CYLINDER` (default): elliptical XZ cross-section, finite Y.
##   With uniform XZ scale, classic cylinder. With non-uniform
##   `(scale.x ≠ scale.z)`, the cross-section is an ellipse aligned
##   to local axes. Test: point lies inside the unit cylinder
##   `lx² + lz² ≤ 0.25 ∧ |ly| ≤ 0.5` after `to_local()`.
## - `BOX`: full 3D rectangular volume. Test: `|lx|, |ly|, |lz| ≤ 0.5`
##   after `to_local()`. Box zones rotate with the node's transform.
##
## **3D test.** Both shapes test full XYZ. A zone short in Y (e.g.
## `scale.y = 5`) excludes only that 5 m vertical slice — points
## above or below pass through. If you want infinite-Y exclusion
## (the legacy behavior), set `scale.y` very large.
##
## **How scatters consume**: any Node added to the
## `procedural_exclusion_zones` group is queryable via
## `density_multiplier(world_x, world_y, world_z, system)` and
## related static helpers. Nodes auto-register on `_enter_tree` and
## unregister on `_exit_tree`, so moving a zone around the editor or
## instancing/freeing one in code Just Works.
##
## **Cost**: per-candidate iteration of all zones in the scene + one
## `to_local()` + axis-test per zone (~10 ops). Cheap up to ~50
## zones; at hundreds, switch to a spatial hash. Currently expected:
## ~5–20 zones per map.

enum Shape { CYLINDER, BOX }

@export var shape: Shape = Shape.CYLINDER: set = _set_shape

@export_group("Per-system density multipliers")
## Multiplier applied to tree-scatter accept probability inside this
## zone. 0.0 = full exclusion (no trees ever; default). 1.0 = no
## suppression. Intermediate values thin: 0.1 = ~10% of normal density,
## 0.5 = half density. Multiple overlapping zones stack toward MORE
## suppression (the lowest mul wins).
##
## Use case: a "town" zone might set tree=0.1 (sparse trees in
## settlements), rock=0.05 (almost no wild rocks), ground_cover=0.5
## (still grassy but less wild ferns) to produce a settlement that
## looks lived-in without going completely sterile.
@export_range(0.0, 1.0, 0.05) var tree_density_mul: float = 0.0
@export_range(0.0, 1.0, 0.05) var rock_density_mul: float = 0.0
@export_range(0.0, 1.0, 0.05) var ground_cover_density_mul: float = 0.0
## Multiplier on trash-scatter accept probability inside this zone.
## **Range up to 10.0** (vs. the others' 0–1) because trash zones
## are typically used to BOOST density inside town/POI zones, not
## exclude. 0.0 = no trash here; 1.0 = baseline trash density (same
## as off-road trail level); 5.0 = town-grade trash density (lots of
## street litter, garbage piles); 10.0 = "abandoned dump" hot spot.
##
## Combined with TrashScatter's road-type curve so a town zone
## intersecting a paved road still benefits from BOTH (zone boost
## stacks multiplicatively with road score). Outside any zone, trash
## density falls back to the road-driven baseline.
@export_range(0.0, 10.0, 0.1) var trash_density_mul: float = 0.0
## Optional human-readable label that shows up in the scene tree
## helper text and in `_get_configuration_warnings`. Doesn't affect
## anything mechanical — purely for the user to identify which
## exclusion belongs to which planned POI.
@export var zone_name: String = ""
## Show a translucent shape in the editor 3D viewport at this
## zone's footprint. Off in builds (Engine.is_editor_hint() ==
## false) so the visualization never ships.
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"procedural_exclusion_zones"
const _DEBUG_ALPHA: float = 0.25

var _debug_mesh: MeshInstance3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


func _set_shape(v: Shape) -> void:
	shape = v
	_rebuild_debug_visual()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_mesh()


## Single-point query — does world point (`wx`, `wy`, `wz`) fall
## inside any exclusion zone in the scene? Iterates all
## `procedural_exclusion_zones` group members and returns true on
## first hit. Kept for back-compat; new callers should use
## `density_multiplier` instead.
##
## Pass `tree` so this is callable from `@tool` scatters that don't
## have direct access to `get_tree()` in all code paths.
static func is_point_excluded(tree: SceneTree, wx: float, wy: float,
		wz: float) -> bool:
	if tree == null:
		return false
	var zones: Array[Node] = tree.get_nodes_in_group(_GROUP)
	for z in zones:
		if not (z is ProceduralExclusionZone):
			continue
		var zone: ProceduralExclusionZone = z
		if zone._contains_world_xyz(wx, wy, wz):
			return true
	return false


## Soft-exclusion query — returns the per-system density multiplier
## active at world point (`wx`, `wy`, `wz`) for the given system.
## 1.0 = no suppression (no zones contain the point), 0.0 = full
## exclusion (at least one zone with mul=0 contains the point).
## Intermediate values mean thinning. Multiple overlapping zones
## stack toward MORE suppression — `min` across all containing zones
## wins.
##
## Valid `system` keys: "trees", "rocks", "ground_cover".
## Caller multiplies its accept_p by the returned multiplier; a
## subsequent `randf() > accept_p` check rejects accordingly.
static func density_multiplier(tree: SceneTree, wx: float, wy: float,
		wz: float, system: String) -> float:
	if tree == null:
		return 1.0
	var zones: Array[Node] = tree.get_nodes_in_group(_GROUP)
	if zones.is_empty():
		return 1.0
	var mul: float = 1.0
	for z in zones:
		if not (z is ProceduralExclusionZone):
			continue
		var zone: ProceduralExclusionZone = z
		if not zone._contains_world_xyz(wx, wy, wz):
			continue
		var zmul: float
		match system:
			"trees":
				zmul = zone.tree_density_mul
			"rocks":
				zmul = zone.rock_density_mul
			"ground_cover":
				zmul = zone.ground_cover_density_mul
			_:
				continue
		if zmul < mul:
			mul = zmul
		# Fast exit on full exclusion — no further zones can lower
		# this; the candidate is already gone.
		if mul <= 0.0:
			return 0.0
	return mul


## Static query: maximum `trash_density_mul` across all zones
## containing world point (`wx`, `wy`, `wz`). Returns 0.0 if no zones
## touch the point.
##
## Aggregation is **MAX** (vs. `density_multiplier`'s MIN) because
## trash zones are boost-style: a town zone explicitly enables
## trash spawn there. Outside any zone, the road-based baseline
## decides — see TrashScatter for the composition.
static func trash_zone_boost(tree: SceneTree, wx: float, wy: float,
		wz: float) -> float:
	if tree == null:
		return 0.0
	var zones: Array[Node] = tree.get_nodes_in_group(_GROUP)
	if zones.is_empty():
		return 0.0
	var max_boost: float = 0.0
	for z in zones:
		if not (z is ProceduralExclusionZone):
			continue
		var zone: ProceduralExclusionZone = z
		if not zone._contains_world_xyz(wx, wy, wz):
			continue
		if zone.trash_density_mul > max_boost:
			max_boost = zone.trash_density_mul
	return max_boost


# Per-shape point-in-zone test against unit primitives in local
# space. Both shapes use `to_local()` so rotation, translation, and
# non-uniform scale on the node (or any ancestor) all factor in
# automatically — visual and test always agree.
#
# Unit conventions:
#   CYLINDER → unit cylinder centered at origin, radius 0.5,
#              height 1 (XZ disc, finite Y)
#   BOX      → unit cube centered at origin, side 1
# So with `transform.scale = (W, H, D)` the world bounding box of
# either primitive is W × H × D meters.
#
# A zone with `scale.y` smaller than the actual zone-of-interest's
# vertical extent will let candidates above or below the slab pass
# through — that's the point of the 3D test. If you want
# legacy-style infinite-Y exclusion, set `scale.y` to something
# much larger than the terrain Y range (e.g. 10000.0).
func _contains_world_xyz(wx: float, wy: float, wz: float) -> bool:
	var local: Vector3 = to_local(Vector3(wx, wy, wz))
	if absf(local.y) > 0.5:
		return false
	match shape:
		Shape.CYLINDER:
			return local.x * local.x + local.z * local.z <= 0.25
		Shape.BOX:
			return absf(local.x) <= 0.5 and absf(local.z) <= 0.5
		_:
			return false


# --- Editor visualization ----------------------------------------

func _rebuild_debug_visual() -> void:
	_clear_debug_mesh()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return
	_debug_mesh = MeshInstance3D.new()
	_debug_mesh.name = "_ExclusionDebugVisual"
	_debug_mesh.mesh = _build_debug_mesh()
	_debug_mesh.material_override = _build_debug_material()
	add_child(_debug_mesh, false, Node.INTERNAL_MODE_BACK)


# Unit primitives. Both fit a 1×1×1 bounding box centered at origin,
# so the debug visual scales 1:1 with the node's transform. The
# tests in `_contains_world_xyz` use the same unit bounds.
func _build_debug_mesh() -> Mesh:
	match shape:
		Shape.CYLINDER:
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.5
			cyl.bottom_radius = 0.5
			cyl.height = 1.0
			return cyl
		Shape.BOX:
			var box := BoxMesh.new()
			box.size = Vector3.ONE
			return box
		_:
			return null


func _build_debug_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# Per-zone hue via name hash so adjacent zones distinguish at
	# a glance + stay deterministic across reloads.
	var h: float = float(name.hash() % 360) / 360.0
	mat.albedo_color = Color.from_hsv(h, 0.65, 1.0, _DEBUG_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = 10
	return mat


func _clear_debug_mesh() -> void:
	if _debug_mesh != null and is_instance_valid(_debug_mesh):
		_debug_mesh.queue_free()
	_debug_mesh = null


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	# Zero scale on any axis collapses the zone to a degenerate
	# slab/line/point — nothing inside it. Catch the common authoring
	# mistake of leaving scale.y at 0 after using a 2D-only gizmo
	# manipulator.
	var s: Vector3 = scale
	if s.x <= 0.0 or s.y <= 0.0 or s.z <= 0.0:
		warnings.append(
			"transform.scale must be > 0 on all axes (current: %s) — "
			% str(s)
			+ "the zone has zero volume and won't mask anything.")
	return warnings
