@tool
class_name ImposterBaker
extends Node3D

## In-Godot bake tool for distant-tree impostor PNGs (lit-billboard
## pipeline).
##
## Replaces the old `scripts/bake_conifer_impostor.py` (Blender +
## Cycles) pipeline, which tried to reproduce close-tier lighting
## inside Cycles using a Principled BSDF — never matched Godot's
## actual `tree_dynamic.gdshader` output.
##
## **Pipeline**: produces TWO PNGs per species:
##   - `<output>_albedo.png` — UNLIT albedo with per-species leaf
##     grading + `albedo_modulation` baked in via
##     `imposter_bake_albedo.gdshader`. Auto-resolves each variant's
##     matching `TreeSpecies` from the output name (with `_1`/`_2`/
##     `_3` numbered fallback for Doug Fir's variants).
##   - `<output>_normal.png` — view-space surface normals encoded as
##     `n × 0.5 + 0.5` via `imposter_bake_normal.gdshader`.
##
## The runtime `tree_cluster.gdshader` samples both, rotates baked
## view-space normals into world space via the billboard's per-
## instance basis, and runs the same `light()` model as close-tier
## (wrap diffuse + warm transmission backlight + sky-bias EMISSION)
## against the live world sun. Distant trees track dynamic sun
## direction, time-of-day, and weather lighting.
##
## Per-species color comes from the bake; per-frame lighting comes
## from the runtime — see CLAUDE.md "Critical Rules" for the
## rationale (we tried baking lighting in for full color match;
## reverted because dynamic lighting is more important than
## perfect-noon match).
##
## **Usage**:
##   1. Open any test scene (e.g. `cascade_locks_test.tscn`).
##   2. Add a Node3D and attach this script — or use the existing
##      `Procedural/Vegetation/DistantTrees/ImposterBaker` node.
##   3. Configure `bake_glb_paths` + `bake_output_names` (defaults
##      match the 14 species in the old Blender script). Per-variant
##      `bake_species_paths` are optional; an empty entry triggers
##      auto-resolve from `<output_name>_impostor` →
##      `res://resources/foliage/trees/<name>.tres`.
##   4. Click **Bake all impostors** in the inspector. Output PNGs
##      land at `<output_directory>/<output_name>_albedo.png` and
##      `<output_directory>/<output_name>_normal.png`. The script
##      auto-pings `EditorFileSystem.update_file` per PNG so Godot
##      imports them immediately.
##   5. Click **Bake distant trees** on `TreeClusterScatter` to
##      regenerate per-variant placements against the new PNGs.
##
## **Editor-only**. Headless rendering of SubViewports is brittle
## the same way Terrain3D's bake buttons are; we don't try.

const _ALBEDO_SHADER_PATH := "res://shaders/imposter_bake_albedo.gdshader"
const _NORMAL_SHADER_PATH := "res://shaders/imposter_bake_normal.gdshader"

@export_group("Source")
## GLB asset paths (repo-relative, e.g. `res://assets/models/...`).
## Each entry is baked once. Index-aligned with `bake_output_names`.
##
## Stored as `Array[String]` (not `Array[Resource]`) per the project
## memo about Godot 4.6.2 inspector segfaults on Resource swaps in
## arrays — see CLAUDE.md "Critical Rules".
@export var bake_glb_paths: Array[String] = [
	"res://assets/models/plants_cgtrader/morepines/Pine_18m_fresh.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_20m_twiggy.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_16m.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_15m_fresh.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_12m_twiggy.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_9m.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_4m.glb",
	"res://assets/models/plants_cgtrader/morepines/Pine_2m_twiggy.glb",
	"res://assets/models/plants_cgtrader/pines/pine_06.glb",
	"res://assets/models/plants_cgtrader/pines/pine_03.glb",
	"res://assets/models/plants_cgtrader/pines/pine_07.glb",
	"res://assets/models/plants_fab/tree_douglas_fir/large_1.glb",
	"res://assets/models/plants_fab/tree_douglas_fir/medium_1.glb",
	"res://assets/models/plants_fab/tree_douglas_fir/small_1.glb",
]

