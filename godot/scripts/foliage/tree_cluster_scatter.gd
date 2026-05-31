@tool
class_name TreeClusterScatter
extends Node3D

## **Distant tree impostor scatter** — places y-axis-billboarded
## quads sampling pre-baked conifer silhouette textures
## (`assets/textures/foliage/<variant>_impostor.png`). One MMI per
## species variant; total draw-call cost = `impostor_texture_paths.size()`
## (3 with the default doug_fir / pine / spruce mix).
##
## **Why this architecture, after iterations**:
## - Single-quad y-billboard always presents flat to camera (no
##   "edge-on disappearance" of pure y-axis billboards, no
##   "moss patches" of cross-billboards seen at oblique angles)
## - Real photo-baked texture (not procedural-in-shader) reads as
##   actual trees from any distance
## - Multiple silhouette variants — adjacent trees pick different
##   species so distant forest reads as a mixed canopy, not clones
## - Per-instance scale + tint variation via MMI per-instance color
##   keeps even same-species neighbors from being identical
## - Distance cull + fade dither in vertex shader → smooth fade-in,
##   no fragment work past `max_distance_m`
##
## **Bake model**: one-shot. Walks the coverage map at `grid_m`
## spacing, places `trees_per_cell` instances per accepted cell at
## random jittered positions. Each placement hashes to a variant
## index. Persists per-variant MultiMeshes to disk.

@export var map_id: String = "cascade_locks"
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Node3D") var terrain3d_path: NodePath

@export_group("Texture")
## Paths to per-variant impostor ALBEDO PNGs. Bake via the
## `godot/tools/imposter_baker.gd` in-Godot baker (replaces the
## deprecated `scripts/bake_conifer_impostor.py` Cycles flow).
##
## **Lit-billboard pipeline**: each entry must follow the
## `<name>_albedo.png` naming convention; the scatter auto-derives
## the companion `_normal.png` path. The bake captures per-species
## color treatment (leaf grading + `albedo_modulation`) as UNLIT
## albedo; the runtime shader samples both PNGs, rotates baked
## view-space normals into world space, and runs the same `light()`
## model as close-tier so distant trees track dynamic sun direction
## + weather lighting. Falls back to flat unshaded display when the
## `_normal.png` companion is missing (legacy single-PNG impostors).
##
## Each entry spawns its own MMI; placements distribute across
## variants via a stable per-position hash so the species mix is
## deterministic across re-bakes.
@export var impostor_texture_paths: Array[String] = [
	"res://assets/textures/foliage/doug_fir_impostor_albedo.png",
	"res://assets/textures/foliage/pine_impostor_albedo.png",
	"res://assets/textures/foliage/spruce_impostor_albedo.png",
]

@export_group("Distribution")
## World-XZ grid spacing for placement decisions. Each cell at this
## size gets `trees_per_cell` tree instances if its coverage pixel
## passes the threshold. 30 m default with ~8 trees/cell yields
## roughly 1 tree per ~110 m² — dense forest read at distance.
@export_range(10.0, 200.0, 1.0) var grid_m: float = 30.0
## Coverage-map alpha threshold for placement. Cells below this get
## ZERO trees. Above it, tree count scales with coverage value.
@export_range(0.0, 1.0, 0.01) var density_threshold: float = 0.01
## Coverage-to-density multiplier. Tree count per cell =
## `trees_per_cell × clamp(col.a × strength, 0, 1)`. Higher = denser
## (10 % coverage cell with strength 5 spawns 50 % of `trees_per_cell`).
## Eliminates the patchy "all or nothing" gate the old probabilistic
## approach produced.
@export_range(1.0, 10.0, 0.5) var coverage_density_strength: float = 5.0
## MAX trees per cell at 100 % coverage. Real count scales linearly
## with coverage value × strength. 16 trees per 18 m grid cell
## (324 m²) ≈ 1 tree per 20 m² — matches close-tier biome density.
@export_range(1, 64, 1) var trees_per_cell: int = 16
## Per-cell jitter radius as a multiple of `grid_m`. >1 lets trees
## spawn outside their cell, overlapping neighbors → smooth blue-
## noise-ish distribution instead of a visible grid pattern. 1.5 =
## trees from each cell wander into a 3× larger area; combined with
## adjacent cells' jitter, the per-cell signature disappears.
@export_range(0.5, 3.0, 0.05) var jitter_radius_mul: float = 1.5
## Random per-instance scale jitter range (1.0 ± jitter). Reads as
## natural tree-height variation. 0 = all identical, 0.4 = noticeable.
@export_range(0.0, 0.6, 0.05) var scale_jitter: float = 0.35

