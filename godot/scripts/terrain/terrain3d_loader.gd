@tool
class_name Terrain3DLoader
extends RefCounted
## Converts our canonical bake artifacts into Terrain3D's data model.
##
## Reads `res://assets/terrain/<map_id>/{terrain.toml,heightmap.r32,
## splatmap_a.rgba8,splatmap_b.rgba8,road_density.rgba8}` and emits
## the three `Image`s Terrain3D's `data.import_images()` expects:
##
##   TYPE_HEIGHT  — `FORMAT_RF`, literal meters
##   TYPE_CONTROL — `FORMAT_RF` (4-byte float bits reinterpreted as uint32)
##   TYPE_COLOR   — `RGBA8`, alpha = 0.5 (neutral wetness)
##
## ## Bake-time transforms (ported from the late `hterrain_loader.gd`)
##
## Three pre-encoding steps run before the per-pixel top-2 control-map
## pack, replicating the look the project tuned across PRs #93–#116:
##
## 1. **Splatmap softening.** A 7×7 separable box blur on the
##    biome splatmaps (`splatmap_a/b.rgba8`) so biome-to-biome
##    transitions read as gradients in Terrain3D's blend channel
##    rather than step-functions. Without this, the bake produces
##    hard edges where the source weights flip dominant between
##    adjacent pixels.
##
## 2. **Variant distribution.** For every pixel inside Forest /
##    Grassland / Bare / Cliff, the encoder picks a variant slot
##    (11 mossy_rock, 12 rocky_steppe, 13 mossy_grass, 14 nordic_moss,
##    15 Rock028) by argmax across N noise fields and writes it as
##    the *overlay*. The blend strength is a smoothstep over the
##    winning noise value, with a non-zero floor — so biome bodies
##    are never a single tile, peaks read as visible variant patches,
##    and argmax-flip seams sit in low-strength valleys where the
##    base shows through. Same noise frequencies / seeds as
##    HTerrain's `_distribute_variants` so patches land in the same
##    world locations the project's eye is used to.
##
## 3. **Road encoding.** Wherever any road weight (paved/unpaved/
##    trail) clears a small threshold (with noise-jitter on the
##    threshold so the outer edge isn't a pixel-grid step), the
##    pixel encodes road and biome via base+overlay. Below 50% road
##    weight the biome stays as base and road is overlay; above 50%
##    they swap. Both directions use the same blend formula so the
##    visible pixel color is continuous across the swap point.
##
## ## Layer id ↔ texture id mapping
##
## Matches the slot ordering in
## `godot/resources/terrain/terrain3d_assets_pnw.tres`:
##
##    0 Forest        4 Bare         8 Paved        12 rocky_steppe
##    1 Grassland     5 BuiltUp      9 Unpaved      13 mossy_grass
##    2 Water         6 Cliff       10 Trail        14 nordic_moss
##    3 Cropland      7 Snow        11 mossy_rock   15 mine_rock
##
## Slots 11–15 are populated by step 2 (variant distribution).
## Slot 6 (Cliff = Rock028, the dark base) dominates cliff faces;
## slot 11 (mossy_rock) is the lichen secondary at moderate strength
## across most of the face; slot 15 (mine_rock_wall, the lighter
## quarry stone) appears only as narrow streak accents where its
## medium-scale noise crosses a high threshold. Note that slots 6
## and 15 carry swapped texture content from the original PolyHaven
## / AmbientCG layout — the numeric IDs are the contract (control
## maps reference them); texture content sits behind them in
## `terrain3d_assets_pnw.tres`. Slot 2 (Water) is a placeholder
## that just samples a rocky tile until a real water shader lands.

const LAYER_COUNT := 16

const SLOT_FOREST := 0
const SLOT_GRASSLAND := 1
const SLOT_WATER := 2
const SLOT_CROPLAND := 3
const SLOT_BARE := 4
const SLOT_BUILTUP := 5
const SLOT_CLIFF := 6
const SLOT_SNOW := 7
const SLOT_PAVED := 8
const SLOT_UNPAVED := 9
const SLOT_TRAIL := 10
const SLOT_MOSSY_ROCK := 11
const SLOT_ROCKY_STEPPE := 12
const SLOT_MOSSY_GRASS := 13
const SLOT_NORDIC_MOSS := 14
# Slot 15 holds mine_rock_wall textures since the cliff swap (slot 6
# now holds Rock028 as the dark cliff base; slot 15 carries
# mine_rock_wall for narrow streak accents). Constant is named for
# its bake-input role, not current texture content — see
# `terrain3d_assets_pnw.tres`.
const SLOT_ROCK028 := 15

