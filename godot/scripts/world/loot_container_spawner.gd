extends Node
## Phase 3D — runtime walker that turns hand-placed
## `LootContainerMarker3D` nodes into real `WorldContainer`
## entities in the sim.
##
## Call [`spawn_authored_containers(region_name)`] from a map
## scene's `_ready` (after terrain is loaded so Y-snapping
## works). The walker iterates the `loot_container_markers`
## group and, for each marker:
##
## 1. Resolves its position in world space (with optional
##    terrain Y-snap if the map scene supplies a `Terrain`
##    sibling with `sample_height(x, z)`).
## 2. Calls `SimHost.register_authored_container(...)` to spawn
##    a `WorldContainer` with the marker's kind / interaction
##    mode / is_public / container_id / faction / depth_tier.
## 3. (Future) — replaces the marker's visual gizmo with the
##    sim-side container's visual model. For now the gizmo
##    stays in scene; the runtime container exists alongside it.
##    A follow-up pass will swap the gizmo for the rolled
##    model variant + hide it in game-mode builds.
##
## Static — call as `LootContainerSpawner.spawn_authored_containers(...)`.
## Doesn't keep per-marker state; safe to re-run if a map is
## re-loaded.

const _GROUP: StringName = &"loot_container_markers"


## Walk every `loot_container_markers` node in the active scene
## tree and register each with the sim. `region_name` is the
## map id (`"map_a"`, `"corbett"`, etc.) — the sim uses this to
## resolve the `RegionId` for the new container.
##
## Y-snap uses Terrain3D.data.get_height() if a Terrain3D sibling
## exists in the scene. Falls back to authored Y verbatim.
static func spawn_authored_containers(
	tree: SceneTree,
	region_name: String,
) -> int:
	if tree == null:
		return 0
	var session := tree.root.get_node_or_null("GameSession")
	if session == null:
		return 0
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("register_authored_container"):
		return 0
	var markers: Array[Node] = tree.get_nodes_in_group(_GROUP)
	if markers.is_empty():
		return 0

	var registered := 0
	for node in markers:
		if not (node is Node3D):
			continue
		var marker: Node3D = node
		var pos: Vector3 = marker.global_position
		var scene_root := tree.current_scene
		if scene_root:
			var t3d := scene_root.get_node_or_null("Terrain3D")
			if t3d and "data" in t3d and t3d.data != null:
				var h := float(t3d.data.get_height(Vector3(pos.x, 0, pos.z)))
				if not (is_nan(h) or is_inf(h)):
					pos.y = h
		# Resolve marker exports via duck-typing rather than a hard
		# class import — keeps the spawner script standalone.
		var kind_id: String = ""
		if marker.has_method("kind_id"):
			kind_id = String(marker.call("kind_id"))
		if kind_id.is_empty():
			continue
		var mode_id: String = "openable"
		if marker.has_method("interaction_mode_id"):
			mode_id = String(marker.call("interaction_mode_id"))
		var is_public: bool = false
		if marker.has_method("get") and marker.get("is_public") != null:
			is_public = bool(marker.get("is_public"))
		var container_id: String = ""
		if marker.get("container_id") != null:
			container_id = String(marker.get("container_id"))
		# Marker doesn't yet expose a faction export — default to
		# wanderers (the neutral pool fallback in
		# `LootPoolRegistry::lookup`). Add a marker export when
		# zones need flavored authored loot.
		var faction: String = ""
		var depth_tier: int = 1

		var cid: int = sim.register_authored_container(
			region_name,
			pos,
			kind_id,
			is_public,
			container_id,
			faction,
			depth_tier,
			mode_id,
		)
		if cid >= 0:
			registered += 1
	return registered