@export_group("Card dimensions")
## Card width / height in meters. Real-tree-sized at 8×18 reads as
## one tree per card. Bigger values read as multi-tree clumps but
## look more like wallpaper at oblique angles.
@export_range(2.0, 30.0, 0.5) var card_width_m: float = 8.0
@export_range(4.0, 50.0, 0.5) var card_height_m: float = 18.0
## Sink the bottom N% of the card below the placement origin.
## Counters two effects: (1) Terrain3D distance-LOD geomorphing can
## shift the visible terrain Y by ±1–2 m vs the heightmap sample
## the placement code used, and (2) the trunk-hidden bake puts the
## silhouette's lowest pixel at the canopy bottom (which in real
## life sits a few meters above ground), so the impostor would
## otherwise float in the gap where the trunk used to be.
##
## Fraction (vs absolute meters) so the embed auto-scales with
## `card_height_m`: a 35 m card at 0.25 sinks 8.75 m below ground;
## an 18 m card at 0.25 sinks 4.5 m. Bump higher (0.35–0.45) for
## species with very tall bare lower trunks (Doug Fir, mature
## Ponderosa); drop to 0.10 if you want trunks visible.
@export_range(0.0, 0.6, 0.01) var ground_embed_fraction: float = 0.25
## Add this much extra embed fraction at max_distance_m, ramping
## linearly from 0 at min_distance_m. Compensates Terrain3D's CLOD
## decimation at far distances (sharp ridges smooth several meters
## → trees that should be hidden behind the ridge end up visible).
## Additive (not multiplicative) so it can't compound with a large
## `ground_embed_fraction` and bury distant trees entirely. Effective
## embed clamps to 0.6 max.
@export_range(0.0, 0.4, 0.01) var embed_distance_extra: float = 0.10
## **Cross-billboards per tree.** Each placement spawns N quads at
## evenly-spaced fixed Y rotations. 1 = single quad (cards stack into
## "wall of clones" stripes when y-billboarded). 2 = perpendicular
## cross — guarantees silhouette area from every angle. 3 = hex-star
## (60° apart) — fullest depth illusion but 3× instance count. AAA
## distant-tree standard is 2.
@export_range(1, 4, 1) var cross_quads_per_tree: int = 2

@export_group("Performance")
## Spatial supercell size for frustum culling. The bake produces one
## big MultiMesh per variant (kept as-is on disk for stable LFS
## storage), but on spawn it re-buckets instances into ⌈world / chunk⌉
## smaller MultiMeshInstance3D nodes — one MMI per (variant, chunk).
## Each chunk's auto-computed AABB is tight to its supercell, so
## Godot can frustum-cull entire chunks that are off-screen.
##
## Trade-off: smaller = tighter cull at the cost of more MMI nodes
## in the scene tree (each adds per-frame VisualInstance3D bookkeeping
## even when fully culled). 1024 m with `max_distance_m = 2400 m`
## and a 90° FOV gives ~6–8 visible chunks per variant — the cull
## win is essentially the same as 512 m (which gave ~10–15 visible)
## but with 4× fewer total chunks (~880 vs ~3500 across all variants
## on cascade_locks). Drop to 512 only if profiling shows the wider
## chunk's "in-frustum but partially off-screen" instances dominating.
##
## Set to 0 to disable chunking and keep the legacy single-MMI-per-
## variant behavior (useful for debugging the chunking itself).
@export_range(0.0, 4096.0, 64.0) var chunk_size_m: float = 1024.0

