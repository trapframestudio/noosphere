@tool
class_name TreeCoverageBaker
extends Node3D

## Bakes a per-map tree-density texture used by the terrain shader to
## paint a "distant forest" tint past the runtime impostor radius.
##
## **Why**: even with the cheap impostor system, rendering individual
## tree silhouettes out to 1500 m+ is ~14K MMI draw calls per frame.
## Past ~600 m the silhouettes are sub-pixel anyway — the visual
## value is just "that hillside reads as forested". A bake captures
## the where + the per-biome tint into a single texture; the terrain
## shader fades the tint in past the impostor cutoff so distant hills
## look forested without spawning anything. Total cost: zero
## additional draw calls, one extra texture sample in the terrain
## fragment shader.
##
## Bakes per-cell canopy coverage data driving the canopy-card layer.
## Output: RGBA8 (RGB = biome tint, A = density), same Terrain3D control-
## map biome lookup. Trees are a coarser feature so default texel
## size is 4 m (vs 2 m for ground cover) — half the resolution, 1/4
## the texture memory.
##
## **Usage**:
##   1. Drop this node as a sibling of `TreeScatter`.
##   2. Wire `terrain3d_path`, `biome_configs` to the same values as
##      `TreeScatter`, plus `terrain_material` to the Terrain3DMaterial.
##   3. Click **Bake tree coverage now** in the inspector.
##   4. Output saves to `tree_coverage.res` next to the Terrain3D
##      region files; runtime `_ready` rebinds it on every load.

@export_node_path("Node3D") var terrain3d_path: NodePath

## Same `TreeBiomeConfig` resources as `TreeScatter`. Bake is
## meaningless if these don't match — distant terrain would tint to
## different density/areas than the runtime scatter.
@export var biome_configs: Array[TreeBiomeConfig] = []

@export_group("Bake settings")
## Texel edge length in world meters. 4 m default — a 6144 m map
## bakes to ~1536² RGBA8 ≈ 9 MB raw, ~2 MB compressed on disk. Trees
## are big features; finer doesn't add detail.
@export_range(2.0, 16.0, 0.5) var meters_per_texel: float = 4.0

## Position-jittered scatter candidates per texel. Each sample picks
## a random XZ inside the texel + does a real biome lookup + accept-
## test (mirroring the close-tier scatter's per-tree gating). More
## samples = smoother density gradient. 12 default — a 4 m texel gets
## 12 candidates ≈ 0.75 trees / m² sample density, plenty to capture
## sub-texel features (trail edges, biome boundaries) faithfully.
@export_range(4, 48, 1) var samples_per_texel: int = 12

## Match `TreeScatter.density_multiplier`. Affects per-cell acceptance
## probability so the bake's density tracks runtime scatter density
## and the impostor → terrain-tint handoff blends seamlessly.
@export_range(0.0, 4.0, 0.05) var density_multiplier: float = 1.0

@export var seed: int = 1337

@export_group("Per-biome tint")
## Forest biome tint — dark conifer-canopy green. The terrain shader
## blends ALBEDO toward this past the impostor distance, weighted by
## the baked density. Tweak per-map if a region needs a different
## canopy tone (boreal vs deciduous etc.). Re-bake after changing —
## RGB is baked into the texture.
@export var forest_tint: Color = Color(0.13, 0.20, 0.13)
## Grassland biome tint — sparse trees on yellow-green grass. Lighter
## + warmer than forest so distant grasslands don't read as forest.
@export var grassland_tint: Color = Color(0.28, 0.34, 0.18)
## Cropland biome tint — stand-alone trees on tilled fields. Brown-
## green; trees on cropland are typically hedgerows / shade trees.
@export var cropland_tint: Color = Color(0.34, 0.30, 0.18)
## Bare biome tint — sparse trees on rock / scrubland. Muted neutral.
@export var bare_tint: Color = Color(0.30, 0.28, 0.22)

@export_group("Runtime")
@export_dir var output_dir_override: String = ""

## Material to bind the baked texture to. If null, falls back to
## `terrain3d.material`. Set explicitly for scenes with custom paths.
@export var terrain_material: Resource

@export_tool_button("Bake tree coverage now", "Add") var _bake_action = bake

