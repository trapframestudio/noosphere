extends Node3D
## Lightweight root for real (non-test) maps.
##
## - Holds the region id.
## - Asks the sim to attach the terrain heightmap once the TerrainNode
##   child has loaded.
## - Spawns transition cubes + beacons at each portal the sim's
##   RegionGraph reports for this region, placing them on the actual
##   terrain surface (not at sim Y=0 — real maps aren't flat).
##
## Unlike `test_map.gd`, this script has no dev aids (no mountain
## ring, compass, or rulers). Real maps get their own visual styling
## later as authored content lands.
##
## Expected scene shape (the baker generates this):
## - Root `Node3D` with this script, `region_id` set
## - `WorldEnvironment` child for sky + env
## - `DirectionalLight3D` child for sun
## - `TerrainNode` child named `"Terrain"` with `map_id` set
## - `PlayerSpawn` (`Node3D`) marker for initial spawn transform

@export var region_id: String = ""


func _ready() -> void:
	_request_region_terrain()
	# Terrain3D heights are pushed to the sim in _request_region_terrain.
	# Spawn immediately — no need to wait for TerrainNode.
	_spawn_transition_cubes_from_sim()
	_spawn_test_loot_crate()
	_spawn_authored_loot_containers()


func _on_terrain_ready(_map_id: String) -> void:
	_spawn_transition_cubes_from_sim()
	_spawn_test_loot_crate()
	_spawn_authored_loot_containers()


## Phase 3D — walk every `LootContainerMarker3D` placed in this
## scene and register it with the sim. Runs after terrain is
## loaded so the spawner can Y-snap each marker to the surface.
func _spawn_authored_loot_containers() -> void:
	if region_id.is_empty():
		return
	var spawner := load("res://scripts/world/loot_container_spawner.gd")
	if spawner == null:
		return
	var n: int = int(spawner.call("spawn_authored_containers", get_tree(), region_id))
	if n > 0:
		print("[real_map] registered %d authored loot container(s)" % n)


## Tell the sim which heightmap belongs to this region so bases get
## Y-snapped to ground and NPCs walk the surface. Looks up the
## scene's `TerrainNode` (named "Terrain") to read its `map_id`.
func _request_region_terrain() -> void:
	if region_id.is_empty():
		return
	var terrain: Node = get_node_or_null("Terrain")
	if terrain == null:
		return
	var terrain_map_id: String = ""
	if terrain.has_method("get"):
		terrain_map_id = String(terrain.get("map_id"))
	if terrain_map_id.is_empty():
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("load_region_terrain"):
		return
	# Iteration 5-13 Phase B2: if NavObstacleMarker3D nodes are
	# present, use the with-obstacles variant so they stamp into
	# the sim nav grid on initial attach. Empty array degrades to
	# the back-compat path.
	var nav_obstacles: Array = _collect_nav_obstacles()
	if sim.has_method("load_region_terrain_with_obstacles") and nav_obstacles.size() > 0:
		sim.load_region_terrain_with_obstacles(region_id, terrain_map_id, nav_obstacles)
	else:
		sim.load_region_terrain(region_id, terrain_map_id)
	# Iteration 5-13 Phase D2: ship designer-placed interaction
	# areas after terrain so the sim has the region + nav set up
	# before it scores reservation requests.
	_request_region_interaction_areas(sim)


## Iteration 5-13 Phase B2. Walk the scene for
## `NavObstacleMarker3D` nodes (group `&"nav_obstacle_markers"`),
## build the per-obstacle dict the bridge expects. Cheap because
## marker count per region is small (tens, not thousands).
func _collect_nav_obstacles() -> Array:
	# Typed `Array[Dictionary]` so the gdext bridge accepts it.
	var out: Array[Dictionary] = []
	for marker in get_tree().get_nodes_in_group(&"nav_obstacle_markers"):
		if not (marker is Node3D):
			continue
		var n: Node3D = marker
		# Skip markers belonging to a different region root, in
		# case multiple maps are loaded simultaneously.
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
				# Enum BLOCK=0, WALKABLE=1.
				kind_str = "walkable" if int(raw) == 1 else "block"
		out.append({
			"pos": n.global_position,
			"extents": extents,
			"kind": kind_str,
		})
	return out


## Iteration 5-13 Phase D2. Walk the scene for
## `InteractionAreaMarker3D` nodes (group
## `&"interaction_area_markers"`), build the bridge dict per
## marker, hand to `Sim::attach_region_interaction_areas`. Mirrors
## `_collect_nav_obstacles` in shape.
func _request_region_interaction_areas(sim: Node) -> void:
	if region_id.is_empty():
		return
	if sim == null or not sim.has_method("attach_region_interaction_areas"):
		return
	# Typed `Array[Dictionary]` so the gdext bridge accepts it.
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