# Splat channel index per logical biome / road class.
# Tuple keys (splat_index, channel) where splat_index ∈
# {0=splat_a, 1=splat_b, 2=road} and channel ∈ {0=R..3=A}.
const _SOURCE := {
	SLOT_FOREST: [0, 0], SLOT_GRASSLAND: [0, 1], SLOT_WATER: [0, 2], SLOT_CROPLAND: [0, 3],
	SLOT_BARE: [1, 0], SLOT_BUILTUP: [1, 1], SLOT_CLIFF: [1, 2], SLOT_SNOW: [1, 3],
	SLOT_PAVED: [2, 0], SLOT_UNPAVED: [2, 1], SLOT_TRAIL: [2, 2],
}

# Pre-routing biome slots considered for "dominant biome" picks
# (excludes roads, which are handled separately, and excludes water
# which always wins where it's > threshold but is otherwise sparse).
const _BIOME_SLOTS := [
	SLOT_FOREST, SLOT_GRASSLAND, SLOT_WATER, SLOT_CROPLAND,
	SLOT_BARE, SLOT_BUILTUP, SLOT_CLIFF, SLOT_SNOW,
]

# Pixel must have a road weight at least this high (out of 255) for
# the road class to override the biome as the pixel's base. Below
# this it's noise / bleed and we keep the biome.
const _ROAD_THRESHOLD := 25

# Biome must have at least this weight to be considered the dominant
# biome (skips background noise where every channel is ~10).
const _BIOME_THRESHOLD := 13

# Box-blur radius applied to splatmaps before encoding. 11×11 (radius
# 5) — wider than HTerrain's 7×7 because Terrain3D's base+overlay
# encoding only has one blend channel, so any unsmoothed step in the
# source splatmap survives as a pixel-grid stair-step in the final
# composition. The Gaussian-ish wash at radius 5 is what kills the
# visible steps on snow / cropland boundaries.
const _SOFTEN_RADIUS := 5

# Noise field seeds. Match `hterrain_loader._distribute_variants` so
# variant patches land in the same world coordinates the user's eye
# is calibrated to.
const _NOISE_FOREST_SEED := 0
const _NOISE_FOREST_DETAIL_SEED := 5511
const _NOISE_ROCKY_LARGE_SEED := 8807
const _NOISE_ROCKY_MED_SEED := 8808
const _NOISE_ROCKY_SMALL_SEED := 8809
const _NOISE_CLIFF_SEED := 1234
const _NOISE_CLIFF_MED_SEED := 1235
const _NOISE_CLIFF_SMALL_SEED := 1236


## Builds the Image trio from the on-disk bake and pushes it into the
## given Terrain3D node's `data` storage. Returns true on success.
static func bake_into(map_id: String, terrain: Terrain3D) -> bool:
	var dir := "res://assets/terrain/%s/" % map_id
	var meta := _parse_terrain_toml(dir + "terrain.toml")
	if meta.is_empty():
		push_error("Terrain3DLoader: failed to parse %sterrain.toml" % dir)
		return false
	var w: int = int(meta.get("width", 0))
	var h: int = int(meta.get("height", 0))
	var spacing_m: float = float(meta.get("spacing_m", 1.0))
	if w <= 0 or h <= 0:
		push_error("Terrain3DLoader: invalid terrain dimensions in %s" % dir)
		return false

	var hm_bytes := _read_bytes(dir + "heightmap.r32")
	var splat_a := _read_bytes(dir + "splatmap_a.rgba8")
	var splat_b := _read_bytes(dir + "splatmap_b.rgba8")
	var road := _read_bytes(dir + "road_density.rgba8")
	if hm_bytes.size() != w * h * 4:
		push_error("Terrain3DLoader: heightmap size mismatch (%d vs %d)"
			% [hm_bytes.size(), w * h * 4])
		return false
	# Splatmaps are optional. Production maps (`bake_map` with a real
	# `[features]` block) ship them; placeholder test maps and
	# canonical-only bakes do not. When absent, fall back to all-
	# zeros — the loader's per-pixel pass interprets that as "100%
	# biome slot 0", which combined with the default Terrain3D asset
	# set renders as a uniform default-biome surface. This lets test
	# maps wire up a Terrain3D node without authoring effort and
	# without needing a separate "no splat" code path in `bake_into`.
	if splat_a.is_empty() and splat_b.is_empty():
		push_warning("Terrain3DLoader: splatmap_a/b absent — falling "
			+ "back to default-biome (slot 0) for every pixel. "
			+ "Authored maps should ship real splatmaps via bake_map.")
		splat_a = PackedByteArray()
		splat_a.resize(w * h * 4)
		splat_b = splat_a.duplicate()
	if splat_a.size() != w * h * 4 or splat_b.size() != w * h * 4:
		push_error("Terrain3DLoader: splatmap_a/b size mismatch")
		return false
	var has_road := road.size() == w * h * 4
	if not has_road:
		push_warning("Terrain3DLoader: road_density.rgba8 absent — "
			+ "road layers (8..10) will not be encoded")

	# Step 1: soften biome splatmaps (in-place on copies).
	var splat_a_soft := _soften_rgba8(splat_a, w, h)
	var splat_b_soft := _soften_rgba8(splat_b, w, h)

	# Step 2: pre-build noise fields (fast access during the
	# per-pixel pass; FastNoiseLite is thread-safe and stateless
	# once configured).
	var noise := _build_noise_fields()

	var height_img := _build_height_image(w, h, hm_bytes)
	var control_img := _build_control_image(
		w, h, splat_a_soft, splat_b_soft, road, has_road,
		spacing_m, noise)
	# TYPE_COLOR is multiplied onto the final ALBEDO in Terrain3D's
	# shader. Tinting per-pixel by the dominant biome gives a "free
	# distance LOD" — terrain at far range reads as the right biome
	# even when no foliage meshes have been baked there. Up close the
	# foliage covers the terrain and the tint becomes a subtle
	# undertone. Costs a one-time bake-time pass; zero runtime cost.
	var color_img := _build_biome_color_image(
		w, h, splat_a_soft, splat_b_soft)

	var images: Array[Image] = []
	images.resize(Terrain3DRegion.TYPE_MAX)
	images[Terrain3DRegion.TYPE_HEIGHT] = height_img
	images[Terrain3DRegion.TYPE_CONTROL] = control_img
	images[Terrain3DRegion.TYPE_COLOR] = color_img

	# Center on world origin so terrain matches the
	# `(W-1) * spacing` extent convention used elsewhere.
	var extent_x := float(w - 1) * spacing_m
	var extent_z := float(h - 1) * spacing_m
	var pos := Vector3(-extent_x * 0.5, 0.0, -extent_z * 0.5)

	terrain.data.import_images(images, pos, 0.0, 1.0)
	terrain.data.calc_height_range(true)
	print("Terrain3DLoader: imported %dx%d → %d active regions"
		% [w, h, terrain.data.get_regions_active().size()])
	return true


