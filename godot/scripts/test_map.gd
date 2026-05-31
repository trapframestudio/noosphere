extends Node3D
## Base script for both test maps.
##
## Procedurally adds engine-native scale references so we don't have
## to maintain a hundred marker nodes by hand in two .tscn files:
##
## - **Origin compass.** Four short posts at the spawn point, one per
##   cardinal direction, each labeled (N, E, S, W). Gives instant
##   orientation when you can't see anything else.
## - **Inner ruler.** White posts every 100 m on +X / +Z out to 500 m.
##   Near-field scale.
## - **Outer ruler.** Tall orange posts every 500 m on +X / +Z out to
##   `ruler_max_meters`. Visible far across the 5 km plane.
##
## Subclasses (well, instances using this script) can override
## `marker_color` to differentiate maps.

@export var marker_color: Color = Color(0.95, 0.95, 0.95)
@export var floor_color: Color = Color(0.4, 0.55, 0.4)
## Which sim region this scene represents. Used to query
## `SimHost.region_transitions()` at load time so transition cubes
## spawn at sim-authoritative positions — scene authors don't have
## to keep both sides in sync by hand.
@export var region_id: String = ""
@export var ruler_max_meters: int = 2500
@export var ruler_step_meters: int = 500
@export var inner_step_meters: int = 100
@export var inner_max_meters: int = 500

## Mountain ring around the playable area. Temporary visual containment
## until real terrain lands.
@export var map_half_extent_m: float = 2500.0
@export var mountain_ring_offset_m: float = 200.0
@export var mountain_count: int = 220
@export var mountain_color: Color = Color(0.42, 0.36, 0.32)
@export var mountain_seed: int = 1


## Cached references resolved in `_ready` so `_process` can update
## lighting and fog without re-walking the scene tree every frame.
var _sun: DirectionalLight3D = null
var _moon: DirectionalLight3D = null
var _env: Environment = null
var _base_fog_density: float = -1.0
var _base_fog_color: Color = Color(0, 0, 0)
var _base_bg_color: Color = Color(0, 0, 0)

## Base lerp rates for weather transitions. Heavy weather (rain,
## storm, wind) transitions slowly so fronts read as rolling in;
## light shifts (clear ↔ overcast ↔ partly cloudy) move faster
## since they're subtle and shouldn't feel laggy.
const WEATHER_LERP_RATE_FAST: float = 0.08  # ~15s for gentle shifts
const WEATHER_LERP_RATE_SLOW: float = 0.02  # ~60s for storm fronts
## Current visual weight per weather kind in [0..1]. Sums to ≈1 but
## not enforced — lerping is per-kind so transitions cross-fade.
var _weather_weights: Dictionary = {
	"clear": 0.0,
	"partly_cloudy": 0.0,
	"overcast": 0.0,
	"marine_layer": 0.0,
	"fog": 0.0,
	"drizzle": 0.0,
	"light_rain": 0.0,
	"heavy_rain": 0.0,
	"windstorm": 0.0,
	"thunderstorm": 0.0,
	"smoke_haze": 0.0,
}
## First update snaps weights to the sim's current weather instead
## of lerping from zero. Set false after first `_update_sky` call.
var _weather_first_frame: bool = true


func _ready() -> void:
	_apply_floor_color()
	_request_region_terrain()
	var ruler := Node3D.new()
	ruler.name = "Ruler"
	add_child(ruler)
	_build_compass(ruler)
	_build_inner_ruler(ruler)
	_build_outer_ruler(ruler)
	_build_mountain_ring()
	# Terrain3D heights are pushed to the sim in _request_region_terrain
	# before this point, so Y-snapping in register_authored_base works.
	_spawn_transition_cubes_from_sim()
	_spawn_authored_bases()
	_register_activity_points()
	_cache_sky_refs()


## Register all ActivityPointMarker3D, PatrolRouteMarker3D,
## SpawnPointMarker3D, and CoverVolumeMarker3D nodes with the sim.
func _register_activity_points() -> void:
	if region_id.is_empty():
		return
	var spawner = load("res://scripts/world/activity_point_spawner.gd")
	if spawner != null:
		var n: int = int(spawner.call(
			"spawn_activity_points", get_tree(), region_id
		))
		if n > 0:
			print("[test_map] registered %d activity/patrol/spawn/cover points" % n)


func _on_terrain_ready_spawn_transitions(_map_id: String) -> void:
	_spawn_transition_cubes_from_sim()
	_spawn_authored_bases()


## Iteration 5-14 Phase E. Walk the scene tree for `PoiMarker3D`
## nodes with `BASE_*` kinds and register them with the sim. Runs
## once after terrain is ready so Y-snapping picks up the real
## surface. No-op if the spawner script is missing.
func _spawn_authored_bases() -> void:
	if region_id.is_empty():
		return
	var spawner := load("res://scripts/world/base_spawner.gd")
	if spawner == null:
		return
	var n: int = int(spawner.call("spawn_authored_bases", get_tree(), region_id))
	if n > 0:
		print("[test_map] registered %d authored base(s)" % n)