## Output base names, index-aligned with `bake_glb_paths`. Each entry
## produces `<name>_albedo.png` + `<name>_normal.png` in
## `output_directory`. Match the existing impostor naming convention
## so downstream `TreeClusterScatter` references stay coherent.
@export var bake_output_names: Array[String] = [
	"pine_p3d_mature_lush_impostor",
	"pine_p3d_mature_twiggy_impostor",
	"pine_p3d_mature_impostor",
	"pine_p3d_medium_lush_impostor",
	"pine_p3d_medium_twiggy_impostor",
	"pine_p3d_small_impostor",
	"pine_p3d_young_impostor",
	"pine_p3d_sapling_impostor",
	"pine_cg_large_impostor",
	"pine_cg_medium_impostor",
	"pine_cg_small_impostor",
	"doug_fir_large_impostor",
	"doug_fir_medium_impostor",
	"doug_fir_small_impostor",
]

## Optional `TreeSpecies` resource paths (parallel to
## `bake_glb_paths`). When set, the baker reads each species'
## `leaf_hue_shift` / `leaf_saturation_mul` / `leaf_value_mul` /
## `leaf_threshold` and applies them to the albedo pass — so the
## baked impostor's color matches whatever leaf grading the close-
## tier `tree_dynamic.gdshader` produces for that species. Empty
## entries fall back to neutral grading.
@export var bake_species_paths: Array[String] = []

@export_group("Output")
@export_dir var output_directory: String = "res://assets/textures/foliage/"

## Final PNG resolution. 512×1024 portrait matches conifer
## silhouettes and the `TreeClusterScatter` 8 m × 18 m card aspect.
@export var atlas_size: Vector2i = Vector2i(512, 1024)

## Camera ortho-size padding (×AABB extent). 1.05 = 5 % margin so
## fronds at the silhouette edge don't clip.
@export_range(1.0, 2.0, 0.01) var camera_padding: float = 1.05

@export_group("Bake")
## Drop fully-transparent border pixels and resize back to atlas
## size. Mirrors the Cycles + ImageMagick `-trim` step from the
## previous Blender pipeline. Without this, sparse trees leave most
## of the texture transparent and the runtime card displays a thin
## centered sliver. Albedo and normal share the same trim rect so
## their UVs align at runtime.
@export var trim_to_silhouette: bool = true

## Hide mesh surfaces whose material/surface name contains any of
## these substrings (case-insensitive). Default removes trunks +
## bark, which otherwise show as crisp dark vertical lines through
## the canopy's alpha-card gaps. Real conifers' overlapping fronds
## fill those gaps at distance; a single-tree bake can't reproduce
## that, so dropping the trunk is the cheap correct fix — at >800 m
## a trunk is sub-pixel anyway.
##
## If a species' canopy is geometrically too sparse and you want the
## trunk to peek through, clear this list before re-baking that
## species.
@export var hide_surface_name_substrings: Array[String] = [
	"trunk", "bark", "wood", "stem", "log",
]

## Minimum row alpha-density to count as the canopy BOTTOM (used to
## clip below-canopy trunk-line stripes from the rect). Top of the
## canopy (pointy conifer tips) and side bounds use any-pixel
## detection so the crop preserves the natural silhouette outline.
##
## 0.03 = "the canopy bottom is the lowest row where ≥3 % of pixels
## are opaque". Raise to 0.05–0.08 if isolated trunk-lines still
## sneak in. Lower toward 0.01 if the canopy bottom looks chopped.
@export_range(0.0, 0.20, 0.005) var canopy_rect_density_threshold: float = 0.03

## Synthesize a thin dark trunk stripe below the cropped canopy so
## the impostor reads as planted on the ground (without internal
## trunk visibility through canopy gaps). Disable to render
## canopy-only with no implied trunk.
@export var synthesize_trunk_shadow: bool = true
## Length of the synthesized trunk stripe as a fraction of the
## cropped canopy's height. 0.30 = trunk extension is 30 % as tall
## as the canopy itself.
@export_range(0.05, 1.0, 0.05) var trunk_shadow_length: float = 0.30
## Width of the trunk stripe as a fraction of the cropped canopy's
## width. Real conifer trunks are very thin from distance; 0.025 =
## 2.5 % of canopy width is a believable thin trunk silhouette.
@export_range(0.005, 0.15, 0.005) var trunk_shadow_width: float = 0.025
## Trunk stripe color (linear, before any runtime modulation).
## Dark brown matches typical conifer bark in shadow.
@export var trunk_shadow_color: Color = Color(0.08, 0.06, 0.04, 0.80)