# Build the FORMAT_RF heightmap. Canonical `.r32` already stores
# literal f32 meters in row-major LE; bytes can be passed straight
# to `Image.create_from_data`. (v1 `.r16` needed a u16-decode +
# `vert_min/max` linear remap; v2 dropped that.)
static func _build_height_image(
		w: int, h: int, hm_bytes: PackedByteArray) -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_RF, hm_bytes)


# Configure the FastNoiseLite fields used by variant distribution.
# Noise frequencies / seeds intentionally match
# `hterrain_loader._distribute_variants` so variant patches land in
# identical world locations on each bake.
static func _build_noise_fields() -> Dictionary:
	var d := {}
	for spec in [
		# (key, freq, octaves, gain, seed)
		["forest_large",  1.0 / 80.0, 4, 0.55, _NOISE_FOREST_SEED],
		["forest_detail", 1.0 / 12.0, 2, 0.5,  _NOISE_FOREST_DETAIL_SEED],
		["rocky_large",   1.0 / 50.0, 2, 0.5,  _NOISE_ROCKY_LARGE_SEED],
		["rocky_med",     1.0 / 14.0, 2, 0.5,  _NOISE_ROCKY_MED_SEED],
		["rocky_small",   1.0 / 4.0,  1, 0.5,  _NOISE_ROCKY_SMALL_SEED],
		["cliff_large",   1.0 / 50.0, 2, 0.5,  _NOISE_CLIFF_SEED],
		["cliff_med",     1.0 / 14.0, 2, 0.5,  _NOISE_CLIFF_MED_SEED],
		["cliff_small",   1.0 / 4.0,  1, 0.5,  _NOISE_CLIFF_SMALL_SEED],
	]:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n.frequency = spec[1]
		n.fractal_octaves = spec[2]
		n.fractal_gain = spec[3]
		n.seed = spec[4]
		d[spec[0]] = n
	return d


