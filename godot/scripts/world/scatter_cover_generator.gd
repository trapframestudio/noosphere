extends Node
## Auto-generates cover volumes from procedural scatter data (rocks
## and trees). Call after scatter bakes are loaded to register cover
## for every placed rock and tree trunk.
##
## Rocks → earth/concrete cover (based on size)
## Trees → wood cover (trunk-width cylinder)
##
## See `docs/book/src/planning/sim-overhaul-plan.md` Phase 3D.

## Material names matching CoverMaterialId variants in cover.rs
const ROCK_MATERIAL: String = "Earth"
const TREE_MATERIAL: String = "WoodThick"

## Minimum rock scale to generate cover (skip pebbles/gravel)
const MIN_ROCK_SCALE: float = 1.5
## Tree trunk half-width in meters (trees are thin vertical cover)
const TREE_TRUNK_HALF_W: float = 0.3
## Tree trunk half-height (cover height)
const TREE_TRUNK_HALF_H: float = 1.2

## Walk all RockScatter and TreeScatter MultiMesh instances in the
## scene tree and register cover volumes with the sim for each
## placed instance above the minimum size threshold.
##
## Returns the number of cover volumes registered.
static func generate_cover_from_scatters(
	tree: SceneTree,
	region_name: String,
) -> int:
	if tree == null:
		return 0
	var session := tree.root.get_node_or_null("GameSession")
	if session == null:
		return 0
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("register_cover_volume"):
		return 0

	var registered := 0

	# --- Rocks ---
	var rock_scatters: Array[Node] = tree.get_nodes_in_group(&"rock_scatters")
	for scatter_node in rock_scatters:
		if not scatter_node is Node3D:
			continue
		for child in scatter_node.get_children():
			if not child is MultiMeshInstance3D:
				continue
			var mmi: MultiMeshInstance3D = child
			var mm := mmi.multimesh
			if mm == null or mm.instance_count == 0:
				continue
			for i in mm.instance_count:
				var xf: Transform3D = mmi.global_transform * mm.get_instance_transform(i)
				var s := xf.basis.get_scale()
				var avg_scale := (s.x + s.y + s.z) / 3.0
				if avg_scale < MIN_ROCK_SCALE:
					continue
				var half := Vector3(s.x * 0.4, s.y * 0.4, s.z * 0.4)
				var pos := xf.origin
				var q := xf.basis.get_rotation_quaternion()
				var thickness := avg_scale * 200.0
				sim.register_cover_volume(
					region_name,
					pos,
					half,
					q,
					ROCK_MATERIAL,
					1, # HIGH
					thickness,
					false, # not destructible
					100.0,
				)
				registered += 1

	# --- Trees ---
	var tree_scatters: Array[Node] = tree.get_nodes_in_group(&"tree_scatters")
	for scatter_node in tree_scatters:
		if not scatter_node is Node3D:
			continue
		for child in scatter_node.get_children():
			if not child is MultiMeshInstance3D:
				continue
			var mmi: MultiMeshInstance3D = child
			var mm := mmi.multimesh
			if mm == null or mm.instance_count == 0:
				continue
			for i in mm.instance_count:
				var xf: Transform3D = mmi.global_transform * mm.get_instance_transform(i)
				var s := xf.basis.get_scale()
				var trunk_w := TREE_TRUNK_HALF_W * s.x
				var trunk_h := TREE_TRUNK_HALF_H * s.y
				var pos := xf.origin
				pos.y += trunk_h
				var q := Quaternion.IDENTITY
				sim.register_cover_volume(
					region_name,
					pos,
					Vector3(trunk_w, trunk_h, trunk_w),
					q,
					TREE_MATERIAL,
					0, # LOW (trunk only protects crouching)
					150.0 * s.x,
					false,
					100.0,
				)
				registered += 1

	if registered > 0:
		print("[ScatterCoverGen] Registered %d cover volumes from scatter data in %s" % [registered, region_name])
	return registered