## Tell the sim which heightmap belongs to this region so bases get
## Y-snapped to ground and NPCs walk the surface. Two paths:
##
## 1. **Live Terrain3D push (preferred).** Walks the sibling
##    Terrain3D's per-pixel height grid and pushes the f32 buffer
##    directly to the sim via `attach_region_terrain_from_packed_heights`.
##    Cuts the canonical `.r32` out of the runtime Y-snap path so
##    `Terrain3DLoader.bake_into` drift (canonical → Terrain3D loses
##    10-20 m of precision per region) can't desync the sim from
##    what Terrain3D renders.
##
## 2. **Legacy canonical (fallback).** If Terrain3D isn't a sibling
##    or doesn't have data loaded yet, fall back to
##    `sim.load_region_terrain(region_id, map_id)` which reads
##    `heightmap.r32` from disk. Production maps (real_map.gd) and
##    any scene without Terrain3D still use this path.
func _request_region_terrain() -> void:
	if region_id.is_empty():
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null:
		return
	# Iteration 5-13 Phase B2: stamp scene-placed nav obstacles
	# alongside the heightmap attach if any markers exist.
	var nav_obstacles: Array[Dictionary] = _collect_nav_obstacles()
	# Iteration 5-14 follow-up: prefer the live Terrain3D push so the
	# sim Y-snaps to whatever the player sees + collides with, instead
	# of the canonical .r32 which drifts ~10-20 m after
	# `Terrain3DLoader.bake_into`.
	var t3d: Node = get_node_or_null("Terrain3D")
	if t3d != null and sim.has_method("attach_region_terrain_from_packed_heights"):
		if _push_terrain3d_heightmap_to_sim(sim, t3d, null, nav_obstacles):
			_request_region_interaction_areas(sim)
			return
	# Fallback: no Terrain3D
	var terrain: Node = get_node_or_null("Terrain")
	if terrain == null:
		return
	var terrain_map_id: String = ""
	if terrain.has_method("get"):
		terrain_map_id = String(terrain.get("map_id"))
	if terrain_map_id.is_empty():
		return
	if not sim.has_method("load_region_terrain"):
		return
	if sim.has_method("load_region_terrain_with_obstacles") and nav_obstacles.size() > 0:
		sim.load_region_terrain_with_obstacles(region_id, terrain_map_id, nav_obstacles)
	else:
		sim.load_region_terrain(region_id, terrain_map_id)
	_request_region_interaction_areas(sim)


func _on_terrain_loaded_push_live(
	_map_id: String,
	sim: Node,
	t3d: Node,
	terrain: Node,
	nav_obstacles: Array[Dictionary],
) -> void:
	if _push_terrain3d_heightmap_to_sim(sim, t3d, terrain, nav_obstacles):
		_request_region_interaction_areas(sim)


## Build a flat `PackedFloat32Array` of Terrain3D heights and push
## to the sim. Grid dimensions come from Terrain3D's own region
## layout — no TerrainNode dependency.
func _push_terrain3d_heightmap_to_sim(
	sim: Node, t3d: Node, _terrain_node: Node, obstacles: Array[Dictionary]
) -> bool:
	if not "data" in t3d or t3d.data == null:
		return false
	var data = t3d.data
	var spacing: float = float(t3d.get("vertex_spacing"))
	if spacing <= 0.0:
		return false
	var region_size: int = int(t3d.get("region_size"))
	if region_size <= 0:
		return false
	var locations = data.get_region_locations()
	if locations.is_empty():
		return false
	var min_loc := Vector2i(99999, 99999)
	var max_loc := Vector2i(-99999, -99999)
	for loc in locations:
		var v: Vector2i = loc
		min_loc.x = mini(min_loc.x, v.x)
		min_loc.y = mini(min_loc.y, v.y)
		max_loc.x = maxi(max_loc.x, v.x)
		max_loc.y = maxi(max_loc.y, v.y)
	var regions_x: int = max_loc.x - min_loc.x + 1
	var regions_z: int = max_loc.y - min_loc.y + 1
	var w: int = regions_x * region_size
	var h: int = regions_z * region_size
	var extent_x: float = float(w - 1) * spacing
	var extent_z: float = float(h - 1) * spacing
	var heights := PackedFloat32Array()
	heights.resize(w * h)
	var min_h: float = INF
	var max_h: float = -INF
	# TYPE_HEIGHT is enum value 0 on Terrain3DRegion (R channel of
	# the returned Color carries the f32 height).
	const TYPE_HEIGHT := 0
	var pixel_call := Callable(t3d.data, "get_pixel")
	for pz in h:
		var wz: float = -extent_z * 0.5 + float(pz) * spacing
		for px in w:
			var wx: float = -extent_x * 0.5 + float(px) * spacing
			var c: Color = pixel_call.call(TYPE_HEIGHT, Vector3(wx, 0.0, wz))
			var y: float = c.r
			if is_nan(y) or is_inf(y):
				y = 0.0
			heights[pz * w + px] = y
			if y < min_h:
				min_h = y
			if y > max_h:
				max_h = y
	if not is_finite(min_h):
		min_h = 0.0
	if not is_finite(max_h):
		max_h = 0.0
	sim.attach_region_terrain_from_packed_heights(
		region_id, w, h, spacing, min_h, max_h, heights, obstacles
	)
	print(
		"[test_map] pushed live Terrain3D heightmap %d×%d @ %.1fm (Y range [%.1f, %.1f]) to sim"
		% [w, h, spacing, min_h, max_h]
	)
	return true


## Iteration 5-13 Phase B2. Mirror of the helper in
## `real_map.gd`; kept inline (rather than autoload-shared) since
## the two map scripts are otherwise independent.
func _collect_nav_obstacles() -> Array:
	# Typed `Array[Dictionary]` so the gdext bridge's
	# `load_region_terrain_with_obstacles` signature match accepts it.
	var out: Array[Dictionary] = []
	for marker in get_tree().get_nodes_in_group(&"nav_obstacle_markers"):
		if not (marker is Node3D):
			continue
		var n: Node3D = marker
		if not n.is_inside_tree() or n.get_tree() != get_tree():
			continue
		if not is_ancestor_of(n) and n != self:
			continue
		var extents: Vector3 = Vector3.ONE
		if "extents" in n:
			extents = n.extents
		var kind_str: String = "block"
		if "override_kind" in n:
			var raw: Variant = n.override_kind
			if raw is String:
				kind_str = raw
			elif raw is int:
				kind_str = "walkable" if int(raw) == 1 else "block"
		out.append({
			"pos": n.global_position,
			"extents": extents,
			"kind": kind_str,
		})
	return out