## Variant decision for a primary biome slot at world XZ. Returns
## `[variant_slot, strength]` where strength is 0..255 (the byte
## written into the Terrain3D blend channel as overlay strength).
##
## Approach: pick the variant by argmax across N noise composites,
## map the winning value through a smoothstep with a non-zero floor,
## and write the picked variant as the overlay.
##
## **Composites are heavily large-scale weighted.** Earlier revisions
## mixed in 25–45 % medium- and small-scale noise per variant — the
## small/medium components produce per-pixel argmax flips that read
## as a uniform "leopard" pattern at gameplay distance. Each variant
## here uses ≥ 80 % of its dominant frequency (XL = 1/80 m, large =
## 1/50 m, medium = 1/14 m), with a small medium-scale top-up just
## to roughen the patch boundary. Different spatial offsets per
## variant decorrelate them so the patches don't all coincide.
##
## **Strength has no per-pixel wobble.** A previous revision layered
## a high-frequency wobble on top of strength to "break up uniform
## opacity" — but that wobble runs at ~1/2 m, i.e. per-pixel, and
## reads as fine-grained spotting. The composites already contain
## natural variation; the wobble was net-negative.
##
## Noise frequencies / seeds are shared with `_build_noise_fields`,
## which mirrors the late `hterrain_loader._distribute_variants` so
## variant patches land in the same world coordinates the project's
## eye is calibrated to.
static func _variant_for(
		dom_slot: int, wx: float, wz: float,
		noise: Dictionary) -> Array:
	if dom_slot == SLOT_FOREST:
		var n_rl: FastNoiseLite = noise["rocky_large"]   # 1/50 m
		var n_rm: FastNoiseLite = noise["rocky_med"]     # 1/14 m
		var n_fl: FastNoiseLite = noise["forest_large"]  # 1/80 m
		var n_fd: FastNoiseLite = noise["forest_detail"] # 1/12 m
		# Each variant: ≥ 80 % its dominant scale, ≤ 20 % roughener.
		# Spatial offsets decorrelate patches across variants.
		var v_rocky := _mix2(n_rl, n_rm, wx, wz, 0.85, 0.15)
		var v_moss := _mix2(n_fl, n_fd, wx + 1500.0, wz - 700.0, 0.85, 0.15)
		var v_grass := _mix2(n_rl, n_rm,
			wx - 900.0, wz + 1100.0, 0.55, 0.45)
		var max_v := maxf(maxf(v_rocky, v_moss), v_grass)
		var strength := _strength(max_v, 60.0, 220.0, 0.30, 0.85)
		if v_rocky == max_v:
			return [SLOT_ROCKY_STEPPE, strength]
		if v_moss == max_v:
			return [SLOT_NORDIC_MOSS, strength]
		return [SLOT_MOSSY_GRASS, strength]
	if dom_slot == SLOT_GRASSLAND:
		var n_fl: FastNoiseLite = noise["forest_large"]
		var n_fd: FastNoiseLite = noise["forest_detail"]
		var n_rl: FastNoiseLite = noise["rocky_large"]
		var n_rm: FastNoiseLite = noise["rocky_med"]
		var v_moss := _mix2(n_fl, n_fd, wx + 1000.0, wz + 500.0, 0.85, 0.15)
		var v_rocky := _mix2(n_rl, n_rm,
			wx - 200.0, wz + 700.0, 0.65, 0.35)
		var max_v := maxf(v_moss, v_rocky)
		var strength := _strength(max_v, 50.0, 200.0, 0.30, 0.85)
		if v_moss > v_rocky:
			return [SLOT_MOSSY_GRASS, strength]
		return [SLOT_ROCKY_STEPPE, strength]
	if dom_slot == SLOT_BARE:
		var n_cl: FastNoiseLite = noise["cliff_large"]
		var n_cm: FastNoiseLite = noise["cliff_med"]
		var v_moss := _mix2(n_cl, n_cm, wx + 500.0, wz + 1500.0, 0.85, 0.15)
		var v_rock := _mix2(n_cl, n_cm,
			wx - 800.0, wz + 200.0, 0.65, 0.35)
		var max_v := maxf(v_moss, v_rock)
		var strength := _strength(max_v, 60.0, 215.0, 0.30, 0.85)
		if v_moss > v_rock:
			return [SLOT_NORDIC_MOSS, strength]
		return [SLOT_MOSSY_ROCK, strength]
	if dom_slot == SLOT_CLIFF:
		var n_cl: FastNoiseLite = noise["cliff_large"]   # 1/50 m
		var n_cm: FastNoiseLite = noise["cliff_med"]     # 1/14 m
		# Cliff base = Rock028 (dark). Two overlays:
		#   - mossy_rock (slot 11, lichen) — wide secondary at the
		#     1/50 m scale, moderate strength so the dark base still
		#     dominates but lichen patches read as clearly present.
		#   - mine_rock_wall (slot 15, lighter quarry stone) — narrow
		#     streaks at the 1/14 m scale, only fires when its noise
		#     crosses a high threshold (≥ 0.72), so it appears as
		#     accent bands here and there rather than competing with
		#     mossy_rock for area.
		# Streak check runs first; if not in a streak pixel, fall
		# through to the mossy_rock secondary.
		var v_streak := _mix2(n_cm, n_cl,
			wx + 1100.0, wz - 700.0, 0.85, 0.15)
		if v_streak > 0.72:
			var t := clampf((v_streak - 0.72) / 0.18, 0.0, 1.0)
			# SLOT_ROCK028 is a misnomer post-swap — slot 15 holds
			# mine_rock_wall textures. See constant declaration above.
			return [SLOT_ROCK028, int(lerpf(80.0, 220.0, t))]
		# Lichen secondary. Floor 80 (≈ 31 % overlay) keeps lichen
		# clearly visible everywhere; cap 200 (≈ 78 %) lets strong
		# noise peaks read as proper lichen patches while still
		# letting some of the dark Rock028 base show through.
		var v_moss := _mix2(n_cl, n_cm, wx, wz, 0.85, 0.15)
		var strength := _strength(v_moss, 80.0, 200.0, 0.30, 0.85)
		return [SLOT_MOSSY_ROCK, strength]
	# Cropland, BuiltUp, Snow, Water — no variants.
	return [dom_slot, 0]