@export_tool_button("Bake all impostors") var _bake_all = bake_all
@export_tool_button("Bake first impostor only (preview)") var _bake_first = bake_first

# --- internal node refs --------------------------------------------

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _tree_root: Node3D = null
var _albedo_shader: Shader = null
var _normal_shader: Shader = null


func _ready() -> void:
	ensure_children()


# Build the SubViewport / Camera3D / TreeRoot triple lazily so the
# user only has to attach this script to a Node3D — no .tscn boilerplate
# to maintain. Runs in editor (@tool) and at runtime.
#
# **Critical**: the SubViewport gets its OWN `World3D` so it is fully
# isolated from the host scene's WorldEnvironment + scattered geometry.
# Without this, `transparent_bg = true` is overridden by an inherited
# `BG_SKY` env (every pixel paints opaque sky → saved PNG alpha = 1
# everywhere → impostor renders as a black rectangle), and the bake
# camera also sees terrain / other scatters that happen to sit near
# the world origin where the bake tree is positioned.
func ensure_children() -> void:
	_viewport = get_node_or_null("BakeViewport") as SubViewport
	if _viewport == null:
		_viewport = SubViewport.new()
		_viewport.name = "BakeViewport"
		_viewport.transparent_bg = true
		_viewport.msaa_3d = Viewport.MSAA_4X
		_viewport.size = atlas_size
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_viewport)
	else:
		_viewport.size = atlas_size

	# Always attach a fresh isolated World3D + clear-color Environment.
	# Done outside the create-once block so re-opening the scene also
	# re-isolates after a Godot restart drops in-memory pointers.
	if _viewport.world_3d == null \
			or _viewport.world_3d == get_viewport().world_3d:
		var iso_world := World3D.new()
		var iso_env := Environment.new()
		iso_env.background_mode = Environment.BG_CLEAR_COLOR
		# Tonemap defaults to LINEAR which preserves bake values 1:1
		# (no sRGB curve compression of leaf colors).
		iso_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		iso_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		iso_world.environment = iso_env
		_viewport.world_3d = iso_world

	_camera = _viewport.get_node_or_null("BakeCamera") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "BakeCamera"
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.size = 20.0
		_camera.near = 0.1
		_camera.far = 200.0
		_camera.current = true
		_viewport.add_child(_camera)

	_tree_root = _viewport.get_node_or_null("TreeRoot") as Node3D
	if _tree_root == null:
		_tree_root = Node3D.new()
		_tree_root.name = "TreeRoot"
		_viewport.add_child(_tree_root)

	if _albedo_shader == null:
		_albedo_shader = load(_ALBEDO_SHADER_PATH) as Shader
	if _normal_shader == null:
		_normal_shader = load(_NORMAL_SHADER_PATH) as Shader


# --- public bake entry points --------------------------------------

func bake_all() -> void:
	ensure_children()
	if bake_glb_paths.size() != bake_output_names.size():
		push_error(("[imposter_baker] bake_glb_paths (%d) and "
			+ "bake_output_names (%d) must be the same length")
			% [bake_glb_paths.size(), bake_output_names.size()])
		return
	for i in bake_glb_paths.size():
		await _bake_one(i)
	_post_bake_import()
	print("[imposter_baker] done — baked %d species" % bake_glb_paths.size())
	print("[imposter_baker]   → next: select TreeClusterScatter and "
		+ "click 'Bake distant trees' to spawn MMIs with the new "
		+ "textures. The scatter caches placements per variant — it "
		+ "won't pick up the new PNGs until you re-bake placements.")


func bake_first() -> void:
	ensure_children()
	if bake_glb_paths.is_empty():
		push_error("[imposter_baker] bake_glb_paths is empty")
		return
	await _bake_one(0)
	_post_bake_import()
	print("[imposter_baker] preview bake done")