## Iteration 5-13 Phase D2. Mirror of the helper in `real_map.gd`.
func _request_region_interaction_areas(sim: Node) -> void:
	if region_id.is_empty():
		return
	if sim == null or not sim.has_method("attach_region_interaction_areas"):
		return
	# Typed `Array[Dictionary]` so the gdext bridge's signature match
	# accepts it. Plain `Array` is untyped and gdext rejects with
	# "expected array of type Builtin(DICTIONARY), got Untyped".
	var areas: Array[Dictionary] = []
	for marker in get_tree().get_nodes_in_group(&"interaction_area_markers"):
		if not (marker is Node3D):
			continue
		var n: Node3D = marker
		if not n.is_inside_tree() or n.get_tree() != get_tree():
			continue
		if not is_ancestor_of(n) and n != self:
			continue
		var kind: String = "rest"
		if "interaction_kind" in n:
			kind = String(n.interaction_kind)
		var extents: Vector3 = Vector3(1.5, 1.0, 1.5)
		if "extents" in n:
			extents = n.extents
		var capacity: int = 1
		if "capacity" in n:
			capacity = int(n.capacity)
		var faction: String = ""
		if "faction" in n:
			faction = String(n.faction)
		var area_id: String = ""
		if "area_id" in n:
			area_id = String(n.area_id)
		var tags: Dictionary = {}
		if "tags" in n and n.tags is Dictionary:
			tags = n.tags
		areas.append({
			"id": area_id,
			"kind": kind,
			"pos": n.global_position,
			"extents": extents,
			"faction": faction,
			"capacity": capacity,
			"tags": tags,
		})
	sim.attach_region_interaction_areas(region_id, areas)


## Resolved reference to SunshineClouds2 driver node (if present in
## the scene). Set in `_cache_sky_refs`.
var _clouds_driver: Node = null
## Resolved reference to the SunshineCloudsGD resource on the
## driver. Stored separately so we can tween its properties
## directly from `_apply_weather_to_clouds`.
var _clouds_res: Resource = null

## Throttle sky/weather updates. `_update_sky` does ~3 sim queries +
## multiple `ProceduralSkyMaterial.set` + `RenderingServer` shader-
## parameter writes per call. At 60+ FPS that's 5-10 ms / frame of
## pure Variant/material churn for visual state that changes on
## time-of-day cadence (minutes, not frames). 10 Hz is well below
## perceptual threshold for sun-rotation / weather-blend smoothness
## and brings the per-frame cost back to ~1 ms.
const _SKY_REFRESH_HZ: float = 10.0
var _sky_refresh_accum: float = 0.0


func _process(delta: float) -> void:
	_sky_refresh_accum += delta
	var min_interval: float = 1.0 / _SKY_REFRESH_HZ
	if _sky_refresh_accum < min_interval:
		return
	# Pass the actual elapsed time so the weather-weight lerp inside
	# `_update_sky` advances at the same wall-clock rate it did at
	# full FPS — just in fewer, bigger steps.
	var elapsed := _sky_refresh_accum
	_sky_refresh_accum = 0.0
	_update_sky(elapsed)


## Recolor the floor mesh's material_override. Scenes all share the
## same floor geometry but differentiate visually via this color,
## which subclasses set through the `floor_color` export.
func _apply_floor_color() -> void:
	var mesh: MeshInstance3D = get_node_or_null("Floor/MeshInstance3D")
	if mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = floor_color
	mat.roughness = 0.85
	mesh.material_override = mat


## Query the sim for this region's transition portals and
## instantiate a TransitionCube at each, plus a tall beacon column
## and a destination label so you can spot portals from halfway
## across the map. Keeps scene content in lockstep with the
## sim-side RegionGraph — add a region in Rust and the markers
## show up automatically wherever it's a neighbor.
func _spawn_transition_cubes_from_sim() -> void:
	if region_id.is_empty():
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("region_transitions"):
		return
	var portals: Dictionary = sim.region_transitions(region_id)

	# Trigger cube (the actual Area3D the player walks into).
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(6, 6, 6)
	var cube_shape := BoxShape3D.new()
	cube_shape.size = Vector3(6, 6, 6)
	var cube_mat := StandardMaterial3D.new()
	cube_mat.albedo_color = Color(1.0, 0.8, 0.2)
	cube_mat.emission_enabled = true
	cube_mat.emission = Color(1.0, 0.7, 0.1)
	cube_mat.emission_energy_multiplier = 2.5

	# Beacon column: a tall cyan cylinder unlit by distance fog so
	# you can see where the portal is from 2km out.
	var beacon_mesh := CylinderMesh.new()
	beacon_mesh.top_radius = 0.8
	beacon_mesh.bottom_radius = 0.8
	beacon_mesh.height = 80.0
	var beacon_mat := StandardMaterial3D.new()
	beacon_mat.albedo_color = Color(0.3, 0.9, 1.0)
	beacon_mat.emission_enabled = true
	beacon_mat.emission = Color(0.3, 0.9, 1.0)
	beacon_mat.emission_energy_multiplier = 4.0
	beacon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beacon_mat.disable_fog = true

	var cube_script: Script = load("res://scripts/transition_cube.gd")
	for neighbor_name in portals.keys():
		var pos: Vector3 = portals[neighbor_name]

		# Trigger cube (collision + script). Lifted 3m so its base
		# sits on the ground.
		var cube := Area3D.new()
		cube.name = "TransitionCube_%s" % neighbor_name
		cube.set_script(cube_script)
		cube.set("target_map", neighbor_name)
		cube.position = Vector3(pos.x, pos.y + 3.0, pos.z)
		add_child(cube)
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = cube_mesh
		mesh_inst.material_override = cube_mat
		cube.add_child(mesh_inst)
		var coll := CollisionShape3D.new()
		coll.shape = cube_shape
		cube.add_child(coll)

		# Beacon column above the cube.
		var beacon := MeshInstance3D.new()
		beacon.name = "PortalBeacon_%s" % neighbor_name
		beacon.mesh = beacon_mesh
		beacon.material_override = beacon_mat
		beacon.position = Vector3(pos.x, pos.y + 40.0, pos.z)
		add_child(beacon)

		# Floating label that reads the destination map name.
		var label := Label3D.new()
		label.name = "PortalLabel_%s" % neighbor_name
		label.text = "→ %s" % neighbor_name
		label.position = Vector3(pos.x, pos.y + 10.0, pos.z)
		# World-scale (not fixed screen size) so distance shrinks
		# the text naturally. Billboard so it still faces you.
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = false
		label.pixel_size = 0.04
		label.font_size = 32
		label.outline_size = 6
		label.modulate = Color(1, 1, 1)
		label.outline_modulate = Color(0, 0, 0)
		label.no_depth_test = false
		add_child(label)