# Two-way weighted noise composite, returns 0..1. Weights apply to
# noise values in [-1, 1] before remapping to [0, 1], so they
# directly control how much each scale contributes.
static func _mix2(
		a: FastNoiseLite, b: FastNoiseLite,
		wx: float, wz: float,
		wa: float, wb: float) -> float:
	var s := a.get_noise_2d(wx, wz) * wa + b.get_noise_2d(wx, wz) * wb
	return clampf((s + 1.0) * 0.5, 0.0, 1.0)


# Strength as a function of the winning composite value. Pure
# smoothstep — no wobble (a previous revision added a per-pixel
# noise wobble that read as fine-grained spotting at gameplay
# distance, which was the chief "leopard print" complaint).
static func _strength(
		max_v: float, floor_s: float, cap_s: float,
		lo: float, hi: float) -> int:
	return int(lerpf(floor_s, cap_s, smoothstep(lo, hi, max_v)))


## Legacy hard-threshold variant routing — kept for reference; the
## per-pixel encoder now calls `_variant_for` which returns both the
## slot id and a smooth 0..255 strength so the blend transitions
## continuously across the noise field.
static func _route_variant(
		dom_slot: int, wx: float, wz: float,
		noise: Dictionary) -> int:
	# `noise[...]` is Variant on lookup; cast to FastNoiseLite so the
	# GDScript type inferencer knows `get_noise_2d` returns float.
	# Without these casts every `var n := (... + 1.0) * 0.5` errors
	# with "Cannot infer the type of 'n' variable because the value
	# doesn't have a set type."
	if dom_slot == SLOT_FOREST:
		var rocky_large: FastNoiseLite = noise["rocky_large"]
		var rocky_med: FastNoiseLite = noise["rocky_med"]
		var rocky_small: FastNoiseLite = noise["rocky_small"]
		var nrl := (rocky_large.get_noise_2d(wx, wz) + 1.0) * 0.5
		var nrm := (rocky_med.get_noise_2d(wx, wz) + 1.0) * 0.5
		var nrs := (rocky_small.get_noise_2d(wx, wz) + 1.0) * 0.5
		if nrl > 0.85 or nrm > 0.88 or nrs > 0.91:
			return SLOT_ROCKY_STEPPE
		var forest_large: FastNoiseLite = noise["forest_large"]
		var forest_detail: FastNoiseLite = noise["forest_detail"]
		var n_large := (forest_large.get_noise_2d(wx, wz) + 1.0) * 0.5
		var n_small := (forest_detail.get_noise_2d(wx, wz) + 1.0) * 0.5
		var n := n_large * 0.7 + n_small * 0.3
		if n >= 0.92:
			return SLOT_MOSSY_GRASS
		if n >= 0.50:
			return SLOT_NORDIC_MOSS
		return SLOT_FOREST
	if dom_slot == SLOT_GRASSLAND:
		var forest_large: FastNoiseLite = noise["forest_large"]
		var ng := (forest_large.get_noise_2d(wx + 1000.0, wz + 500.0) + 1.0) * 0.5
		if ng >= 0.85:
			return SLOT_MOSSY_GRASS
		if ng >= 0.70:
			return SLOT_ROCKY_STEPPE
		return SLOT_GRASSLAND
	if dom_slot == SLOT_BARE:
		var cliff_large: FastNoiseLite = noise["cliff_large"]
		var nb := (cliff_large.get_noise_2d(wx + 500.0, wz + 1500.0) + 1.0) * 0.5
		if nb >= 0.83:
			return SLOT_NORDIC_MOSS
		if nb >= 0.65:
			return SLOT_MOSSY_ROCK
		return SLOT_BARE
	if dom_slot == SLOT_CLIFF:
		var cliff_large: FastNoiseLite = noise["cliff_large"]
		var cliff_med: FastNoiseLite = noise["cliff_med"]
		var cliff_small: FastNoiseLite = noise["cliff_small"]
		var ncl := (cliff_large.get_noise_2d(wx, wz) + 1.0) * 0.5
		var ncm := (cliff_med.get_noise_2d(wx, wz) + 1.0) * 0.5
		var ncs := (cliff_small.get_noise_2d(wx, wz) + 1.0) * 0.5
		if ncl > 0.85 or ncm > 0.88 or ncs > 0.92:
			return SLOT_MOSSY_ROCK
		var is_light: bool = ncm > 0.65 or ncs > 0.78
		if is_light:
			return SLOT_ROCK028
		return SLOT_CLIFF
	# Cropland, BuiltUp, Snow have no variants.
	return dom_slot


