@tool
class_name RockScatter
extends Node3D

## Streams rocks into the active radius around the player, with
## tiered collision shapes, the rock shader, and per-species cluster
## noise for boulder-field-style placement.
##
## Mirrors `TreeScatter` but stripped of tree-specific bits — no
## impostor swap, no live-tunable shader uniforms, no shadow refresh
## (small rocks don't shadow well anyway), no per-tile cache (rocks
## are cheap enough to bake in real-time at typical densities).
##
## Adds rock-specific bits:
## - Per-species cluster noise (`cluster_strength`, `cluster_scale_m`)
##   biases density toward boulder fields without breaking determinism.
## - Per-species random tilt — rocks visibly settled off-axis instead
##   of all flat-side-down.
## - Tiered collision dispatch (`RockSpecies.collision_tier`):
##   0 NONE / 1 STEPPABLE (CONCEALMENT layer) / 2 CROUCH (SOLID) /
##   3 STAND (SOLID, larger shape).

@export var map_id: String = "cascade_locks"
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Node3D") var terrain3d_path: NodePath

@export var biome_configs: Array[RockBiomeConfig] = []

@export_group("Scatter density")
@export_range(8.0, 256.0, 4.0) var tile_size_m: float = 32.0
@export_range(8, 16384, 8) var placements_per_tile_cap: int = 256
@export_range(32.0, 1000.0, 8.0) var active_radius_m: float = 150.0
@export_range(2.0, 128.0, 2.0) var rebuild_threshold_m: float = 12.0
## Per-frame steady-state bake budget (tiles per frame). Mirrors
## `TreeScatter.bake_per_frame_budget` but rocks bake faster — small
## meshes, no LOD-pack walking — so we can afford a higher rate.
@export_range(0, 64, 1) var bake_per_frame_budget: int = 2
## Burst budget while `_bake_queue.size() > _BAKE_BURST_THRESHOLD`.
@export_range(1, 128, 1) var bake_burst_budget: int = 6
@export_range(0.0, 4.0, 0.05) var density_multiplier: float = 1.0

@export_subgroup("Collision")
## Spawn StaticBody3D + shape per rock (subject to per-species
## `collision_tier`). Off → no rocks get colliders even if their
## tier > 0. Useful for editor preview where physics adds nothing.
@export var enable_collision: bool = true
## Only spawn colliders for tiles whose center is within this distance
## of the camera. Outside this range the rocks render but have no
## physics body. Same pattern TreeScatter uses; keeps RID + broadphase
## counts bounded regardless of `active_radius_m`.
@export_range(0.0, 400.0, 4.0) var collision_radius_m: float = 80.0

@export_subgroup("Shadows")
## Cast directional shadows from rock close-tier MMIs. Off → no rock
## shadows at all (saves the shadow draw call but loses the visual
## anchor). Impostor MMIs (proxy tier) NEVER cast shadow regardless
## of this setting — distant rocks have negligible shadow contribution
## and the cost is real.
@export var cast_shadow: bool = true
## Only set `cast_shadow = ON` on tiles whose center is within this
## distance of the camera. The Sun's `directional_shadow_max_distance`
## (typically 160 m on cascade_locks) means rock shadows past that
## range are culled by the renderer anyway, but the CPU still submits
## a shadow draw call per shadow-cast MMI. Suppressing them saves
## several ms / frame on dense scatters.
##
## Default 120 m provides margin past the Sun's typical shadow range.
## Bump if you raise `directional_shadow_max_distance` on the Sun.
@export_range(0.0, 500.0, 8.0) var shadow_radius_m: float = 120.0
## Only LODs at or below this level cast shadows. LOD0 + LOD1 by
## default — LOD2 is too coarse to read as a meaningful shadow at the
## distances it actually renders. Set 0 for "LOD0 only" if shadow
## cost is still high, or 2 to also enable LOD2 shadows.
@export_range(0, 2, 1) var max_shadow_lod: int = 1

@export_subgroup("LOD")
## Inter-LOD distance boundaries (meters). Element N is the LOD-N →
## LOD-N+1 transition distance. Defaults: [40, 90] = LOD0 covers 0-40,
## LOD1 40-90, LOD2 90+ until species `max_render_distance_m` cull.
## Rocks LOD-pop more subtly than trees (no canopy silhouette change)
## so bands can be tighter.
@export var lod_band_ends_m: PackedFloat32Array = PackedFloat32Array([40.0, 90.0])
## Total fade-zone width (meters) across each LOD boundary. Wider =
## softer per-rock crossfade.
@export_range(2.0, 80.0, 1.0) var lod_band_fade_m: float = 20.0

@export_subgroup("Terrain awareness")
## Radius (m) over which RockScatter samples height to compute the
## "rockiness" score that gates big species. Larger radius catches
## farther features (cliff bases, distant ridges); smaller radius
## responds to local undulations only. 25 m is a good default — far
## enough to see a real cliff above, close enough that small hills
## still register.
##
## Cost: 5 height samples per candidate (= ~25 byte reads) → ~1 µs
## per candidate, ~1 ms per tile at peak bake. Negligible.
@export_range(5.0, 100.0, 1.0) var terrain_sample_radius_m: float = 25.0
## Slope value at which the rockiness score saturates to 1.0. Slopes
## above this register as "max rocky"; below it scale linearly to 0.
## 2.5 ≈ a 70° face — well into "rock outcrop / cliff" territory.
@export_range(0.5, 5.0, 0.1) var terrain_score_saturation: float = 2.5

@export_subgroup("Road clearance")
## Max road-density byte (0–255 from `road_density.rgba8`) tolerated
## anywhere in the rock's horizontal footprint. The rock's body covers
## a `horizontal_radius` disc; if any of the 9 sample points (center +
## 8 perimeter) exceeds this byte value, the placement is rejected.
##
## The center-only road check in `_biome_at_world` (`> 25` byte) only
## catches "rock dropped on the asphalt". Big boulders placed 2 m off
## the road edge still drape their bodies across it without this
## perimeter check. Default `30` matches the strictness of the center
## check; raise to `60–80` if rocks need to spawn close to roads.
@export_range(0, 255, 1) var road_max_density_byte: int = 30

@export_subgroup("Slope")
## Slope at which the global thinning ramp BEGINS (lower number =
## start thinning earlier). Per-species `slope_max` runs in addition
## and clamps individual species off particular slope bands.
@export_range(0.0, 4.0, 0.05) var slope_thin_start: float = 1.5
## Global hard cutoff: NO species spawns above this slope, regardless
## of their per-species `slope_max`. Default 4.0 supports cliff-face
## species (which use `slope_min ≈ 1.8`) all the way up to vertical
## terrain. Lower this if rocks shouldn't appear on the steepest
## faces (e.g. snow-covered peaks where bare rock would look wrong).
@export_range(0.0, 4.0, 0.05) var slope_cutoff: float = 4.0

@export_group("Determinism")
@export var seed: int = 4242

@export_group("Persistent bake cache")
## When ON, each baked tile's placement set is written to disk under
## `res://assets/foliage_bake/<map_id>/rocks/<key>/<tx>_<tz>.bin`.
## Subsequent loads skip the per-tile RNG / cluster / slope work and
## just read the placement transforms back. Cache key is a 16-char
## hash of seed + tile_size + biome densities + species params, so
## any tunable change automatically invalidates stale cache entries.
@export var cache_enabled: bool = true
## Bump (or click Clear + Bake) to re-roll rock placements. Pairs
## with `cache_version` on TreeScatter / GroundCoverScatter — bump
## independently so you can re-roll just the rocks.
@export_range(1, 999, 1) var cache_version: int = 1
# Internal toggle used by the "Bake placement cache" button to write
# fresh bakes to disk regardless of existing cache state. NOT @export
# — the equivalent inspector checkbox was removed because leaving it
# on by accident tanked perf for entire sessions; use the Rebuild
# button or bump `cache_version` to re-roll instead.
var _bake_force_fresh: bool = false
@export_tool_button("Bake placement cache", "Save") var bake_cache_action: Callable = _bake_cache_near_origin
## Radius (meters) around world origin to bake when "Bake placement
## cache" is clicked. Each tile's placements get cached to disk so
## first-time scene loads near origin spawn instantly.
@export_range(64.0, 2048.0, 64.0) var prebake_radius_m: float = 512.0
## Inspector button — bakes EVERY tile inside the active Terrain3D
## regions for this map. Slow on large maps; useful for first-time
## map setup. Also the target of `Terrain3DBaker.Rebake Vegetation`.
@export_tool_button("Bake whole map", "Save") var bake_whole_map_action: Callable = _bake_cache_whole_map
@export_tool_button("Clear placement cache", "Remove") var clear_cache_action: Callable = _clear_cache_for_map

@export_group("Editor")
@export var editor_preview: bool = false : set = _set_editor_preview
@export_tool_button("Rebuild rocks", "Reload") var force_rebuild_action: Callable = _force_rebuild

const ROCK_SHADER_PATH := "res://shaders/rock_dynamic.gdshader"

# Stable script ref for static-method dispatch. See `tree_scatter.gd`
# for why direct `ProceduralExclusionZone.foo()` is unsafe in @tool.
const _ExclusionZoneRef := preload("res://scripts/procedural_exclusion_zone.gd")
const ROCK_IMPOSTER_SHADER_PATH := "res://shaders/rock_imposter.gdshader"
const TEXTURE_TIERS := ["1k", "2k", "4k"]

# Collision tier enum (mirrors RockSpecies.collision_tier).
const TIER_NONE: int = 0
const TIER_STEPPABLE: int = 1
const TIER_CROUCH_COVER: int = 2
const TIER_STAND_COVER: int = 3

var _camera: Camera3D = null
var _terrain3d: Node3D = null

# Terrain artifacts (same shape as tree_scatter / ground_cover).
var _hm_bytes: PackedByteArray = PackedByteArray()
var _splat_a: PackedByteArray = PackedByteArray()
var _splat_road: PackedByteArray = PackedByteArray()
var _splat_b: PackedByteArray = PackedByteArray()
var _terrain_w: int = 0
var _terrain_h: int = 0
var _spacing_m: float = 1.0
var _extent_x: float = 0.0
var _extent_z: float = 0.0
var _terrain_ready: bool = false

# Per-species caches.
var _species_resource_cache: Dictionary = {}  # path → RockSpecies
# Per-species sub-variant LOD chains. The rock pack ships multiple
# sub-variants per shape (e.g. `rock_round_v0`, `rock_round_v1`,
# `rock_round_v2`) so a single species transparently uses three
# different geometric realizations of its shape. Per-instance hash
# picks the variant at spawn time, and each (variant, LOD) gets its
# own MMI in the spawn dict.
#
#   _species_variant_meshes[species_path] = {
#       "_v0": [Mesh_LOD0, Mesh_LOD1, Mesh_LOD2],
#       "_v1": [Mesh_LOD0, Mesh_LOD1, Mesh_LOD2],
#       ...
#   }
var _species_variant_meshes: Dictionary = {}    # path → Dictionary[variant_key → Array[Mesh]]
var _species_variant_lod_levels: Dictionary = {} # path → Dictionary[variant_key → PackedInt32Array]
# Per-variant LOD0 AABB. Sampled once at species-load and used at
# placement to compute the rotated rock's lowest world-Y, so the rock
# always sits with its actual lowest point on the terrain — not the
# un-rotated AABB's lowest point, which gets noticeably wrong once the
# basis is tilted toward the slope normal + random tilt is applied.
# (The pre-2026-05-04 implementation cached only `aabb.position.y` and
# subtracted `min_y * scale`; that produced floating rocks on slopes
# because the rotation moves the actual lowest world-Y point.)
# Per variant rather than per species — LOD0 AABBs vary slightly
# between rock shapes within a pack.
var _species_variant_aabb: Dictionary = {} # path → Dictionary[variant_key → AABB]
# Sorted list of variant keys per species — used to pick a variant by
# index from a per-instance hash. Cached so we don't sort every spawn.
var _species_variant_keys: Dictionary = {}      # path → PackedStringArray
# Per-species impostor mesh chains — built when species's
# proxy_swap_distance_m > 0. The impostor reuses the highest-LOD mesh
# (LOD2 in the rock pack, ~27 verts) but rendered with the unshaded
# `rock_imposter.gdshader` and cast_shadow=OFF.
var _species_variant_imposter_meshes: Dictionary = {}  # path → Dictionary[variant_key → Mesh]
var _species_packs: Dictionary = {}             # path → PackedScene
# Per-species ShaderMaterial registry — populated as materials are
# created so the species's `changed` signal callback can re-push
# live-tunable uniforms (albedo_modulation, roughness_floor) without
# a full rebuild.
var _species_shader_materials: Dictionary = {}  # path → Array[ShaderMaterial]
var _species_imposter_materials: Dictionary = {} # path → Array[ShaderMaterial]
# Tracks species `changed` signal connections — see equivalent comment
# in tree_scatter / ground_cover. Bound callables can't be matched
# via `is_connected`, so dict-track to avoid duplicate handlers.
var _species_changed_connected: Dictionary = {}  # path → true

# Per-biome density bookkeeping.
var _biome_species_paths: Dictionary = {}     # int → PackedStringArray
var _biome_species_cumweight: Dictionary = {}  # int → PackedFloat32Array
var _biome_density: Dictionary = {}           # int → float
var _max_rocks_per_sq_m: float = 0.0

# Tile state.
var _baked_tiles: Dictionary = {}             # Vector2i → Node3D
var _baked_tile_placements: Dictionary = {}   # Vector2i → Dictionary[path → Array[Transform3D]]
var _baked_tile_collision: Dictionary = {}    # Vector2i → bool
var _baked_tile_shadow: Dictionary = {}       # Vector2i → bool
# Per-tile tree-exclusion zones — populated as tiles bake. One entry
# per rock with `RockSpecies.tree_exclusion_radius > 0`. Stored as
# Vector3(world_x, world_z, radius) so the per-candidate check is a
# tight squared-distance comparison.
#
# Keyed by ROCK tile (32 m default). A tree/foliage candidate at
# (wx, wz) looks up the rock tile containing the candidate AND the
# 3 neighbors (a rock near the tile boundary can extend its
# exclusion into the adjacent tile), then iterates the per-tile
# arrays. ~5–10 entries per tile typical → ~40 distance comps per
# candidate, ~340 µs / frame at peak bake rate. Negligible.
var _tile_tree_exclusions: Dictionary = {}    # Vector2i (rock tile) → PackedFloat32Array (x, z, r, x, z, r, …)
var _last_player_xz: Vector2 = Vector2(INF, INF)
var _last_shadow_refresh_xz: Vector2 = Vector2(INF, INF)
var _shadow_pending: Array = []  # pooled, cleared per frame
var _bake_queue: Array[Vector2i] = []
const _TREE_EXCLUSION_GROUP: String = "rocks_tree_exclusion"
# Memoized cache key — `_compute_cache_key` iterates every biome's
# species + density list, so re-hashing per-tile would be wasteful.
# Cleared by `_invalidate_cache_key` when params change.
var _cached_key: String = ""
const _BAKE_BURST_THRESHOLD: int = 32
# Shadow refresh rate-limit. Mirrors `tree_scatter._SHADOW_FLIPS_PER_FRAME`.
# Each flip toggles cast_shadow on every shadow-eligible MMI in the tile;
# spreading flips across frames avoids slamming the directional shadow
# map's caster bookkeeping with N tiles' worth of new entities at once.
const _SHADOW_FLIPS_PER_FRAME: int = 1
# Tiles turn ON shadows at `shadow_radius_m`, but only turn OFF once
# they're past `shadow_radius_m * _SHADOW_OFF_HYSTERESIS`. Prevents
# tiles right at the boundary from flapping ON/OFF every camera step.
const _SHADOW_OFF_HYSTERESIS: float = 1.3
# Skip the per-frame iteration entirely when the camera has barely
# moved. Saves the per-tile distance comp + dict lookup when player
# is stationary or panning the view.
const _SHADOW_REFRESH_MIN_MOVE: float = 1.0