# ---------- mountain perimeter ----------

func _build_mountain_ring() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = mountain_seed

	var mountains := Node3D.new()
	mountains.name = "Mountains"
	add_child(mountains)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = mountain_color
	mat.roughness = 0.95

	var inner := map_half_extent_m + mountain_ring_offset_m
	var outer := inner + 800.0

	for i in mountain_count:
		# Place around the perimeter. Pick a side, then a distance
		# along it; randomly push the mountain outward into the band.
		var side := i % 4
		var t := rng.randf()
		var depth := rng.randf_range(inner, outer)
		var x: float
		var z: float
		match side:
			0: # north edge: vary X across full span, z = -depth
				x = lerp(-outer, outer, t)
				z = -depth
			1: # east
				x = depth
				z = lerp(-outer, outer, t)
			2: # south
				x = lerp(-outer, outer, t)
				z = depth
			_: # west
				x = -depth
				z = lerp(-outer, outer, t)

		var height := rng.randf_range(120.0, 380.0)
		var radius := rng.randf_range(80.0, 220.0)
		var rot_y := rng.randf_range(0.0, TAU)

		var mesh := CylinderMesh.new()
		mesh.height = height
		mesh.top_radius = 0.0      # cone
		mesh.bottom_radius = radius

		var inst := MeshInstance3D.new()
		inst.mesh = mesh
		inst.material_override = mat
		inst.position = Vector3(x, height * 0.5 - 5.0, z)
		inst.rotation = Vector3(0, rot_y, 0)
		mountains.add_child(inst)


# ---------- compass at origin ----------

func _build_compass(parent: Node3D) -> void:
	var post_mat := _emissive_mat(Color(0.95, 0.95, 1.0))
	var dirs := [
		[Vector3(0, 0, -1), "N"],
		[Vector3(1, 0, 0),  "E"],
		[Vector3(0, 0, 1),  "S"],
		[Vector3(-1, 0, 0), "W"],
	]
	for entry in dirs:
		var dir: Vector3 = entry[0]
		var letter: String = entry[1]
		var pos := dir * 8.0
		var post := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = 0.4
		mesh.height = 6.0
		post.mesh = mesh
		post.material_override = post_mat
		post.position = Vector3(pos.x, 3.0, pos.z)
		parent.add_child(post)

		var label := _make_label(letter, post.position + Vector3(0, 4.0, 0), Color(1, 1, 1))
		label.font_size = 64
		parent.add_child(label)


# ---------- inner ruler (every 100m to 500m, on +X and +Z) ----------

func _build_inner_ruler(parent: Node3D) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.6
	mesh.height = 6.0
	var mat := _emissive_mat(Color(0.85, 0.85, 0.9))
	var distance := inner_step_meters
	while distance <= inner_max_meters:
		_spawn_axis_posts(parent, distance, 3.0, mesh, mat, 36)
		distance += inner_step_meters


# ---------- outer ruler (every 500m to ruler_max_meters, all 4 axes) ----------

func _build_outer_ruler(parent: Node3D) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 2.5
	mesh.height = 25.0
	var mat := _emissive_mat(marker_color)
	var distance := ruler_step_meters
	while distance <= ruler_max_meters:
		_spawn_axis_posts(parent, distance, 12.5, mesh, mat, 64)
		distance += ruler_step_meters


## Spawn four posts at `distance` from origin — one per cardinal
## axis (+X, -X, +Z, -Z) — so we have reference markers in every
## quadrant of the map, not just the positive corner.
func _spawn_axis_posts(
	parent: Node3D,
	distance: int,
	y: float,
	mesh: Mesh,
	mat: Material,
	font_size: int,
) -> void:
	_spawn_post(parent, Vector3(distance, y, 0), distance, mesh, mat, font_size)
	_spawn_post(parent, Vector3(-distance, y, 0), distance, mesh, mat, font_size)
	_spawn_post(parent, Vector3(0, y, distance), distance, mesh, mat, font_size)
	_spawn_post(parent, Vector3(0, y, -distance), distance, mesh, mat, font_size)


# ---------- helpers ----------

func _spawn_post(
	parent: Node3D,
	pos: Vector3,
	distance_m: int,
	mesh: Mesh,
	mat: Material,
	font_size: int,
) -> void:
	var post := MeshInstance3D.new()
	post.mesh = mesh
	post.material_override = mat
	post.position = pos
	parent.add_child(post)

	var label := _make_label(
		_format_distance(distance_m),
		pos + Vector3(0, mesh.height / 2.0 + 2.0, 0),
		(mat as StandardMaterial3D).albedo_color,
	)
	label.font_size = font_size
	parent.add_child(label)


func _make_label(text: String, pos: Vector3, color: Color) -> Label3D:
	# World-space text: scales with distance so labels for distant
	# posts are small in the foreground rather than huge billboards
	# stacked across the camera. `no_depth_test` is OFF so labels
	# are properly occluded by anything in front of them.
	var label := Label3D.new()
	label.text = text
	label.position = pos
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.fixed_size = false
	label.pixel_size = 0.04
	label.modulate = color
	label.outline_modulate = Color(0, 0, 0, 1)
	label.outline_size = 12
	return label


func _emissive_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.5
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.4
	return mat


static func _format_distance(meters: int) -> String:
	if meters >= 1000:
		var km := float(meters) / 1000.0
		if km == floor(km):
			return "%.0f km" % km
		return "%.1f km" % km
	return "%d m" % meters