# After writing PNGs to disk, ping the editor filesystem so the new
# images get imported as Texture2D resources. Without this step
# `ResourceLoader.exists()` returns false on the freshly-written paths
# and `TreeClusterScatter._bake` silently skips every variant — visible
# as "I baked but see nothing in the distance".
func _post_bake_import() -> void:
	if not Engine.is_editor_hint():
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	# Ping each PNG explicitly so it imports even if a pending scan
	# would otherwise miss it (large projects can lag the scan by
	# minutes; explicit `update_file` is immediate).
	var suffixes: Array[String] = ["_albedo.png", "_normal.png"]
	for out_name in bake_output_names:
		var base: String = _dir_with_trailing_slash(output_directory) + out_name
		for suffix in suffixes:
			var p: String = base + suffix
			if FileAccess.file_exists(p):
				efs.update_file(p)
	efs.scan()


# --- per-species bake ----------------------------------------------

func _bake_one(idx: int) -> void:
	var glb_path: String = bake_glb_paths[idx]
	var out_name: String = bake_output_names[idx]
	var species_path: String = ""
	if idx < bake_species_paths.size():
		species_path = bake_species_paths[idx]
	# Auto-resolve from output_name if no explicit path was provided.
	# E.g. `pine_p3d_mature_lush_impostor` →
	# `res://resources/foliage/trees/pine_p3d_mature_lush.tres`.
	# Doug Fir's `_1`/`_2`/`_3` numbered variants are tried as
	# fallback so `doug_fir_large_impostor` resolves to
	# `doug_fir_large_1.tres`.
	if species_path.is_empty():
		species_path = _auto_species_path(out_name)
	print("[imposter_baker] [%d/%d] baking %s ← %s (species: %s)"
		% [idx + 1, bake_glb_paths.size(), out_name, glb_path,
		species_path if species_path != "" else "<none, defaults>"])

	var packed: PackedScene = load(glb_path) as PackedScene
	if packed == null:
		push_error("[imposter_baker] could not load %s" % glb_path)
		return
	var instance: Node = packed.instantiate()
	if instance == null:
		push_error("[imposter_baker] could not instantiate %s" % glb_path)
		return
	# Clear previous bake's tree, install this one.
	for c in _tree_root.get_children():
		c.queue_free()
	_tree_root.add_child(instance)
	# Wait one frame so the instance's children are present in the tree
	# (some glTF imports defer resource binding by a frame).
	await get_tree().process_frame

	# Drop LOD1+ surfaces so we render the highest-quality silhouette,
	# matching the Blender flow's `_LOD\d` filter.
	_hide_secondary_lods(instance)

	# Compute combined world-space AABB across the kept MeshInstance3Ds.
	var aabb := _compute_combined_aabb(instance)
	if aabb.size == Vector3.ZERO:
		push_warning("[imposter_baker] empty AABB for %s — skipped"
			% out_name)
		instance.queue_free()
		return

	# Frame the camera. The bake camera looks along world -Z toward
	# the tree at world origin (after the instance is positioned at
	# origin). Ortho size = max(width, height * width-bias) so portrait
	# trees fit vertically without horizontal clipping.
	_frame_camera(aabb)

	# Resolve leaf-grading uniforms from the optional TreeSpecies.
	var grading := _resolve_grading(species_path)

	# Single canopy-only bake for both albedo and normal. Trunks are
	# kept hidden via `hide_surface_name_substrings` so the canopy
	# silhouette has no internal trunk-line visibility (which read
	# as crisp dark stripes through fronds at distance — real
	# conifers' overlapping canopies + atmospheric haze hide that).
	# After cropping to the canopy rect, a thin synthesized trunk
	# shadow is composited BELOW the canopy so the impostor reads
	# as ground-planted instead of a floating leaf cluster.

	# --- Pass 1: albedo ----
	_apply_bake_material(instance, _albedo_shader, grading)
	var albedo_raw := await _render_once()
	var canopy_rect: Rect2i = _find_dense_canopy_rect(albedo_raw,
		canopy_rect_density_threshold)
	if canopy_rect.size == Vector2i.ZERO:
		push_warning("[imposter_baker] empty canopy rect for %s — skipped"
			% out_name)
		instance.queue_free()
		return
	print("[imposter_baker]   canopy_rect: %s (img %s)" % [
		canopy_rect, albedo_raw.get_size()])
	var albedo_img := _compose_with_trunk(albedo_raw, canopy_rect, true)
	var albedo_path: String = "%s%s_albedo.png" % [
		_dir_with_trailing_slash(output_directory), out_name]
	var err := albedo_img.save_png(ProjectSettings.globalize_path(albedo_path))
	if err != OK:
		push_error("[imposter_baker] albedo save failed (%d) → %s"
			% [err, albedo_path])

	# --- Pass 2: normal ----
	_apply_bake_material(instance, _normal_shader, {})
	var normal_raw := await _render_once()
	var normal_img := _compose_with_trunk(normal_raw, canopy_rect, false)
	var normal_path: String = "%s%s_normal.png" % [
		_dir_with_trailing_slash(output_directory), out_name]
	err = normal_img.save_png(ProjectSettings.globalize_path(normal_path))
	if err != OK:
		push_error("[imposter_baker] normal save failed (%d) → %s"
			% [err, normal_path])

	print("[imposter_baker]   → %s + _normal.png" % albedo_path)
	instance.queue_free()