# --- Lifecycle ---

func _ready() -> void:
	# Register in the exclusion group regardless of editor / runtime
	# mode so tree + ground-cover scatters can find us via
	# `get_tree().get_nodes_in_group(_TREE_EXCLUSION_GROUP)`. Empty
	# exclusion dict reads as "no exclusions" — safe before the first
	# tile has baked.
	add_to_group(_TREE_EXCLUSION_GROUP)
	if Engine.is_editor_hint() and not editor_preview:
		return
	_resolve_camera()
	# Lazy init in `_process` — same pattern as TreeScatter.


func _process(_dt: float) -> void:
	var cam: Camera3D
	if Engine.is_editor_hint():
		if not editor_preview:
			return
		cam = _get_editor_camera()
	else:
		cam = _camera
	if cam == null:
		return
	if not _terrain_ready and not _ensure_terrain_loaded():
		return
	_resolve_terrain3d()
	if _biome_species_paths.is_empty():
		_build_species_table()
		if _biome_species_paths.is_empty():
			return
	# `player_cam_pos` is a global shader uniform — at runtime
	# `player.gd` pushes it once per frame (single source of truth).
	# We only push in editor preview where `player.gd` doesn't run,
	# so the rock scatter still works when no other system is active.
	if Engine.is_editor_hint():
		RenderingServer.global_shader_parameter_set(
			"player_cam_pos", cam.global_position)
	var p_xz := _xz(cam.global_position)
	if (p_xz - _last_player_xz).length() >= rebuild_threshold_m:
		_rebuild_active(p_xz)
		_refresh_collisions()
	# Shadow refresh runs EVERY FRAME (decoupled from rebuild_threshold)
	# with a per-frame flip cap, so individual tiles toggle precisely
	# as the camera crosses each one's boundary instead of batching
	# many tile flips into one rebuild-tick frame.
	_refresh_shadows(p_xz)
	if bake_per_frame_budget > 0 and not _bake_queue.is_empty():
		var budget: int = (
			bake_burst_budget
			if _bake_queue.size() > _BAKE_BURST_THRESHOLD
			else bake_per_frame_budget)
		_drain_bake_queue(budget)


# --- Editor preview / rebuild ---

func _set_editor_preview(v: bool) -> void:
	editor_preview = v
	if not is_inside_tree():
		return
	if v:
		_last_player_xz = Vector2(INF, INF)
		set_process(true)
	else:
		_clear_all_tiles()
		_last_player_xz = Vector2(INF, INF)


func _force_rebuild() -> void:
	_clear_all_tiles()
	_invalidate_cache_key()
	# Disconnect species `changed` signals before clearing the cache,
	# otherwise stale signal connections leak across rebuilds.
	for path in _species_resource_cache.keys():
		var sp_old: RockSpecies = _species_resource_cache[path]
		if sp_old == null:
			continue
		var cb := _on_species_changed.bind(path)
		if sp_old.changed.is_connected(cb):
			sp_old.changed.disconnect(cb)
	_species_changed_connected.clear()
	_species_resource_cache.clear()
	_species_variant_meshes.clear()
	_species_variant_aabb.clear()
	_species_variant_lod_levels.clear()
	_species_variant_keys.clear()
	_species_variant_imposter_meshes.clear()
	_species_shader_materials.clear()
	_species_imposter_materials.clear()
	_species_packs.clear()
	_biome_species_paths.clear()
	_biome_species_cumweight.clear()
	_biome_density.clear()
	_max_rocks_per_sq_m = 0.0
	_last_player_xz = Vector2(INF, INF)


func _clear_all_tiles() -> void:
	for k in _baked_tiles.keys():
		var n: Node3D = _baked_tiles[k]
		if is_instance_valid(n):
			n.queue_free()
	_baked_tiles.clear()
	_baked_tile_placements.clear()
	_baked_tile_collision.clear()
	_baked_tile_shadow.clear()
	_tile_tree_exclusions.clear()
	_bake_queue.clear()


# --- Camera + terrain resolution ---

func _resolve_camera() -> void:
	if not camera_path.is_empty():
		_camera = get_node_or_null(camera_path) as Camera3D
		if _camera != null:
			return
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_camera = _find_first_camera(players[0])


func _find_first_camera(n: Node) -> Camera3D:
	if n is Camera3D:
		return n
	for c in n.get_children():
		var cam := _find_first_camera(c)
		if cam != null:
			return cam
	return null


func _get_editor_camera() -> Camera3D:
	if not Engine.is_editor_hint():
		return null
	var vp = EditorInterface.get_editor_viewport_3d()
	return vp.get_camera_3d() if vp != null else null


func _resolve_terrain3d() -> void:
	if _terrain3d != null and is_instance_valid(_terrain3d):
		return
	if not terrain3d_path.is_empty():
		_terrain3d = get_node_or_null(terrain3d_path) as Node3D


# --- Terrain artifact loading (heightmap + splat for biome lookup) ---

func _ensure_terrain_loaded() -> bool:
	if _terrain_ready:
		return true
	var dir := "res://assets/terrain/%s/" % map_id
	var toml_path := dir + "terrain.toml"
	if not FileAccess.file_exists(toml_path):
		return false
	var meta := _parse_terrain_toml(toml_path)
	if meta.is_empty():
		return false
	_terrain_w = int(meta.get("width", 0))
	_terrain_h = int(meta.get("height", 0))
	_spacing_m = float(meta.get("spacing_m", 1.0))
	_extent_x = float(_terrain_w - 1) * _spacing_m
	_extent_z = float(_terrain_h - 1) * _spacing_m
	var hm := FileAccess.open(dir + "heightmap.r32", FileAccess.READ)
	if hm != null:
		_hm_bytes = hm.get_buffer(hm.get_length())
		hm.close()
	var sa := FileAccess.open(dir + "splatmap_a.rgba8", FileAccess.READ)
	if sa != null:
		_splat_a = sa.get_buffer(sa.get_length())
		sa.close()
	# splat_b — needed for the BuiltUp channel (G), which marks town
	# footprints. Folded into `_road_density_at` so big rocks vacate
	# settlements alongside roads. Without this, rocks spawn through
	# people's houses on splat_a-tagged-as-forest pixels that are
	# actually town centres.
	var sb := FileAccess.open(dir + "splatmap_b.rgba8", FileAccess.READ)
	if sb != null:
		_splat_b = sb.get_buffer(sb.get_length())
		sb.close()
	var sr := FileAccess.open(dir + "road_density.rgba8", FileAccess.READ)
	if sr != null:
		_splat_road = sr.get_buffer(sr.get_length())
		sr.close()
	_terrain_ready = _hm_bytes.size() > 0 and _splat_a.size() > 0
	return _terrain_ready