# ---------- sky + weather ----------


## Resolve nodes for the sun light + environment once, so `_update_sky`
## can mutate them cheaply per frame.
func _cache_sky_refs() -> void:
	_sun = get_node_or_null("DirectionalLight3D")
	# TODO: Sun overlay causes a black-hole artifact when
	# resource_local_to_scene=true on the cloud compositor. Current
	# workaround: ProceduralSky's native sun disc shows when the
	# compositor is disabled (clear weather). Proper sun-through-
	# clouds needs a shader-level approach. Revisit with custom sky
	# shader or addon update.

	# Procedurally add a moonlight — cool blue, lower energy, no
	# shadows (keeps nights readable without doubling the shadow
	# cost). `_update_sky` rotates + modulates it per moon phase.
	_moon = DirectionalLight3D.new()
	_moon.name = "MoonLight3D"
	_moon.light_color = Color(0.55, 0.65, 0.9)
	_moon.light_energy = 0.0
	_moon.shadow_enabled = false
	add_child(_moon)
	var world_env: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if world_env != null:
		_env = world_env.environment
		if _env != null:
			_base_fog_density = _env.fog_density
			_base_fog_color = _env.fog_light_color
			# background_color isn't meaningful in SKY mode; store the
			# fog horizon as our "base background" for weather tinting.
			_base_bg_color = _env.fog_light_color
	# SunshineClouds2: find the scene-placed driver, grab its resource,
	# and wire the DirectionalLight3D reference (can't be set via
	# NodePath in .tscn — the typed Array[DirectionalLight3D] needs
	# actual node objects, so we resolve it here at runtime).
	for child in get_children():
		if child is SunshineCloudsDriverGD:
			_clouds_driver = child
			_clouds_res = child.get("clouds_resource")
			if _sun != null:
				var lights: Array[DirectionalLight3D] = [_sun]
				var steps: Array[int] = [4]
				child.tracked_directional_lights = lights
				child.tracked_directional_light_shadow_steps = steps
			if _env != null:
				child.ambience_sample_environment = _env
			break


## Spawn SunshineClouds2 driver + compositor procedurally. Uses the
## addon's example noise textures so there's zero manual scene setup.
func _setup_sunshine_clouds() -> void:
	# Check for an existing driver first.
	for child in get_children():
		if child is SunshineCloudsDriverGD:
			_clouds_driver = child
			_clouds_res = child.get("clouds_resource")
			return

	# Load the addon's pre-built test resource — it has all noise
	# textures, compute shaders, and sane defaults already wired.
	# Building SunshineCloudsGD from scratch in code often fails
	# because the compute shader pipeline needs resources loaded
	# through Godot's import system, not constructed at runtime.
	var clouds_effect: SunshineCloudsGD = load(
		"res://addons/SunshineClouds2/SunshineCloudsGDTestResource.tres"
	).duplicate() as SunshineCloudsGD
	if clouds_effect == null:
		push_warning("SunshineClouds2: failed to load test resource")
		return
	# Override to PNW defaults.
	clouds_effect.clouds_coverage = 0.85
	clouds_effect.clouds_density = 0.14
	clouds_effect.atmospheric_density = 0.5
	clouds_effect.cloud_ambient_color = Color(0.76, 0.78, 0.82)
	clouds_effect.fog_effect_ground = 1.0
	clouds_effect.use_environment_fog = 1.0
	clouds_effect.set("resolution_scale", 1) # half res for perf

	# Attach to a Compositor on the WorldEnvironment.
	var compositor := Compositor.new()
	compositor.compositor_effects = [clouds_effect]
	var world_env: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if world_env != null:
		world_env.compositor = compositor

	# Driver node: manages wind, light tracking, continuous update.
	# IMPORTANT: add to tree FIRST, then configure tracked lights —
	# the driver's property setters call retrieve_texture_data()
	# which needs the node in the tree to resolve light references.
	var driver := SunshineCloudsDriverGD.new()
	driver.name = "SunshineCloudsDriver"
	driver.set("clouds_resource", clouds_effect)
	driver.set("wind_direction", Vector3(1.0, 0.0, 0.5))
	driver.set("medium_structures_wind_speed", 40.0)
	driver.set("small_structures_wind_speed", 12.0)
	add_child(driver)
	# Now that the driver is in the tree, wire up tracked lights
	# so the cloud shader gets proper sun direction + color data.
	if _sun != null:
		driver.set("tracked_directional_lights", [_sun])
		driver.set("tracked_directional_light_shadow_steps", [4])
	if _env != null:
		driver.set("ambience_sample_environment", _env)
	driver.set("update_continuously", true)

	_clouds_driver = driver
	_clouds_res = clouds_effect