# Build the FORMAT_RF control map. Each pixel encodes (base_id,
# overlay_id, blend, flags) as a uint32 stuffed into a float32.
# Per-pixel biome tint baked into the TYPE_COLOR image. Terrain3D's
# shader does `ALBEDO *= color_map.rgb`, so a green tint here makes
# the terrain itself read as grassland from afar — the "color trick"
# distance-LOD for foliage. Alpha = 0.5 in the source meant "neutral
# wetness" (the shader interprets `color_map.a - 0.5` as wetness
# adjustment); preserved here.
#
# **Multi-scale noise modulation.** A flat tint reads as a uniform
# wash from afar, which doesn't sell "patchy ground cover" the way
# real foliage does. We layer three octaves of noise (large /
# medium / small) and modulate the tint's brightness ±15 % per
# pixel — bright spots read as sunlit clumps, dark spots as
# shadowed patches. Up close the actual foliage covers most of
# this; far out where the foliage scatter doesn't reach, the
# noise pattern is what makes the terrain read as cover. Noise is
# baked into the static image, so zero runtime cost.
#
# Tints picked to match the loaded ground textures roughly so the
# undertone doesn't shift the terrain colour too aggressively at
# close range — the foliage on top is what's supposed to dominate.
static func _build_biome_color_image(
		w: int, h: int,
		splat_a: PackedByteArray,
		splat_b: PackedByteArray) -> Image:
	# RGB tints, alpha 0.5. The shader does `ALBEDO *= color_map.rgb`
	# so EVERY channel < 1 darkens. Tints stay close to white (≥ 0.88)
	# so they nudge hue without dropping albedo significantly.
	# Combined with `_NOISE_AMP = 0.15` per-pixel modulation gives
	# subtle patchy variation suggesting cover at distance.
	const TINT_FOREST    := Color(0.88, 0.95, 0.82, 0.5)  # subtle cool green
	const TINT_GRASSLAND := Color(0.95, 0.97, 0.85, 0.5)  # subtle warm green
	const TINT_CROPLAND  := Color(0.95, 0.90, 0.83, 0.5)  # subtle warm tan
	const TINT_BARE      := Color(0.97, 0.94, 0.88, 0.5)  # subtle sandy
	const TINT_NEUTRAL   := Color(1.00, 1.00, 1.00, 0.5)  # cliff/built/snow/water
	const _TINT_THRESHOLD := 38  # ignore noise weights below ~15 %
	# Noise modulation strength (max ±fraction of tint brightness).
	# 0.15 keeps tints in [0.85 × base_tint, 1.15 × base_tint] —
	# subtle hue variation suggesting patchy cover at distance
	# without darkening terrain meaningfully.
	const _NOISE_AMP := 0.15
	# Three octaves combined per pixel:
	#   large (~40 m): biome-scale variation (broad lighter / darker zones)
	#   medium (~10 m): cluster / patch suggestion
	#   small (~2 m): per-plant grain
	var n_large := FastNoiseLite.new()
	n_large.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_large.frequency = 0.025
	n_large.seed = 4242
	var n_med := FastNoiseLite.new()
	n_med.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_med.frequency = 0.10
	n_med.seed = 9090
	var n_small := FastNoiseLite.new()
	n_small.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_small.frequency = 0.50
	n_small.seed = 12321
	var bytes := PackedByteArray()
	bytes.resize(w * h * 4)
	for px in h:
		for py in w:
			var i := px * w + py
			var pi := i * 4
			var w_forest := int(splat_a[pi])
			var w_grass := int(splat_a[pi + 1])
			var w_crop := int(splat_a[pi + 3])
			var w_bare := int(splat_b[pi])
			# Argmax over tintable biomes only — water/built/cliff/snow
			# all leave the terrain at neutral (their own textures
			# already have the right colour signature).
			var tint: Color = TINT_NEUTRAL
			var apply_noise := false
			var best_w := _TINT_THRESHOLD
			if w_forest > best_w:
				best_w = w_forest
				tint = TINT_FOREST
				apply_noise = true
			if w_grass > best_w:
				best_w = w_grass
				tint = TINT_GRASSLAND
				apply_noise = true
			if w_crop > best_w:
				best_w = w_crop
				tint = TINT_CROPLAND
				apply_noise = true
			if w_bare > best_w:
				best_w = w_bare
				tint = TINT_BARE
				apply_noise = true
			if apply_noise:
				# Sample noise at pixel coords (no need to convert to
				# world m — we just need a stable per-pixel pattern).
				var nl := n_large.get_noise_2d(float(py), float(px))
				var nm := n_med.get_noise_2d(float(py), float(px))
				var ns := n_small.get_noise_2d(float(py), float(px))
				# Weighted composite: large dominates, small grain on top.
				var noise_v := nl * 0.5 + nm * 0.35 + ns * 0.15
				var modulator := 1.0 + noise_v * _NOISE_AMP
				tint.r = clampf(tint.r * modulator, 0.0, 1.0)
				tint.g = clampf(tint.g * modulator, 0.0, 1.0)
				tint.b = clampf(tint.b * modulator, 0.0, 1.0)
			bytes[pi]     = int(tint.r * 255.0)
			bytes[pi + 1] = int(tint.g * 255.0)
			bytes[pi + 2] = int(tint.b * 255.0)
			bytes[pi + 3] = int(tint.a * 255.0)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)