# --- helpers --------------------------------------------------------

# Walk the imported GLB tree, drop MeshInstance3Ds whose name encodes a
# non-zero LOD (Doug Fir ships LOD1/LOD2/LOD3 nodes alongside LOD0).
# Mirror of `bake_conifer_impostor.py::import_glb` LOD filter.
func _hide_secondary_lods(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var nm := n.name as String
			var idx := nm.rfind("_LOD")
			if idx >= 0 and idx + 4 < nm.length() \
					and nm[idx + 4].is_valid_int() \
					and nm[idx + 4] != "0":
				n.visible = false
				continue
		for c in n.get_children():
			stack.append(c)


func _compute_combined_aabb(root: Node) -> AABB:
	var combined := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).visible:
			var mi: MeshInstance3D = n
			var local_aabb: AABB = mi.get_aabb()
			# Transform AABB into the tree-root's local space (which we
			# treat as "world space" for bake framing — the tree sits at
			# origin in this scene).
			var xform: Transform3D = mi.global_transform
			var world_aabb := xform * local_aabb
			if first:
				combined = world_aabb
				first = false
			else:
				combined = combined.merge(world_aabb)
		for c in n.get_children():
			stack.append(c)
	return combined


func _frame_camera(aabb: AABB) -> void:
	# Aspect: portrait viewport (height > width). Camera ortho `size`
	# is the LARGER world-space view extent; the smaller dim is
	# `size * (width / height)`. Pick whichever AABB axis is the
	# binding constraint.
	var aspect_w_over_h: float = float(atlas_size.x) / float(atlas_size.y)
	var size_for_height: float = aabb.size.y * camera_padding
	var width_world := maxf(aabb.size.x, aabb.size.z)
	var size_for_width: float = (width_world * camera_padding
		/ aspect_w_over_h)
	_camera.size = maxf(size_for_height, size_for_width)
	# Position camera looking along -Z at the AABB center, far enough
	# back to clear the AABB depth.
	var center: Vector3 = aabb.position + aabb.size * 0.5
	var depth_clear: float = aabb.size.z * 0.5 + 5.0
	_camera.transform = Transform3D(Basis.IDENTITY,
		Vector3(center.x, center.y, center.z + depth_clear * 4.0))
	# Adjust near/far so the AABB sits comfortably inside the frustum.
	_camera.near = 0.1
	_camera.far = depth_clear * 8.0 + 10.0


# Replace every MeshInstance3D's surface materials with a ShaderMaterial
# that runs `bake_shader`. Each material reuses the source surface's
# albedo texture so leaf-card cutouts stay correct (bark surfaces
# get bark albedo, leaf surfaces get leaf albedo). Surfaces matching
# `hide_surface_name_substrings` get a discard-everything material so
# they contribute nothing to the silhouette. Returns nothing —
# mutates the instance in place.
func _apply_bake_material(root: Node, bake_shader: Shader,
		grading: Dictionary) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var mesh: Mesh = mi.mesh
			if mesh != null:
				for s in mesh.get_surface_count():
					# Read from the MESH's intrinsic material, not
					# `mi.get_active_material(s)` — pass 1 may have
					# layered a discard override on this surface, and
					# `get_active_material` would return THAT instead
					# of the source GLB material, leaving us with no
					# albedo_texture and `hint_default_white` painting
					# the trunk pure white.
					var src_mat: Material = mesh.surface_get_material(s)
					if _should_hide_surface(src_mat, mesh, s):
						mi.set_surface_override_material(s,
							_get_discard_material())
						continue
					var src_albedo: Texture2D = _extract_albedo_tex(src_mat)
					var sm := ShaderMaterial.new()
					sm.shader = bake_shader
					if src_albedo != null:
						sm.set_shader_parameter("albedo_texture",
							src_albedo)
					if grading.has("leaf_hue_shift"):
						sm.set_shader_parameter("leaf_hue_shift",
							grading["leaf_hue_shift"])
					if grading.has("leaf_saturation_mul"):
						sm.set_shader_parameter("leaf_saturation_mul",
							grading["leaf_saturation_mul"])
					if grading.has("leaf_value_mul"):
						sm.set_shader_parameter("leaf_value_mul",
							grading["leaf_value_mul"])
					if grading.has("leaf_threshold"):
						sm.set_shader_parameter("leaf_threshold",
							grading["leaf_threshold"])
					if grading.has("species_albedo_modulation"):
						sm.set_shader_parameter("species_albedo_modulation",
							grading["species_albedo_modulation"])
					mi.set_surface_override_material(s, sm)
		for c in n.get_children():
			stack.append(c)