## Pull time + weather from the sim, lerp visuals toward them. Pure
## view layer — sim is authoritative, we just reflect.
func _update_sky(delta: float) -> void:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null:
		return

	# --- Time of day ---
	if _sun != null and sim.has_method("world_time"):
		var time: Dictionary = sim.world_time()
		if not time.is_empty():
			var sun_angle: float = time.get("sun_angle_rad", 0.0)
			# Rotate around X so light sweeps east → overhead → west.
			# Keep yaw at 45° so shadows fall consistently.
			_sun.rotation = Vector3(-sun_angle, deg_to_rad(45.0), 0.0)
			# Energy peaks at noon, drops to near-zero at night.
			# The floor is 0.0 — moonlight (separate light) and
			# ambient provide the only nighttime illumination.
			var elevation := sin(sun_angle)
			var energy := clampf(0.04 + elevation * 1.0, 0.01, 1.0)
			_sun.light_energy = energy
			# Ambient light dims at night so the world actually gets
			# dark. Daytime ambient ~0.6, night ~0.05.
			if _env != null:
				var ambient_e := clampf(0.08 + max(elevation, 0.0) * 0.52, 0.08, 0.6)
				_env.ambient_light_energy = ambient_e
				# Tint ambient toward deep blue at night.
				var night_t := clampf(-elevation * 2.0, 0.0, 1.0)
				_env.ambient_light_color = Color(0.7, 0.75, 0.85).lerp(
					Color(0.12, 0.15, 0.25), night_t
				)
			# Darken the procedural sky material at night so the
			# background isn't a permanent light-blue wash.
			var sky_mat: ProceduralSkyMaterial = null
			if _env != null and _env.sky != null:
				sky_mat = _env.sky.sky_material as ProceduralSkyMaterial
			if sky_mat != null:
				var night_t := clampf(-elevation * 3.0, 0.0, 1.0)
				sky_mat.sky_top_color = Color(0.35, 0.48, 0.72).lerp(
					Color(0.02, 0.03, 0.06), night_t
				)
				sky_mat.sky_horizon_color = Color(0.65, 0.70, 0.78).lerp(
					Color(0.04, 0.05, 0.08), night_t
				)
				sky_mat.ground_horizon_color = Color(0.65, 0.70, 0.78).lerp(
					Color(0.03, 0.04, 0.06), night_t
				)
			# Color shift: cool dawn/dusk amber → neutral midday →
			# very dark blue-gray at night.
			var color: Color
			if elevation > 0.3:
				color = Color(1.0, 0.96, 0.88)  # midday
			elif elevation > 0.0:
				var t := elevation / 0.3
				color = Color(1.0, 0.76, 0.45).lerp(Color(1.0, 0.96, 0.88), t)
			else:
				color = Color(0.15, 0.18, 0.3)  # night
			# Smoke haze shifts the sun to a deep orange and cuts
			# its energy — wildfire-sky feel.
			var smoke: float = _weather_weights.get("smoke_haze", 0.0)
			if smoke > 0.01:
				color = color.lerp(Color(1.0, 0.45, 0.15), smoke * 0.9)
				_sun.light_energy = energy * lerp(1.0, 0.55, smoke)
			# Heavy overcast / storms also dim the sun.
			var heavy: float = _weather_weights.get("heavy_rain", 0.0)
			var thunder: float = _weather_weights.get("thunderstorm", 0.0)
			var dim = max(heavy * 0.5, thunder * 0.7)
			if dim > 0.01:
				_sun.light_energy = _sun.light_energy * (1.0 - dim)
			_sun.light_color = color


	# --- Moon ---
	if _moon != null and sim.has_method("world_time"):
		var time2: Dictionary = sim.world_time()
		if not time2.is_empty():
			var moon_angle: float = time2.get("moon_angle_rad", 0.0)
			var moon_illum: float = time2.get("moon_illumination", 0.0)
			var sun_elev: float = sin(time2.get("sun_angle_rad", 0.0))
			# Yaw 90° off from the sun so shadows feel different and
			# the moon doesn't stack on the same rotation axis.
			_moon.rotation = Vector3(-moon_angle, deg_to_rad(-45.0), 0.0)
			# Moonlight fades in as the sun sets; fully on at night,
			# scaled by illumination. Base energy is small — moonlight
			# is atmospheric, not a flashlight.
			var night := clampf(1.0 - max(sun_elev, 0.0) * 3.0, 0.0, 1.0)
			var moon_elev := sin(moon_angle)
			var above := clampf(moon_elev, 0.0, 1.0)
			_moon.light_energy = 0.25 * night * moon_illum * above
			# Smoke haze warms the moon too — classic orange "hunter's
			# moon" look through wildfire smoke.
			var smoke2: float = _weather_weights.get("smoke_haze", 0.0)
			if smoke2 > 0.01:
				_moon.light_color = Color(0.55, 0.65, 0.9).lerp(
					Color(1.0, 0.55, 0.3), smoke2 * 0.85
				)
			else:
				_moon.light_color = Color(0.55, 0.65, 0.9)

	# --- Weather ---
	if _env == null or not sim.has_method("weather_state"):
		return
	var w: Dictionary = sim.weather_state()
	if w.is_empty():
		return
	var target_kind: String = w.get("current", "clear")
	# First frame: snap weights so you load straight into the current
	# weather instead of watching clouds draw in from nothing.
	if _weather_first_frame:
		_weather_first_frame = false
		for kind in _weather_weights.keys():
			_weather_weights[kind] = 1.0 if kind == target_kind else 0.0
	else:
		var is_heavy: bool = target_kind in [
			"heavy_rain", "thunderstorm", "windstorm", "fog", "smoke_haze"
		]
		var lerp_rate := WEATHER_LERP_RATE_SLOW if is_heavy else WEATHER_LERP_RATE_FAST
		var rate := clampf(lerp_rate * delta, 0.0, 1.0)
		for kind in _weather_weights.keys():
			var target_w := 1.0 if kind == target_kind else 0.0
			var current_w: float = _weather_weights[kind]
			_weather_weights[kind] = lerp(current_w, target_w, rate)

	_apply_weather_visuals()
	_apply_weather_to_clouds()