# **Canopy card system removed (2026-04-30)** — replaced by
# `TreeClusterScatter` which spawns pre-baked cluster meshes
# (10 cross-billboards each) per coverage cell. Single-quad cards
# with procedural silhouettes couldn't substitute for forest mass
# at distance — research recommended cluster-mesh impostors
# (Brucks/Epic, Sucker Punch GDC 2021). This baker now ONLY
# produces the per-cell coverage map; the cluster scatter consumes
# it for placement decisions.

# --- State ----------------------------------------------------------------

const _T3D_TYPE_CONTROL := 1

# Stable script ref for static-method dispatch. See `tree_scatter.gd`
# for why direct `ProceduralExclusionZone.foo()` is unsafe in @tool.
const _ExclusionZoneRef := preload("res://scripts/procedural_exclusion_zone.gd")

var _terrain3d: Node = null
# int biome_id → effective trees-per-sq-m for that biome (sum of all
# species-density entries in the matching `TreeBiomeConfig`).
var _biome_density: Dictionary = {}
# int biome_id → fallback Color tint (only used when a biome has zero
# species or its species lookup fails — usually unreachable).
var _biome_tints: Dictionary = {}
# int biome_id → PackedFloat32Array of cumulative species densities.
# Parallel to _biome_species_paths / _biome_species_canopy_tints so a
# weighted-RNG pick is just a binary search into the cumulative array.
var _biome_species_cumweight: Dictionary = {}
# int biome_id → PackedColorArray of per-species canopy_tints, indexed
# the same way as _biome_species_cumweight.
var _biome_species_canopy_tints: Dictionary = {}
var _max_trees_per_sq_m: float = 0.0


func _set_param(mat: Resource, name: String, value: Variant) -> void:
	if mat.has_method("set_shader_parameter"):
		mat.set_shader_parameter(name, value)
	elif mat.has_method("set_shader_param"):
		mat.set_shader_param(name, value)
	else:
		push_warning("TreeCoverageBaker: material %s has no shader-param setter."
			% mat.resource_path)


func _bind_runtime(tex: Texture2D, origin: Vector2, size_m: Vector2) -> void:
	var mat: Resource = terrain_material
	if mat == null and _terrain3d != null:
		mat = _terrain3d.material
	if mat == null:
		push_warning("TreeCoverageBaker: no terrain material to bind to.")
		return
	_set_param(mat, "tree_coverage_map", tex)
	_set_param(mat, "tree_coverage_origin", origin)
	_set_param(mat, "tree_coverage_size", size_m)
	# Don't ResourceSaver.save the material here. Terrain3DMaterial filters
	# user-defined uniforms when serialising (only its own parsed params
	# round-trip cleanly), so saving wipes any tweaks the user made via
	# the inspector to OTHER override-shader uniforms (tree_coverage_distance_*,
	# bumpiness, lum_match, etc.). The runtime `_reapply_saved_binding()`
	# in `_ready()` re-binds the texture + origin + size from disk every
	# scene load, so disk persistence of the material is unnecessary.


func _build_biome_lookup() -> void:
	_biome_density.clear()
	_biome_tints.clear()
	_biome_species_cumweight.clear()
	_biome_species_canopy_tints.clear()
	_max_trees_per_sq_m = 0.0
	for cfg in biome_configs:
		if cfg == null:
			continue
		var use_explicit := cfg.tree_densities.size() == cfg.tree_paths.size()
		var cums := PackedFloat32Array()
		var tints := PackedColorArray()
		var cum := 0.0
		for i in cfg.tree_paths.size():
			var path: String = cfg.tree_paths[i]
			if path.is_empty():
				continue
			var contribution: float = (cfg.tree_densities[i]
				if use_explicit else cfg.trees_per_sq_m)
			if contribution <= 0.0:
				continue
			# Resolve the species's canopy_tint. Fall back to the biome
			# default tint if the species file failed to load or is
			# missing the property (defensive; should never happen in
			# practice).
			var tint: Color = _tint_for_biome(cfg.biome)
			var sp: TreeSpecies = load(path) as TreeSpecies
			if sp != null and "canopy_tint" in sp:
				tint = sp.canopy_tint
			cum += contribution
			cums.append(cum)
			tints.append(tint)
		if cums.size() == 0:
			continue
		var sum_d: float = cums[cums.size() - 1]
		var eff: float = sum_d if use_explicit else cfg.trees_per_sq_m
		_biome_density[cfg.biome] = eff
		_biome_tints[cfg.biome] = _tint_for_biome(cfg.biome)
		_biome_species_cumweight[cfg.biome] = cums
		_biome_species_canopy_tints[cfg.biome] = tints
		_max_trees_per_sq_m = maxf(_max_trees_per_sq_m, eff)