# Substring-match the source material's resource_name AND the mesh
# surface name (Godot 4 ArrayMesh exposes per-surface names) against
# `hide_surface_name_substrings`. Either match wins. Case-insensitive.
func _should_hide_surface(mat: Material, mesh: Mesh,
		surface_idx: int) -> bool:
	if hide_surface_name_substrings.is_empty():
		return false
	var names: Array[String] = []
	if mat != null and mat.resource_name != "":
		names.append(mat.resource_name.to_lower())
	if mesh is ArrayMesh:
		var sn: String = (mesh as ArrayMesh).surface_get_name(surface_idx)
		if sn != "":
			names.append(sn.to_lower())
	for n in names:
		for needle in hide_surface_name_substrings:
			if needle.to_lower() in n:
				return true
	return false


var _discard_material: ShaderMaterial = null


# A render-nothing material used for hidden trunk/bark surfaces. The
# inline shader just discards every fragment so the surface contributes
# zero to the bake silhouette.
func _get_discard_material() -> ShaderMaterial:
	if _discard_material != null:
		return _discard_material
	var sh := Shader.new()
	sh.code = ("shader_type spatial;\n"
		+ "render_mode unshaded, depth_draw_opaque, cull_disabled;\n"
		+ "void fragment() { discard; }\n")
	_discard_material = ShaderMaterial.new()
	_discard_material.shader = sh
	return _discard_material


# Pull `albedo_texture` from a StandardMaterial3D / BaseMaterial3D, or
# the first sampler2D in a ShaderMaterial. Returns null if none.
func _extract_albedo_tex(mat: Material) -> Texture2D:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture
	if mat is ShaderMaterial:
		var sm: ShaderMaterial = mat
		# Try the common names.
		for k in ["albedo_texture", "albedo_tex", "texture_albedo"]:
			var t = sm.get_shader_parameter(k)
			if t is Texture2D:
				return t
	return null


# Render the SubViewport once and return the captured Image.
func _render_once() -> Image:
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Two frames: one to apply the new material/transform, one for the
	# render to flush. `await RenderingServer.frame_post_draw` would
	# also work but `process_frame` is safer in @tool context.
	await get_tree().process_frame
	await get_tree().process_frame
	var tex: ViewportTexture = _viewport.get_texture()
	if tex == null:
		push_error("[imposter_baker] viewport produced no texture")
		return Image.create(atlas_size.x, atlas_size.y, false,
			Image.FORMAT_RGBA8)
	var img: Image = tex.get_image()
	if img == null:
		push_error("[imposter_baker] viewport image was null")
		return Image.create(atlas_size.x, atlas_size.y, false,
			Image.FORMAT_RGBA8)
	# Image flush may produce data in a non-RGBA8 format; normalize.
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