static func _build_control_image(
		w: int, h: int,
		splat_a: PackedByteArray, splat_b: PackedByteArray,
		road: PackedByteArray, has_road: bool,
		spacing_m: float,
		noise: Dictionary) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(w * h * 4)
	var pixel_count := w * h
	# World extent (centered convention) — convert pixel coords to
	# world meters so noise fields produce stable patches across
	# bakes regardless of map dimensions.
	var extent_x := float(w - 1) * spacing_m
	var extent_z := float(h - 1) * spacing_m
	var w_minus_1_f := float(w - 1)
	var h_minus_1_f := float(h - 1)

	for i in pixel_count:
		var pi := i * 4
		var px := i % w
		var pz := i / w
		var wx := float(px) / w_minus_1_f * extent_x - extent_x * 0.5
		var wz := float(pz) / h_minus_1_f * extent_z - extent_z * 0.5

		# Read raw weights at this pixel.
		var w_forest := int(splat_a[pi])
		var w_grass := int(splat_a[pi + 1])
		var w_water := int(splat_a[pi + 2])
		var w_crop := int(splat_a[pi + 3])
		var w_bare := int(splat_b[pi])
		var w_built := int(splat_b[pi + 1])
		var w_cliff := int(splat_b[pi + 2])
		var w_snow := int(splat_b[pi + 3])
		var w_paved := 0
		var w_unpaved := 0
		var w_trail := 0
		if has_road:
			w_paved = int(road[pi])
			w_unpaved = int(road[pi + 1])
			w_trail = int(road[pi + 2])

		var biome_weights := [
			w_forest, w_grass, w_water, w_crop,
			w_bare, w_built, w_cliff, w_snow,
		]

		# Find primary + secondary biome (by weight, both unrouted —
		# we want the actual biome IDs in the control map, with the
		# variant assignment expressed via the blend channel).
		var primary_slot := -1
		var primary_w := _BIOME_THRESHOLD - 1
		var primary_idx := -1
		for k in _BIOME_SLOTS.size():
			var weight: int = biome_weights[k]
			if weight > primary_w:
				primary_w = weight
				primary_slot = _BIOME_SLOTS[k]
				primary_idx = k
		if primary_slot < 0:
			primary_slot = SLOT_FOREST
			primary_w = 0
		var secondary_slot := -1
		var secondary_w := -1
		for k in _BIOME_SLOTS.size():
			if k == primary_idx:
				continue
			var weight: int = biome_weights[k]
			if weight > secondary_w:
				secondary_w = weight
				secondary_slot = _BIOME_SLOTS[k]

		# Variant decision for the primary biome. Returns a slot id
		# + a 0..255 strength tracking the noise field so the blend
		# transitions smoothly across the variant patch instead of
		# stair-stepping at thresholds (which is what produced the
		# hexagonal cellular look in the first bake).
		var variant_slot := primary_slot
		var variant_strength := 0
		var v := _variant_for(primary_slot, wx, wz, noise)
		variant_slot = v[0]
		variant_strength = v[1]

		# Decide (base, overlay, blend) per the priority chain:
		#   1. road — present (with jitter) → road and biome share
		#      the pixel via base/overlay. Below 50% road weight the
		#      base stays as the biome and road is the overlay; above
		#      50% they swap. Both directions use the same blend
		#      formula so the transition across the swap point is
		#      seamless. Noise-jitter on the threshold check breaks
		#      up the pixel-grid edge that produced visible stair-
		#      stepping in earlier bakes.
		#   2. biome→biome transition — when secondary biome weight
		#      is competitive (>= 60% of primary), blend tracks the
		#      raw weight ratio so the splatmap-softened edge reads
		#      as a real gradient.
		#   3. variant patch — base = primary biome, overlay =
		#      variant slot, blend = variant_strength.
		var base_slot := primary_slot
		var overlay_slot := primary_slot
		var blend_byte := 0
		var max_road: int = maxi(maxi(w_paved, w_unpaved), w_trail)
		# Symmetric noise jitter (mean 0) on the road extent so the
		# road's outer edge isn't a pixel-perfect 1-pixel step. ±10
		# units of road weight ≈ a ~1-pixel irregular fringe in the
		# softened splatmap, enough to defeat the eye's grid-pattern
		# detection without dilating or eroding the road on average.
		var n_jit: FastNoiseLite = noise["rocky_small"]
		var jitter := int(((n_jit.get_noise_2d(wx * 1.5, wz * 1.5) + 1.0) * 0.5 - 0.5) * 20.0)
		var effective_road: int = clampi(max_road + jitter, 0, 255)
		if effective_road >= _ROAD_THRESHOLD:
			var road_slot := SLOT_PAVED
			if w_paved >= w_unpaved and w_paved >= w_trail:
				road_slot = SLOT_PAVED
			elif w_unpaved >= w_trail:
				road_slot = SLOT_UNPAVED
			else:
				road_slot = SLOT_TRAIL
			# Continuous formulation across the 50% swap point —
			# below 50% road, biome=base + road=overlay with blend
			# tracking road share; above 50%, base/overlay swap.
			# Both sides carry a 1.8× boost on the "minority" share
			# so trails (whose source weight tops out around 80–120
			# rather than 255) actually read as visible road instead
			# of a faint dirty wash on the biome.
			if effective_road >= 128:
				base_slot = road_slot
				overlay_slot = primary_slot
				blend_byte = clampi(int((255 - effective_road) * 1.8), 0, 127)
			else:
				base_slot = primary_slot
				overlay_slot = road_slot
				blend_byte = clampi(int(effective_road * 1.8), 0, 127)
		elif secondary_w >= int(primary_w * 0.35) and secondary_w >= _BIOME_THRESHOLD:
			# Biome boundary: blend toward the runner-up.
			overlay_slot = secondary_slot
			var sum_w := primary_w + maxi(secondary_w, 0)
			if sum_w > 0:
				blend_byte = int(round(float(secondary_w) / float(sum_w) * 255.0))
			blend_byte = clampi(blend_byte, 0, 255)
		else:
			# In the body of a single biome — overlay is its variant
			# (rocky_steppe, nordic_moss, mossy_grass, etc.) and the
			# blend tracks the noise field smoothly.
			overlay_slot = variant_slot
			blend_byte = variant_strength

		var packed: int = (
			Terrain3DUtil.enc_base(base_slot)
			| Terrain3DUtil.enc_overlay(overlay_slot)
			| Terrain3DUtil.enc_blend(blend_byte))
		bytes.encode_float(i * 4, Terrain3DUtil.as_float(packed))
	return Image.create_from_data(w, h, false, Image.FORMAT_RF, bytes)


