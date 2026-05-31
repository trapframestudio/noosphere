@tool
class_name TreeTestSpawn
extends Node3D

## Editor + runtime helper that pops a single Birch tree into the
## scene, with the tree-tier `tree_dynamic.gdshader` applied to its
## bark + atlas surfaces. Lets us validate the shader before the
## full TreeSpecies / TreeScatter pipeline lands.
##
## Usage: drop this node into any scene (e.g. `cascade_locks_test`)
## near the player spawn. On `_ready` it instantiates the birch
## gltf, locates the LOD0 bark + atlas mesh of one variant, builds
## ShaderMaterial wrappers from the imported textures, and adds two
## `MeshInstance3D` children at this node's position.
##
## Toggle `editor_preview` to spawn / despawn in editor without
## entering Play mode. Re-spawning is cheap (cached load).

## How to position the spawned tree on `_ready`:
## - "manual": leave at this node's transform.origin (drag in editor)
## - "editor_camera": snap to the editor 3D viewport camera's
##    look-at point (only meaningful in editor)
## - "node_path": copy the position from `auto_pos_node`
@export_enum("manual", "editor_camera", "node_path") var auto_pos: String = "node_path"

## Node whose global_position to copy when `auto_pos = "node_path"`.
## Defaults to the Player node sibling for the cascade_locks scene.
@export_node_path("Node3D") var auto_pos_node: NodePath = NodePath("../Player")

## When set, snap the spawn's Y to the Terrain3D surface at this
## XZ. Avoids "tree buried in the mountain" — what just happened to
## the user. Off → use whatever Y the auto-pos node provides.
@export var snap_to_terrain: bool = true

## Path to the Terrain3D node used for ground-Y queries.
@export_node_path("Node3D") var terrain3d_path: NodePath = NodePath("../Terrain3D")

@export var birch_pack_path: String = "res://assets/models/trees/birch_lod_pack/scene.gltf"

## Which top-level birch variant to use. The pack ships 5
## ("Birch", "Birch_2", "Birch_3", "Birch_4", "Birch_5"); each has a
## bark + atlas pair at LOD0 / LOD1 / LOD2.
@export var variant_prefix: String = "Birch"

## Per-tree wind sway scale (passed to the shader). Mature birches
## should sway less in absolute meters than saplings, so default to
## 0.4.
@export_range(0.0, 5.0, 0.1) var wind_amplitude_scale: float = 0.4

## Trunk-base anchor height in meters. Vertex-bend below this is
## zero — keeps the lower trunk planted while the canopy flexes.
@export_range(0.0, 5.0, 0.1) var trunk_anchor_height: float = 0.5

@export var editor_preview: bool = false : set = _set_editor_preview

@export_tool_button("Force respawn", "Reload") var force_respawn_action: Callable = _force_respawn


const TREE_SHADER_PATH := "res://shaders/tree_dynamic.gdshader"

var _spawned_root: Node3D = null
var _lit_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview:
		return
	_apply_auto_pos()
	_spawn()


func _force_respawn() -> void:
	_apply_auto_pos()
	_spawn()


func _apply_auto_pos() -> void:
	match auto_pos:
		"editor_camera":
			if Engine.is_editor_hint():
				var vp := EditorInterface.get_editor_viewport_3d() if Engine.has_singleton("EditorInterface") else null
				var cam: Camera3D = vp.get_camera_3d() if vp != null else null
				if cam != null:
					global_position = cam.global_position - cam.global_transform.basis.z * 8.0
		"node_path":
			var n := get_node_or_null(auto_pos_node) as Node3D
			if n != null:
				global_position = n.global_position + Vector3(3.0, 0.0, 0.0)
	if snap_to_terrain:
		var t := get_node_or_null(terrain3d_path)
		if t != null and "data" in t:
			var h: float = t.data.get_height(Vector3(global_position.x, 0.0, global_position.z))
			if not is_nan(h):
				global_position.y = h


func _set_editor_preview(v: bool) -> void:
	editor_preview = v
	if not is_inside_tree():
		return
	if v:
		_spawn()
	else:
		_despawn()


func _despawn() -> void:
	if is_instance_valid(_spawned_root):
		_spawned_root.queue_free()
	_spawned_root = null
	_lit_meshes.clear()


func _spawn() -> void:
	_despawn()
	var packed: PackedScene = load(birch_pack_path) as PackedScene
	if packed == null:
		push_warning("[tree-test] failed to load %s" % birch_pack_path)
		return
	# Instance the whole packed scene so the importer's Z-up→Y-up
	# rotation (typically parked on a `Sketchfab_model` parent node)
	# stays applied. Pulling individual MeshInstance3Ds out by name
	# and re-spawning them under our node throws away that parent
	# basis → the tree renders rotated 90° onto its side.
	var root_node: Node3D = packed.instantiate() as Node3D
	if root_node == null:
		push_warning("[tree-test] pack root is not Node3D")
		return
	root_node.name = "BirchPack"
	add_child(root_node)
	_spawned_root = root_node

	# Replace the imported StandardMaterial3D on each MeshInstance3D
	# with our ShaderMaterial wrapping its textures, so the tree
	# shader (cull_back, anchored wind, alpha cutout) drives rendering.
	# Hide any MI whose name doesn't start with `<variant_prefix>_` —
	# that filters out the other 4 birches AND the LOD1/LOD2 versions
	# of the chosen one (their names have `_LOD1` / `_LOD2` after the
	# prefix; we want the no-suffix LOD0 only for the validation).
	var shader: Shader = load(TREE_SHADER_PATH) as Shader
	var lod0_prefix := variant_prefix + "_Birch_"  # e.g. "Birch_Birch_"
	var lod_re := RegEx.new()
	lod_re.compile("_LOD\\d+_")
	var mis: Array[MeshInstance3D] = []
	_collect_mesh_instances(root_node, mis)
	for mi in mis:
		# Hide if not the chosen variant's LOD0.
		if not mi.name.begins_with(lod0_prefix):
			mi.visible = false
			continue
		if lod_re.search(mi.name):
			mi.visible = false
			continue
		_apply_tree_shader_to(mi, shader)
		_lit_meshes.append(mi)


func _apply_tree_shader_to(mi: MeshInstance3D, shader: Shader) -> void:
	if mi.mesh == null:
		return
	var src_mat: StandardMaterial3D = (
		mi.get_surface_override_material(0) as StandardMaterial3D)
	if src_mat == null and mi.mesh.get_surface_count() > 0:
		src_mat = mi.mesh.surface_get_material(0) as StandardMaterial3D
	var sm := ShaderMaterial.new()
	sm.shader = shader
	if src_mat != null:
		sm.set_shader_parameter("albedo_tex", src_mat.albedo_texture)
		sm.set_shader_parameter("normal_tex", src_mat.normal_texture)
	sm.set_shader_parameter("trunk_anchor_height", trunk_anchor_height)
	sm.set_shader_parameter("wind_amplitude_scale", wind_amplitude_scale)
	# Material override on the MI rather than on the mesh — keeps the
	# imported mesh resource untouched.
	mi.material_override = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _collect_mesh_instances(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_mesh_instances(c, out)