# Crop to an EXPLICIT rect (not the image's own used_rect), resize
# back to atlas size, then vertical flip. The explicit-rect path lets
# the canopy-probe pass dictate the bounds for the full-mesh albedo
# and normal passes — so trunks below the canopy get cropped away
# while trunks INSIDE the canopy region (filling leaf-card alpha
# gaps) survive.
#
# **Why the flip**: `tree_cluster.gdshader`'s vertex builds the quad
# with UV.y=0 at the GROUND vertex and UV.y=1 at the TOP. Sampling
# `texture(albedo_tex, UV)` at UV.y=0 reads PNG row 0. The bake
# camera renders with image y=0 at the TOP of the rendered scene —
# = top of tree. Without flipping, UV.y=0 (ground sample) reads
# PNG row 0 (tree top) and every distant tree renders inverted.
# Same fix the Blender pipeline used (`magick -flip`).
# Crop the bake to the canopy rect, append a synthesized trunk-shadow
# stripe BELOW the canopy, resize to atlas size, then vertical flip.
#
# **Why synthesis**: a canopy bake with internal trunks visible
# reads as crisp dark stripes through the leaf cards from distance
# — real conifers' overlapping canopies + atmospheric haze hide
# that. A canopy bake with NO trunk reads as a floating leaf
# cluster. The middle ground: hide trunks in the bake, then paint
# a thin dark stripe in extra rows below the cropped canopy. Wide
# enough to ground the impostor, narrow enough to read as haze.
#
# **Why the flip**: `tree_cluster.gdshader` builds the quad with
# UV.y=0 at the GROUND vertex; sampling at UV.y=0 reads PNG row 0.
# The bake camera puts image y=0 at the TOP of the rendered scene
# (= top of tree). Without the flip, UV.y=0 (ground sample) reads
# PNG row 0 (tree top) and trees render inverted.
func _compose_with_trunk(raw: Image, canopy_rect: Rect2i,
		is_albedo_pass: bool) -> Image:
	if canopy_rect.size == Vector2i.ZERO:
		return raw
	var ix: int = clamp(canopy_rect.position.x, 0, raw.get_width() - 1)
	var iy: int = clamp(canopy_rect.position.y, 0, raw.get_height() - 1)
	var iw: int = min(canopy_rect.size.x, raw.get_width() - ix)
	var ih: int = min(canopy_rect.size.y, raw.get_height() - iy)
	var safe_rect := Rect2i(Vector2i(ix, iy), Vector2i(iw, ih))
	var canopy: Image = raw.get_region(safe_rect)
	if not synthesize_trunk_shadow:
		canopy.resize(atlas_size.x, atlas_size.y, Image.INTERPOLATE_BILINEAR)
		canopy.flip_y()
		return canopy
	var trunk_h: int = max(1, int(round(float(ih) * trunk_shadow_length)))
	var combined_h: int = ih + trunk_h
	var combined: Image = Image.create(iw, combined_h, false,
		Image.FORMAT_RGBA8)
	combined.fill(Color(0.0, 0.0, 0.0, 0.0))
	combined.blit_rect(canopy,
		Rect2i(Vector2i.ZERO, Vector2i(iw, ih)), Vector2i.ZERO)
	# Paint trunk stripe in the bottom `trunk_h` rows.
	var stripe_w: int = max(1, int(round(float(iw) * trunk_shadow_width)))
	var stripe_x_center: int = _find_canopy_center_column(canopy)
	var stripe_x_left: int = clamp(
		stripe_x_center - stripe_w / 2, 0, iw - stripe_w)
	var stripe_color: Color
	if is_albedo_pass:
		stripe_color = trunk_shadow_color
	else:
		# Camera-facing normal encoded as `n*0.5+0.5`. View +Z = (0,0,1)
		# → (0.5, 0.5, 1.0). Alpha matches the albedo stripe so the
		# scissor logic stays consistent across both channels.
		stripe_color = Color(0.5, 0.5, 1.0, trunk_shadow_color.a)
	for y in range(ih, combined_h):
		for x in range(stripe_x_left, stripe_x_left + stripe_w):
			combined.set_pixel(x, y, stripe_color)
	combined.resize(atlas_size.x, atlas_size.y, Image.INTERPOLATE_BILINEAR)
	combined.flip_y()
	return combined


# Find the X column where the cropped canopy's bottom mass is
# centered — weighted by alpha. Used to align the synthesized trunk
# stripe with the canopy's bottom (where a real trunk would attach),
# not the canopy's overall horizontal mid-point. Cheap one-pass.
func _find_canopy_center_column(canopy: Image) -> int:
	var w: int = canopy.get_width()
	var h: int = canopy.get_height()
	if w == 0 or h == 0:
		return 0
	var data: PackedByteArray = canopy.get_data()
	var weighted_sum := 0.0
	var total_weight := 0.0
	# Scan only the bottom 30 % — the trunk attaches below the canopy
	# in real life, so the trunk should align with that mass center.
	var y_start: int = int(float(h) * 0.7)
	for y in range(y_start, h):
		var row_off: int = y * w * 4 + 3
		for x in w:
			var a: int = data[row_off + x * 4]
			if a > 127:
				weighted_sum += float(x)
				total_weight += 1.0
	if total_weight <= 0.0:
		return w / 2
	return int(round(weighted_sum / total_weight))