# Pick a per-cell canopy tint via density-weighted RNG. Same shape as
# `tree_scatter._pick_species` so the bake's per-cell species
# distribution matches the runtime scatter's distribution: a cell
# placed in a Doug-Fir-dominant biome reads with a Doug Fir tint
# proportionally more often than a pine tint, and adjacent cells
# naturally vary because each pulls a fresh RNG sample.
func _pick_species_tint(biome: int, r: float) -> Color:
	if not _biome_species_cumweight.has(biome):
		return _biome_tints.get(biome, Color(0.2, 0.3, 0.2))
	var cums: PackedFloat32Array = _biome_species_cumweight[biome]
	var tints: PackedColorArray = _biome_species_canopy_tints[biome]
	if cums.size() == 0:
		return _biome_tints.get(biome, Color(0.2, 0.3, 0.2))
	var total: float = cums[cums.size() - 1]
	var target: float = r * total
	for i in cums.size():
		if target <= cums[i]:
			return tints[i]
	return tints[tints.size() - 1]


func _tint_for_biome(biome: int) -> Color:
	# Match the biome enum used elsewhere: 0=Forest, 1=Grassland,
	# 2=Cropland, 3=Bare, 4=Road. Roads never have trees so no tint.
	match biome:
		0: return forest_tint
		1: return grassland_tint
		2: return cropland_tint
		3: return bare_tint
		_: return Color(0, 0, 0, 0)


# Sample Terrain3D's control map for the biome at world XZ. Same
# decode pattern as `ground_cover.gd._biome_via_control_map`.
func _biome_at_world(wx: float, wz: float) -> int:
	if _terrain3d == null:
		return -1
	var col: Color = _terrain3d.data.get_pixel(_T3D_TYPE_CONTROL,
		Vector3(wx, 0.0, wz))
	if is_nan(col.r):
		return -1
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, col.r)
	var control: int = bytes.decode_u32(0)
	var base_id: int = (control >> 27) & 0x1F
	var overlay_id: int = (control >> 22) & 0x1F
	var blend: int = (control >> 14) & 0xFF
	# Hard-priority road suppression.
	if base_id in [8, 9, 10] or overlay_id in [8, 9, 10]:
		return -1
	# Biome from the dominant (winning) slot.
	var winning := base_id if blend < 128 else overlay_id
	return _slot_to_biome(winning)


# Same Terrain3D-slot → biome-id mapping as ground_cover.gd. Trees
# only spawn on Forest/Grassland/Cropland/Bare. Roads return -1.
func _slot_to_biome(slot: int) -> int:
	match slot:
		0: return 0  # Forest
		1: return 1  # Grassland
		3: return 2  # Cropland
		4: return 3  # Bare
		_: return -1