@export_group("Distance band")
## Camera distance at which trees fade in. Should overlap the per-
## tree impostor outer edge for a clean handoff.
@export_range(100.0, 2000.0, 10.0) var min_distance_m: float = 600.0
## Hard backstop — trees past this distance collapse (no fragment
## cost). Cascade Locks: 2400 m covers all visible distant terrain.
@export_range(500.0, 6000.0, 50.0) var max_distance_m: float = 2400.0
## Fade-in margin at the close edge. Per-instance hash dither
## avoids hard pop as the player walks toward distant forest.
@export_range(0.0, 300.0, 10.0) var fade_margin_m: float = 80.0

@export_group("Look")
## Per-channel tint applied to the baked silhouette color. With the
## lit-billboard pipeline (2026-05-11 onward) the bake captures
## UNLIT albedo and the runtime shader handles lighting + tonemap
## via the standard pipeline, so the default is identity — no warm
## correction is needed to undo Cycles dimness. Keep it identity
## unless a species genuinely needs a per-impostor shift.
@export var albedo_modulation: Color = Color(1.0, 1.0, 1.0, 1.0)

## Warm transmission backlight strength — mirrors close-tier
## `tree_dynamic.gdshader::backlight_strength` so shadow-side leaves
## glow warm instead of going pitch black. Tune to match the
## close-tier species the impostor band fades into.
@export_range(0.0, 1.0, 0.01) var backlight_strength: float = 0.25
@export var backlight_color: Color = Color(0.85, 0.95, 0.55)
## Sky-bias emission floor — bypasses shadow attenuation so impostors
## in cascade shadow don't crater to black while close-tier still
## has ambient lift.
@export var emission_skylight_color: Color = Color(0.20, 0.22, 0.25)

@export_group("Leaf grading")
## Scatter-level color grading applied ON TOP of the bake's
## per-species grading. The bake captures each
## species' authored leaf color treatment (`leaf_value_mul` ×
## `albedo_modulation`); these knobs let you nudge the whole
## distant-tree tier as one (e.g. shift greens toward yellow for
## autumn, or desaturate everything for an overcast look) without
## re-baking.
##
## Defaults are identity (no-op) so the bake's per-species color
## shows through unchanged. Live-tunable — setters re-push to
## every spawned MMI material so changes show up immediately.
@export_range(-0.2, 0.2, 0.005) var leaf_hue_shift: float = 0.0: set = _set_leaf_hue_shift
@export_range(0.0, 2.0, 0.05) var leaf_saturation_mul: float = 1.0: set = _set_leaf_saturation_mul
@export_range(0.0, 2.0, 0.05) var leaf_value_mul: float = 1.0: set = _set_leaf_value_mul
## "Greenness" threshold — only pixels with G - max(R,B) above this
## get graded. Default 0 = grade every canopy pixel (impostors don't
## have visible bark; trunks are hidden in bake).
@export_range(0.0, 0.5, 0.01) var leaf_threshold: float = 0.0: set = _set_leaf_threshold
## Brightness scale for the entire distant-tree tier — mirrors
## `TreeScatter.close_tier_brightness`. Multiply the final ALBEDO
## by this so distant trees can be tuned to match the close tier
## without re-baking. 1.0 = unchanged.
@export_range(0.0, 2.0, 0.01) var distant_brightness: float = 1.0: set = _set_distant_brightness

@export_group("Determinism")
@export var seed: int = 9001

@export_group("Editor")
@export_tool_button("Bake distant trees", "Save") var bake_action: Callable = _bake
@export_tool_button("Clear baked trees", "Remove") var clear_action: Callable = _clear

const _SHADER_PATH := "res://shaders/tree_cluster.gdshader"
const _MMI_NODE_PREFIX: String = "DistantTreesMMI_"

var _terrain3d: Node3D = null
var _quad_mesh: QuadMesh = null
# Per-variant cached materials — one ShaderMaterial per variant so
# each MMI binds its own albedo_tex.
var _shader_materials: Dictionary = {}


func _ready() -> void:
	_load_baked()


# --- Bake (editor button) ---------------------------------------