## Query the sim's RegionGraph for this region's portals; spawn a
## TransitionCube + beacon column + destination label at each. Mirrors
## the pattern from `test_map.gd::_spawn_transition_cubes_from_sim`
## but places cubes on the real terrain surface — real maps have
## Y-variation, and sim reports portals at Y=0, which would bury
## them without a terrain sample.
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
	if portals.is_empty():
		return

	# (height queries via _terrain3d_height helper)

	# Trigger cube mesh + shape — the Area3D the player walks into.
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(6, 6, 6)
	var cube_shape := BoxShape3D.new()
	cube_shape.size = Vector3(6, 6, 6)
	var cube_mat := StandardMaterial3D.new()
	cube_mat.albedo_color = Color(1.0, 0.8, 0.2)
	cube_mat.emission_enabled = true
	cube_mat.emission = Color(1.0, 0.7, 0.1)
	cube_mat.emission_energy_multiplier = 2.5

	# Beacon column — tall unlit cyan cylinder visible from across the
	# map so the next transition is findable from 2 km out.
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
		var ground_y: float = 0.0
		ground_y = _terrain3d_height(pos.x, pos.z, ground_y)

		# Trigger cube — base 3 m above the sampled ground.
		var cube := Area3D.new()
		cube.name = "TransitionCube_%s" % neighbor_name
		cube.set_script(cube_script)
		cube.set("target_map", neighbor_name)
		cube.position = Vector3(pos.x, ground_y + 3.0, pos.z)
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
		beacon.position = Vector3(pos.x, ground_y + 40.0, pos.z)
		add_child(beacon)

		# Floating destination label.
		var label := Label3D.new()
		label.name = "PortalLabel_%s" % neighbor_name
		label.text = "→ %s" % neighbor_name
		label.position = Vector3(pos.x, ground_y + 10.0, pos.z)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = false
		label.pixel_size = 0.04
		label.font_size = 32
		label.outline_size = 6
		label.modulate = Color(1, 1, 1)
		label.outline_modulate = Color(0, 0, 0)
		label.no_depth_test = false
		add_child(label)


## PR-4c — drop a single test crate near the player spawn so the
## looting loop is exercisable from any real map without first
## killing an NPC. Public (`is_public = true`) so its contents also
## count toward the crafting kit-pool, doubling as a portable
## bench-bin demo. Removed once authored loot placements + scripted
## spawns land.
func _spawn_test_loot_crate() -> void:
	if region_id.is_empty():
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("spawn_world_container"):
		return
	# Anchor 6 m forward + 2 m right of the PlayerSpawn so the player
	# walks into the prompt range immediately on first spawn.
	var spawn := get_node_or_null("PlayerSpawn")
	if spawn == null:
		return
	var origin: Vector3 = (spawn as Node3D).global_position
	var forward: Vector3 = -(spawn as Node3D).global_transform.basis.z
	var right: Vector3 = (spawn as Node3D).global_transform.basis.x
	var crate_pos: Vector3 = origin + forward * 6.0 + right * 2.0
	# Y-snap to the surface so the visual marker lands on terrain.
	crate_pos.y = _terrain3d_height(crate_pos.x, crate_pos.z, crate_pos.y)
	var cid: int = sim.spawn_world_container(region_id, crate_pos, 4, 4, true)
	if cid < 0:
		return
	# Seed it with a couple of ration items so the player has something
	# to take. Granted to the player first then put_in_container —
	# avoids needing a dedicated "grant straight to a container" #[func].
	# (The Sim host's `set_player_near_workbench` debug already pre-pops
	# inventories at spawn; this keeps the test self-contained.)
	# For now leave the crate empty; PR-4b NPC corpses + ground drops
	# from `drop_item` already exercise the take path with content.
	# Visual marker so the player can find it in 3D.
	var marker := MeshInstance3D.new()
	marker.name = "TestLootCrate"
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.6, 0.6)
	marker.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.4, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.7, 0.3)
	mat.emission_energy_multiplier = 0.6
	marker.material_override = mat
	marker.position = crate_pos + Vector3(0, 0.3, 0)
	add_child(marker)


func _terrain3d_height(x: float, z: float, fallback: float = 0.0) -> float:
	var t3d := get_node_or_null("Terrain3D")
	if t3d == null or not "data" in t3d or t3d.data == null:
		return fallback
	var h := float(t3d.data.get_height(Vector3(x, 0.0, z)))
	if is_nan(h) or is_inf(h):
		return fallback
	return h