## Combine per-kind weights into environment changes. Each weather
## kind contributes a density multiplier, a fog tint, and a
## background tint in proportion to its weight. The weights lerp
## smoothly in `_update_sky`, so transitions cross-fade rather
## than snap.
##
## Density multipliers are authored as "how much thicker than the
## scene baseline does the air read"; the scene baseline itself
## already bakes in some atmospheric fog for the 5km maps.
func _apply_weather_visuals() -> void:
	if _env == null or _base_fog_density < 0.0:
		return
	var w_clear: float = _weather_weights.get("clear", 0.0)
	var w_partly: float = _weather_weights.get("partly_cloudy", 0.0)
	var w_overcast: float = _weather_weights.get("overcast", 0.0)
	var w_marine: float = _weather_weights.get("marine_layer", 0.0)
	var w_fog: float = _weather_weights.get("fog", 0.0)
	var w_drizzle: float = _weather_weights.get("drizzle", 0.0)
	var w_light: float = _weather_weights.get("light_rain", 0.0)
	var w_heavy: float = _weather_weights.get("heavy_rain", 0.0)
	var w_wind: float = _weather_weights.get("windstorm", 0.0)
	var w_thunder: float = _weather_weights.get("thunderstorm", 0.0)
	var w_smoke: float = _weather_weights.get("smoke_haze", 0.0)

	# Density multiplier per kind, blended by weight.
	var density_mul := (
		1.0 * w_clear
		+ 1.1 * w_partly
		+ 1.6 * w_overcast
		+ 2.5 * w_marine
		+ 5.0 * w_fog
		+ 2.0 * w_drizzle
		+ 2.5 * w_light
		+ 3.5 * w_heavy
		+ 2.8 * w_wind
		+ 4.0 * w_thunder
		+ 3.0 * w_smoke
	)
	_env.fog_density = _base_fog_density * density_mul

	# Fog tint: base colour mixed with each kind's signature tint
	# in proportion to its weight. Keeps the scene's authored mood
	# when multiple kinds overlap briefly during a transition.
	var base := _base_fog_color
	var tint := base
	tint = tint.lerp(Color(0.88, 0.90, 0.94), w_marine * 0.7)
	tint = tint.lerp(Color(0.85, 0.88, 0.92), w_fog * 0.9)
	tint = tint.lerp(Color(0.55, 0.58, 0.62), w_drizzle * 0.35)
	tint = tint.lerp(Color(0.48, 0.52, 0.58), w_light * 0.55)
	tint = tint.lerp(Color(0.35, 0.38, 0.45), w_heavy * 0.75)
	tint = tint.lerp(Color(0.3, 0.32, 0.38), w_wind * 0.5)
	tint = tint.lerp(Color(0.25, 0.25, 0.3), w_thunder * 0.85)
	tint = tint.lerp(Color(0.78, 0.55, 0.35), w_smoke * 0.9) # sepia
	_env.fog_light_color = tint

	# Background: dims under heavy rain / thunder / wind, yellows
	# under smoke haze, and stays mostly neutral otherwise.
	var bg := _base_bg_color
	bg = bg.lerp(Color(0.16, 0.18, 0.22), w_heavy * 0.4)
	bg = bg.lerp(Color(0.12, 0.13, 0.17), w_thunder * 0.7)
	bg = bg.lerp(Color(0.25, 0.28, 0.32), w_wind * 0.3)
	bg = bg.lerp(Color(0.7, 0.45, 0.25), w_smoke * 0.75)
	_env.background_color = bg