func _parse_terrain_toml(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var out: Dictionary = {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("#") or line.is_empty():
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		var k := line.substr(0, eq).strip_edges()
		var v := line.substr(eq + 1).strip_edges()
		if v.is_valid_float():
			out[k] = v.to_float()
		elif v.is_valid_int():
			out[k] = v.to_int()
		else:
			out[k] = v
	f.close()
	return out


# --- Species + biome table ---

func _build_species_table() -> void:
	_biome_species_paths.clear()
	_biome_species_cumweight.clear()
	_biome_density.clear()
	_max_rocks_per_sq_m = 0.0
	for cfg in biome_configs:
		if cfg == null or cfg.rock_paths.is_empty():
			continue
		var paths := PackedStringArray()
		var cums := PackedFloat32Array()
		var cum := 0.0
		# Track peak density (base + max possible cluster bonus per
		# species) so the per-tile candidate count is large enough to
		# fill clump crests. Without this, a high-cluster_strength
		# species runs out of candidates inside its own clumps and the
		# user sees thin sprinkles instead of dense boulder fields.
		var peak: float = 0.0
		var use_explicit := cfg.rock_densities.size() == cfg.rock_paths.size()
		for i in cfg.rock_paths.size():
			var p: String = cfg.rock_paths[i]
			if p.is_empty():
				continue
			var contribution: float = (cfg.rock_densities[i]
				if use_explicit else cfg.rocks_per_sq_m)
			if contribution <= 0.0:
				continue
			paths.append(p)
			cum += contribution
			cums.append(cum)
			# Peak per-species contribution = base × (1 + max terrain
			# boost). At maximum terrain rockiness (score = 1), the
			# species's accept rate scales by 1 + terrain_density_boost.
			# Sizing the candidate budget to peak (not mean) ensures
			# steep-terrain tiles can fill their boulder accumulations
			# without running out of draws.
			var sp: RockSpecies = _get_cached_species(p)
			var max_terrain: float = 0.0
			if sp != null:
				max_terrain = sp.terrain_density_boost
			peak += contribution * (1.0 + max_terrain)
		if paths.size() == 0:
			continue
		_biome_species_paths[cfg.biome] = paths
		_biome_species_cumweight[cfg.biome] = cums
		var eff: float = cum if use_explicit else cfg.rocks_per_sq_m
		_biome_density[cfg.biome] = eff
		# Use peak (not eff) for the candidate-count target. `eff` still
		# drives the bernoulli accept_p so per-biome thinning works
		# correctly; peak just guarantees enough draws are available
		# inside cluster crests.
		_max_rocks_per_sq_m = maxf(_max_rocks_per_sq_m, peak)


func _get_cached_species(species_path: String) -> RockSpecies:
	if _species_resource_cache.has(species_path):
		return _species_resource_cache[species_path]
	var sp: RockSpecies = load(species_path) as RockSpecies
	_species_resource_cache[species_path] = sp
	# Hook the resource's `changed` signal so inspector edits to live-
	# tunable fields (albedo_modulation, roughness_floor) push to
	# running materials without requiring a tile rebuild. Mirrors the
	# pattern in `tree_scatter._get_cached_species`.
	if sp != null and not _species_changed_connected.get(species_path, false):
		sp.changed.connect(_on_species_changed.bind(species_path))
		_species_changed_connected[species_path] = true
	return sp


# Re-push live-tunable uniforms to all materials registered for this
# species. Triggered by inspector edits to `RockSpecies` properties
# (the resource emits `changed` automatically on `@export var` writes).
func _on_species_changed(species_path: String) -> void:
	var sp: RockSpecies = _species_resource_cache.get(species_path)
	if sp == null:
		return
	# Close-tier materials.
	var mats: Array = _species_shader_materials.get(species_path, [])
	for m in mats:
		var sm: ShaderMaterial = m as ShaderMaterial
		if sm == null or not is_instance_valid(sm):
			continue
		_push_live_uniforms(sm, sp)
	# Impostor materials — same albedo + jitter push, but no
	# roughness uniform (impostor is unshaded; roughness is meaningless).
	var imp_mats: Array = _species_imposter_materials.get(species_path, [])
	for m in imp_mats:
		var sm: ShaderMaterial = m as ShaderMaterial
		if sm == null or not is_instance_valid(sm):
			continue
		sm.set_shader_parameter("albedo_modulation", Vector3(
			sp.albedo_modulation.r, sp.albedo_modulation.g,
			sp.albedo_modulation.b))
		sm.set_shader_parameter("albedo_value_jitter", sp.albedo_value_jitter)
		sm.set_shader_parameter("albedo_hue_jitter_deg", sp.albedo_hue_jitter_deg)


# Single source of truth for which uniforms are "live-tunable" —
# pushed both at material creation AND on `species.changed`. Other
# uniforms (LOD bands, max render distance) are spawn-time only
# because they're tied to the per-tile MMI dispatch.
func _push_live_uniforms(sm: ShaderMaterial, sp: RockSpecies) -> void:
	sm.set_shader_parameter("albedo_modulation", Vector3(
		sp.albedo_modulation.r, sp.albedo_modulation.g,
		sp.albedo_modulation.b))
	sm.set_shader_parameter("roughness_floor", sp.roughness_floor)
	sm.set_shader_parameter("albedo_value_jitter", sp.albedo_value_jitter)
	sm.set_shader_parameter("albedo_hue_jitter_deg", sp.albedo_hue_jitter_deg)


# Walk the rock pack scene, collect MeshInstance3Ds whose name starts
# with `<variant_prefix>_` AND contains a `_LOD<N>` segment. Bucket
# results by sub-variant key (the substring between prefix and `_LOD`,
# e.g. `_v0`, `_v1`, or empty for legacy single-variant packs). Each
# variant gets its own LOD chain with the species's textures + LOD
# boundaries baked in.
func _ensure_species_resources(species_path: String) -> bool:
	if _species_variant_meshes.has(species_path):
		return _species_variant_meshes[species_path].size() > 0
	var sp: RockSpecies = load(species_path) as RockSpecies
	if sp == null or sp.pack_scene_path.is_empty():
		_species_variant_meshes[species_path] = {}
		return false
	var packed: PackedScene = load(sp.pack_scene_path) as PackedScene
	if packed == null:
		push_warning("[rocks] failed to load pack %s" % sp.pack_scene_path)
		_species_variant_meshes[species_path] = {}
		return false
	_species_packs[species_path] = packed
	var root: Node = packed.instantiate()
	# Add to tree so global_transform composes — same gltf-importer
	# Z-up→Y-up rotation parent dance as TreeScatter.
	add_child(root)
	var mis: Array[MeshInstance3D] = []
	_collect_mesh_instances(root, mis)
	# Bucket by variant key. `_parse_variant_lod` splits each mesh's
	# name into (variant_key, lod_level). variant_key is `_v0` / `_v1`
	# / etc. for the multi-variant pack, or empty string for legacy.
	var prefix := sp.variant_prefix
	var raw_buckets: Dictionary = {}  # variant_key → Array[{mesh, lod}]
	var min_lod := 999
	var max_lod := -1
	for mi in mis:
		if mi.mesh == null:
			continue
		var parsed: Dictionary = _parse_variant_lod(mi.name, prefix)
		if parsed["lod"] < 0:
			continue
		var k: String = parsed["variant"]
		var lvl: int = parsed["lod"]
		if not raw_buckets.has(k):
			raw_buckets[k] = []
		raw_buckets[k].append({"mesh": mi.mesh, "lod": lvl})
		if lvl < min_lod:
			min_lod = lvl
		if lvl > max_lod:
			max_lod = lvl
	remove_child(root)
	root.queue_free()
	if raw_buckets.is_empty():
		push_warning("[rocks] %s found 0 variants for prefix '%s' in %s"
			% [species_path, prefix, sp.pack_scene_path])
		_species_variant_meshes[species_path] = {}
		return false
	var shader: Shader = load(ROCK_SHADER_PATH) as Shader
	var imposter_shader: Shader = load(ROCK_IMPOSTER_SHADER_PATH) as Shader
	# Resolve texture set once per species. All variants share the
	# same textures — variation comes from geometry, not texturing.
	var tex_color: Texture2D = _load_rock_texture(sp, "color.png")
	var tex_normal: Texture2D = _load_rock_texture(sp, "normal.png")
	var tex_rough: Texture2D = _load_rock_texture(sp, "roughness.png")
	# Build per-variant mesh chains: dup each variant's source mesh,
	# bake ShaderMaterial with LOD-band uniforms onto every surface.
	var variant_meshes: Dictionary = {}
	var variant_lod_levels: Dictionary = {}
	var variant_imposter_meshes: Dictionary = {}
	var variant_keys: PackedStringArray = PackedStringArray()
	# Cached LOD0 AABB per variant. Used at placement to compute the
	# rotated rock's lowest world-Y so the rock sits with its actual
	# lowest point on the terrain regardless of where the mesh's local
	# origin sits AND regardless of how the basis is tilted by terrain
	# alignment + random tilt.
	var variant_aabb: Dictionary = {}
	# Track all materials we create for this species so the
	# live-update callback can re-push uniforms on `changed`.
	var live_close_mats: Array = []
	var live_imposter_mats: Array = []
	# Sort the keys so the spawn-time index lookup is stable across
	# runs (Dictionary key ordering is insertion-order in GDScript,
	# which is fine but explicit sort makes it bulletproof).
	var sorted_keys: Array = raw_buckets.keys()
	sorted_keys.sort()
	for k in sorted_keys:
		variant_keys.append(k)
		var entries: Array = raw_buckets[k]
		var dup_meshes: Array[Mesh] = []
		var lod_levels: PackedInt32Array = PackedInt32Array()
		# Capture LOD0's AABB for this variant. Entries are in
		# bucket-insertion order (`raw_buckets[k].append(...)`); LOD0
		# is the lowest-numbered LOD, which we find via min over
		# entries since pack scenes may list LODs out of order. The
		# full AABB (not just min.y) is needed at placement because
		# we transform all 8 corners through the rotated basis to find
		# the actual lowest world-Y point.
		var lod0_aabb: AABB = AABB()
		var lod0_seen: int = 999
		for entry in entries:
			if entry["lod"] < lod0_seen:
				lod0_seen = entry["lod"]
				var src_mesh: Mesh = entry["mesh"]
				if src_mesh != null:
					lod0_aabb = src_mesh.get_aabb()
		variant_aabb[k] = lod0_aabb
		# Track the highest-LOD source mesh so we can dup it again as
		# the impostor (different shader / shadow setting).
		var hi_lod_mesh: Mesh = null
		var hi_lod_seen: int = -1
		for entry in entries:
			var src: Mesh = entry["mesh"]
			var dup: Mesh = src.duplicate(true) as Mesh
			if dup == null:
				dup = src
			var lod_level: int = entry["lod"]
			if lod_level > hi_lod_seen:
				hi_lod_seen = lod_level
				hi_lod_mesh = src
			var bounds: Dictionary = _lod_boundaries(
				lod_level, sp, min_lod, max_lod)
			for s in dup.get_surface_count():
				var sm := ShaderMaterial.new()
				sm.shader = shader
				if tex_color != null:
					sm.set_shader_parameter("albedo_tex", tex_color)
				if tex_normal != null:
					sm.set_shader_parameter("normal_tex", tex_normal)
				if tex_rough != null:
					sm.set_shader_parameter("roughness_tex", tex_rough)
				_push_live_uniforms(sm, sp)
				sm.set_shader_parameter("lod_lower_boundary", bounds["lower"])
				sm.set_shader_parameter("lod_upper_boundary", bounds["upper"])
				sm.set_shader_parameter("lod_fade_half_width", lod_band_fade_m * 0.5)
				sm.set_shader_parameter(
					"max_render_distance_m",
					maxf(sp.max_render_distance_m, bounds["upper"] + lod_band_fade_m))
				dup.surface_set_material(s, sm)
				live_close_mats.append(sm)
			dup_meshes.append(dup)
			lod_levels.append(lod_level)
		variant_meshes[k] = dup_meshes
		variant_lod_levels[k] = lod_levels
		# Build the impostor mesh for this variant. Reuses the highest-
		# LOD source mesh (LOD2 in the standard pack) — at proxy_swap
		# distance the silhouette difference between LOD2 and a true
		# billboard card is invisible. Skipped if species has no
		# proxy_swap_distance_m set.
		if sp.proxy_swap_distance_m > 0.0 and hi_lod_mesh != null:
			var imp_dup: Mesh = hi_lod_mesh.duplicate(true) as Mesh
			if imp_dup == null:
				imp_dup = hi_lod_mesh
			for s in imp_dup.get_surface_count():
				var imp_sm := ShaderMaterial.new()
				imp_sm.shader = imposter_shader
				if tex_color != null:
					imp_sm.set_shader_parameter("albedo_tex", tex_color)
				imp_sm.set_shader_parameter("albedo_modulation", Vector3(
					sp.albedo_modulation.r, sp.albedo_modulation.g,
					sp.albedo_modulation.b))
				imp_sm.set_shader_parameter(
					"albedo_value_jitter", sp.albedo_value_jitter)
				imp_sm.set_shader_parameter(
					"albedo_hue_jitter_deg", sp.albedo_hue_jitter_deg)
				# Impostor's lower boundary matches close-tier's upper
				# boundary (= proxy_swap_distance_m) so the close fade-
				# out and impostor fade-in share a complementary dither
				# at the swap zone.
				imp_sm.set_shader_parameter(
					"lod_lower_boundary", sp.proxy_swap_distance_m)
				imp_sm.set_shader_parameter(
					"lod_fade_half_width", lod_band_fade_m * 0.5)
				# Impostor renders out to a generous backstop. Tune via
				# species.max_render_distance_m if you want the impostor
				# to cull earlier.
				imp_sm.set_shader_parameter(
					"max_render_distance_m",
					maxf(sp.max_render_distance_m,
						 sp.proxy_swap_distance_m + 600.0))
				imp_dup.surface_set_material(s, imp_sm)
				live_imposter_mats.append(imp_sm)
			variant_imposter_meshes[k] = imp_dup
	_species_variant_meshes[species_path] = variant_meshes
	_species_variant_lod_levels[species_path] = variant_lod_levels
	_species_variant_aabb[species_path] = variant_aabb
	_species_variant_imposter_meshes[species_path] = variant_imposter_meshes
	_species_variant_keys[species_path] = variant_keys
	_species_shader_materials[species_path] = live_close_mats
	_species_imposter_materials[species_path] = live_imposter_mats
	return true


# Parse a mesh name into (variant_key, lod_level). The naming
# convention is `<prefix><variant_key>_LOD<N>` where variant_key is
# `_v0`, `_v1`, `_v2`, ... in the multi-variant pack, or empty in a
# single-variant pack. Returns lod = -1 if the name doesn't match.
static func _parse_variant_lod(name: String, prefix: String) -> Dictionary:
	if not name.begins_with(prefix + "_"):
		# `prefix + "_"` not just prefix — keeps "rock_round" from
		# matching "rock_round_alt" if a future variant name happens
		# to subset another's name.
		return {"variant": "", "lod": -1}
	var idx_lod: int = name.find("_LOD")
	if idx_lod < prefix.length():
		return {"variant": "", "lod": -1}
	var variant_key: String = name.substr(
		prefix.length(), idx_lod - prefix.length())
	# variant_key is e.g. "" (legacy) or "_v0" / "_v1" / "_v2" (new).
	var lod := 0
	var i: int = idx_lod + 4
	while i < name.length():
		var c: int = name.unicode_at(i)
		if c < 0x30 or c > 0x39:
			break
		lod = lod * 10 + (c - 0x30)
		i += 1
	return {"variant": variant_key, "lod": lod}


# Resolve the species's PBR texture path. Tiers 1k / 2k live under
# `res://assets/textures/rocks/<set>/<tier>/`; the 4k tier reads
# directly from the source AmbientCG dir.
func _load_rock_texture(sp: RockSpecies, channel_filename: String) -> Texture2D:
	var tier_name: String = TEXTURE_TIERS[clampi(sp.resolution_tier, 0, 2)]
	var path: String
	if tier_name == "4k":
		# Source files use the AmbientCG `<id>_4K-PNG_<Channel>.png`
		# naming. Map our channel filename back to the source name.
		var channel_to_amb: Dictionary = {
			"color.png": "Color",
			"normal.png": "NormalGL",
			"roughness.png": "Roughness",
		}
		var amb: String = channel_to_amb.get(channel_filename, "")
		if amb.is_empty():
			return null
		path = "res://assets/textures/terrain/%s_4K-PNG/%s_4K-PNG_%s.png" % [
			sp.texture_set, sp.texture_set, amb]
	else:
		path = "res://assets/textures/rocks/%s/%s/%s" % [
			sp.texture_set, tier_name, channel_filename]
	if not ResourceLoader.exists(path):
		push_warning("[rocks] missing texture %s for species %s"
			% [path, sp.resource_path])
		return null
	return load(path) as Texture2D


# Compute the per-LOD distance band [lower, upper] for a species's
# given LOD level. Same algorithm as TreeScatter._lod_boundaries
# but inlined here since rocks have no proxy_swap_distance concept.
func _lod_boundaries(lod_level: int, sp: RockSpecies,
		min_lod: int, max_lod: int) -> Dictionary:
	var lower: float
	if lod_level <= min_lod:
		lower = -1.0
	else:
		lower = _band_end_for_lod(lod_level - 1, sp, max_lod)
	var upper: float
	if lod_level >= max_lod:
		# Highest LOD's upper bound is the species cull distance;
		# the lod_upper_boundary fade lets it crossfade to nothing
		# before the hard `max_render_distance_m` kicks in.
		upper = sp.max_render_distance_m
	else:
		upper = _band_end_for_lod(lod_level, sp, max_lod)
	return {"lower": lower, "upper": upper}


func _band_end_for_lod(lod_level: int, sp: RockSpecies, max_lod: int) -> float:
	# Highest LOD's upper bound = where the close-tier hands off. If
	# the species ships an impostor (`proxy_swap_distance_m > 0`),
	# hand off there; otherwise hand off at the species's own cull
	# distance. Mirrors `tree_scatter._band_end_for_lod`.
	if lod_level >= max_lod:
		if sp.proxy_swap_distance_m > 0.0:
			return sp.proxy_swap_distance_m
		return sp.max_render_distance_m
	if lod_level < lod_band_ends_m.size():
		return lod_band_ends_m[lod_level]
	return lod_band_ends_m[lod_band_ends_m.size() - 1]


func _collect_mesh_instances(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_mesh_instances(c, out)


# --- Active tile management ---

func _rebuild_active(player_xz: Vector2) -> void:
	_last_player_xz = player_xz
	if not _terrain_ready:
		return
	var radius_tiles := int(ceil(active_radius_m / tile_size_m))
	var center_tile := Vector2i(
		int(floor(player_xz.x / tile_size_m)),
		int(floor(player_xz.y / tile_size_m)))
	var wanted: Dictionary = {}
	var r_sq := active_radius_m * active_radius_m
	for dz in range(-radius_tiles, radius_tiles + 1):
		for dx in range(-radius_tiles, radius_tiles + 1):
			var tile := center_tile + Vector2i(dx, dz)
			var tcx := (float(tile.x) + 0.5) * tile_size_m
			var tcz := (float(tile.y) + 0.5) * tile_size_m
			var d_sq := (tcx - player_xz.x) ** 2 + (tcz - player_xz.y) ** 2
			if d_sq <= r_sq:
				wanted[tile] = true
	for k in _baked_tiles.keys():
		if not wanted.has(k):
			var n: Node3D = _baked_tiles[k]
			if is_instance_valid(n):
				n.queue_free()
			_baked_tiles.erase(k)
			_baked_tile_placements.erase(k)
			_baked_tile_collision.erase(k)
			_baked_tile_shadow.erase(k)
			_tile_tree_exclusions.erase(k)
	_bake_queue = _bake_queue.filter(func(t: Vector2i) -> bool:
		return wanted.has(t))
	var pending: Array[Vector2i] = []
	for k in wanted.keys():
		if not _baked_tiles.has(k) and not _bake_queue.has(k):
			pending.append(k)
	pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ax := (float(a.x) + 0.5) * tile_size_m - player_xz.x
		var az := (float(a.y) + 0.5) * tile_size_m - player_xz.y
		var bx := (float(b.x) + 0.5) * tile_size_m - player_xz.x
		var bz := (float(b.y) + 0.5) * tile_size_m - player_xz.y
		return (ax * ax + az * az) < (bx * bx + bz * bz))
	_bake_queue.append_array(pending)


func _drain_bake_queue(count: int) -> int:
	var baked := 0
	while baked < count and not _bake_queue.is_empty():
		var tile: Vector2i = _bake_queue[0]
		_bake_queue.remove_at(0)
		if not _baked_tiles.has(tile):
			_bake_tile(tile)
		baked += 1
	return baked


# --- Tile bake ---

func _bake_tile(tile: Vector2i, cache_only: bool = false) -> void:
	# `cache_only` is the whole-map-bake escape hatch: skip the
	# `_spawn_tile` step (which creates per-species MultiMesh +
	# collision bodies) and only write the disk cache + tree-exclusion
	# table. The runtime spawns from cache when the player approaches.
	# Without this, a whole-map bake on a large map would create
	# hundreds of thousands of MultiMesh RIDs and exhaust Godot's RID
	# owner. The tree-exclusion table is still populated so trees baked
	# afterward see the rocks they shouldn't grow inside.
	if cache_enabled and not _bake_force_fresh and not cache_only:
		var cached: Dictionary = _try_load_tile_cache(tile)
		if not cached.is_empty():
			_spawn_tile_from_cache(tile, cached)
			return
	var rng := RandomNumberGenerator.new()
	rng.seed = (
		(int(seed) * 73856093) ^
		(int(tile.x) * 19349663) ^
		(int(tile.y) * 83492791))
	var origin_x := float(tile.x) * tile_size_m
	var origin_z := float(tile.y) * tile_size_m
	var tile_area := tile_size_m * tile_size_m
	var raw_count := int(round(_max_rocks_per_sq_m * tile_area * density_multiplier))
	var candidates := clampi(raw_count, 1, placements_per_tile_cap)
	var max_density := maxf(_max_rocks_per_sq_m, 0.0001)
	var per_species_xforms: Dictionary = {}
	# Tree-exclusion zones for THIS rock tile — accumulated as
	# placements are accepted. Flat (x, z, r) triplets so per-candidate
	# tree/foliage queries are tight squared-distance comps.
	var tile_exclusions: PackedFloat32Array = PackedFloat32Array()

	# ==== ANCHOR PRE-PASS ====
	# Roll anchor placements before the main candidate loop so the
	# anchor positions are available for satellite proximity
	# boosting. AAA approach: hero rocks (boulders, clusters) act as
	# attractors; smaller species (pebbles, gravel) get density
	# multiplied near anchors. Result: clumped formations instead of
	# uniform pepper-spray.
	#
	# Uses a separate RNG seeded off the tile RNG so anchor positions
	# are deterministic per-tile but independent of main-pass RNG
	# consumption — adding a satellite species doesn't shift the
	# anchor layout.
	var anchor_rng := RandomNumberGenerator.new()
	anchor_rng.seed = (rng.seed ^ 0xA10C0FF1)
	var anchor_positions: PackedFloat32Array = PackedFloat32Array()
	var anchor_radii: PackedFloat32Array = PackedFloat32Array()
	# Iterate distinct biomes touching this tile via a single anchor
	# attempt loop driven by the same `candidates` budget × an anchor
	# multiplier (~2x so anchors get enough rolls to actually place
	# at their typically-low density).
	var anchor_candidates := candidates * 2
	for _ai in anchor_candidates:
		var ajx := anchor_rng.randf()
		var ajz := anchor_rng.randf()
		var awx := origin_x + ajx * tile_size_m
		var awz := origin_z + ajz * tile_size_m
		var abiome := _biome_at_world(awx, awz)
		if abiome < 0 or not _biome_species_paths.has(abiome):
			continue
		if abiome == 4:
			continue
		# Terrain Y at this anchor candidate. Hoisted above the
		# exclusion check because the zone test needs full XYZ; reused
		# below for placement so the rejection-path cost is one
		# heightmap lookup per skipped anchor.
		var ay: float = _height_at_world(awx, awz)
		var aexcl_mul: float = _ExclusionZoneRef.density_multiplier(
			get_tree(), awx, ay, awz, "rocks")
		if aexcl_mul <= 0.0:
			continue
		# Pick an anchor-eligible species via the cumulative weight
		# table, then re-roll if it's not an anchor. Cheaper than
		# building a parallel anchor-only weight table.
		var aspath := _pick_species(abiome, anchor_rng.randf())
		if aspath.is_empty():
			continue
		var asp: RockSpecies = _get_cached_species(aspath)
		if asp == null or not asp.is_anchor:
			continue
		var afeats: Dictionary = _terrain_features(awx, awz)
		if afeats.slope < asp.terrain_min_score:
			continue
		var aslope: float = _slope_at_world(awx, awz)
		if aslope < asp.slope_min or aslope > asp.slope_max:
			continue
		var abiome_target: float = _biome_density.get(abiome, 0.0)
		var aterrain_factor: float = 1.0 \
			+ asp.terrain_density_boost * afeats.slope \
			+ asp.terrain_curvature_boost * afeats.curvature \
			+ asp.terrain_basal_boost * afeats.basal
		var aaccept_p: float = (abiome_target / max_density) * aexcl_mul \
			* aterrain_factor
		if aaccept_p < 1.0 and anchor_rng.randf() > aaccept_p:
			continue
		# Anchor placement accepted. Build transform here (mirror of
		# the main-loop construction) so we can both add it to the
		# species's xform list AND register the anchor position. `ay`
		# was the raw heightmap-Y at the anchor; we'll rebase it below
		# so the rotated rock's lowest world-point lands on terrain.
		var as_scale: float = lerpf(asp.scale_min, asp.scale_max,
			anchor_rng.randf()) * asp.size_multiplier
		if asp.scale_terrain_boost > 0.0:
			as_scale *= 1.0 + asp.scale_terrain_boost * afeats.slope
		if asp.scale_basal_boost > 0.0:
			as_scale *= 1.0 + asp.scale_basal_boost * afeats.basal
		# Variant pick — needed for the AABB lookup that drives the
		# rotated-Y snap below.
		if not _ensure_species_resources(aspath):
			continue
		var akeys: PackedStringArray = _species_variant_keys.get(
			aspath, PackedStringArray())
		if akeys.is_empty():
			continue
		var av_idx: int = _variant_pick_idx(awx, awz, akeys.size())
		var av_key: String = akeys[av_idx]
		var aabb_lookup_a: Dictionary = _species_variant_aabb.get(aspath, {})
		var a_aabb: AABB = aabb_lookup_a.get(av_key, AABB())
		# Build the basis BEFORE doing any Y math — the rotated-AABB
		# Y-min depends on the fully-built basis. Mirrors the main loop.
		var aaligned_up: Vector3 = Vector3.UP
		if asp.terrain_alignment_factor > 0.0:
			var atn: Vector3 = _terrain_normal_at(awx, awz)
			aaligned_up = Vector3.UP.lerp(atn, asp.terrain_alignment_factor).normalized()
		var asx: float = as_scale
		var asy: float = as_scale
		var asz: float = as_scale
		if asp.scale_axis_jitter > 0.0:
			var aaj: float = asp.scale_axis_jitter
			asx *= 1.0 + (anchor_rng.randf() * 2.0 - 1.0) * aaj
			asz *= 1.0 + (anchor_rng.randf() * 2.0 - 1.0) * aaj
		var abasis: Basis = _basis_with_up(aaligned_up).scaled(
			Vector3(asx, asy, asz))
		if asp.random_yaw:
			abasis = abasis.rotated(aaligned_up, anchor_rng.randf() * TAU)
		if asp.random_tilt_deg > 0.0:
			var atilt_rad: float = deg_to_rad(asp.random_tilt_deg)
			var atx: float = (anchor_rng.randf() * 2.0 - 1.0) * atilt_rad
			var atz: float = (anchor_rng.randf() * 2.0 - 1.0) * atilt_rad
			var atilt_x: Vector3 = aaligned_up.cross(Vector3.RIGHT).normalized()
			if atilt_x.length_squared() < 0.01:
				atilt_x = aaligned_up.cross(Vector3.FORWARD).normalized()
			var atilt_z: Vector3 = aaligned_up.cross(atilt_x).normalized()
			abasis = abasis.rotated(atilt_x, atx)
			abasis = abasis.rotated(atilt_z, atz)
		if asp.extreme_tilt_chance > 0.0 and asp.extreme_tilt_deg > 0.0 \
				and anchor_rng.randf() < asp.extreme_tilt_chance:
			var aext_t: float = (anchor_rng.randf() * 2.0 - 1.0) * deg_to_rad(asp.extreme_tilt_deg)
			var aext_yaw: float = anchor_rng.randf() * TAU
			var aext_axis: Vector3 = Vector3.RIGHT.rotated(aaligned_up, aext_yaw).normalized()
			abasis = abasis.rotated(aext_axis, aext_t)
		# Footprint-min snap + stacked sinks (mirror of main loop).
		var a_lowest_y: float = _lowest_world_y_offset(abasis, a_aabb)
		var a_vertical_extent: float = a_aabb.size.y * asy
		var a_horizontal_radius: float = maxf(
			a_aabb.size.x * asx, a_aabb.size.z * asz) * 0.5
		if _max_road_density_in_footprint(awx, awz, a_horizontal_radius) > road_max_density_byte:
			continue
		var a_snap_y: float = _min_terrain_y_in_footprint(awx, awz, a_horizontal_radius)
		var aslope_factor: float = smoothstep(0.5, 1.6, aslope)
		var a_sink: float = (asp.terrain_sink_baseline
			+ asp.terrain_sink_factor * aslope_factor) * asy
		if asp.terrain_sink_random_max > 0.0:
			a_sink += anchor_rng.randf() * asp.terrain_sink_random_max * a_aabb.size.y * asy
		a_sink = clampf(a_sink, 0.0, a_vertical_extent * 0.5)
		ay = a_snap_y - a_lowest_y - a_sink
		var axform := Transform3D(abasis, Vector3(awx, ay, awz))
		# Variant + species_resources already resolved above for the
		# AABB lookup; reuse here.
		var aper_var: Dictionary = per_species_xforms.get(aspath, {})
		var aarr: Array = aper_var.get(av_key, [])
		aarr.append(axform)
		aper_var[av_key] = aarr
		per_species_xforms[aspath] = aper_var
		# Publish tree exclusion the same way as main loop.
		if asp.tree_exclusion_radius > 0.0:
			tile_exclusions.append(awx)
			tile_exclusions.append(awz)
			tile_exclusions.append(asp.tree_exclusion_radius * as_scale)
		# Register anchor position + radius for satellite lookup.
		anchor_positions.append(awx)
		anchor_positions.append(awz)
		anchor_radii.append(asp.satellite_anchor_radius)

		# ==== ANCHOR SIBLING CLUSTER ====
		# Roll up to feature_cluster_count_max additional same-species
		# anchors within feature_cluster_radius. Drives compound boulder
		# features — multiple overlapping rocks reading as one geological
		# feature. Siblings bypass the terrain-score gate (parent
		# vouched) and density acceptance (we want them to land), but
		# still respect slope_min/max + biome.
		if asp.feature_cluster_count_max > 0:
			var sib_count: int = anchor_rng.randi_range(
				1, asp.feature_cluster_count_max)
			for _si in sib_count:
				# Uniform in disk: r = R*sqrt(u), θ = 2π*v
				var sib_angle: float = anchor_rng.randf() * TAU
				var sib_dist: float = sqrt(anchor_rng.randf()) * asp.feature_cluster_radius
				var sib_wx: float = awx + cos(sib_angle) * sib_dist
				var sib_wz: float = awz + sin(sib_angle) * sib_dist
				var sib_biome: int = _biome_at_world(sib_wx, sib_wz)
				if sib_biome < 0 or sib_biome == 4:
					continue
				if not _biome_species_paths.has(sib_biome):
					continue
				var sib_slope: float = _slope_at_world(sib_wx, sib_wz)
				if sib_slope < asp.slope_min or sib_slope > asp.slope_max:
					continue
				# Sibling scale: FORCED tiering — sibling i gets the i-th
				# equal slice of [scale_min, scale_max]. Guarantees every
				# cluster has a small/medium/large mix instead of relying
				# on luck (uniform rolls cluster around the mean, dragging
				# scale_terrain_boost into the mix made every sibling at
				# the same terrain feature look the same size).
				var sib_feats: Dictionary = _terrain_features(sib_wx, sib_wz)
				var bin_lo: float = float(_si) / float(sib_count)
				var bin_hi: float = float(_si + 1) / float(sib_count)
				var bin_t: float = lerpf(bin_lo, bin_hi, anchor_rng.randf())
				var sib_scale: float = lerpf(asp.scale_min, asp.scale_max,
					bin_t) * asp.size_multiplier
				if asp.scale_terrain_boost > 0.0:
					sib_scale *= 1.0 + asp.scale_terrain_boost * sib_feats.slope
				if asp.scale_basal_boost > 0.0:
					sib_scale *= 1.0 + asp.scale_basal_boost * sib_feats.basal
				var sib_result: Dictionary = _build_placement_xform(
					asp, aspath, sib_wx, sib_wz, sib_scale, anchor_rng)
				if sib_result.is_empty():
					continue
				var sib_v_key: String = sib_result["v_key"]
				var sib_xform: Transform3D = sib_result["xform"]
				var sib_per_var: Dictionary = per_species_xforms.get(
					aspath, {})
				var sib_arr: Array = sib_per_var.get(sib_v_key, [])
				sib_arr.append(sib_xform)
				sib_per_var[sib_v_key] = sib_arr
				per_species_xforms[aspath] = sib_per_var
				# Siblings publish exclusion + register as anchors too —
				# they're full-fledged feature elements, satellites should
				# cluster around them as well.
				if asp.tree_exclusion_radius > 0.0:
					tile_exclusions.append(sib_wx)
					tile_exclusions.append(sib_wz)
					tile_exclusions.append(asp.tree_exclusion_radius * sib_scale)
				anchor_positions.append(sib_wx)
				anchor_positions.append(sib_wz)
				anchor_radii.append(asp.satellite_anchor_radius)

	# ==== MAIN PASS ====
	for _i in candidates:
		var jx := rng.randf()
		var jz := rng.randf()
		var wx := origin_x + jx * tile_size_m
		var wz := origin_z + jz * tile_size_m
		var biome := _biome_at_world(wx, wz)
		if biome < 0 or not _biome_species_paths.has(biome):
			continue
		# Rocks never spawn on roads — same hard guard as TreeScatter.
		if biome == 4:
			continue
		# Terrain Y at this candidate. Hoisted above the exclusion
		# check because the zone test needs full XYZ; reused below
		# for placement.
		var y := _height_at_world(wx, wz)
		# Procedural exclusion zone density multiplier — folded into
		# accept_p so towns / handmade POIs thin rocks proportionally.
		var excl_mul: float = _ExclusionZoneRef.density_multiplier(
			get_tree(), wx, y, wz, "rocks")
		if excl_mul <= 0.0:
			continue
		# Pick species FIRST so the cluster-bonus contribution can fold
		# into the bernoulli accept rule. Species pick is a cheap
		# cumulative-weight RNG step.
		var species_path := _pick_species(biome, rng.randf())
		if species_path.is_empty():
			continue
		var sp: RockSpecies = _get_cached_species(species_path)
		if sp == null:
			continue
		# **Terrain-aware acceptance**. Rocks aren't placed by synthetic
		# noise — they're placed by the GEOLOGY. Big rocks only show up
		# where the surrounding terrain has steep features (cliff bases
		# = talus piles, mountain shoulders = boulder fields). Small
		# rocks scatter everywhere because surface stones are universal.
		#
		# `terrain_score` is the species-independent rockiness signal
		# (0 = flat valley floor, 1 = ridge / cliff zone). Each species
		# gates on `terrain_min_score` and gets density-boosted by
		# `terrain_density_boost`. The synthetic cluster-noise system
		# this replaced was spatially independent of the heightmap and
		# produced unnatural "boulders in random patches throughout
		# flat forest" — see CLAUDE.md "Procedural placement caches"
		# section for the parallel issue with cluster_noise.
		var feats: Dictionary = _terrain_features(wx, wz)
		var terrain_score: float = feats.slope
		if terrain_score < sp.terrain_min_score:
			continue
		# Anchor pre-pass already placed anchor-tier species; skip them
		# in the main loop to avoid duplicates.
		if sp.is_anchor:
			continue
		var biome_target: float = _biome_density.get(biome, 0.0)
		# Compose the 4 density signals multiplicatively. Each starts
		# at 1.0 (no contribution); per-species fields scale them up.
		# This is the AAA-style "feature mask layer" approach:
		# composable, additive within a category, multiplicative
		# across categories. End factor ranges ~1× (uniform) to ~50×
		# (talus base + concave + near anchor + steep).
		var terrain_factor: float = 1.0 \
			+ sp.terrain_density_boost * terrain_score \
			+ sp.terrain_curvature_boost * feats.curvature \
			+ sp.terrain_basal_boost * feats.basal
		# Anchor proximity: if this species is a satellite, query the
		# tile's pre-pass anchor positions and apply a falloff boost.
		# Linear from full-strength at anchor center to zero at
		# the anchor's `satellite_anchor_radius`. Picks the closest
		# anchor (not a sum across all anchors — multiple anchors
		# already implies high local density on their own).
		if sp.satellite_anchor_boost > 0.0 and not anchor_positions.is_empty():
			var best_prox: float = 0.0
			var i: int = 0
			while i < anchor_positions.size():
				var ax: float = anchor_positions[i]
				var az: float = anchor_positions[i + 1]
				var ar: float = anchor_radii[i / 2]
				var dx: float = wx - ax
				var dz: float = wz - az
				var d_sq: float = dx * dx + dz * dz
				var ar_sq: float = ar * ar
				if d_sq < ar_sq:
					var d: float = sqrt(d_sq)
					var prox: float = 1.0 - d / ar
					if prox > best_prox:
						best_prox = prox
				i += 2
			if best_prox > 0.0:
				terrain_factor *= 1.0 + sp.satellite_anchor_boost * best_prox
		var accept_p: float = (biome_target / max_density) * excl_mul \
			* terrain_factor
		# `randf() > accept_p` rejects; `accept_p > 1` means always
		# accept (rng.randf() returns < 1).
		if accept_p < 1.0 and rng.randf() > accept_p:
			continue
		# Per-species slope band — cliff-face species have
		# `slope_min > 0` so they only spawn on steep terrain; ground
		# species have `slope_max < 4` so they don't appear on cliffs.
		# Sample once and reuse for the global slope cutoff below.
		var slope: float = _slope_at_world(wx, wz)
		if slope < sp.slope_min or slope > sp.slope_max:
			continue
		if slope_cutoff > slope_thin_start:
			if slope >= slope_cutoff:
				continue
			if slope > slope_thin_start:
				var slope_t := (slope - slope_thin_start) / (slope_cutoff - slope_thin_start)
				var slope_keep := 1.0 - smoothstep(0.0, 1.0, slope_t)
				if rng.randf() > slope_keep:
					continue
		# `y` was computed earlier (above the exclusion check) for
		# the zone XYZ test; reuse here.
		var s := lerpf(sp.scale_min, sp.scale_max, rng.randf()) * sp.size_multiplier
		# Terrain scale boost — rocks in steep terrain scale up, so
		# talus piles + boulder fields contain visibly bigger rocks
		# than scattered surface stones. Reuses `terrain_score` from
		# the accept calc above.
		if sp.scale_terrain_boost > 0.0:
			s *= 1.0 + sp.scale_terrain_boost * terrain_score
		# Basal scale boost: rocks at the BASE of cliffs are bigger
		# than those at the apex. Real talus deposits sort by gravity
		# — large blocks roll all the way down, small debris fans out
		# at the top. Composes with terrain_scale_boost above (a rock
		# in a basal zone with steep neighborhood gets BOTH boosts).
		if sp.scale_basal_boost > 0.0:
			s *= 1.0 + sp.scale_basal_boost * feats.basal
		# Variant + AABB lookup — needed before we can compute the
		# rotated-Y snap below. `_ensure_species_resources` is
		# idempotent (fast cache hit on repeated calls).
		if not _ensure_species_resources(species_path):
			continue
		var keys: PackedStringArray = _species_variant_keys.get(
			species_path, PackedStringArray())
		if keys.is_empty():
			continue
		var v_idx: int = _variant_pick_idx(wx, wz, keys.size())
		var v_key: String = keys[v_idx]
		var aabb_lookup: Dictionary = _species_variant_aabb.get(
			species_path, {})
		var v_aabb: AABB = aabb_lookup.get(v_key, AABB())
		# Build the rock's basis. Two-step composition:
		#   1. Outer alignment: lerp world-up toward the terrain
		#      normal at the placement point. Real rocks settle along
		#      the slope they sit on; pure world-up made every rock
		#      look like it had been placed by hand on a flat tile,
		#      sticking up vertically through the slope. With
		#      `terrain_alignment_factor = 0.7` the rock leans 70 %
		#      of the way toward the slope normal.
		#   2. Random yaw + small random tilt — applied AROUND the
		#      aligned-up axis so cylindrical rocks rotate in the
		#      slope plane (not the world plane). Random tilt
		#      becomes a small slope-relative perturbation rather
		#      than a world-space wobble that would look jarring on
		#      a 45° face.
		var aligned_up: Vector3 = Vector3.UP
		if sp.terrain_alignment_factor > 0.0:
			var t_normal: Vector3 = _terrain_normal_at(wx, wz)
			aligned_up = Vector3.UP.lerp(t_normal, sp.terrain_alignment_factor).normalized()
		# Non-uniform per-axis scale: X/Z jitter independently of Y so
		# neighboring rocks of the same mesh look like distinct shapes.
		var sx_axis: float = s
		var sy_axis: float = s
		var sz_axis: float = s
		if sp.scale_axis_jitter > 0.0:
			var aj: float = sp.scale_axis_jitter
			sx_axis *= 1.0 + (rng.randf() * 2.0 - 1.0) * aj
			sz_axis *= 1.0 + (rng.randf() * 2.0 - 1.0) * aj
		var basis: Basis = _basis_with_up(aligned_up).scaled(
			Vector3(sx_axis, sy_axis, sz_axis))
		if sp.random_yaw:
			# Yaw around the aligned-up axis (slope-relative rotation,
			# not world-relative).
			basis = basis.rotated(aligned_up, rng.randf() * TAU)
		if sp.random_tilt_deg > 0.0:
			var tilt_rad: float = deg_to_rad(sp.random_tilt_deg)
			var tx: float = (rng.randf() * 2.0 - 1.0) * tilt_rad
			var tz: float = (rng.randf() * 2.0 - 1.0) * tilt_rad
			# Tilt around two axes orthogonal to aligned-up so the
			# wobble is in the slope plane.
			var tilt_axis_x: Vector3 = aligned_up.cross(Vector3.RIGHT).normalized()
			if tilt_axis_x.length_squared() < 0.01:
				tilt_axis_x = aligned_up.cross(Vector3.FORWARD).normalized()
			var tilt_axis_z: Vector3 = aligned_up.cross(tilt_axis_x).normalized()
			basis = basis.rotated(tilt_axis_x, tx)
			basis = basis.rotated(tilt_axis_z, tz)
		# Extreme-tilt event — small per-instance probability of a big
		# extra tilt on top of the normal random_tilt. Random horizontal
		# axis in the slope plane so direction varies between events.
		if sp.extreme_tilt_chance > 0.0 and sp.extreme_tilt_deg > 0.0 \
				and rng.randf() < sp.extreme_tilt_chance:
			var ext_t: float = (rng.randf() * 2.0 - 1.0) * deg_to_rad(sp.extreme_tilt_deg)
			var ext_yaw: float = rng.randf() * TAU
			var ext_axis: Vector3 = Vector3.RIGHT.rotated(aligned_up, ext_yaw).normalized()
			basis = basis.rotated(ext_axis, ext_t)
		# Snap Y so the rotated rock's lowest world-point lands on
		# terrain, with three sinks stacking on top:
		#   - `terrain_sink_baseline`: always-on (every rock settles in)
		#   - `terrain_sink_factor` × slope_factor: slope-driven burial
		#   - `terrain_sink_random_max` × randf(): per-instance variety
		# Combined sink hard-clamped at half the rock's vertical extent.
		#
		# Snap reference is the MIN terrain Y across the rock's
		# horizontal footprint, not just the center. On a slope this
		# guarantees the downhill perimeter is touching/buried; without
		# it big boulders perch on one center-point and float on the
		# downhill side. Footprint + vertical extent use the post-jitter
		# per-axis scales so the math holds under non-uniform scale.
		var lowest_y: float = _lowest_world_y_offset(basis, v_aabb)
		var vertical_extent: float = v_aabb.size.y * sy_axis
		var horizontal_radius: float = maxf(
			v_aabb.size.x * sx_axis, v_aabb.size.z * sz_axis) * 0.5
		# Footprint-perimeter road check — reject if the rock's BODY
		# extends onto a road, even if its center is off-road.
		if _max_road_density_in_footprint(wx, wz, horizontal_radius) > road_max_density_byte:
			continue
		var snap_y: float = _min_terrain_y_in_footprint(wx, wz, horizontal_radius)
		var slope_factor: float = smoothstep(0.5, 1.6, slope)
		var sink: float = (sp.terrain_sink_baseline
			+ sp.terrain_sink_factor * slope_factor) * sy_axis
		if sp.terrain_sink_random_max > 0.0:
			sink += rng.randf() * sp.terrain_sink_random_max * v_aabb.size.y * sy_axis
		sink = clampf(sink, 0.0, vertical_extent * 0.5)
		y = snap_y - lowest_y - sink
		var xform := Transform3D(basis, Vector3(wx, y, wz))
		# Variant + species_resources already resolved above for the
		# AABB lookup; reuse here. (`v_key` / `keys` declared earlier.)
		var per_var: Dictionary = per_species_xforms.get(species_path, {})
		var arr: Array = per_var.get(v_key, [])
		arr.append(xform)
		per_var[v_key] = arr
		per_species_xforms[species_path] = per_var
		# Publish exclusion zone for trees + ground cover. Only species
		# with `tree_exclusion_radius > 0` opt in — small rocks don't
		# bother. Uses the placement's actual scale so a randomly-large
		# instance pushes plants away proportionally.
		if sp.tree_exclusion_radius > 0.0:
			tile_exclusions.append(wx)
			tile_exclusions.append(wz)
			tile_exclusions.append(sp.tree_exclusion_radius * s)
	if per_species_xforms.is_empty():
		if not cache_only:
			_baked_tiles[tile] = null
		return
	if cache_only:
		# Whole-map bake: still populate the tree-exclusion table so
		# trees baked in the same pass respect rocks, but skip the
		# scene-tree spawn. Avoids RID exhaustion (see _bake_tile
		# docstring).
		if tile_exclusions.size() > 0:
			_tile_tree_exclusions[tile] = tile_exclusions
		if cache_enabled:
			_write_tile_cache(tile, per_species_xforms, tile_exclusions)
		return
	_baked_tile_placements[tile] = per_species_xforms
	if tile_exclusions.size() > 0:
		_tile_tree_exclusions[tile] = tile_exclusions
	var container := _spawn_tile(tile, per_species_xforms)
	_baked_tiles[tile] = container
	if cache_enabled:
		_write_tile_cache(tile, per_species_xforms, tile_exclusions)


# Stable per-position variant index. Hash is independent of the
# `_hash01` cluster noise (different constants) so variant pick and
# clump position aren't correlated → variants spread evenly through
# clumps instead of one variant dominating per clump.
func _variant_pick_idx(wx: float, wz: float, n: int) -> int:
	if n <= 1:
		return 0
	# Quantize to ~10 cm so floating-point jitter doesn't flip the
	# variant on a re-bake.
	var qx: int = int(round(wx * 10.0))
	var qz: int = int(round(wz * 10.0))
	var h: float = sin(float(qx) * 8.317 + float(qz) * 27.913) * 91347.541
	h -= floor(h)
	return int(h * float(n)) % n


# Terrain rockiness score: max height delta within
# `terrain_sample_radius_m`, normalized by saturation slope. Returns
# 0 (flat ground) → 1 (cliff face nearby).
#
# Why 5 axis-aligned samples (not 8 ring + center): max-delta
# captures the same signal at fewer samples, since we care about
# "is there a steep feature in this neighborhood" not "exact slope
# magnitude". Cardinal samples catch ridges along XZ axes; diagonal
# ridges still register because the height_at_world bilinear sample
# averages neighbors anyway.
func _terrain_rocky_score(wx: float, wz: float) -> float:
	return _terrain_features(wx, wz).slope


# AAA-style terrain analysis: returns slope + curvature + basal
# scores in one packed call. Used by the placement loop to drive
# natural distributions (talus piles at cliff bases, satellites
# in concave dips, big rocks at the base of steep features).
#
# Sample layout (5 + 4 = 9 height taps):
#   - center + 4 cardinal at radius `r` (slope, curvature)
#   - 4 cardinal at radius `2r` (basal — wider context)
#
# Cost is 9 bilinear height fetches per call (each ~50ns), about
# 0.5µs per candidate placement. Negligible vs. the rest of the
# bake loop. Already-computed `_height_at_world` so no setup cost.
func _terrain_features(wx: float, wz: float) -> Dictionary:
	var r: float = terrain_sample_radius_m
	if r <= 0.0:
		return {"slope": 0.0, "curvature": 0.0, "basal": 0.0}
	var h0: float = _height_at_world(wx, wz)
	var h_n: float = _height_at_world(wx, wz - r)
	var h_s: float = _height_at_world(wx, wz + r)
	var h_e: float = _height_at_world(wx + r, wz)
	var h_w: float = _height_at_world(wx - r, wz)
	# Slope: max neighborhood delta / r, normalized to saturation.
	var max_d: float = maxf(maxf(absf(h0 - h_n), absf(h0 - h_s)),
		maxf(absf(h0 - h_e), absf(h0 - h_w)))
	var slope_norm: float = clampf(max_d / r / terrain_score_saturation,
		0.0, 1.0)
	# Curvature: mean(neighbors) - center, normalized. Positive =
	# concave (bowl/dip — rock attractor); negative = convex (ridge —
	# rock shedder). We clamp to [0, 1] so only the concave side
	# boosts; convex terrain just gets zero curvature contribution.
	var mean_n: float = (h_n + h_s + h_e + h_w) * 0.25
	var curvature_raw: float = (mean_n - h0) / r
	var curvature_norm: float = clampf(curvature_raw / terrain_score_saturation,
		0.0, 1.0)
	# Basal: "I'm flat-ish but the wider neighborhood is steep" —
	# captures the talus base case. Sample 2r outward, take max
	# delta, subtract local slope. Positive = "below something steep".
	var h_n2: float = _height_at_world(wx, wz - 2.0 * r)
	var h_s2: float = _height_at_world(wx, wz + 2.0 * r)
	var h_e2: float = _height_at_world(wx + 2.0 * r, wz)
	var h_w2: float = _height_at_world(wx - 2.0 * r, wz)
	var max_d_far: float = maxf(maxf(absf(h0 - h_n2), absf(h0 - h_s2)),
		maxf(absf(h0 - h_e2), absf(h0 - h_w2)))
	var far_slope_norm: float = clampf(max_d_far / (2.0 * r) / terrain_score_saturation,
		0.0, 1.0)
	var basal_norm: float = clampf(far_slope_norm - slope_norm, 0.0, 1.0)
	return {"slope": slope_norm, "curvature": curvature_norm, "basal": basal_norm}


# Terrain normal at world position. Used to align rocks with the
# slope they sit on (vs. random tilt around world-up). Computed via
# central differences on 4 height samples — same convention as
# physics-side `_height_at_world` so the visual alignment matches the
# collision surface exactly.
func _terrain_normal_at(wx: float, wz: float) -> Vector3:
	var r: float = 1.0
	var h_l: float = _height_at_world(wx - r, wz)
	var h_r: float = _height_at_world(wx + r, wz)
	var h_d: float = _height_at_world(wx, wz - r)
	var h_u: float = _height_at_world(wx, wz + r)
	# Tangent vectors: dx along X = (h_r - h_l) / (2r), dz along Z =
	# (h_u - h_d) / (2r). Normal = (-dx, 1, -dz) for up-pointing.
	return Vector3(-(h_r - h_l), 2.0 * r, -(h_u - h_d)).normalized()


# Build a placement transform for a rock at (wx, wz) using the given
# species, scale, and RNG. Returns `{}` on failure (variant unresolved,
# slope out of band). Used by both the anchor pre-pass siblings and
# any other code path that needs to place a rock at a specific point
# without re-running biome/density gates.
#
# `scale_in` is the pre-rolled scale (already includes size_multiplier
# and any terrain/basal scale boosts the caller wanted to apply).
func _build_placement_xform(sp: RockSpecies, species_path: String,
		wx: float, wz: float, scale_in: float,
		rng: RandomNumberGenerator) -> Dictionary:
	if not _ensure_species_resources(species_path):
		return {}
	var keys: PackedStringArray = _species_variant_keys.get(
		species_path, PackedStringArray())
	if keys.is_empty():
		return {}
	var v_idx: int = _variant_pick_idx(wx, wz, keys.size())
	var v_key: String = keys[v_idx]
	var aabb_lookup: Dictionary = _species_variant_aabb.get(species_path, {})
	var v_aabb: AABB = aabb_lookup.get(v_key, AABB())
	# Build basis: align to slope, scale, yaw, tilt.
	var aligned_up: Vector3 = Vector3.UP
	if sp.terrain_alignment_factor > 0.0:
		var t_normal: Vector3 = _terrain_normal_at(wx, wz)
		aligned_up = Vector3.UP.lerp(t_normal,
			sp.terrain_alignment_factor).normalized()
	# Non-uniform per-instance scale: X and Z jitter independently of
	# Y. Y stays as the size determinant so vertical_extent / sink
	# math is predictable. Drives "same mesh, different silhouette" —
	# the highest-leverage knob for breaking up boulder-field clones.
	var sx: float = scale_in
	var sy: float = scale_in
	var sz: float = scale_in
	if sp.scale_axis_jitter > 0.0:
		var aj: float = sp.scale_axis_jitter
		sx *= 1.0 + (rng.randf() * 2.0 - 1.0) * aj
		sz *= 1.0 + (rng.randf() * 2.0 - 1.0) * aj
	var basis: Basis = _basis_with_up(aligned_up).scaled(Vector3(sx, sy, sz))
	if sp.random_yaw:
		basis = basis.rotated(aligned_up, rng.randf() * TAU)
	if sp.random_tilt_deg > 0.0:
		var tilt_rad: float = deg_to_rad(sp.random_tilt_deg)
		var tx: float = (rng.randf() * 2.0 - 1.0) * tilt_rad
		var tz: float = (rng.randf() * 2.0 - 1.0) * tilt_rad
		var tilt_axis_x: Vector3 = aligned_up.cross(Vector3.RIGHT).normalized()
		if tilt_axis_x.length_squared() < 0.01:
			tilt_axis_x = aligned_up.cross(Vector3.FORWARD).normalized()
		var tilt_axis_z: Vector3 = aligned_up.cross(tilt_axis_x).normalized()
		basis = basis.rotated(tilt_axis_x, tx)
		basis = basis.rotated(tilt_axis_z, tz)
	# Extreme-tilt event: small per-instance probability of a big extra
	# tilt (e.g. 30–60°) on top of the normal random_tilt. Captures the
	# "freshly tumbled" / "weirdly perched" rocks that punctuate real
	# boulder fields. Axis is random in the slope plane so the tilt
	# direction varies between events.
	if sp.extreme_tilt_chance > 0.0 and sp.extreme_tilt_deg > 0.0 \
			and rng.randf() < sp.extreme_tilt_chance:
		var ext_t: float = (rng.randf() * 2.0 - 1.0) * deg_to_rad(sp.extreme_tilt_deg)
		var ext_yaw: float = rng.randf() * TAU
		var ext_axis: Vector3 = Vector3.RIGHT.rotated(aligned_up, ext_yaw).normalized()
		basis = basis.rotated(ext_axis, ext_t)
	# Y snap with footprint min + stacked sinks. `vertical_extent` and
	# `horizontal_radius` use the post-jitter per-axis scales so sink
	# clamping and footprint sampling stay correct under non-uniform
	# scale.
	var lowest_y: float = _lowest_world_y_offset(basis, v_aabb)
	var vertical_extent: float = v_aabb.size.y * sy
	var horizontal_radius: float = maxf(
		v_aabb.size.x * sx, v_aabb.size.z * sz) * 0.5
	# Reject if the rock's body extends onto a road. Empty return signals
	# rejection to the caller (cluster sibling loop).
	if _max_road_density_in_footprint(wx, wz, horizontal_radius) > road_max_density_byte:
		return {}
	var snap_y: float = _min_terrain_y_in_footprint(wx, wz, horizontal_radius)
	var slope: float = _slope_at_world(wx, wz)
	var slope_factor: float = smoothstep(0.5, 1.6, slope)
	var sink: float = (sp.terrain_sink_baseline
		+ sp.terrain_sink_factor * slope_factor) * sy
	if sp.terrain_sink_random_max > 0.0:
		sink += rng.randf() * sp.terrain_sink_random_max * v_aabb.size.y * sy
	sink = clampf(sink, 0.0, vertical_extent * 0.5)
	var y: float = snap_y - lowest_y - sink
	return {
		"v_key": v_key,
		"xform": Transform3D(basis, Vector3(wx, y, wz)),
		"scale": scale_in,
	}


# Maximum road-density byte across the rock's horizontal footprint.
# Used to reject placements where a rock's BODY extends onto a road,
# even when the center is safely off-road. The center-only road check
# in `_biome_at_world` only catches "rock dropped on the asphalt" —
# big boulders placed 2 m off the road edge still drape their bodies
# across it without this perimeter check.
#
# Same 9-sample pattern as `_min_terrain_y_in_footprint`: center + 8
# perimeter. Cheap (~9 byte reads).
func _max_road_density_in_footprint(wx: float, wz: float, radius_xz: float) -> int:
	var max_d: int = _road_density_at(wx, wz)
	if radius_xz < 0.5:
		return max_d
	const SQRT2_INV: float = 0.70710678
	var offsets: Array = [
		Vector2(radius_xz, 0.0),
		Vector2(-radius_xz, 0.0),
		Vector2(0.0, radius_xz),
		Vector2(0.0, -radius_xz),
		Vector2(radius_xz * SQRT2_INV, radius_xz * SQRT2_INV),
		Vector2(-radius_xz * SQRT2_INV, radius_xz * SQRT2_INV),
		Vector2(radius_xz * SQRT2_INV, -radius_xz * SQRT2_INV),
		Vector2(-radius_xz * SQRT2_INV, -radius_xz * SQRT2_INV),
	]
	for o in offsets:
		var d: int = _road_density_at(wx + o.x, wz + o.y)
		if d > max_d:
			max_d = d
	return max_d


# Minimum terrain height across the rock's horizontal footprint —
# used to snap the rock so it touches/buries on the DOWNHILL side
# instead of perching with one corner just touching at the center.
# On a slope, terrain at (wx, wz) is the average across the rock's
# footprint, but the downhill perimeter is lower; snapping to that
# minimum makes the rock embed into the uphill side and just-touch
# (or lightly clip) the downhill side.
#
# Samples 9 points: center + 8 perimeter (cardinal + diagonal at
# `radius_xz`). Cheap (~9 heightmap reads). For tiny rocks
# (radius_xz < 0.5 m) skips the multi-sample and just returns the
# center value — slope doesn't matter at that scale.
func _min_terrain_y_in_footprint(wx: float, wz: float, radius_xz: float) -> float:
	var center: float = _height_at_world(wx, wz)
	if radius_xz < 0.5:
		return center
	var min_y: float = center
	# Cardinal perimeter
	const SQRT2_INV: float = 0.70710678
	var offsets: Array = [
		Vector2(radius_xz, 0.0),
		Vector2(-radius_xz, 0.0),
		Vector2(0.0, radius_xz),
		Vector2(0.0, -radius_xz),
		Vector2(radius_xz * SQRT2_INV, radius_xz * SQRT2_INV),
		Vector2(-radius_xz * SQRT2_INV, radius_xz * SQRT2_INV),
		Vector2(radius_xz * SQRT2_INV, -radius_xz * SQRT2_INV),
		Vector2(-radius_xz * SQRT2_INV, -radius_xz * SQRT2_INV),
	]
	for o in offsets:
		var h: float = _height_at_world(wx + o.x, wz + o.y)
		if h < min_y:
			min_y = h
	return min_y


# Lowest world-Y offset of an ellipsoid bound to the AABB after basis.
#
# Approximates the rock mesh as an ellipsoid with semi-axes equal to
# the AABB half-extents. This is exact for icosphere-derived rocks
# (sphere = ellipsoid with equal axes) and a tight fit for the
# noise-displaced variants we ship. Critically, it correctly handles
# **asymmetric rocks under rotation**: e.g. `rock_slab` has y-half=1.35
# but z-half=0.31, so when a tilt pushes its slab face vertical, the
# world-Y extent collapses from 1.35 to 0.31 — and the rock should
# snap to terrain accordingly, not float by a meter.
#
# Why not transform-the-8-AABB-corners-and-min? The AABB is a BOX, but
# the mesh fills only the inscribed ellipsoid. Picking the worst BOX
# corner under rotation over-lifts spherical rocks by `(√3 − 1) × r ×
# scale` — on a scale-4 boulder that's ~2 m of float. (Reproduced
# 2026-05-04, see CLAUDE.md.)
#
# Why not un-rotated `aabb.position.y × scale`? Asymmetric rocks under
# rotation have actual world-Y extent < un-rotated extent, so we'd
# place origin too high and the rock floats. (Reproduced 2026-05-04
# on rock_slab — the slab face goes vertical and the world-Y span
# collapses from 1.35 m to 0.31 m unit, but un-rotated math snaps to
# the 1.35 m number, leaving the rock 1.04 m of unit-scale off the
# ground.)
#
# The ellipsoid projection: for a unit ellipsoid with semi-axes
# (hx, hy, hz) centered at the origin, the maximum projection onto a
# unit vector u is `sqrt((u.x·hx)² + (u.y·hy)² + (u.z·hz)²)`. The world-Y
# axis projected back into mesh-local space is the basis's middle ROW
# divided by scale (since rows have length `scale`). The world-Y of
# the mesh center is `(basis · aabb.center).y` (basis already includes
# scale).
func _lowest_world_y_offset(basis: Basis, aabb: AABB) -> float:
	# Use the Y-axis row length specifically — this lets the math hold
	# under NON-UNIFORM scale (`scale_axis_jitter`). For uniform scale
	# basis.x.length() == basis.y.length() so we'd get the same answer,
	# but for axis-jittered placements basis.x carries the X scale and
	# we'd be projecting against the wrong magnitude.
	var sy: float = basis.y.length()
	if sy <= 0.0:
		return 0.0
	# basis.y is the world-Y row scaled by sy. Divide to get the unit
	# projection direction in mesh-local space.
	var u: Vector3 = basis.y / sy
	var hx: float = aabb.size.x * 0.5
	var hy: float = aabb.size.y * 0.5
	var hz: float = aabb.size.z * 0.5
	var extent: float = sqrt(u.x * u.x * hx * hx
		+ u.y * u.y * hy * hy
		+ u.z * u.z * hz * hz)
	var center_world_y: float = (basis * aabb.get_center()).y
	return center_world_y - extent * sy


# Build a Basis whose Y axis points along the given world-space `up`
# vector, with X/Z arbitrary (filled by random yaw later). For
# vertical `up` returns identity; for tilted `up` rotates around the
# axis perpendicular to (world-up, up) by their angular difference.
func _basis_with_up(up: Vector3) -> Basis:
	var dot: float = Vector3.UP.dot(up)
	if dot > 0.99999:
		return Basis.IDENTITY
	if dot < -0.99999:
		# Upside-down — degenerate; return 180° rotation around X
		return Basis(Vector3.RIGHT, PI)
	var axis: Vector3 = Vector3.UP.cross(up).normalized()
	var angle: float = acos(clampf(dot, -1.0, 1.0))
	return Basis(axis, angle)


# Static query: does any RockScatter in the scene have a baked rock
# whose tree-exclusion zone covers world-XZ point (wx, wz)? Walks all
# nodes in the `rocks_tree_exclusion` group; checks the rock tile
# containing the point AND its 3 neighbors (a rock near a tile edge
# can extend its exclusion into adjacent tiles).
#
# Called by tree_scatter + ground_cover at candidate placement.
# Cost: 4 dict lookups + ~5–10 distance comps per hit tile = ~40 ops
# per call, ~340 µs/frame at peak bake rate. Negligible.
static func is_point_excluded(scene_tree: SceneTree, wx: float,
		wz: float) -> bool:
	if scene_tree == null:
		return false
	var nodes: Array = scene_tree.get_nodes_in_group("rocks_tree_exclusion")
	for n in nodes:
		var rs := n as RockScatter
		if rs == null:
			continue
		if rs._point_excluded(wx, wz):
			return true
	return false


# Per-instance check called by `is_point_excluded`. Splits out so the
# static side stays simple.
func _point_excluded(wx: float, wz: float) -> bool:
	if _tile_tree_exclusions.is_empty() or tile_size_m <= 0.0:
		return false
	var tx: int = int(floor(wx / tile_size_m))
	var tz: int = int(floor(wz / tile_size_m))
	# Check the containing tile + 3 neighbors. The neighbor selection
	# is biased toward whichever side of the tile center the point
	# falls on, so we always cover the full possible exclusion radius
	# (capped at ~1 tile width — sane for our biggest rock < 5 m).
	var fx: float = wx - float(tx) * tile_size_m
	var fz: float = wz - float(tz) * tile_size_m
	var dx: int = -1 if fx < tile_size_m * 0.5 else 1
	var dz: int = -1 if fz < tile_size_m * 0.5 else 1
	for ox in [0, dx]:
		for oz in [0, dz]:
			var key := Vector2i(tx + ox, tz + oz)
			if not _tile_tree_exclusions.has(key):
				continue
			var arr: PackedFloat32Array = _tile_tree_exclusions[key]
			if arr.size() == 0:
				continue
			var i: int = 0
			while i + 2 < arr.size():
				var rx: float = arr[i]
				var rz: float = arr[i + 1]
				var rr: float = arr[i + 2]
				var ddx: float = wx - rx
				var ddz: float = wz - rz
				if ddx * ddx + ddz * ddz <= rr * rr:
					return true
				i += 3
	return false


func _spawn_tile(tile: Vector2i, per_species_xforms: Dictionary) -> Node3D:
	var container := Node3D.new()
	container.name = "RockTile_%d_%d" % [tile.x, tile.y]
	var tile_center := Vector3(
		(float(tile.x) + 0.5) * tile_size_m,
		0.0,
		(float(tile.y) + 0.5) * tile_size_m)
	container.position = tile_center
	add_child(container)
	var spawn_collision_now := (enable_collision
		and _tile_in_collision_range(tile_center))
	var spawned_any := false
	for path in per_species_xforms.keys():
		if not _ensure_species_resources(path):
			continue
		var sp: RockSpecies = _get_cached_species(path)
		# `per_species_xforms[path]` is now a Dictionary[variant_key →
		# Array[Transform3D]]. Spawn one MMI per (variant, LOD).
		var per_var: Dictionary = per_species_xforms[path]
		var variant_meshes: Dictionary = _species_variant_meshes[path]
		var variant_lod_levels: Dictionary = _species_variant_lod_levels[path]
		var variant_imposter_meshes: Dictionary = (
			_species_variant_imposter_meshes.get(path, {}))
		# Flat list across all variants — used for collisions (which
		# don't care about variant) and the spawned_any gate.
		var all_xforms: Array = []
		for v_key in per_var.keys():
			var xforms: Array = per_var[v_key]
			if xforms.is_empty():
				continue
			var meshes: Array = variant_meshes.get(v_key, [])
			var lod_levels: PackedInt32Array = variant_lod_levels.get(
				v_key, PackedInt32Array())
			if meshes.is_empty():
				continue
			_spawn_species_multimeshes(
				container, xforms, meshes, lod_levels, sp, tile_center)
			# Impostor (proxy) MMI for the same per-instance transforms
			# — same world positions, just rendered as the cheap
			# unshaded LOD2 mesh past `proxy_swap_distance_m`.
			if sp.proxy_swap_distance_m > 0.0:
				var imp_mesh: Mesh = variant_imposter_meshes.get(v_key)
				if imp_mesh != null:
					_spawn_species_proxy(
						_get_or_make_proxies_node(container),
						xforms, imp_mesh, sp, tile_center)
			all_xforms.append_array(xforms)
		if spawn_collision_now and sp.collision_tier != TIER_NONE:
			_spawn_species_collisions(
				_get_or_make_colliders_node(container),
				all_xforms, sp, tile_center)
		if not all_xforms.is_empty():
			spawned_any = true
	if not spawned_any:
		container.queue_free()
		return null
	_baked_tile_collision[tile] = spawn_collision_now
	# Spawn-time shadow state is ALWAYS off; `_refresh_shadows` flips
	# it on next frame if the tile is in range, paying the per-tile
	# shadow-caster registration cost rate-limited via
	# `_SHADOW_FLIPS_PER_FRAME` instead of stacking N tiles' worth of
	# caster adds in the same frame as a multi-tile rebuild.
	_baked_tile_shadow[tile] = false
	return container


func _spawn_species_multimeshes(parent: Node3D, xforms: Array,
		meshes: Array, lod_levels: PackedInt32Array, sp: RockSpecies,
		tile_center: Vector3) -> void:
	# One MMI per LOD level. The dup'd mesh has the rock shader baked
	# onto every surface with this LOD's distance bands, so the per-
	# instance hash dither in the shader handles the LOD selection
	# (each rock picks ONE LOD via stable world-XZ hash, identical to
	# the tree pattern).
	var min_lod := 999
	var max_lod := -1
	for lvl in lod_levels:
		if lvl < min_lod:
			min_lod = lvl
		if lvl > max_lod:
			max_lod = lvl
	for i in meshes.size():
		var mesh: Mesh = meshes[i] as Mesh
		if mesh == null:
			continue
		var lod_level: int = lod_levels[i] if i < lod_levels.size() else 0
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.use_custom_data = false
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for j in xforms.size():
			var local: Transform3D = xforms[j]
			local.origin -= tile_center
			mm.set_instance_transform(j, local)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		# Tile-MMI visibility = COARSE pre-cull. The shader handles
		# per-instance LOD selection + smooth crossfade. The tile-
		# MMI vis just hides whole tiles whose center is too far
		# outside this LOD's band for any instance to be in-band.
		var bounds: Dictionary = _lod_boundaries(lod_level, sp, min_lod, max_lod)
		var tile_half_diag: float = tile_size_m * 0.7071
		var lower_bound: float = bounds["lower"]
		var upper_bound: float = bounds["upper"]
		if lower_bound >= 0.0:
			mmi.visibility_range_begin = maxf(
				lower_bound - tile_half_diag - lod_band_fade_m, 0.0)
		else:
			mmi.visibility_range_begin = 0.0
		if upper_bound >= 0.0:
			mmi.visibility_range_end = (
				upper_bound + tile_half_diag + lod_band_fade_m)
		else:
			mmi.visibility_range_end = 0.0
		mmi.visibility_range_fade_mode = (
			GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED)
		# Tag with LOD level so `_refresh_shadows` can filter to only
		# shadow-eligible LODs (≤ `max_shadow_lod`) instead of toggling
		# cast_shadow on every LOD MMI in the tile.
		mmi.set_meta("lod_level", lod_level)
		# Spawn-time cast_shadow is ALWAYS OFF (even for shadow-
		# eligible LODs in shadow range). `_refresh_shadows` runs
		# every frame with a per-frame flip cap — letting it flip
		# new tiles ON one-at-a-time costs a few extra frames of
		# delayed shadow vs. spawning many tiles cast_shadow=ON in
		# one frame, which slams the directional shadow map's caster
		# bookkeeping with N tiles' worth of new entities at once.
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)


# Tier dispatch — picks the collision shape per `RockSpecies.collision_tier`.
# Tier 1 (STEPPABLE) lands on CONCEALMENT layer per Option A in the
# project memory `project_rock_collision_tier_b.md`; promote to a
# dedicated STEPPABLE_SOLID layer when combat work needs hard cover
# from small rocks.
func _spawn_species_collisions(parent: Node3D, xforms: Array,
		sp: RockSpecies, tile_center: Vector3) -> void:
	if sp.collision_tier == TIER_NONE:
		return
	# Layer + mask per tier.
	var layer: int
	if sp.collision_tier == TIER_STEPPABLE:
		layer = Layers.CONCEALMENT
	else:
		# CROUCH_COVER + STAND_COVER both use SOLID — the difference
		# between them is shape SIZE, not layer semantics.
		layer = Layers.SOLID
	# Shape sizing — pulls per-instance scale from `xf.basis.get_scale()`
	# (the same Vector3 the visual MultiMesh sees, including
	# `size_multiplier × scale_jitter × scale_axis_jitter`). Auto path
	# derives radius/height from horizontal-average and Y scale directly;
	# override path treats `collision_*_override` as the unit-scale value
	# at jitter=1 and applies the per-instance jitter on top so explicit
	# overrides also follow scale. Tier multipliers stay on the auto
	# defaults only — existing override-driven species are tuned without
	# tier scaling and should keep that behaviour.
	var tier_r_mul: float = 1.0
	var tier_h_mul: float = 1.0
	if sp.collision_tier == TIER_STAND_COVER:
		tier_h_mul = 1.4   # taller silhouette for cover-eligible standing
		tier_r_mul = 1.1
	# Use a sphere for steppable tier (cheap + the player walks AROUND
	# it not over it; the broadphase is happy with sphere). Use a
	# capsule for higher tiers — taller silhouette, better for
	# leaning against / shooting over.
	for xf in xforms:
		var s: Vector3 = xf.basis.get_scale()
		var s_h: float = (s.x + s.z) * 0.5
		var auto_radius: float = s_h * 0.5 * tier_r_mul
		var auto_height: float = s.y * 0.8 * tier_h_mul
		# Override jitter factor = per-instance scale / species default.
		# Recovers the random per-instance jitter so a user-tuned override
		# at jitter=1 size_mult=N keeps its old value, but a 2x-jittered
		# rock gets 2x the override.
		var size_mult: float = (sp.size_multiplier
			if sp.size_multiplier > 0.0 else 1.0)
		var jitter_h: float = s_h / size_mult
		var jitter_v: float = s.y / size_mult
		var radius: float = (sp.collision_radius_override * jitter_h
			if sp.collision_radius_override > 0.0 else auto_radius)
		var height: float = (sp.collision_height_override * jitter_v
			if sp.collision_height_override > 0.0 else auto_height)
		var body := StaticBody3D.new()
		body.collision_layer = layer
		body.collision_mask = 0  # static; doesn't actively check anything
		# Anchor at rock origin + half-height up so the shape straddles
		# the rock base evenly. height is already per-instance-scaled.
		var world_pos: Vector3 = xf.origin + Vector3(0.0, height * 0.5, 0.0)
		body.transform = Transform3D(Basis.IDENTITY, world_pos - tile_center)
		var cs := CollisionShape3D.new()
		if sp.collision_tier == TIER_STEPPABLE:
			var sphere := SphereShape3D.new()
			sphere.radius = maxf(radius, 0.1)
			cs.shape = sphere
		else:
			var capsule := CapsuleShape3D.new()
			capsule.radius = maxf(radius, 0.1)
			capsule.height = maxf(height, capsule.radius * 2.0 + 0.05)
			cs.shape = capsule
		body.add_child(cs)
		parent.add_child(body)


# --- Collision tile refresh (tile enters/leaves collision_radius_m) ---

func _refresh_collisions() -> void:
	if not enable_collision:
		return
	for tile in _baked_tiles.keys():
		var container: Node3D = _baked_tiles[tile]
		if not is_instance_valid(container):
			continue
		var tile_center := container.position
		var should_have := _tile_in_collision_range(tile_center)
		var has_now: bool = _baked_tile_collision.get(tile, false)
		if should_have == has_now:
			continue
		if should_have:
			var per_species: Dictionary = _baked_tile_placements.get(tile, {})
			if per_species.is_empty():
				continue
			var colliders_node := _get_or_make_colliders_node(container)
			for path in per_species.keys():
				var sp: RockSpecies = _get_cached_species(path)
				if sp == null or sp.collision_tier == TIER_NONE:
					continue
				# `per_species[path]` is now Dictionary[variant_key →
				# Array[Transform3D]]. Flatten across variants for
				# collision spawn (collisions don't care about variant).
				var per_var: Dictionary = per_species[path]
				var flat: Array = []
				for v_key in per_var.keys():
					flat.append_array(per_var[v_key])
				if flat.is_empty():
					continue
				_spawn_species_collisions(
					colliders_node, flat, sp, tile_center)
			_baked_tile_collision[tile] = true
		else:
			var colliders: Node = container.get_node_or_null("Colliders")
			if colliders != null:
				colliders.queue_free()
			_baked_tile_collision[tile] = false


func _tile_in_collision_range(tile_center: Vector3) -> bool:
	if collision_radius_m <= 0.0:
		return false
	var cam_xz := _last_player_xz
	if cam_xz.x == INF:
		return false
	var dx := tile_center.x - cam_xz.x
	var dz := tile_center.z - cam_xz.y
	return (dx * dx + dz * dz) <= collision_radius_m * collision_radius_m


# Walk every baked tile and toggle `cast_shadow` on its shadow-
# eligible MMIs based on whether the tile center is within
# `shadow_radius_m`. Mirrors `tree_scatter._refresh_shadows`:
# distance-sorted closest-first, per-frame flip cap, hysteresis on
# the off-threshold, movement gate to skip work when stationary.
#
# Only MMIs at LOD ≤ `max_shadow_lod` are toggled — proxy MMIs live
# under "Proxies" so `container.get_children()` on the close-tier
# parent skips them automatically (they stay OFF).
static func _shadow_sort_by_distance(a: Dictionary, b: Dictionary) -> bool:
	return a["d_sq"] < b["d_sq"]


func _refresh_shadows(cam_xz: Vector2) -> void:
	if not cast_shadow:
		return
	if _baked_tiles.is_empty():
		return
	# Movement gate — saves the per-tile distance comp + dict lookup
	# when the camera hasn't moved enough to flip any tile.
	if (cam_xz - _last_shadow_refresh_xz).length_squared() \
			< _SHADOW_REFRESH_MIN_MOVE * _SHADOW_REFRESH_MIN_MOVE:
		return
	_last_shadow_refresh_xz = cam_xz
	var on_radius_sq: float = shadow_radius_m * shadow_radius_m
	var off_radius: float = shadow_radius_m * _SHADOW_OFF_HYSTERESIS
	var off_radius_sq: float = off_radius * off_radius
	# Two-pass distance-sorted refresh — same logic as tree_scatter.
	# First pass collects every tile that needs to flip + its squared
	# camera distance; second pass sorts by distance and flips the N
	# closest. Guarantees the tile right in front of the player gets
	# shadows before tiles 100 m to either side.
	_shadow_pending.clear()
	for tile in _baked_tiles.keys():
		var container: Node3D = _baked_tiles[tile]
		if not is_instance_valid(container):
			continue
		var dx: float = container.position.x - cam_xz.x
		var dz: float = container.position.z - cam_xz.y
		var d_sq: float = dx * dx + dz * dz
		var has_now: bool = _baked_tile_shadow.get(tile, false)
		var should_have: bool
		if has_now:
			should_have = d_sq <= off_radius_sq
		else:
			should_have = d_sq <= on_radius_sq
		if should_have == has_now:
			continue
		_shadow_pending.append({"tile": tile, "d_sq": d_sq,
			"should_have": should_have, "container": container})
	if _shadow_pending.is_empty():
		return
	_shadow_pending.sort_custom(_shadow_sort_by_distance)
	var flips: int = 0
	for entry in _shadow_pending:
		if flips >= _SHADOW_FLIPS_PER_FRAME:
			break
		var container: Node3D = entry["container"]
		var should_have: bool = entry["should_have"]
		var new_mode: int = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if should_have
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		# Iterate direct-child MMIs (close-tier only — proxy MMIs
		# under "Proxies" stay OFF). Filter by LOD level meta.
		for child in container.get_children():
			if not (child is MultiMeshInstance3D):
				continue
			var lod_level: int = child.get_meta("lod_level", -1)
			if lod_level < 0 or lod_level > max_shadow_lod:
				continue
			(child as MultiMeshInstance3D).cast_shadow = new_mode
		_baked_tile_shadow[entry["tile"]] = should_have
		flips += 1


func _get_or_make_colliders_node(container: Node3D) -> Node3D:
	var existing: Node3D = container.get_node_or_null("Colliders") as Node3D
	if existing != null:
		return existing
	var node := Node3D.new()
	node.name = "Colliders"
	container.add_child(node)
	return node


# Proxy MMIs live under "Proxies" so `_refresh_shadows` (which
# iterates direct-child MMIs) doesn't accidentally toggle their
# cast_shadow — they're intentionally OFF for the impostor tier.
func _get_or_make_proxies_node(container: Node3D) -> Node3D:
	var existing: Node3D = container.get_node_or_null("Proxies") as Node3D
	if existing != null:
		return existing
	var node := Node3D.new()
	node.name = "Proxies"
	container.add_child(node)
	return node


# Spawn one impostor MMI for one species's variant at this tile.
# Same per-instance transforms as the close-tier MMI, just rendered
# with the unshaded `rock_imposter` shader and cast_shadow = OFF.
func _spawn_species_proxy(parent: Node3D, xforms: Array,
		imp_mesh: Mesh, sp: RockSpecies, tile_center: Vector3) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.mesh = imp_mesh
	mm.instance_count = xforms.size()
	for j in xforms.size():
		var local: Transform3D = xforms[j]
		local.origin -= tile_center
		mm.set_instance_transform(j, local)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# No MMI-level visibility range — the per-instance distance cull
	# in `rock_imposter.gdshader` handles the close↔impostor handoff.
	# Tile-level visibility could hard-pop tiles in/out (the same
	# bug `tree_imposter` saw), so we always submit the MMI and rely
	# on the shader.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)


# --- Species pick (cumulative-weight RNG) ---

func _pick_species(biome: int, r: float) -> String:
	var paths: PackedStringArray = _biome_species_paths[biome]
	var cum: PackedFloat32Array = _biome_species_cumweight[biome]
	if cum.size() == 0:
		return ""
	var total := cum[cum.size() - 1]
	var target := r * total
	for i in cum.size():
		if target <= cum[i]:
			return paths[i]
	return paths[paths.size() - 1]


# --- Biome / slope / height sampling (parallels TreeScatter) ---

func _biome_at_world(wx: float, wz: float) -> int:
	var u := (wx + _extent_x * 0.5) / _spacing_m
	var v := (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 or u >= float(_terrain_w) or v >= float(_terrain_h):
		return -1
	var x := int(u)
	var z := int(v)
	var i := (z * _terrain_w + x) * 4
	if i + 3 >= _splat_a.size():
		return -1
	var fr: int = _splat_a[i]
	var gr: int = _splat_a[i + 1]
	var bl: int = _splat_a[i + 2]
	var al: int = _splat_a[i + 3]
	# Road check — same `road_density.rgba8` max-channel pattern as
	# TreeScatter; any road pixel suppresses rocks. No buffer offset
	# because rocks are small enough that trunk-position is sufficient.
	if _road_density_at(wx, wz) > 25:
		return 4
	var best := 0
	var best_v := fr
	if gr > best_v:
		best = 1
		best_v = gr
	if bl > best_v:
		best = 2
		best_v = bl
	if al > best_v:
		best = 3
		best_v = al
	if best_v < 32:
		return -1
	return best


# Returns "human presence" density: max across road tiers AND the
# BuiltUp channel (splat_b G). Mirror of tree_scatter / ground_cover —
# town footprints often have BuiltUp tagging without road pixels
# through the centre, so big rocks need to vacate those areas too.
func _road_density_at(wx: float, wz: float) -> int:
	if _splat_road.size() == 0 and _splat_b.size() == 0:
		return 0
	var u: float = (wx + _extent_x * 0.5) / _spacing_m
	var v: float = (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 \
			or u >= float(_terrain_w) or v >= float(_terrain_h):
		return 0
	var x: int = int(u)
	var z: int = int(v)
	var i: int = (z * _terrain_w + x) * 4
	var road_d: int = 0
	if i + 3 < _splat_road.size():
		road_d = maxi(maxi(int(_splat_road[i]), int(_splat_road[i + 1])),
			maxi(int(_splat_road[i + 2]), int(_splat_road[i + 3])))
	if i + 1 < _splat_b.size():
		road_d = maxi(road_d, int(_splat_b[i + 1]))
	return road_d


func _slope_at_world(wx: float, wz: float) -> float:
	const _STEP := 2.0
	var h_l := _height_at_world(wx - _STEP, wz)
	var h_r := _height_at_world(wx + _STEP, wz)
	var h_d := _height_at_world(wx, wz - _STEP)
	var h_u := _height_at_world(wx, wz + _STEP)
	var dx := (h_r - h_l) / (2.0 * _STEP)
	var dz := (h_u - h_d) / (2.0 * _STEP)
	return sqrt(dx * dx + dz * dz)


func _height_at_world(wx: float, wz: float) -> float:
	if _hm_bytes.size() > 0 and _terrain_w > 0 and _terrain_h > 0:
		var u := (wx + _extent_x * 0.5) / _spacing_m
		var v := (wz + _extent_z * 0.5) / _spacing_m
		u = clampf(u, 0.0, float(_terrain_w - 1))
		v = clampf(v, 0.0, float(_terrain_h - 1))
		var x0 := int(u)
		var z0 := int(v)
		var x1 := mini(x0 + 1, _terrain_w - 1)
		var z1 := mini(z0 + 1, _terrain_h - 1)
		var fx := u - float(x0)
		var fz := v - float(z0)
		var h00 := _sample_f32_meters(x0, z0)
		var h10 := _sample_f32_meters(x1, z0)
		var h01 := _sample_f32_meters(x0, z1)
		var h11 := _sample_f32_meters(x1, z1)
		var h0 := lerpf(h00, h10, fx)
		var h1 := lerpf(h01, h11, fx)
		return lerpf(h0, h1, fz)
	if _terrain3d != null and is_instance_valid(_terrain3d):
		var h: float = _terrain3d.data.get_height(Vector3(wx, 0.0, wz))
		if not is_nan(h):
			return h
	return 0.0


# Decode one f32 sample (literal meters) from the canonical `.r32`.
# Format-version-2; v1 used u16 + `vert_min/max` linear remap.
func _sample_f32_meters(x: int, z: int) -> float:
	return _hm_bytes.decode_float((z * _terrain_w + x) * 4)


func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


# --- Persistent bake cache (raw FileAccess bytes; mirrors the
# tree_scatter pattern but with rock-specific extensions: per-
# (species, variant_key) buckets and per-tile tree-exclusion arrays
# so cached tiles immediately suppress trees + ground cover on
# reload — without this, trees baking against a cached rock tile
# would miss the exclusion until the rock tile re-baked.

const _CACHE_FORMAT_VERSION: int = 1
var _cache_magic: PackedByteArray = PackedByteArray([0x52, 0x4F, 0x42, 0x4B])  # "ROBK"


func _compute_cache_key() -> String:
	# **Stable cache key**: only `cache_version` + `seed`. See the
	# field docstring on `cache_version` for the full rationale —
	# balance tweaks don't shuffle in-session bakes. Bump
	# `cache_version` (or Clear + Bake) when an intentional re-roll
	# is wanted.
	var ctx := PackedStringArray()
	ctx.append("v%d" % cache_version)
	ctx.append(str(seed))
	return "|".join(ctx).md5_text().substr(0, 16)


func _get_cache_key() -> String:
	if _cached_key.is_empty():
		_cached_key = _compute_cache_key()
	return _cached_key


func _invalidate_cache_key() -> void:
	_cached_key = ""


func _cache_dir_for_map(key: String) -> String:
	return "res://assets/foliage_bake/%s/rocks/%s" % [map_id, key]


func _cache_path_for_tile(tile: Vector2i, key: String) -> String:
	return "%s/%d_%d.bin" % [_cache_dir_for_map(key), tile.x, tile.y]


func _try_load_tile_cache(tile: Vector2i) -> Dictionary:
	var key := _get_cache_key()
	var path := _cache_path_for_tile(tile, key)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var magic := f.get_buffer(4)
	if magic != _cache_magic:
		f.close()
		return {}
	var version := f.get_32()
	if version != _CACHE_FORMAT_VERSION:
		f.close()
		return {}
	var len_bytes := f.get_64()
	var blob := f.get_buffer(len_bytes)
	f.close()
	var data: Variant = bytes_to_var(blob)
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = data
	if d.get("cache_key", "") != key:
		return {}
	return d


func _write_tile_cache(tile: Vector2i,
		per_species_xforms: Dictionary,
		tile_exclusions: PackedFloat32Array) -> void:
	var key := _get_cache_key()
	var entries: Array = []
	for path in per_species_xforms.keys():
		var per_var: Dictionary = per_species_xforms[path]
		var variants: Array = []
		for v_key in per_var.keys():
			var xforms: Array = per_var[v_key]
			# Flatten Transform3D (basis + origin = 12 floats) into a
			# PackedFloat32Array so var_to_bytes can serialize it
			# (var_to_bytes doesn't support Transform3D directly).
			var t_flat := PackedFloat32Array()
			t_flat.resize(xforms.size() * 12)
			for i in xforms.size():
				var xf: Transform3D = xforms[i]
				t_flat[i * 12 + 0] = xf.basis.x.x
				t_flat[i * 12 + 1] = xf.basis.x.y
				t_flat[i * 12 + 2] = xf.basis.x.z
				t_flat[i * 12 + 3] = xf.basis.y.x
				t_flat[i * 12 + 4] = xf.basis.y.y
				t_flat[i * 12 + 5] = xf.basis.y.z
				t_flat[i * 12 + 6] = xf.basis.z.x
				t_flat[i * 12 + 7] = xf.basis.z.y
				t_flat[i * 12 + 8] = xf.basis.z.z
				t_flat[i * 12 + 9] = xf.origin.x
				t_flat[i * 12 + 10] = xf.origin.y
				t_flat[i * 12 + 11] = xf.origin.z
			variants.append({"key": v_key, "transforms": t_flat})
		entries.append({"species_path": path, "variants": variants})
	var data := {
		"cache_key": key,
		"tile": [tile.x, tile.y],
		"entries": entries,
		"exclusions": tile_exclusions,
	}
	var dir := _cache_dir_for_map(key)
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var path := _cache_path_for_tile(tile, key)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	var blob := var_to_bytes(data)
	f.store_buffer(_cache_magic)
	f.store_32(_CACHE_FORMAT_VERSION)
	f.store_64(blob.size())
	f.store_buffer(blob)
	f.close()


func _spawn_tile_from_cache(tile: Vector2i, cache: Dictionary) -> void:
	var per_species: Dictionary = {}
	var entries: Array = cache.get("entries", [])
	for e in entries:
		var sp_path: String = e.get("species_path", "")
		if sp_path.is_empty():
			continue
		var per_var: Dictionary = {}
		var variants: Array = e.get("variants", [])
		for v in variants:
			var v_key: String = v.get("key", "")
			var t_flat: PackedFloat32Array = v.get("transforms",
				PackedFloat32Array())
			var n: int = t_flat.size() / 12
			var xforms: Array = []
			xforms.resize(n)
			for i in n:
				xforms[i] = Transform3D(
					Basis(
						Vector3(t_flat[i * 12 + 0], t_flat[i * 12 + 1], t_flat[i * 12 + 2]),
						Vector3(t_flat[i * 12 + 3], t_flat[i * 12 + 4], t_flat[i * 12 + 5]),
						Vector3(t_flat[i * 12 + 6], t_flat[i * 12 + 7], t_flat[i * 12 + 8])),
					Vector3(t_flat[i * 12 + 9], t_flat[i * 12 + 10], t_flat[i * 12 + 11]))
			per_var[v_key] = xforms
		per_species[sp_path] = per_var
	_baked_tile_placements[tile] = per_species
	# Restore tree-exclusion zones from cache so trees + ground cover
	# baking against this tile see the exclusion immediately.
	var exclusions: PackedFloat32Array = cache.get("exclusions",
		PackedFloat32Array())
	if exclusions.size() > 0:
		_tile_tree_exclusions[tile] = exclusions
	_baked_tiles[tile] = _spawn_tile(tile, per_species)


func _bake_cache_near_origin() -> void:
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[rocks] cannot bake cache: terrain not loaded")
		return
	# Force a fresh load of species data from disk (see
	# `_invalidate_species_cache` for why).
	_invalidate_species_cache()
	if _biome_species_paths.is_empty():
		_build_species_table()
		if _biome_species_paths.is_empty():
			return
	var prev := _bake_force_fresh
	_bake_force_fresh = true
	var radius_tiles := int(ceil(prebake_radius_m / tile_size_m))
	var n := 0
	var total := (radius_tiles * 2 + 1) * (radius_tiles * 2 + 1)
	print("[rocks] baking cache: radius=%.0fm (%d tiles, key=%s)..."
		% [prebake_radius_m, total, _get_cache_key()])
	for tz in range(-radius_tiles, radius_tiles + 1):
		for tx in range(-radius_tiles, radius_tiles + 1):
			var tile := Vector2i(tx, tz)
			if _baked_tiles.has(tile):
				var existing: Node3D = _baked_tiles[tile]
				if is_instance_valid(existing):
					existing.queue_free()
				_baked_tiles.erase(tile)
				_baked_tile_placements.erase(tile)
				_baked_tile_collision.erase(tile)
				_baked_tile_shadow.erase(tile)
				_tile_tree_exclusions.erase(tile)
			_bake_tile(tile)
			n += 1
			if n % 100 == 0:
				print("[rocks]   %d / %d tiles..." % [n, total])
	_bake_force_fresh = prev
	print("[rocks] bake cache complete: %d tiles → %s/" % [
		n, _cache_dir_for_map(_get_cache_key())])


# Bake EVERY tile inside the active Terrain3D regions. Mirrors
# `tree_scatter._bake_cache_whole_map` — used both as a manual tool
# button and as the target of `Terrain3DBaker.Rebake Vegetation`.
func _bake_cache_whole_map() -> void:
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[rocks] cannot bake whole map: terrain not loaded")
		return
	# Force a fresh load of species data from disk. Without this, a
	# whole-map bake done after editing a species `.tres` or after
	# re-importing the rock pack `.glb` reuses the old in-memory
	# mesh/AABB data, silently producing stale placements. (See
	# `_invalidate_species_cache` docstring for the full reasoning.)
	_invalidate_species_cache()
	if _biome_species_paths.is_empty():
		_build_species_table()
		if _biome_species_paths.is_empty():
			return
	_resolve_terrain3d()
	if _terrain3d == null:
		push_warning("[rocks] cannot bake whole map: Terrain3D node not resolved")
		return
	var region_size_verts: int = int(_terrain3d.get("region_size"))
	var vertex_spacing: float = float(_terrain3d.get("vertex_spacing"))
	var region_size_m := float(region_size_verts) * vertex_spacing
	var regions: Array = _terrain3d.data.get_regions_active()
	if regions.is_empty():
		push_warning("[rocks] cannot bake whole map: no active Terrain3D regions")
		return
	var min_loc := Vector2i(2147483647, 2147483647)
	var max_loc := Vector2i(-2147483648, -2147483648)
	for region in regions:
		var loc: Vector2i = region.location
		min_loc.x = mini(min_loc.x, loc.x)
		min_loc.y = mini(min_loc.y, loc.y)
		max_loc.x = maxi(max_loc.x, loc.x)
		max_loc.y = maxi(max_loc.y, loc.y)
	var world_min_x := float(min_loc.x) * region_size_m
	var world_min_z := float(min_loc.y) * region_size_m
	var world_max_x := float(max_loc.x + 1) * region_size_m
	var world_max_z := float(max_loc.y + 1) * region_size_m
	var tile_min_x: int = int(floor(world_min_x / tile_size_m))
	var tile_min_z: int = int(floor(world_min_z / tile_size_m))
	var tile_max_x: int = int(floor((world_max_x - 0.001) / tile_size_m))
	var tile_max_z: int = int(floor((world_max_z - 0.001) / tile_size_m))
	var n_tx: int = tile_max_x - tile_min_x + 1
	var n_tz: int = tile_max_z - tile_min_z + 1
	var total: int = n_tx * n_tz
	var prev := _bake_force_fresh
	_bake_force_fresh = true
	var t_start: int = Time.get_ticks_msec()
	var print_every: int = maxi(1, mini(100, total / 20))
	print("[rocks] bake whole map: %d × %d tiles (%d total), bounds %.0f×%.0f m, key=%s"
		% [n_tx, n_tz, total, world_max_x - world_min_x,
		world_max_z - world_min_z, _get_cache_key()])
	var n: int = 0
	for tz in range(tile_min_z, tile_max_z + 1):
		for tx in range(tile_min_x, tile_max_x + 1):
			var tile := Vector2i(tx, tz)
			# `cache_only=true` skips MMI / collision body instantiation
			# — we're populating disk cache, not visualising. Runtime
			# spawns from cache when the player gets close. Pre-existing
			# scene-tree containers from the editor preview pass are
			# left alone; they stay as the visible preview while the
			# cache rebuilds.
			_bake_tile(tile, true)
			n += 1
			if n % print_every == 0 or n == total:
				var t_now: int = Time.get_ticks_msec()
				var elapsed_s: float = float(t_now - t_start) / 1000.0
				var pct: float = 100.0 * float(n) / float(total)
				var rate: float = float(n) / maxf(elapsed_s, 0.001)
				var eta_s: float = float(total - n) / maxf(rate, 0.001)
				print("[rocks]   %d / %d (%.1f%%) — %.1fs elapsed, %.1f tiles/s, ETA %.0fs"
					% [n, total, pct, elapsed_s, rate, eta_s])
	_bake_force_fresh = prev
	var t_end: int = Time.get_ticks_msec()
	var total_s: float = float(t_end - t_start) / 1000.0
	print("[rocks] bake whole map COMPLETE: %d tiles in %.1fs (%.1f tiles/s avg) → %s/"
		% [n, total_s, float(n) / maxf(total_s, 0.001),
		_cache_dir_for_map(_get_cache_key())])


func _clear_cache_for_map() -> void:
	var root := "res://assets/foliage_bake/%s/rocks" % map_id
	var n := _delete_dir_recursive(root)
	# Also drop the in-memory species + AABB cache. Without this, a
	# subsequent bake reuses the previously-loaded mesh/AABB data
	# even if the .glb on disk has been re-imported (e.g. asset
	# recenter pass). Stale AABBs were the silent cause of "rocks
	# still float after rebake" reports — the bake placed origins
	# using OLD AABB centers while the renderer used NEW mesh data.
	_invalidate_species_cache()
	print("[rocks] cleared %d cache files from %s + invalidated species cache" % [n, root])


# Drop every in-memory bit of species/mesh state so the next bake
# re-loads from disk. Lighter than `_force_rebuild` — doesn't queue_free
# active tile MMIs or reset the per-tile bake queue. Used by the
# Clear-cache and Bake-whole-map paths so they pick up freshly-imported
# mesh data without requiring a full editor restart.
func _invalidate_species_cache() -> void:
	for path in _species_resource_cache.keys():
		var sp_old: RockSpecies = _species_resource_cache[path]
		if sp_old == null:
			continue
		var cb := _on_species_changed.bind(path)
		if sp_old.changed.is_connected(cb):
			sp_old.changed.disconnect(cb)
	_species_changed_connected.clear()
	_species_resource_cache.clear()
	_species_variant_meshes.clear()
	_species_variant_aabb.clear()
	_species_variant_lod_levels.clear()
	_species_variant_keys.clear()
	_species_variant_imposter_meshes.clear()
	_species_shader_materials.clear()
	_species_imposter_materials.clear()
	_species_packs.clear()
	_biome_species_paths.clear()
	_biome_species_cumweight.clear()
	_biome_density.clear()
	_max_rocks_per_sq_m = 0.0
	_invalidate_cache_key()


func _delete_dir_recursive(path: String) -> int:
	if not DirAccess.dir_exists_absolute(path):
		return 0
	var n := 0
	var d := DirAccess.open(path)
	if d == null:
		return 0
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := "%s/%s" % [path, name]
		if d.current_is_dir():
			n += _delete_dir_recursive(child)
		else:
			DirAccess.remove_absolute(child)
			n += 1
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
	return n