func _bake() -> void:
	if not _resolve_terrain3d():
		push_error("[distant trees] Terrain3D node not resolved.")
		return
	if impostor_texture_paths.is_empty():
		push_error("[distant trees] impostor_texture_paths is empty.")
		return
	var coverage := _load_coverage_map()
	if coverage.is_empty():
		push_error("[distant trees] no tree_coverage.res — bake "
			+ "TreeCoverageBaker first.")
		return
	var img: Image = coverage["image"]
	var origin: Vector2 = coverage["origin"]
	var size_m: Vector2 = coverage["size"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed) * 2654435761
	var cells_x: int = maxi(int(size_m.x / grid_m), 1)
	var cells_y: int = maxi(int(size_m.y / grid_m), 1)
	var img_w: int = img.get_width()
	var img_h: int = img.get_height()
	var n_variants: int = impostor_texture_paths.size()
	# Per-variant accumulators.
	var xforms_per_v: Array = []
	var tints_per_v: Array = []
	for _v in n_variants:
		xforms_per_v.append([] as Array[Transform3D])
		tints_per_v.append([] as Array[Color])

	# Cache exclusion zones once for per-card boundary-respect. The
	# coverage texture has zone holes baked in at 4 m texel resolution,
	# but per-cell sampling + per-card jitter (`grid_m * jitter_radius_mul`,
	# typ. 45 m) lets cards land well outside the cell that decided
	# whether to spawn them — punching distant impostors through small
	# zones the texel-sampled cell didn't notice.
	#
	# Skip zones with `tree_density_mul >= 1.0` (no suppression) and
	# inline the test instead of `ProceduralExclusionZone.density_multiplier(...)`
	# so we sidestep the static-dispatch fragility that bit
	# `is_point_excluded` earlier in this session.
	var zone_refs: Array = []
	var zone_muls: PackedFloat32Array = PackedFloat32Array()
	for z in get_tree().get_nodes_in_group(&"procedural_exclusion_zones"):
		# Property-presence check rather than `is ProceduralExclusionZone`
		# — same stale-class_name-registry rationale as the other
		# scatters.
		if not ("tree_density_mul" in z and "shape" in z):
			continue
		var mul: float = float(z.get("tree_density_mul"))
		if mul >= 1.0:
			continue
		zone_refs.append(z)
		zone_muls.append(mul)
	var n_zones: int = zone_refs.size()
	var has_zones: bool = n_zones > 0
	for cy in cells_y:
		for cx in cells_x:
			var cu: float = (float(cx) + 0.5) / float(cells_x)
			var cv: float = (float(cy) + 0.5) / float(cells_y)
			var px: int = clampi(int(cu * float(img_w)), 0, img_w - 1)
			var py: int = clampi(int(cv * float(img_h)), 0, img_h - 1)
			var col: Color = img.get_pixel(px, py)
			if col.a < density_threshold:
				continue
			# Coverage-scaled tree count. Low-coverage cells get a
			# fractional count (rounded probabilistically); dense
			# cells get the full trees_per_cell.
			var coverage_factor: float = clampf(
				col.a * coverage_density_strength, 0.0, 1.0)
			var n_trees: float = float(trees_per_cell) * coverage_factor
			var n_int: int = int(floor(n_trees))
			if rng.randf() < (n_trees - float(n_int)):
				n_int += 1
			if n_int <= 0:
				continue
			var jitter_extent: float = grid_m * jitter_radius_mul
			for _i in n_int:
				var wx: float = origin.x + (float(cx) + 0.5) * grid_m
				var wz: float = origin.y + (float(cy) + 0.5) * grid_m
				wx += (rng.randf() - 0.5) * jitter_extent
				wz += (rng.randf() - 0.5) * jitter_extent
				# Hoist terrain Y above the zone test so the 3D zone
				# check has the actual world Y (matches the 2026-05-04
				# zone schema with finite Y extent).
				var wy: float = _terrain3d.data.get_height(
					Vector3(wx, 0.0, wz))
				if is_nan(wy):
					continue
				# Per-card zone boundary check at FINAL jittered
				# position. Same lowest-mul-wins semantics as
				# `density_multiplier(..., "trees")`. Treats the card
				# as fully blocked when any containing zone has mul=0;
				# uses Bernoulli rejection for soft (mul>0) zones so a
				# 0.3-mul "thinned" town gets ~30% of cards, matching
				# close-tier scatter behavior.
				if has_zones:
					var excl_mul: float = 1.0
					for zi in n_zones:
						var zref = zone_refs[zi]
						if zref._contains_world_xyz(wx, wy, wz):
							var zmul: float = zone_muls[zi]
							if zmul < excl_mul:
								excl_mul = zmul
							if excl_mul <= 0.0:
								break
					if excl_mul <= 0.0:
						continue
					if excl_mul < 1.0 and rng.randf() > excl_mul:
						continue
				var s_w: float = 1.0 + (rng.randf() - 0.5) * 2.0 * scale_jitter
				var s_h: float = 1.0 + (rng.randf() - 0.5) * 2.0 * scale_jitter * 0.8
				# Variant pick: per-placement world-XZ hash so the
				# species mix is stable across re-bakes (and players).
				var v_idx: int = _hash_variant(wx, wz, n_variants)
				# Per-channel hue jitter on top of brightness jitter.
				# Brightness alone produces a uniform "all green" wash
				# at distance; per-channel adds the same kind of
				# species + sun-spot variance you see in a real
				# canopy from a kilometer away.
				var bright: float = 0.8 + rng.randf() * 0.35
				var r_jit: float = bright * (0.85 + rng.randf() * 0.3)
				var g_jit: float = bright * (0.85 + rng.randf() * 0.3)
				var b_jit: float = bright * (0.85 + rng.randf() * 0.3)
				var tint := Color(col.r * r_jit, col.g * g_jit,
					col.b * b_jit)
				# Cross-billboards: spawn N quads at evenly-spaced fixed
				# Y rotations. Each quad does NOT face camera (no y-
				# billboard) — instead has its own permanent orientation.
				# From any viewing angle, every tree shows real silhouette
				# area (some quad is always at >30° from edge-on), and
				# trees don't all stack into the "wall of clones" stripes
				# you get with y-billboarded singles. AAA standard.
				var base_angle: float = rng.randf() * TAU
				var n_q: int = maxi(cross_quads_per_tree, 1)
				for q in n_q:
					var q_angle: float = base_angle \
						+ float(q) * (PI / float(n_q))
					var basis_q := Basis().scaled(Vector3(s_w, s_h, 1.0))
					basis_q = basis_q.rotated(Vector3.UP, q_angle)
					xforms_per_v[v_idx].append(
						Transform3D(basis_q, Vector3(wx, wy, wz)))
					tints_per_v[v_idx].append(tint)
	var total: int = 0
	for v in n_variants:
		total += xforms_per_v[v].size()
	if total == 0:
		push_warning("[distant trees] coverage map gave 0 placements")
		return
	_save_and_spawn_all(xforms_per_v, tints_per_v)
	print("[distant trees] baked %d distant tree placements across %d variants"
		% [total, n_variants])