# Asymmetric canopy bounds: the BOTTOM row uses a density threshold
# (drops sparse trunk-line rows that survive the canopy-only bake
# via leaf-textured branches in assets like Fab Doug Fir). TOP row
# and SIDES use any-pixel detection (alpha > 0.5) so pointy conifer
# tips and natural canopy width survive — using density on those
# would chop the silhouette into a rectangle.
func _find_dense_canopy_rect(img: Image, density: float) -> Rect2i:
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w == 0 or h == 0:
		return Rect2i()
	var col_thresh: int = max(1, int(float(w) * density))
	var data: PackedByteArray = img.get_data()
	var row_dense_counts: PackedInt32Array = PackedInt32Array()
	row_dense_counts.resize(h)
	var min_y_any := -1
	var max_y_any := -1
	var min_x_any := -1
	var max_x_any := -1
	for y in h:
		var row_off: int = y * w * 4 + 3
		var rc := 0
		var row_has_any := false
		for x in w:
			var a: int = data[row_off + x * 4]
			if a > 127:
				rc += 1
				row_has_any = true
				if min_x_any == -1 or x < min_x_any:
					min_x_any = x
				if x > max_x_any:
					max_x_any = x
		row_dense_counts[y] = rc
		if row_has_any:
			if min_y_any == -1:
				min_y_any = y
			max_y_any = y
	if min_y_any == -1:
		return Rect2i()
	# TOP: first any-pixel row (preserves pointy canopy tip).
	var top: int = min_y_any
	# BOTTOM: scanning UP from the lowest any-pixel row, find the
	# first row that's "dense" (≥ col_thresh opaque pixels).
	# Anything below that is the sparse trunk-only stripe — dropped.
	var bottom: int = max_y_any
	for y in range(max_y_any, top - 1, -1):
		if row_dense_counts[y] >= col_thresh:
			bottom = y
			break
	# SIDES: any-pixel bounds.
	var left: int = min_x_any
	var right: int = max_x_any
	return Rect2i(Vector2i(left, top),
		Vector2i(right - left + 1, bottom - top + 1))


func _resolve_grading(species_path: String) -> Dictionary:
	if species_path.is_empty():
		return {}
	var sp: Resource = load(species_path)
	if sp == null:
		push_warning("[imposter_baker] species not found: %s"
			% species_path)
		return {}
	var grading: Dictionary = {}
	for k in ["leaf_hue_shift", "leaf_saturation_mul",
			"leaf_value_mul", "leaf_threshold"]:
		if k in sp:
			grading[k] = sp.get(k)
	# Pre-lit bake also captures species `albedo_modulation` so the
	# baked PNG matches close-tier color exactly. Stored as Vector3
	# for the shader uniform (not the engine's Color type).
	if "albedo_modulation" in sp:
		var c: Color = sp.albedo_modulation
		grading["species_albedo_modulation"] = Vector3(c.r, c.g, c.b)
	return grading


# Resolve a TreeSpecies for an output_name by stripping `_impostor`
# and trying numbered suffixes (`_1` / `_2` / `_3`) — mirrors the
# runtime auto-resolve in `tree_cluster_scatter._resolve_species_for`.
# Returns the species path or "" if no match.
func _auto_species_path(output_name: String) -> String:
	var base: String = output_name
	if base.ends_with("_impostor"):
		base = base.substr(0, base.length() - "_impostor".length())
	var dir: String = "res://resources/foliage/trees/"
	for suffix in ["", "_1", "_2", "_3"]:
		var candidate: String = dir + base + suffix + ".tres"
		if ResourceLoader.exists(candidate):
			return candidate
	return ""


func _dir_with_trailing_slash(d: String) -> String:
	if d.is_empty():
		return "res://"
	if d.ends_with("/"):
		return d
	return d + "/"