func _bake_combined(origin: Vector2, size_m: Vector2, img_w: int, img_h: int) -> Image:
	var img := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	var texel_x := size_m.x / float(img_w)
	var texel_y := size_m.y / float(img_h)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed) * 73856093
	var max_density: float = maxf(_max_trees_per_sq_m, 0.0001)
	# Inner loop is texel × samples_per_texel ≈ tens of millions of
	# operations on a region-sized map. Print progress every 5% of
	# rows (or every 50 rows on tiny maps) plus a hard "every ~3s"
	# floor so the user always sees movement on a slow machine. Track
	# accept count for the completion summary.
	var t_start: int = Time.get_ticks_msec()
	var print_every_rows: int = maxi(1, mini(50, img_h / 20))
	var last_print_ms: int = t_start
	var total_accepted: int = 0

	# --- HOT-LOOP PRECOMPUTE ---------------------------------------
	# Cache exclusion zones once. The previous code called
	# `_ExclusionZoneRef.density_multiplier(get_tree(), ...)` per
	# sample — that's tens of millions of group lookups + static
	# dispatch + match-system-string per bake. Cache the zone refs
	# once and inline the test in the inner loop.
	#
	# Skip zones whose `tree_density_mul == 1.0` entirely — they have
	# no effect on tree placement, so testing them per sample is pure
	# overhead.
	var zone_refs: Array = []
	var zone_muls: PackedFloat32Array = PackedFloat32Array()
	var raw_zones: Array[Node] = get_tree().get_nodes_in_group(
		&"procedural_exclusion_zones")
	for z in raw_zones:
		# Property-presence check rather than `is ProceduralExclusionZone`
		# — same stale-class_name-registry rationale as
		# `_ExclusionZoneRef`, see tree_scatter.gd const block.
		if not ("tree_density_mul" in z and "shape" in z):
			continue
		var mul: float = float(z.get("tree_density_mul"))
		if mul >= 1.0:
			continue
		zone_refs.append(z)
		zone_muls.append(mul)
	var n_zones: int = zone_refs.size()
	var has_zones: bool = n_zones > 0

	# Precompute per-biome accept probability into a flat indexed
	# array. The original `_biome_density.has(biome)` + .get()` per
	# sample does a hash + variant unbox each time. With 4 valid
	# biomes (Forest=0, Grassland=1, Cropland=2, Bare=3) and at most
	# ~10 in any conceivable expansion, a fixed-size PackedFloat32Array
	# of size N_BIOMES is dirt cheap. -1 (no-biome) shortcircuits earlier.
	const N_BIOMES_MAX: int = 16
	var biome_accept_p_max: PackedFloat32Array = PackedFloat32Array()
	biome_accept_p_max.resize(N_BIOMES_MAX)
	for b in N_BIOMES_MAX:
		var bd: float = float(_biome_density.get(b, 0.0))
		# Pre-applies the global density multiplier; per-sample only
		# needs one multiply by `excl_mul` and a clamp.
		biome_accept_p_max[b] = bd / max_density * density_multiplier
	# Per-texel biome counts — replaces the per-texel Dictionary
	# allocation. Reset by `fill(0)` per texel; that's a single
	# bulk-clear on a small array vs. dict-rebuild + variant boxing.
	var biome_counts_arr: PackedInt32Array = PackedInt32Array()
	biome_counts_arr.resize(N_BIOMES_MAX)

	# Sample N positions JITTERED within each texel and accept-test
	# each one (mirroring the close-tier scatter's per-candidate
	# approach — see tree_scatter.gd::_bake_tile). The previous
	# implementation point-sampled biome at the texel center then
	# Bernoulli-rolled `samples_per_texel` times against the same
	# biome — a single non-forest pixel at the center (a trail, a
	# splatmap blend artifact) zeroed the whole 4 m × 4 m texel,
	# producing visible holes that the cluster scatter then magnified
	# by point-sampling one texel per 18 m grid cell. Per-position
	# biome lookup means the alpha smoothly reflects forest density
	# across the texel area.
	for y in img_h:
		# Progress: row-based with a wall-clock floor. Print on row
		# threshold OR if 3+ seconds have passed since the last line
		# (keeps slow machines from going quiet for minutes).
		var now: int = Time.get_ticks_msec()
		if y > 0 and (y % print_every_rows == 0 or now - last_print_ms > 3000):
			var elapsed: float = float(now - t_start) / 1000.0
			var pct: float = 100.0 * float(y) / float(img_h)
			var rate: float = float(y) / maxf(elapsed, 0.001)
			var eta: float = float(img_h - y) / maxf(rate, 0.001)
			print("[coverage]   row %d / %d (%.1f%%) — %.1fs elapsed, %.0f rows/s, ETA %.0fs"
				% [y, img_h, pct, elapsed, rate, eta])
			last_print_ms = now
		# `oz` only depends on y → hoist out of x loop.
		var oz: float = origin.y + float(y) * texel_y
		for x in img_w:
			var ox: float = origin.x + float(x) * texel_x
			var accepted := 0
			biome_counts_arr.fill(0)
			# Per-texel terrain Y for the 3D zone test. Sampled once at
			# the texel's world center and shared across all
			# `samples_per_texel` sub-samples — a 4 m texel rarely has
			# > 1 m terrain Y delta, plenty accurate for zone testing
			# (zones with sub-1m Y precision aren't a real authoring
			# pattern). Per-texel costs ~2M heightmap lookups on
			# cascade_locks vs ~25M if we sampled per-sub-sample.
			var texel_cy: float = oz + 0.5 * texel_y
			var texel_cx: float = ox + 0.5 * texel_x
			var texel_world_y: float = _terrain3d.data.get_height(
				Vector3(texel_cx, 0.0, texel_cy))
			if is_nan(texel_world_y):
				texel_world_y = 0.0
			for _s in samples_per_texel:
				var sx := ox + rng.randf() * texel_x
				var sz := oz + rng.randf() * texel_y
				var biome := _biome_at_world(sx, sz)
				if biome < 0 or biome >= N_BIOMES_MAX:
					continue
				var accept_p_base: float = biome_accept_p_max[biome]
				if accept_p_base <= 0.0:
					continue  # biome not in density table
				# Procedural exclusion zones — inlined point-in-zone
				# test. Same continuous `density_multiplier` semantics
				# (lowest mul among containing zones wins) as
				# `ProceduralExclusionZone.density_multiplier(tree, ...)`
				# but without the per-sample group lookup + static
				# dispatch + match-system-string overhead. Uses the
				# texel's terrain Y so zones with finite Y extent
				# (the 2026-05-04 schema) are honored.
				var excl_mul: float = 1.0
				if has_zones:
					for zi in n_zones:
						var zref = zone_refs[zi]
						if zref._contains_world_xyz(sx, texel_world_y, sz):
							var zmul: float = zone_muls[zi]
							if zmul < excl_mul:
								excl_mul = zmul
							if excl_mul <= 0.0:
								break
					if excl_mul <= 0.0:
						continue
				var accept_p: float = clampf(
					accept_p_base * excl_mul, 0.0, 1.0)
				if rng.randf() <= accept_p:
					accepted += 1
					biome_counts_arr[biome] += 1
			total_accepted += accepted
			if accepted == 0:
				# Image.create zero-fills RGBA8, so an empty pixel is
				# already (0,0,0,0) — skip the redundant write.
				continue
			# Per-texel tint: pick from the dominant accepted biome.
			# Adjacent texels naturally vary by species via the per-tint
			# weighted RNG below.
			var dominant_biome: int = -1
			var dominant_count: int = 0
			for b in N_BIOMES_MAX:
				var c: int = biome_counts_arr[b]
				if c > dominant_count:
					dominant_count = c
					dominant_biome = b
			var tint: Color = _pick_species_tint(dominant_biome, rng.randf())
			var density: float = float(accepted) / float(samples_per_texel)
			img.set_pixel(x, y, Color(tint.r, tint.g, tint.b, density))
	var loop_elapsed: float = float(Time.get_ticks_msec() - t_start) / 1000.0
	var total_samples: int = img_w * img_h * samples_per_texel
	var accept_pct: float = 100.0 * float(total_accepted) / maxf(float(total_samples), 1.0)
	print("[coverage] loop done: %d×%d texels × %d samples = %d total samples, %d accepted (%.1f%%) in %.1fs"
		% [img_w, img_h, samples_per_texel, total_samples,
		total_accepted, accept_pct, loop_elapsed])
	return img