func _clear() -> void:
	# Sweep any baked .res files matching the per-variant naming.
	for v in impostor_texture_paths.size():
		var path := _output_path_for(v)
		if ResourceLoader.exists(path):
			DirAccess.remove_absolute(path)
	_drop_spawned()
	print("[distant trees] cleared baked MMIs.")


# --- Variant hash ------------------------------------------------

func _hash_variant(wx: float, wz: float, n: int) -> int:
	# Cheap deterministic hash → integer in [0, n). Quantize position
	# to ~1 m so micro-jitter doesn't flip variants randomly across
	# re-bakes if scatter params shift slightly.
	var ix: int = int(floor(wx))
	var iz: int = int(floor(wz))
	var h: int = (ix * 73856093) ^ (iz * 19349663)
	if h < 0:
		h = -h
	return h % n


# --- Mesh + material setup --------------------------------------

func _ensure_quad_mesh() -> QuadMesh:
	if _quad_mesh != null:
		return _quad_mesh
	# 1×1 quad anchored so UV.y=0 sits at instance Y, UV.y=1 at Y+1.
	# Shader scales to actual card_height_m.
	var qm := QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	qm.center_offset = Vector3(0.0, 0.5, 0.0)
	_quad_mesh = qm
	return _quad_mesh


func _ensure_shader_material(variant_idx: int) -> ShaderMaterial:
	if _shader_materials.has(variant_idx):
		return _shader_materials[variant_idx]
	var shader: Shader = load(_SHADER_PATH) as Shader
	var sm := ShaderMaterial.new()
	sm.shader = shader
	var tex_path: String = impostor_texture_paths[variant_idx]
	var tex: Texture2D = load(tex_path) as Texture2D
	if tex != null:
		sm.set_shader_parameter("albedo_tex", tex)
	else:
		push_warning("[distant trees] missing impostor texture %s"
			% tex_path)
	# Derive the companion normal map path by `_albedo` → `_normal`.
	# The lit-billboard shader gates on `has_normal_map`; when the
	# companion doesn't exist (e.g. legacy single-PNG impostors),
	# the shader uses a generic upward canopy normal — still lit,
	# just less surface detail.
	var normal_path: String = tex_path.replace("_albedo.", "_normal.")
	var has_normal: bool = false
	if normal_path != tex_path and ResourceLoader.exists(normal_path):
		var ntex: Texture2D = load(normal_path) as Texture2D
		if ntex != null:
			sm.set_shader_parameter("normal_tex", ntex)
			has_normal = true
	sm.set_shader_parameter("has_normal_map", has_normal)
	_push_uniforms(sm)
	# Per-variant TreeSpecies override at runtime is no longer needed:
	# the bake already captures each species' authored
	# leaf_value_mul × albedo_modulation directly into the PNG. Runtime
	# grading is now scatter-level only (composes ON TOP of the bake).
	_shader_materials[variant_idx] = sm
	return sm