# Box-blur an RGBA8 PackedByteArray in place, separable
# horizontal+vertical with `_SOFTEN_RADIUS` per side. Mirrors
# `hterrain_loader._soften_splatmap` — same look, ported off Image
# onto PackedByteArray since that's our native representation.
static func _soften_rgba8(src: PackedByteArray, w: int, h: int) -> PackedByteArray:
	var radius := _SOFTEN_RADIUS
	var size := w * h * 4
	var tmp := PackedByteArray()
	tmp.resize(size)
	# Horizontal pass.
	for y in h:
		var row_start := y * w * 4
		for x in w:
			var s_r := 0
			var s_g := 0
			var s_b := 0
			var s_a := 0
			var count := 0
			for dx in range(-radius, radius + 1):
				var nx := clampi(x + dx, 0, w - 1)
				var pi := row_start + nx * 4
				s_r += src[pi]
				s_g += src[pi + 1]
				s_b += src[pi + 2]
				s_a += src[pi + 3]
				count += 1
			var oi := row_start + x * 4
			@warning_ignore("integer_division")
			tmp[oi]     = s_r / count
			@warning_ignore("integer_division")
			tmp[oi + 1] = s_g / count
			@warning_ignore("integer_division")
			tmp[oi + 2] = s_b / count
			@warning_ignore("integer_division")
			tmp[oi + 3] = s_a / count
	# Vertical pass.
	var dst := PackedByteArray()
	dst.resize(size)
	for y in h:
		for x in w:
			var s_r := 0
			var s_g := 0
			var s_b := 0
			var s_a := 0
			var count := 0
			for dy in range(-radius, radius + 1):
				var ny := clampi(y + dy, 0, h - 1)
				var pi := (ny * w + x) * 4
				s_r += tmp[pi]
				s_g += tmp[pi + 1]
				s_b += tmp[pi + 2]
				s_a += tmp[pi + 3]
				count += 1
			var oi := (y * w + x) * 4
			@warning_ignore("integer_division")
			dst[oi]     = s_r / count
			@warning_ignore("integer_division")
			dst[oi + 1] = s_g / count
			@warning_ignore("integer_division")
			dst[oi + 2] = s_b / count
			@warning_ignore("integer_division")
			dst[oi + 3] = s_a / count
	return dst


# Minimal TOML reader.
static func _parse_terrain_toml(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var out := {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("["):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var val := line.substr(eq + 1).strip_edges()
		if val.begins_with("\"") and val.ends_with("\""):
			out[key] = val.substr(1, val.length() - 2)
		elif val == "true":
			out[key] = true
		elif val == "false":
			out[key] = false
		elif val.contains("."):
			out[key] = val.to_float()
		else:
			out[key] = val.to_int()
	return out


static func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	return f.get_buffer(f.get_length())