func bake() -> void:
	if not _resolve_terrain3d():
		push_error("TreeCoverageBaker: terrain3d_path unresolved.")
		return
	if biome_configs.is_empty():
		push_error("TreeCoverageBaker: biome_configs is empty.")
		return

	_build_biome_lookup()
	if _biome_density.is_empty():
		push_error("TreeCoverageBaker: no biome densities derived.")
		return

	var region_size_verts: int = int(_terrain3d.get("region_size"))
	var vertex_spacing: float = float(_terrain3d.get("vertex_spacing"))
	var region_size_m := float(region_size_verts) * vertex_spacing

	var output_dir := _resolve_output_dir()
	if not output_dir.ends_with("/"):
		output_dir += "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))

	var regions: Array = _terrain3d.data.get_regions_active()
	if regions.is_empty():
		push_warning("TreeCoverageBaker: no active regions to bake.")
		return

	# Compute world XZ bounds of all active regions; bake one combined
	# image covering them.
	var min_loc := Vector2i(2147483647, 2147483647)
	var max_loc := Vector2i(-2147483648, -2147483648)
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	var origin := Vector2(float(min_loc.x) * region_size_m,
		float(min_loc.y) * region_size_m)
	var size_m := Vector2(
		float(max_loc.x - min_loc.x + 1) * region_size_m,
		float(max_loc.y - min_loc.y + 1) * region_size_m)
	var img_w := maxi(int(size_m.x / meters_per_texel), 16)
	var img_h := maxi(int(size_m.y / meters_per_texel), 16)

	# Pre-flight: surface the work scale before kicking off so the
	# user sees movement on long bakes (cascade_locks at default 4 m
	# texels = ~2 M texels × 12 samples = ~25 M operations).
	var n_zones: int = get_tree().get_nodes_in_group(
		&"procedural_exclusion_zones").size()
	print("[coverage] starting bake: %d×%d texels (%.1f m / texel),"
		% [img_w, img_h, meters_per_texel]
		+ " covers %.0f × %.0f m, origin %v" % [size_m.x, size_m.y, origin])
	print("[coverage]   %d biomes, %d samples/texel, %d exclusion zones, density_mul=%.2f"
		% [_biome_density.size(), samples_per_texel, n_zones, density_multiplier])

	var t0 := Time.get_ticks_msec()
	var img := _bake_combined(origin, size_m, img_w, img_h)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var path := output_dir + "tree_coverage.res"
	var err := ResourceSaver.save(tex, path, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_error("TreeCoverageBaker: save failed for %s (err=%d)" % [path, err])
		return
	var total_ms: int = Time.get_ticks_msec() - t0
	print("[coverage] saved %s in %.1fs total"
		% [path, float(total_ms) / 1000.0])
	_bind_runtime(tex, origin, size_m)
	print("[coverage] runtime binding refreshed (terrain shader has new texture)")


func _ready() -> void:
	# Re-bind the saved coverage texture so the terrain shader has it
	# without an editor bake on every load. (Canopy card spawning was
	# removed — TreeClusterScatter handles distant trees now.)
	_reapply_saved_binding()
	_drop_legacy_canopy_layer()


# Re-bind the saved tree-coverage texture at runtime so the terrain
# shader has it without needing an editor bake on every load.
func _reapply_saved_binding() -> void:
	if not _resolve_terrain3d():
		return
	var output_dir := _resolve_output_dir()
	if not output_dir.ends_with("/"):
		output_dir += "/"
	var path := output_dir + "tree_coverage.res"
	if not ResourceLoader.exists(path):
		return
	var tex := ResourceLoader.load(path) as Texture2D
	if tex == null:
		return
	# Reconstruct origin / size from the active regions — must match
	# what was baked or UVs map wrong.
	var region_size_verts: int = int(_terrain3d.get("region_size"))
	var vertex_spacing: float = float(_terrain3d.get("vertex_spacing"))
	var region_size_m := float(region_size_verts) * vertex_spacing
	var regions: Array = _terrain3d.data.get_regions_active()
	if regions.is_empty():
		return
	var min_loc := Vector2i(2147483647, 2147483647)
	var max_loc := Vector2i(-2147483648, -2147483648)
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	var origin := Vector2(float(min_loc.x) * region_size_m,
		float(min_loc.y) * region_size_m)
	var size_m := Vector2(
		float(max_loc.x - min_loc.x + 1) * region_size_m,
		float(max_loc.y - min_loc.y + 1) * region_size_m)
	_bind_runtime(tex, origin, size_m)


func _resolve_terrain3d() -> bool:
	if _terrain3d != null and is_instance_valid(_terrain3d):
		return true
	if terrain3d_path.is_empty():
		return false
	_terrain3d = get_node_or_null(terrain3d_path) as Node
	return _terrain3d != null


func _resolve_output_dir() -> String:
	if not output_dir_override.is_empty():
		return output_dir_override
	if _terrain3d == null:
		return "res://"
	var data_dir := str(_terrain3d.get("data_directory"))
	if data_dir.is_empty():
		return "res://"
	return data_dir


# Strip any lingering legacy CanopyCardLayer node spawned by an
# earlier session. Idempotent — safe to call when nothing's there.
# Also delete the stale on-disk `canopy_cards.res` so it doesn't
# accidentally get re-loaded by an older script copy.
func _drop_legacy_canopy_layer() -> void:
	var existing: Node = get_node_or_null("CanopyCardLayer")
	if existing != null:
		existing.queue_free()
	if Engine.is_editor_hint():
		var output_dir := _resolve_output_dir()
		if not output_dir.ends_with("/"):
			output_dir += "/"
		var stale := output_dir + "canopy_cards.res"
		if ResourceLoader.exists(stale):
			DirAccess.remove_absolute(stale)