# Live-update setters for scatter-level grading. Each re-pushes the
# affected uniform to every spawned MMI material so the user sees
# changes immediately when dragging the inspector slider.
func _set_leaf_hue_shift(v: float) -> void:
	leaf_hue_shift = v
	_repush_param("leaf_hue_shift", v)


func _set_leaf_saturation_mul(v: float) -> void:
	leaf_saturation_mul = v
	_repush_param("leaf_saturation_mul", v)


func _set_leaf_value_mul(v: float) -> void:
	leaf_value_mul = v
	_repush_param("leaf_value_mul", v)


func _set_leaf_threshold(v: float) -> void:
	leaf_threshold = v
	_repush_param("leaf_threshold", v)


func _set_distant_brightness(v: float) -> void:
	distant_brightness = v
	_repush_param("distant_brightness", v)


func _repush_param(param: String, value) -> void:
	for mat_v in _shader_materials.values():
		var sm: ShaderMaterial = mat_v as ShaderMaterial
		if sm != null:
			sm.set_shader_parameter(param, value)


func _push_uniforms(sm: ShaderMaterial) -> void:
	sm.set_shader_parameter("min_distance_m", min_distance_m)
	sm.set_shader_parameter("max_distance_m", max_distance_m)
	sm.set_shader_parameter("fade_margin_m", fade_margin_m)
	sm.set_shader_parameter("card_width_m", card_width_m)
	sm.set_shader_parameter("card_height_m", card_height_m)
	sm.set_shader_parameter("ground_embed_fraction", ground_embed_fraction)
	sm.set_shader_parameter("embed_distance_extra", embed_distance_extra)
	sm.set_shader_parameter("leaf_hue_shift", leaf_hue_shift)
	sm.set_shader_parameter("leaf_saturation_mul", leaf_saturation_mul)
	sm.set_shader_parameter("leaf_value_mul", leaf_value_mul)
	sm.set_shader_parameter("leaf_threshold", leaf_threshold)
	sm.set_shader_parameter("distant_brightness", distant_brightness)
	sm.set_shader_parameter("albedo_modulation", Vector3(
		albedo_modulation.r, albedo_modulation.g, albedo_modulation.b))
	sm.set_shader_parameter("backlight_strength", backlight_strength)
	sm.set_shader_parameter("backlight_color", Vector3(
		backlight_color.r, backlight_color.g, backlight_color.b))
	sm.set_shader_parameter("emission_skylight_color", Vector3(
		emission_skylight_color.r, emission_skylight_color.g,
		emission_skylight_color.b))


# --- Save + spawn ------------------------------------------------

