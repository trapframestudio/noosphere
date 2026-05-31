extends Node
## Runtime walker that turns scene-authored `ActivityPointMarker3D`,
## `PatrolRouteMarker3D`, and `SpawnPointMarker3D` nodes into sim
## resources. Call from a map scene's `_ready` after terrain loads.
##
## See `docs/book/src/planning/sim-overhaul-plan.md` Phase 2D.

## Map from ActivityPointMarker3D.ActivityKind enum int to the Rust
## ActivityKind variant name the sim bridge accepts.
const _KIND_NAMES: Array[String] = [
	"GuardStatic",
	"GuardPerimeter",
	"PatrolWaypoint",
	"RestSpot",
	"Lookout",
	"Campfire",
	"Workbench",
	"Stash",
	"SniperNest",
	"AmbushPoint",
]

## Map from PoiMarker3D Faction enum ints to factions.toml ids.
## Shared with base_spawner.gd — keep in sync.
const _FACTION_NAMES: Array[String] = [
	"",             # NONE
	"pwa",
	"linemen",
	"revere_guard",
	"federal",
	"gulf_compact",
	"merged",
	"noosphere_worshippers",
	"looters",
	"corporate_research",
	"wanderers",
]


static func spawn_activity_points(
	tree: SceneTree,
	region_name: String,
) -> int:
	if tree == null:
		return 0
	var session := tree.root.get_node_or_null("GameSession")
	if session == null:
		return 0
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("register_activity_point"):
		return 0

	var registered := 0

	# --- Activity points ---
	var ap_markers: Array[Node] = tree.get_nodes_in_group(&"activity_points")
	for node in ap_markers:
		if not (node is ActivityPointMarker3D):
			continue
		var marker: ActivityPointMarker3D = node
		var kind_idx: int = marker.kind
		if kind_idx < 0 or kind_idx >= _KIND_NAMES.size():
			continue
		var faction_str: String = marker.faction
		var pos: Vector3 = marker.global_position
		sim.register_activity_point(
			region_name,
			_KIND_NAMES[kind_idx],
			Vector3(pos.x, pos.y, pos.z),
			marker.facing_yaw_deg,
			faction_str,
			marker.radius_m,
			marker.capacity,
			marker.priority,
			marker.loop_id,
		)
		registered += 1

	# --- Patrol routes ---
	var route_markers: Array[Node] = tree.get_nodes_in_group(&"patrol_routes")
	for node in route_markers:
		if not (node is PatrolRouteMarker3D):
			continue
		var marker: PatrolRouteMarker3D = node
		var waypoints: PackedVector3Array = marker.get_waypoints()
		if waypoints.size() < 2:
			continue
		sim.register_patrol_route(
			region_name,
			marker.route_id,
			waypoints,
			marker.faction,
			marker.loop_route,
			marker.priority,
		)
		registered += 1

	# --- Spawn points ---
	var sp_markers: Array[Node] = tree.get_nodes_in_group(&"spawn_points")
	for node in sp_markers:
		if not (node is SpawnPointMarker3D):
			continue
		var marker: SpawnPointMarker3D = node
		if marker.faction.strip_edges().is_empty():
			continue
		if not marker.enabled:
			continue
		var pos: Vector3 = marker.global_position
		var delay_ticks: int = int(marker.initial_delay_s * 20.0)
		sim.register_spawn_point(
			region_name,
			Vector3(pos.x, pos.y, pos.z),
			marker.faction,
			marker.spawn_rate,
			marker.max_concurrent,
			marker.squad_size_min,
			marker.squad_size_max,
			marker.spread_radius_m,
			marker.loadout_tier,
			delay_ticks,
		)
		registered += 1

	# --- Cover volumes ---
	var cv_markers: Array[Node] = tree.get_nodes_in_group(&"cover_volumes")
	for node in cv_markers:
		if not (node is CoverVolumeMarker3D):
			continue
		var marker: CoverVolumeMarker3D = node
		var pos: Vector3 = marker.global_position
		var he: Vector3 = marker.get_half_extents()
		var q: Quaternion = marker.global_transform.basis.get_rotation_quaternion()
		sim.register_cover_volume(
			region_name,
			Vector3(pos.x, pos.y, pos.z),
			Vector3(he.x, he.y, he.z),
			Quaternion(q.x, q.y, q.z, q.w),
			marker.material_name(),
			marker.height,
			marker.thickness_mm,
			marker.destructible,
			marker.health,
		)
		registered += 1

	if registered > 0:
		print("[ActivityPointSpawner] Registered %d activity/patrol/spawn/cover points in %s" % [registered, region_name])
	return registered