## Drive SunshineClouds2 properties from the current weather weight
## blend. Only runs if the driver node + resource are present in
## the scene. Values lerp smoothly via the weight system upstream
## so cloud transitions cross-fade automatically.
func _apply_weather_to_clouds() -> void:
	if _clouds_res == null:
		return
	var w_clear: float = _weather_weights.get("clear", 0.0)
	var w_partly: float = _weather_weights.get("partly_cloudy", 0.0)
	var w_overcast: float = _weather_weights.get("overcast", 0.0)
	var w_marine: float = _weather_weights.get("marine_layer", 0.0)
	var w_fog: float = _weather_weights.get("fog", 0.0)
	var w_drizzle: float = _weather_weights.get("drizzle", 0.0)
	var w_light: float = _weather_weights.get("light_rain", 0.0)
	var w_heavy: float = _weather_weights.get("heavy_rain", 0.0)
	var w_wind: float = _weather_weights.get("windstorm", 0.0)
	var w_thunder: float = _weather_weights.get("thunderstorm", 0.0)
	var w_smoke: float = _weather_weights.get("smoke_haze", 0.0)

	# Coverage stays relatively stable — we use a moderate baseline
	# and drive the visual "more/fewer clouds" through SHARPNESS
	# instead. Lower sharpness = existing cloud formations grow and
	# merge (overcast). Higher sharpness = formations thin out and
	# separate (clear). This way weather changes look like the same
	# clouds evolving, not new ones spawning from nothing.
	# --- Cloud parameter table ---
	# Every weather type that shows clouds needs enough DENSITY for
	# overhead visibility (min ~0.3). The ray path looking straight
	# up is short; horizon paths are long. Low density = clouds only
	# visible at the horizon. Each type is tuned for both overhead
	# and distant reads:
	#
	#                    coverage  sharpness  density
	# clear:            few wisps, mostly blue sky
	# partly_cloudy:    scattered defined puffs overhead + horizon
	# overcast:         solid gray blanket everywhere
	# marine_layer:     thin low layer, more at horizon
	# fog:              thin high haze, ground fog does heavy lifting
	# drizzle:          solid gray, slightly textured
	# light_rain:       solid dark gray
	# heavy_rain:       solid dark blanket
	# windstorm:        solid, fast-moving
	# thunderstorm:     solid, very dark
	# smoke_haze:       thin high haze, sepia
	# Resource baseline: coverage=0.726, sharpness=0.5, density=1.0.
	# Coverage + sharpness control spread/merge; density controls
	# thickness. All values relative to the working baseline.
	var coverage := (
		0.4 * w_clear
		+ 0.78 * w_partly
		+ 0.95 * w_overcast
		+ 0.85 * w_marine
		+ 0.75 * w_fog
		+ 0.93 * w_drizzle
		+ 0.96 * w_light
		+ 0.99 * w_heavy
		+ 0.92 * w_wind
		+ 0.99 * w_thunder
		+ 0.45 * w_smoke
	)
	_clouds_res.set("clouds_coverage", clampf(coverage, 0.0, 1.0))
	_clouds_res.set("enabled", coverage > 0.25)

	var sharpness := (
		0.8 * w_clear
		+ 0.3 * w_partly
		+ 0.08 * w_overcast
		+ 0.2 * w_marine
		+ 0.15 * w_fog
		+ 0.06 * w_drizzle
		+ 0.04 * w_light
		+ 0.02 * w_heavy
		+ 0.06 * w_wind
		+ 0.01 * w_thunder
		+ 0.5 * w_smoke
	)
	_clouds_res.set("clouds_sharpness", clampf(sharpness, 0.0, 2.0))

	# Density: baseline 1.0. Storm/rain go higher for dark thick
	# blanket; clear goes lower for wispy.
	var density := (
		0.12 * w_clear
		+ 0.2 * w_partly
		+ 0.3 * w_overcast
		+ 0.25 * w_marine
		+ 0.2 * w_fog
		+ 0.4 * w_drizzle
		+ 0.7 * w_light
		+ 1.4 * w_heavy
		+ 0.8 * w_wind
		+ 2.0 * w_thunder
		+ 0.15 * w_smoke
	)
	_clouds_res.set("clouds_density", clampf(density, 0.0, 5.0))

	# Cloud altitude: clear = high scattered clouds, overcast/rain =
	# low oppressive ceiling, storm = very low and looming. This is
	# what makes the difference between "clouds on the horizon" and
	# "clouds overhead" — PNW overcast sits at 500-2000m, not 25km.
	# Noise scales: the resource defaults (85km large, 20km medium)
	# create features so wide that our 5km map sits under one tiny
	# slice of the noise — you might just be under a gap with no
	# clouds overhead. Shrinking scales creates more frequent,
	# smaller features distributed across the whole dome.
	var large_scale := (
		85000.0 * w_clear
		+ 60000.0 * w_partly
		+ 40000.0 * w_overcast
		+ 50000.0 * w_marine
		+ 45000.0 * w_fog
		+ 35000.0 * w_drizzle
		+ 30000.0 * w_light
		+ 25000.0 * w_heavy
		+ 35000.0 * w_wind
		+ 20000.0 * w_thunder
		+ 70000.0 * w_smoke
	)
	_clouds_res.set("large_noise_scale", large_scale)
	var medium_scale := (
		20000.0 * w_clear
		+ 14000.0 * w_partly
		+ 8000.0 * w_overcast
		+ 12000.0 * w_marine
		+ 10000.0 * w_fog
		+ 7000.0 * w_drizzle
		+ 6000.0 * w_light
		+ 5000.0 * w_heavy
		+ 7000.0 * w_wind
		+ 4000.0 * w_thunder
		+ 16000.0 * w_smoke
	)
	_clouds_res.set("medium_noise_scale", medium_scale)

	# Atmospheric density: haze / scatter contribution. This is the
	# cloud system's own atmosphere layer that sits OVER the
	# ProceduralSky. Clear weather needs to be near-zero so the
	# sun disc and blue sky show through; heavier weather can
	# push it up to wash out the sky convincingly.
	var atmo := (
		0.0 * w_clear
		+ 0.08 * w_partly
		+ 0.35 * w_overcast
		+ 0.5 * w_marine
		+ 0.9 * w_fog
		+ 0.3 * w_drizzle
		+ 0.4 * w_light
		+ 0.6 * w_heavy
		+ 0.35 * w_wind
		+ 0.7 * w_thunder
		+ 1.0 * w_smoke
	)
	_clouds_res.set("atmospheric_density", clampf(atmo, 0.0, 2.0))

	# Cloud ambient color: goes cooler/darker in storms, warmer
	# under smoke. Lerp from a "clear sky" default.
	# Cloud color: bright white for fair weather, darkens only for
	# rain/storm. The resource default is pure white Color(1,1,1).
	var base_cloud := Color(1.0, 1.0, 1.0)
	var cloud_col := base_cloud
	cloud_col = cloud_col.lerp(Color(0.7, 0.72, 0.76), w_overcast * 0.5)
	cloud_col = cloud_col.lerp(Color(0.5, 0.52, 0.58), w_light * 0.7)
	cloud_col = cloud_col.lerp(Color(0.35, 0.38, 0.45), w_heavy * 0.9)
	cloud_col = cloud_col.lerp(Color(0.25, 0.28, 0.35), w_thunder * 0.95)
	cloud_col = cloud_col.lerp(Color(0.85, 0.65, 0.45), w_smoke * 0.7)
	_clouds_res.set("cloud_ambient_color", cloud_col)

	# Atmosphere color: sepia under smoke, neutral-gray under storm.
	var atmo_col := Color(1.0, 1.0, 1.0)
	atmo_col = atmo_col.lerp(Color(0.55, 0.55, 0.6), w_thunder * 0.5)
	atmo_col = atmo_col.lerp(Color(0.95, 0.7, 0.45), w_smoke * 0.8)
	_clouds_res.set("atmosphere_color", atmo_col)

	# Wind speed — windstorm and thunderstorm push clouds faster.
	if _clouds_driver != null:
		var base_wind := 40.0
		var wind_mul := (
			1.0 * w_clear
			+ 1.0 * w_partly
			+ 1.0 * w_overcast
			+ 0.6 * w_marine
			+ 0.3 * w_fog
			+ 1.2 * w_drizzle
			+ 1.5 * w_light
			+ 2.5 * w_heavy
			+ 4.0 * w_wind
			+ 3.5 * w_thunder
			+ 0.4 * w_smoke
		)
		# During transitions (weights not settled), boost wind so
		# clouds visually blow in from the wind direction instead of
		# materializing everywhere at once. "Transition intensity"
		# is how far we are from any single weight being dominant.
		var max_w := 0.0
		for kind in _weather_weights.keys():
			var wv: float = _weather_weights[kind]
			if wv > max_w:
				max_w = wv
		# max_w < 0.7 means we're mid-transition; boost wind up to 3×.
		var transition_boost := clampf((1.0 - max_w) * 4.0, 1.0, 3.0)
		wind_mul *= transition_boost
		_clouds_driver.set("medium_structures_wind_speed", base_wind * wind_mul)
		_clouds_driver.set("small_structures_wind_speed", 12.0 * wind_mul)
		_clouds_driver.set("large_structures_wind_speed", 100.0 * wind_mul)
		_clouds_driver.set("extra_large_structures_wind_speed", 140.0 * transition_boost)