func _save_and_spawn_all(xforms_per_v: Array,
		tints_per_v: Array) -> void:
	_drop_spawned()
	var quad := _ensure_quad_mesh()
	for v in impostor_texture_paths.size():
		var xforms: Array = xforms_per_v[v]
		var tints: Array = tints_per_v[v]
		if xforms.is_empty():
			continue
		var mat := _ensure_shader_material(v)
		# Each variant gets its own QuadMesh instance because Mesh.material
		# is a property of the mesh; sharing one mesh would force a single
		# material across all MMIs.
		var per_v_quad := quad.duplicate() as QuadMesh
		per_v_quad.material = mat
		# Save the big single-variant MultiMesh as before — keeps the
		# on-disk format stable so existing LFS-tracked .res files
		# don't churn. Chunking is a runtime-only concern.
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = false
		mm.mesh = per_v_quad
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
			mm.set_instance_color(i, tints[i])
		var path := _output_path_for(v)
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(path.get_base_dir()))
		ResourceSaver.save(mm, path, ResourceSaver.FLAG_COMPRESS)
		_spawn_chunked_mmis(v, mm, per_v_quad)


# Re-bucket a per-variant MultiMesh into chunked MMIs for frustum
# culling. The on-disk MultiMesh is one big buffer that Godot
# auto-AABBs across the entire world (== the whole map's bounding
# box), which makes the per-MMI frustum cull effectively a no-op.
# Splitting into ⌈world / chunk_size_m⌉ smaller MultiMeshes lets
# Godot cull whole chunks that are off-screen.
#
# Reads from `source_mm.buffer` directly rather than calling
# `get_instance_transform()` — the latter returns zeros on a
# freshly-loaded MultiMesh resource until a RenderingServer cycle
# has handed the buffer over to the GPU, which means we can't trust
# it inside `_load_baked()`. The raw buffer is in CPU RAM straight
# after `load()` and is the source of truth.
#
# Buffer layout (TRANSFORM_3D + use_colors, no custom_data):
#   per instance, 16 floats:
#     [0..3]   basis row 0 + origin.x
#     [4..7]   basis row 1 + origin.y
#     [8..11]  basis row 2 + origin.z
#     [12..15] instance color (r, g, b, a)
#
# `chunk_size_m = 0` keeps the legacy "one MMI per variant" path —
# useful for debugging the chunking itself.
func _spawn_chunked_mmis(
		variant_idx: int,
		source_mm: MultiMesh,
		per_v_quad: QuadMesh) -> void:
	if chunk_size_m <= 0.0:
		_spawn_mmi(variant_idx, source_mm, "")
		return
	var n: int = source_mm.instance_count
	if n == 0:
		return
	var buf: PackedFloat32Array = source_mm.buffer
	# Compute stride from MultiMesh flags. Today this is always 16
	# (TRANSFORM_3D + use_colors + no custom_data) but read it off
	# the source so a future format change doesn't silently corrupt
	# the chunk buffers.
	var stride: int = 12  # TRANSFORM_3D = basis (9) + origin (3) packed as 3 rows of 4
	if source_mm.use_colors:
		stride += 4
	if source_mm.use_custom_data:
		stride += 4
	if buf.size() < n * stride:
		push_warning(
			"[distant trees] variant %d: buffer too small (%d < %d), "
			% [variant_idx, buf.size(), n * stride]
			+ "falling back to single MMI")
		_spawn_mmi(variant_idx, source_mm, "")
		return

	# Bucket every instance by its world-XZ supercell.
	var buckets: Dictionary = {}  # Vector2i → Array[int] (instance idx)
	for i in n:
		var off: int = i * stride
		var ox: float = buf[off + 3]
		var oz: float = buf[off + 11]
		var key := Vector2i(
			int(floor(ox / chunk_size_m)),
			int(floor(oz / chunk_size_m)))
		var arr: Array = buckets.get(key, [])
		arr.append(i)
		buckets[key] = arr

	# One MMI per non-empty chunk. Build each chunk's buffer by
	# memcpying the relevant 16-float slices, then assigning it to
	# a fresh MultiMesh.
	for key in buckets:
		var idxs: Array = buckets[key]
		var n_chunk: int = idxs.size()
		var chunk_buf := PackedFloat32Array()
		chunk_buf.resize(n_chunk * stride)
		for j in n_chunk:
			var src_off: int = idxs[j] * stride
			var dst_off: int = j * stride
			for k in stride:
				chunk_buf[dst_off + k] = buf[src_off + k]
		var chunk_mm := MultiMesh.new()
		chunk_mm.transform_format = MultiMesh.TRANSFORM_3D
		chunk_mm.use_colors = true
		chunk_mm.use_custom_data = false
		chunk_mm.mesh = per_v_quad
		chunk_mm.instance_count = n_chunk
		# Assigning `buffer` after `instance_count` populates the
		# transform + color data in one shot — no per-instance
		# `set_instance_transform` calls.
		chunk_mm.buffer = chunk_buf
		var k_v: Vector2i = key
		_spawn_mmi(
			variant_idx, chunk_mm, "_chunk_%d_%d" % [k_v.x, k_v.y])


func _spawn_mmi(
		variant_idx: int,
		mm: MultiMesh,
		name_suffix: String) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = _MMI_NODE_PREFIX + str(variant_idx) + name_suffix
	mmi.multimesh = mm
	# Distant trees never cast shadows — shadow contribution at 600m+
	# is negligible and the cost is real.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _load_baked() -> void:
	if not _resolve_terrain3d():
		return
	_drop_spawned()
	var quad := _ensure_quad_mesh()
	for v in impostor_texture_paths.size():
		var path := _output_path_for(v)
		if not ResourceLoader.exists(path):
			continue
		var mm: MultiMesh = load(path) as MultiMesh
		if mm == null:
			continue
		var mat := _ensure_shader_material(v)
		var per_v_quad := quad.duplicate() as QuadMesh
		per_v_quad.material = mat
		mm.mesh = per_v_quad
		_spawn_chunked_mmis(v, mm, per_v_quad)


func _drop_spawned() -> void:
	for child in get_children():
		if child.name.begins_with(_MMI_NODE_PREFIX):
			child.queue_free()


# --- Coverage map loading ---------------------------------------

func _load_coverage_map() -> Dictionary:
	var dir := _output_dir()
	var path := dir + "tree_coverage.res"
	if not ResourceLoader.exists(path):
		return {}
	var tex: ImageTexture = load(path) as ImageTexture
	if tex == null:
		return {}
	var img: Image = tex.get_image()
	if img == null:
		return {}
	if _terrain3d == null or _terrain3d.data == null:
		return {}
	var region_size_verts: int = int(_terrain3d.get("region_size"))
	var vertex_spacing: float = float(_terrain3d.get("vertex_spacing"))
	var region_size_m := float(region_size_verts) * vertex_spacing
	var regions: Array = _terrain3d.data.get_regions_active()
	if regions.is_empty():
		return {}
	var min_loc := Vector2i(2147483647, 2147483647)
	var max_loc := Vector2i(-2147483648, -2147483648)
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	var origin := Vector2(
		float(min_loc.x) * region_size_m,
		float(min_loc.y) * region_size_m)
	var size_m := Vector2(
		float(max_loc.x - min_loc.x + 1) * region_size_m,
		float(max_loc.y - min_loc.y + 1) * region_size_m)
	return {"image": img, "origin": origin, "size": size_m}


# --- Helpers ------------------------------------------------------

func _resolve_terrain3d() -> bool:
	if _terrain3d != null and is_instance_valid(_terrain3d):
		return true
	if not terrain3d_path.is_empty():
		_terrain3d = get_node_or_null(terrain3d_path) as Node3D
	return _terrain3d != null


func _output_dir() -> String:
	if _terrain3d != null:
		var dd := str(_terrain3d.get("data_directory"))
		if not dd.is_empty():
			if dd.ends_with("/"):
				return dd
			return dd + "/"
	return "res://assets/terrain/%s/terrain3d/" % map_id


func _output_path_for(variant_idx: int) -> String:
	var tex_path: String = impostor_texture_paths[variant_idx]
	var tex_name: String = tex_path.get_file().get_basename()
	return _output_dir() + "distant_trees_mm_%s.res" % tex_name
