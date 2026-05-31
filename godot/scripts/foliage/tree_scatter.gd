@tool
class_name TreeScatter
extends Node3D

## Streams trees into the active radius around the player, with
## trunk collision shapes, the tree shader, and a per-tile binary
## cache for fast scene reopens.
##
## Mirrors `GroundCoverScatter` but tuned for trees:
## - way lower density (~0.005 trees/m² vs 1.3 plants/m²)
## - bigger tiles (64 m vs 16 m)
## - bigger active radius (300 m default — trees are visible from far)
## - individual MeshInstance3D + StaticBody3D nodes per tree (not
##   MultiMesh — trees need per-instance collision)
## - tree shader (`tree_dynamic.gdshader`) with per-species wind +
##   trunk anchor + albedo modulation
## - max-render-distance per species (GPU collapse past that range)
##
## Biome lookup, slope thinning, splatmap reads, RNG seeding all
## reuse the same patterns as the ground cover scatter for
## consistency across the foliage system.

@export var map_id: String = "cascade_locks"
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Node3D") var terrain3d_path: NodePath

@export var biome_configs: Array[TreeBiomeConfig] = []
## Shared with GroundCoverScatter — wind globals are scene-wide.
@export var globals: FoliageGlobals = null

@export_group("Scatter density")
@export_range(16.0, 512.0, 8.0) var tile_size_m: float = 64.0
@export_range(8, 65536, 8) var placements_per_tile_cap: int = 64
@export_range(64.0, 4000.0, 16.0) var active_radius_m: float = 300.0
@export_range(2.0, 256.0, 2.0) var rebuild_threshold_m: float = 16.0
## Per-frame steady-state bake budget (tiles per frame). On top of
## this, an adaptive burst kicks in while the queue is large (>32
## tiles backed up) — see `_drain_bake_queue` — so the initial
## scene-load tile burst drains faster than the steady-state rate.
##
## Each tile spawn creates ~24 species × 2 LOD MMIs (after the
## LOD0 drop in `_ensure_species_resources` and the fully-blanked
## LOD3 filter in `_spawn_species_multimeshes`), each with ~30–40
## per-instance transforms after density-weighted RNG distributes
## the tile's ~852 tree placements across species. At budget=2,
## that's ~96 MMIs / 3K transform writes per frame — usually fine,
## but the user reports occasional residual hitching. Drop to 1
## tile per frame steady-state — slower scene drainage, but every
## walking step pays at most one tile's spawn cost.
@export_range(0, 64, 1) var bake_per_frame_budget: int = 1
## Burst budget while `_bake_queue.size() > _BAKE_BURST_THRESHOLD`.
## Used during initial scene load and after fast camera moves.
## 4 tiles per frame is the upper bound that doesn't hitch on the
## current 24-species forest mix; previously 6 was probably the
## hitch source the user reported.
@export_range(1, 128, 1) var bake_burst_budget: int = 4
@export_range(0.0, 4.0, 0.05) var density_multiplier: float = 1.0

## Scatter-level brightness scale for ALL species' close-tier
## materials. Per-species `leaf_value_mul` × `albedo_modulation`
## stack to produce vibrant trees, but the resulting brightness
## drifts away from the lit-billboard distant impostor tier.
## Multiply final ALBEDO by this so close + distant trees match
## without re-tuning every TreeSpecies. 1.0 = unchanged authored
## brightness; 0.75 = 25 % toned down. Pushed to every species'
## ShaderMaterial via `_push_live_uniforms` so changes propagate
## live as you drag the slider.
@export_range(0.0, 2.0, 0.01) var close_tier_brightness: float = 0.75: set = _set_close_tier_brightness

## Scatter-level color grading for ALL species' close-tier
## materials. Composes with each species' authored
## `leaf_hue_shift` / `leaf_saturation_mul` / `leaf_value_mul` —
## doesn't override, so per-species variation is preserved.
##
## Effective values pushed to each material:
##   hue        = species.leaf_hue_shift  + extra_leaf_hue_shift
##   saturation = species.leaf_saturation_mul × extra_leaf_saturation_mul
##   value      = species.leaf_value_mul × extra_leaf_value_mul
##
## Defaults (0, 1, 1) are no-ops. Negative hue shift = blue-green;
## positive = yellow-green. Saturation/value > 1 brighten; < 1 mute.
@export_range(-0.2, 0.2, 0.005) var extra_leaf_hue_shift: float = 0.0: set = _set_extra_leaf_hue_shift
@export_range(0.0, 2.0, 0.05) var extra_leaf_saturation_mul: float = 1.0: set = _set_extra_leaf_saturation_mul
@export_range(0.0, 2.0, 0.05) var extra_leaf_value_mul: float = 1.0: set = _set_extra_leaf_value_mul

@export_subgroup("Distant tier")
## Cast directional shadows from this scatter's MMIs. Off for the
## distant tier — at 500 m+ the shadow contribution is invisible
## anyway and `directional_shadow_max_distance` (typically 80 m on
## the Sun) culls them out, but disabling explicitly stops the
## renderer from queuing shadow draws.
@export var cast_shadow: bool = true
## Spawn `StaticBody3D + CylinderShape3D` per tree (trunk collision).
## Off for the distant tier — the player will never reach those
## distances during a tile's lifetime, and per-tree physics bodies
## are the dominant cost when the tile count is high.
@export var enable_collision: bool = true

## Only spawn trunk collision for tiles whose center is within this
## distance of the camera. As the camera moves, tiles are dynamically
## granted / stripped of their colliders so RID + physics-broadphase
## counts stay bounded regardless of how big `active_radius_m` is.
##
## At active_radius=2000m + density 0.04 trees/m² that'd be ~500K
## trees, ~1.5M RIDs, well past Godot's allocator cap. With
## `collision_radius_m=150` we're back to ~3K colliders, ~9K RIDs —
## fine for any modern physics engine.
##
## Set to `active_radius_m` (or larger) to disable the dynamic gate
## and spawn collisions for every baked tile (only viable on tiny
## scatters).
@export_range(0.0, 1000.0, 8.0) var collision_radius_m: float = 150.0

## Only set `cast_shadow = ON` on tiles whose center is within this
## distance of the camera. The Sun's `directional_shadow_max_distance`
## (typically 80 m) means shadows from trees past that range are
## culled by the renderer anyway, but the CPU still submits a shadow
## draw call per shadow-cast MMI. With ~3K MMIs in the scatter,
## suppressing those submissions per-tile is a several-millisecond
## win per frame on the main thread.
##
## Default 100 m provides margin past the Sun's typical shadow range.
## Bump if you raise `directional_shadow_max_distance` on the Sun.
@export_range(0.0, 500.0, 8.0) var shadow_radius_m: float = 100.0

@export_subgroup("LOD")
## Skip LOD0 (highest-detail mesh) for any species that has higher
## LODs available. Recommended ON — LOD0 vs LOD1 silhouette
## difference is below the canopy-texture noise floor at any
## viewing distance, but LOD0 has 4-8× the vert count of LOD1.
## Set OFF if a specific asset's LOD0 has details visible at close
## range that LOD1 lacks.
@export var skip_lod0: bool = true: set = _set_skip_lod0
## Skip LOD1 (mid-high-detail mesh) for any species that has LOD2
## or higher available. OFF by default. Combined with skip_lod0=ON
## and skip_lod2=OFF, the close-tier renders ONLY LOD2 + LOD3 →
## maximum optimization, no full-detail meshes anywhere in the
## scatter (use hand-placed full-detail trees in POIs instead).
@export var skip_lod1: bool = false: set = _set_skip_lod1
## Skip LOD2 (mid-detail mesh) for any species that has higher
## LODs available. OFF by default since LOD2 covers the 100-180m
## band cheaply (LOD2 has fewer verts than LOD1). Set ON to halve
## close-tier MMI count for a CPU win at the cost of more vert work
## in the 100-180m range (LOD1 then covers the whole 0-180m).
@export var skip_lod2: bool = false: set = _set_skip_lod2
## Inter-LOD distance boundaries (meters). Element N is the
## LOD-N → LOD-N+1 transition distance. Highest LOD's upper bound
## comes from per-species `proxy_swap_distance_m`, NOT from this
## array. Defaults: [25, 100, 180] = LOD0 covers 0-25, LOD1 25-100,
## LOD2 100-180. With `skip_lod0` / `skip_lod2` on, the relevant
## entries become unused but stay in the array for legacy single-
## LOD species fallback.
@export var lod_band_ends_m: PackedFloat32Array = PackedFloat32Array([25.0, 100.0, 180.0]) : set = _set_lod_band_ends_m
## Total fade-zone width (meters) across each LOD boundary. Wider
## spreads per-tree pops over more meters → softer visual gradient
## but more overlap-zone vert work. 60m balances these well at
## walking speeds.
@export_range(4.0, 200.0, 1.0) var lod_band_fade_m: float = 60.0 : set = _set_lod_band_fade_m

@export_subgroup("Slope")
@export_range(0.0, 4.0, 0.05) var slope_thin_start: float = 0.8
@export_range(0.0, 4.0, 0.05) var slope_cutoff: float = 1.6

@export_subgroup("Road clearance")
## Sample road density at this many meters offset from each candidate
## placement (4 cardinal offsets: +X, -X, +Z, -Z). If ANY offset hits
## a road pixel, the placement is suppressed. Models the tree's
## canopy radius — a trunk on a "grass" pixel right next to a road
## would still overhang the road without this buffer.
##
## 0 disables (only the trunk position is checked, same as before
## the buffer was added). 4–5 m is a reasonable mature-tree canopy.
## Saplings already check at radius 0 because the buffer is global,
## not per-species — if you place 100 % saplings the buffer might be
## too aggressive; tune down.
@export_range(0.0, 12.0, 0.5) var road_buffer_m: float = 4.0
## Road density threshold. The `road_density.rgba8` channels go 0
## (no road) → 255 (definitely road). Edge-of-road pixels bleed
## down to ~20-50 from the central road values. Threshold 25
## catches the edge bleed; higher values let trees creep in. Match
## with `road_buffer_m > 0` for a wider clearance band.
@export_range(0, 255, 1) var road_threshold: int = 25

## **Soft road clearance** — radius (meters) over which tree density
## smoothly thins toward roads. Pairs with the hard `road_buffer_m`
## (which kills trees AT the road) for a soft falloff out to this
## distance. Naturally produces:
##   - Cleaner road shoulders (single-road clearings)
##   - Town-shaped clearings where roads cluster (the more roads
##     within `road_clearance_radius_m` of a candidate, the higher
##     the suppression)
##
## 0 disables the soft falloff. 25 m default suits PNW road-shoulder
## clearings. Bigger for more aggressive town clearing; smaller for
## tighter shoulders. Cost: ~8 splat-byte reads per candidate at the
## sample radii, ~2 µs per candidate. ~1-2 ms per tile bake at peak.
@export_range(0.0, 80.0, 1.0) var road_clearance_radius_m: float = 25.0
## Strength of the soft road clearance falloff. 1.0 = full kill at
## the road's exact pixel; 0.0 = no soft thinning at all (only the
## hard `road_buffer_m` cull). Intermediate values thin instead of
## kill: 0.5 means trees within `road_clearance_radius_m` of a
## road pixel get up to 50% suppression at center, easing to 0 at
## the radius edge.
@export_range(0.0, 1.0, 0.05) var road_clearance_strength: float = 0.85

@export_group("Determinism")
@export var seed: int = 1337

@export_group("Persistent bake cache")
@export var cache_enabled: bool = true
# Internal toggle used by the "Bake placement cache" button to write
# fresh bakes to disk regardless of existing cache state. NOT @export
# — the equivalent inspector checkbox was removed because leaving it
# on by accident tanked perf for entire sessions; use the Rebuild
# button or bump `cache_version` to re-roll instead.
var _bake_force_fresh: bool = false
## Bump (or click Clear + Bake) to re-roll forest placements. The
## cache key is `cache_version + seed` ONLY — species params,
## densities, biomes, slope filters, terrain content all flow through
## without invalidating cache, so balance tweaks don't shuffle the
## world mid-session. Bakes are gitignored locally; bump this int
## when you want a clean re-roll instead of carrying old tiles.
@export_range(1, 999, 1) var cache_version: int = 1
@export_tool_button("Bake placement cache", "Save") var bake_cache_action: Callable = _bake_cache_near_origin
@export_range(64.0, 2048.0, 64.0) var prebake_radius_m: float = 512.0
## Bakes EVERY tile inside the active terrain regions, regardless of
## `prebake_radius_m`. Use this once per map (or after bumping
## `cache_version`) so subsequent gameplay never hits an on-demand
## bake — every tile loads from the local disk cache. For
## a 6×4 km map at 128 m tiles that's ~1500 tiles / scatter, ~1
## minute of bake time. Logs progress every 5 % to terminal.
@export_tool_button("Bake whole map", "Save") var bake_whole_map_action: Callable = _bake_cache_whole_map
@export_tool_button("Clear placement cache", "Remove") var clear_cache_action: Callable = _clear_cache_for_map

@export_group("Editor")
@export var editor_preview: bool = false : set = _set_editor_preview
@export_tool_button("Rebuild trees", "Reload") var force_rebuild_action: Callable = _force_rebuild

const TREE_SHADER_PATH := "res://shaders/tree_dynamic.gdshader"
const TREE_IMPOSTER_SHADER_PATH := "res://shaders/tree_imposter.gdshader"

# Stable script ref for `ProceduralExclusionZone.density_multiplier(...)`
# static dispatch. Direct `ProceduralExclusionZone.foo()` calls fail
# in `@tool` context after script reloads — Godot's global class_name
# registry doesn't always re-cache, and the call errors with
# `Nonexistent function 'foo' in base 'GDScript'`. Because GDScript
# treats failed-call returns as null (→ falsy), the exclusion check
# then silently passes through and trees place inside POI zones.
# preload()-bound const refs sidestep the registry by binding the
# script object at parse time instead.
#
# `RockScatter.is_point_excluded(...)` was previously called the same
# way; we now inline the group iteration in `_bake_tile` because even
# the const-preload pattern occasionally loses static-method binding
# after hot-reload (same "Nonexistent function ... in base 'GDScript'"
# symptom, only on `static func` — instance methods are unaffected).
const _ExclusionZoneRef := preload("res://scripts/procedural_exclusion_zone.gd")

var _camera: Camera3D = null
var _terrain3d: Node3D = null

# Terrain artifacts for biome lookup + height sampling fallback.
var _hm_bytes: PackedByteArray = PackedByteArray()
var _splat_a: PackedByteArray = PackedByteArray()
var _splat_b: PackedByteArray = PackedByteArray()
# Road density texture (`road_density.rgba8`) — separate from
# splatmap_a/b. Channels are R/G/B/A = different road tiers (paved /
# trail / dirt / unpaved depending on the bake). Tree scatter takes
# the max across channels: any road-class pixel suppresses trees.
var _splat_road: PackedByteArray = PackedByteArray()
var _terrain_w: int = 0
var _terrain_h: int = 0
var _spacing_m: float = 1.0
var _extent_x: float = 0.0
var _extent_z: float = 0.0
var _terrain_ready: bool = false

# Per-species TreeSpecies resource cache. `load(path)` hits Godot's
# ResourceLoader cache but each call still has function-call + cast
# overhead; with hundreds of placement RNG draws per tile bake (each
# resolving its species via load()), the aggregate cost shows up as
# CPU spikes during tile spawn. A local Dictionary[String → TreeSpecies]
# is one-pointer-lookup per call and lives for the whole session.
var _species_resource_cache: Dictionary = {}  # path → TreeSpecies

# Per-species ShaderMaterial registry — populated as materials are
# created in `_ensure_species_resources` so the
# `species.changed` signal callback can re-push leaf grading
# uniforms (and any other live-tunable @export) without a full
# rebuild. Without this, edits to a species's `leaf_hue_shift` /
# `leaf_value_mul` / etc. in the inspector wouldn't take effect
# until the user clicked Rebuild.
var _species_shader_materials: Dictionary = {}  # path → Array[ShaderMaterial]
# Tracks which species we've already connected `changed` to.
# `is_connected(callable.bind(...))` doesn't match a previously-bound
# connection (each `bind()` returns a fresh Callable), so we'd
# otherwise stack a fresh connection on every tile bake → dozens of
# duplicate signal handlers per species.
var _species_changed_connected: Dictionary = {}  # path → true

# Per-species cache: instanced gltf scenes, walked variant meshes,
# shared shader materials. Keyed by species resource_path.
var _species_packs: Dictionary = {}        # path → PackedScene
var _species_variant_meshes: Dictionary = {}  # path → Array[Mesh]
# Parallel array to `_species_variant_meshes` — each entry is the
# LOD level (0 = highest detail) parsed from the source MeshInstance3D
# name. Drives per-MMI `visibility_range_*` so each tree placement
# only renders ONE LOD at any given camera distance instead of
# stacking all of them.
var _species_variant_lod_levels: Dictionary = {}  # path → PackedInt32Array
# Impostor meshes split out from each variant — surfaces with vert
# count < `min_surface_verts` (the LOD3 billboard cards baked into
# Fab/Megascans tree .glbs). One impostor mesh per variant; spawned
# alongside the close-tier mesh in `_spawn_species_proxy`. May be
# empty for species whose source assets don't ship LOD3 billboards
# (e.g. our Birch lowpoly pack).
var _species_imposter_meshes: Dictionary = {}  # path → Array[Mesh]
var _species_variant_bases: Dictionary = {}   # path → Array[Basis]
# Parallel to `_species_variant_meshes` — 1 (true) if the dup mesh
# at that index has at least one non-blanked surface, 0 (false) if
# every surface was extracted into the impostor and replaced with a
# zero-alpha StandardMaterial3D. False entries get skipped at MMI
# spawn — creating a MultiMesh + setting 1024 instance transforms
# only to render nothing visible is the dominant per-tile spawn
# cost on multi-LOD species (Doug Fir + pine LOD3).
var _species_variant_renderable: Dictionary = {}  # path → PackedByteArray
var _species_shader_mats: Dictionary = {}     # path → ShaderMaterial

# Per-biome density bookkeeping (parallel to GroundCoverScatter).
var _biome_species_paths: Dictionary = {}    # int biome_id → PackedStringArray
var _biome_species_cumweight: Dictionary = {}  # int → PackedFloat32Array
var _biome_density: Dictionary = {}           # int → float
var _max_trees_per_sq_m: float = 0.0

# Tile state. Each baked tile owns a Node3D container with N tree
# children inside (each tree = MeshInstance3D + StaticBody3D pair).
var _baked_tiles: Dictionary = {}  # Vector2i → Node3D
# Per-tile placement dict (species_path → Array[Transform3D]) kept in
# RAM so we can lazily spawn collision when the camera enters
# `collision_radius_m` of a previously-baked-without-collision tile.
# Without this we'd have to re-run the per-tile RNG bake just to
# recover positions.
var _baked_tile_placements: Dictionary = {}  # Vector2i → Dictionary
# Per-tile collision state. True iff that tile currently has a
# "Colliders" subnode populated. Toggled by `_refresh_collisions`.
var _baked_tile_collision: Dictionary = {}  # Vector2i → bool
# Per-tile shadow state. True iff that tile's MMIs currently have
# `cast_shadow = ON`. Toggled by `_refresh_shadows`.
var _baked_tile_shadow: Dictionary = {}  # Vector2i → bool
var _last_player_xz: Vector2 = Vector2(INF, INF)
var _bake_queue: Array[Vector2i] = []
## Switch to `bake_burst_budget` when the queue exceeds this depth.
## 32 picked so the typical rebuild-after-walk wave (5–15 new tiles)
## stays at the calmer steady-state budget but the initial scene-load
## queue (~80 tiles for active_radius=800, tile_size=128) triggers
## the burst and drains in 5–6 frames.
const _BAKE_BURST_THRESHOLD: int = 32
## Pooled `pending` Array reused across `_refresh_shadows` calls —
## avoids allocating a new Array (and the Dictionary entries inside)
## every frame. Cleared at the top of each call.
var _shadow_pending: Array = []
## Camera XZ at the last `_refresh_shadows` execution. Skip the
## per-frame iteration entirely when the camera has barely moved —
## tile-camera distances haven't changed enough to flip any tile's
## shadow state, so the work is pure overhead. Camera turning
## without translating doesn't change distances, so the gate is
## translation-only.
var _last_shadow_refresh_xz: Vector2 = Vector2(INF, INF)
## Camera must move at least this many meters between
## `_refresh_shadows` runs. 1 m gates out the per-frame iteration
## when the player is stationary, walking very slowly, or just
## panning the view; flips are still rate-limited at 1 per frame
## via `_SHADOW_FLIPS_PER_FRAME` once movement clears the gate.
const _SHADOW_REFRESH_MIN_MOVE: float = 1.0

# Cached cache key (lazily computed to avoid re-hashing biome configs
# every tile bake).
var _cached_key: String = ""


# --- Lifecycle ---

func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview:
		return
	_resolve_camera()
	# Lazy init — `_process` handles terrain load, terrain3d resolve,
	# species table build, and first rebuild once a camera is available
	# (editor camera in editor mode, scene camera at runtime). Trying
	# to rebuild here crashes when `camera_path` is empty and the
	# editor viewport camera hasn't been queried yet.


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
	# Push camera position globals only in editor preview. At runtime
	# `player.gd` is the single source of truth — three scatters all
	# pushing the same uniform every frame is just write-after-write
	# on the same RID.
	if Engine.is_editor_hint():
		RenderingServer.global_shader_parameter_set(
			"player_cam_pos", cam.global_position)
		var fwd := -cam.global_transform.basis.z.normalized()
		RenderingServer.global_shader_parameter_set("player_cam_forward", fwd)
	var p_xz := _xz(cam.global_position)
	if (p_xz - _last_player_xz).length() >= rebuild_threshold_m:
		_rebuild_active(p_xz)
		_refresh_collisions()
	# Shadow refresh runs EVERY FRAME (decoupled from rebuild_threshold)
	# with a per-frame flip cap, so individual tiles toggle precisely
	# as the camera crosses each one's boundary instead of batching
	# 5–10 tile flips into one rebuild-tick frame. Per-tile flip = ~30
	# MMI cast_shadow property sets; spread across frames = invisible,
	# batched = a directional-shadow-map regen hitch.
	_refresh_shadows(p_xz)
	if bake_per_frame_budget > 0 and not _bake_queue.is_empty():
		# Adaptive burst — when the queue piles up (initial scene
		# load, fast camera move, just-revealed area), drain at
		# `bake_burst_budget` instead of the steady-state budget.
		# Falls back to steady-state once the queue catches up.
		var budget: int = (
			bake_burst_budget
			if _bake_queue.size() > _BAKE_BURST_THRESHOLD
			else bake_per_frame_budget)
		_drain_bake_queue(budget)


## Walk every baked tile and add/remove its Colliders subnode based
## on whether the tile center is currently within `collision_radius_m`
## of the camera. Called from `_process` after the visual tile set
## has been refreshed; cheap because we only touch tiles that change
## state across the boundary.
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
			# Tile entered collision range — re-spawn its colliders
			# from the cached placement dict.
			var per_species: Dictionary = _baked_tile_placements.get(tile, {})
			if per_species.is_empty():
				continue
			var colliders_node := _get_or_make_colliders_node(container)
			for path in per_species.keys():
				var sp: TreeSpecies = _get_cached_species(path)
				if sp == null:
					continue
				if sp.trunk_collision_radius <= 0.0 or sp.trunk_collision_height <= 0.0:
					continue
				_spawn_species_collisions(
					colliders_node, per_species[path], sp, tile_center)
			_baked_tile_collision[tile] = true
		else:
			# Tile left collision range — drop the whole Colliders
			# subnode in one queue_free, freeing all StaticBody3D RIDs.
			var colliders: Node = container.get_node_or_null("Colliders")
			if colliders != null:
				colliders.queue_free()
			_baked_tile_collision[tile] = false


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


# LOD knobs flip → force a rebuild so the species cache reloads
# with the new effective LOD set / boundaries / fade width. Edits
# to these in the inspector take immediate effect.
func _set_skip_lod0(v: bool) -> void:
	skip_lod0 = v
	if is_inside_tree():
		_force_rebuild()


func _set_skip_lod1(v: bool) -> void:
	skip_lod1 = v
	if is_inside_tree():
		_force_rebuild()


func _set_skip_lod2(v: bool) -> void:
	skip_lod2 = v
	if is_inside_tree():
		_force_rebuild()


func _set_lod_band_ends_m(v: PackedFloat32Array) -> void:
	lod_band_ends_m = v
	if is_inside_tree():
		_force_rebuild()


func _set_lod_band_fade_m(v: float) -> void:
	lod_band_fade_m = v
	if is_inside_tree():
		_force_rebuild()


# Live-update every existing species' ShaderMaterial when the user
# drags the brightness slider. No tile rebake needed — uniform-only
# change propagates per-frame.
func _set_close_tier_brightness(v: float) -> void:
	close_tier_brightness = v
	for mats_v in _species_shader_materials.values():
		var mats: Array = mats_v
		for sm_v in mats:
			var sm: ShaderMaterial = sm_v as ShaderMaterial
			if sm != null:
				sm.set_shader_parameter(
					"foliage_close_tier_brightness", v)


# Live-update setters for the scatter-level color grading. Each
# re-pushes the COMPOSED leaf grading values (per-species ×
# scatter extras) to every existing material. Per-species values
# are looked up from the cached species resource.
func _set_extra_leaf_hue_shift(v: float) -> void:
	extra_leaf_hue_shift = v
	_repush_composed_grading()


func _set_extra_leaf_saturation_mul(v: float) -> void:
	extra_leaf_saturation_mul = v
	_repush_composed_grading()


func _set_extra_leaf_value_mul(v: float) -> void:
	extra_leaf_value_mul = v
	_repush_composed_grading()


func _repush_composed_grading() -> void:
	for path_v in _species_shader_materials.keys():
		var sp: TreeSpecies = _species_resource_cache.get(path_v, null)
		if sp == null:
			continue
		var mats: Array = _species_shader_materials[path_v]
		for sm_v in mats:
			var sm: ShaderMaterial = sm_v as ShaderMaterial
			if sm == null:
				continue
			sm.set_shader_parameter("leaf_hue_shift",
				sp.leaf_hue_shift + extra_leaf_hue_shift)
			sm.set_shader_parameter("leaf_saturation_mul",
				sp.leaf_saturation_mul * extra_leaf_saturation_mul)
			sm.set_shader_parameter("leaf_value_mul",
				sp.leaf_value_mul * extra_leaf_value_mul)


func _force_rebuild() -> void:
	_clear_all_tiles()
	_invalidate_cache_key()
	# Clear species ref cache + signal connections so reloaded
	# species re-connect on next access. Without this, a freed-and-
	# re-baked tile would skip the signal hookup.
	for path in _species_resource_cache.keys():
		var sp: TreeSpecies = _species_resource_cache[path]
		if sp == null:
			continue
		var cb := _on_species_changed.bind(path)
		if sp.changed.is_connected(cb):
			sp.changed.disconnect(cb)
	_species_resource_cache.clear()
	_species_shader_materials.clear()
	_species_changed_connected.clear()
	_species_packs.clear()
	_species_variant_meshes.clear()
	_species_variant_bases.clear()
	_species_variant_lod_levels.clear()
	_species_imposter_meshes.clear()
	_species_variant_renderable.clear()
	_species_shader_mats.clear()
	_biome_species_paths.clear()
	_biome_species_cumweight.clear()
	_biome_density.clear()
	_max_trees_per_sq_m = 0.0
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
	_bake_queue.clear()


func _resolve_camera() -> void:
	if not camera_path.is_empty():
		_camera = get_node_or_null(camera_path) as Camera3D
		if _camera != null:
			return
	# Runtime fallback: walk the "player" group for the first
	# Camera3D. Same pattern GroundCoverScatter uses so trees + ground
	# cover follow the same camera without needing both to wire up
	# `camera_path` explicitly. Player scenes set themselves into
	# `add_to_group("player")` during _ready.
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
	var sb := FileAccess.open(dir + "splatmap_b.rgba8", FileAccess.READ)
	if sb != null:
		_splat_b = sb.get_buffer(sb.get_length())
		sb.close()
	# Roads live in a SEPARATE file (`road_density.rgba8`), not in
	# splatmap_b. Loading them lets `_biome_at_world` correctly
	# return biome 4 (road) for road / trail pixels — without this,
	# trees place on top of roads because the splatmap_b R channel
	# they were reading isn't actually road data.
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
	_max_trees_per_sq_m = 0.0
	for cfg in biome_configs:
		if cfg == null or cfg.tree_paths.is_empty():
			continue
		var paths := PackedStringArray()
		var cums := PackedFloat32Array()
		var cum := 0.0
		var use_explicit := cfg.tree_densities.size() == cfg.tree_paths.size()
		for i in cfg.tree_paths.size():
			var p: String = cfg.tree_paths[i]
			if p.is_empty():
				continue
			var contribution: float = (cfg.tree_densities[i]
				if use_explicit else cfg.trees_per_sq_m)
			if contribution <= 0.0:
				continue
			paths.append(p)
			cum += contribution
			cums.append(cum)
		if paths.size() == 0:
			continue
		_biome_species_paths[cfg.biome] = paths
		_biome_species_cumweight[cfg.biome] = cums
		var eff: float = cum if use_explicit else cfg.trees_per_sq_m
		_biome_density[cfg.biome] = eff
		_max_trees_per_sq_m = maxf(_max_trees_per_sq_m, eff)


# Cached `load(path) as TreeSpecies` — see `_species_resource_cache`
# field comment for the rationale (CPU-spike-during-tile-spawn fix).
# Also lazily connects the species's `changed` signal to the
# live-update callback so inspector edits to leaf grading / albedo
# modulation propagate without a full Rebuild click.
func _get_cached_species(species_path: String) -> TreeSpecies:
	if _species_resource_cache.has(species_path):
		return _species_resource_cache[species_path]
	var sp: TreeSpecies = load(species_path) as TreeSpecies
	_species_resource_cache[species_path] = sp
	if sp != null and not _species_changed_connected.get(species_path, false):
		sp.changed.connect(_on_species_changed.bind(species_path))
		_species_changed_connected[species_path] = true
	return sp


# Re-push live-tunable uniforms to all materials registered for this
# species. Called when the inspector edits a property on the
# TreeSpecies resource (the resource emits `changed` automatically
# on `@export var` changes from the inspector).
func _on_species_changed(species_path: String) -> void:
	var sp: TreeSpecies = _species_resource_cache.get(species_path)
	if sp == null:
		return
	var mats: Array = _species_shader_materials.get(species_path, [])
	for sm_v in mats:
		var sm: ShaderMaterial = sm_v as ShaderMaterial
		if sm == null or not is_instance_valid(sm):
			continue
		_push_live_uniforms(sm, sp)


# Single source of truth for which uniforms are "live-tunable" —
# pushed both at spawn (initial value) and on `species.changed`
# (subsequent inspector edits). Other uniforms (LOD bands, max
# render distance, wind anchor) are spawn-time only.
func _push_live_uniforms(sm: ShaderMaterial, sp: TreeSpecies) -> void:
	sm.set_shader_parameter("albedo_modulation", Vector3(
		sp.albedo_modulation.r, sp.albedo_modulation.g, sp.albedo_modulation.b))
	# Compose per-species values with scatter-level extras.
	sm.set_shader_parameter("leaf_hue_shift",
		sp.leaf_hue_shift + extra_leaf_hue_shift)
	sm.set_shader_parameter("leaf_saturation_mul",
		sp.leaf_saturation_mul * extra_leaf_saturation_mul)
	sm.set_shader_parameter("leaf_value_mul",
		sp.leaf_value_mul * extra_leaf_value_mul)
	sm.set_shader_parameter("leaf_threshold", sp.leaf_threshold)
	# Foliage lighting uniforms — see tree_species.gd "Foliage lighting"
	# group + tree_dynamic.gdshader for what each does.
	sm.set_shader_parameter(
		"canopy_normal_up_blend", sp.canopy_normal_up_blend)
	sm.set_shader_parameter("backlight_strength", sp.backlight_strength)
	sm.set_shader_parameter("backlight_color", Vector3(
		sp.backlight_color.r, sp.backlight_color.g, sp.backlight_color.b))
	sm.set_shader_parameter(
		"normal_map_strength", sp.normal_map_strength)
	# Scatter-level brightness scale — applies uniformly across all
	# species so the scatter's exposure matches the lit-billboard
	# distant impostor tier without re-tuning every TreeSpecies.
	sm.set_shader_parameter(
		"foliage_close_tier_brightness", close_tier_brightness)


func _ensure_species_resources(species_path: String) -> bool:
	if _species_variant_meshes.has(species_path):
		return _species_variant_meshes[species_path].size() > 0
	var sp: TreeSpecies = load(species_path) as TreeSpecies
	if sp == null or sp.pack_scene_path.is_empty():
		_species_variant_meshes[species_path] = []
		return false
	var packed: PackedScene = load(sp.pack_scene_path) as PackedScene
	if packed == null:
		push_warning("[trees] failed to load %s" % sp.pack_scene_path)
		_species_variant_meshes[species_path] = []
		return false
	# Instance once to walk variants, then keep the PackedScene for
	# spawning copies later (we duplicate the chosen variant's
	# subtree per-instance to preserve transforms).
	_species_packs[species_path] = packed
	var root: Node = packed.instantiate()
	# CRITICAL: add to tree so `global_transform` actually composes
	# parent transforms. The Birch gltf has no per-node transforms
	# in source, but Godot's importer adds a rotation parent during
	# .scn conversion to convert source-Z-up → Godot-Y-up. That parent
	# transform only resolves into `global_transform` when the node
	# is in the tree.
	add_child(root)
	var mis: Array[MeshInstance3D] = []
	_collect_mesh_instances(root, mis)
	# Walk all variant meshes, parsing the LOD level from the MI name
	# (`_LOD0`, `_LOD1`, etc.). Source assets ship explicit per-LOD
	# MeshInstance3Ds; the previous regex filter only matched
	# `_LODN_` (with trailing underscore) which let Doug Fir's
	# trailing-form `_LODN` slip through and stack ALL LOD levels at
	# every tree placement. Now we explicitly tag each kept mesh with
	# its LOD level so spawn can set per-MMI visibility ranges and
	# render only one LOD per band.
	var prefix := sp.variant_prefix
	# First pass: scan to find the highest LOD level present for this
	# species. We use that to decide whether to skip LOD0 MIs entirely
	# (see comment below at the keep-mesh check).
	var max_lod_present := 0
	for mi in mis:
		if mi.mesh == null:
			continue
		if not prefix.is_empty() and not mi.name.begins_with(prefix + "_"):
			continue
		var l := _parse_lod_level(mi.name)
		if l > max_lod_present:
			max_lod_present = l
	# **Drop LOD0 if the species has higher LODs present.** LOD0 is
	# the highest-detail mesh; with separate per-LOD MeshInstance3Ds
	# (which is what every species in this project uses), the
	# LOD0↔LOD1 swap at boundary distance ~25 m is the most visually
	# obvious LOD pop because the tree fills a chunk of the screen at
	# that distance. Per-instance dither + 40 m fade band still leaves
	# individual tree pops noticeable when walking. Skipping LOD0
	# entirely promotes LOD1 to the closest band (0–100 m) — the
	# silhouette difference between LOD0 and LOD1 is well below the
	# canopy-texture noise floor at any viewing distance, so the
	# quality tradeoff is invisible.
	#
	# Species that only ship LOD0 (the unsuffixed Birch and any
	# legacy single-LOD assets) are exempt — `max_lod_present > 0`
	# is the gate. Without higher LODs present, dropping LOD0 would
	# leave the species with zero close-tier meshes.
	# `skip_lod0` / `skip_lod2` are @export toggles; gate by
	# `max_lod_present > N` so single-LOD species (which have no
	# higher LODs to fall back to) keep their LOD0 / LOD2 even when
	# the user toggles "skip" on for the multi-LOD case.
	# Per-species `force_skip_lodN` flags OR with global flags so a
	# species with broken-detail LODN (e.g. doug fir LOD2 missing
	# branches) can opt out without affecting other species like pine
	# whose LOD2 is fine. Per-species flags only ADD skips, never
	# remove globally-skipped LODs.
	var sp_skip_lod1: bool = "force_skip_lod1" in sp and sp.force_skip_lod1
	var sp_skip_lod2: bool = "force_skip_lod2" in sp and sp.force_skip_lod2
	var effective_skip_lod0: bool = skip_lod0 and max_lod_present > 0
	var effective_skip_lod1: bool = (skip_lod1 or sp_skip_lod1) and max_lod_present > 1
	var effective_skip_lod2: bool = (skip_lod2 or sp_skip_lod2) and max_lod_present > 1
	var meshes: Array[Mesh] = []
	var bases: Array[Basis] = []
	var lod_levels: PackedInt32Array = PackedInt32Array()
	for mi in mis:
		if mi.mesh == null:
			continue
		if not prefix.is_empty() and not mi.name.begins_with(prefix + "_"):
			continue
		var lod := _parse_lod_level(mi.name)
		if effective_skip_lod0 and lod == 0:
			continue
		if effective_skip_lod1 and lod == 1:
			continue
		if effective_skip_lod2 and lod == 2:
			continue
		meshes.append(mi.mesh)
		bases.append(mi.global_transform.basis)
		lod_levels.append(lod)
	remove_child(root)
	root.queue_free()
	if meshes.is_empty():
		push_warning("[trees] %s found 0 meshes for variant '%s'"
			% [species_path, prefix])
		_species_variant_meshes[species_path] = []
		return false
	# Build per-surface shader materials and bake them onto a
	# DUPLICATED mesh resource per filtered MI. Why duplicate + bake:
	#
	# - Fab Doug Fir packs bark + needles as separate surfaces of the
	#   same MeshInstance3D. Each needs its own ShaderMaterial.
	# - MultiMeshInstance3D has NO `set_surface_override_material` —
	#   only `material_override`, which collapses every surface to one
	#   material (bark bleeds onto needle cards, the bug we're fixing).
	# - The MultiMesh renderer DOES honor per-surface materials baked
	#   into the mesh resource itself, so we put the materials there.
	# - We duplicate before mutating because the imported Mesh resource
	#   is shared across every consumer in the project (TreeTestSpawn,
	#   any future TreeScatter, raw scene drops). Clobbering its
	#   surface materials globally would be a footgun.
	var shader: Shader = load(TREE_SHADER_PATH) as Shader
	var imposter_shader: Shader = load(TREE_IMPOSTER_SHADER_PATH) as Shader
	var root2: Node = packed.instantiate()
	var mis2: Array[MeshInstance3D] = []
	_collect_mesh_instances(root2, mis2)
	var dup_meshes: Array[Mesh] = []
	var imposter_meshes: Array[Mesh] = []
	# Per dup_meshes[i]: 1 if it has a renderable surface, 0 if every
	# surface was extracted into the impostor mesh (LOD3 of multi-LOD
	# species). Spawn skips zero entries to avoid creating MMIs +
	# uploading 1024 instance transforms for zero visual output.
	var renderable: PackedByteArray = PackedByteArray()
	for mi in mis2:
		if mi.mesh == null:
			continue
		if not prefix.is_empty() and not mi.name.begins_with(prefix + "_"):
			continue
		# Mirror the LOD0 + LOD1 + LOD2 skip from the first-pass loop
		# above so the parallel arrays (dup_meshes / imposter_meshes /
		# renderable) stay aligned with `lod_levels` / `meshes` /
		# `bases`.
		var mi_lod_level: int = _parse_lod_level(mi.name)
		if effective_skip_lod0 and mi_lod_level == 0:
			continue
		if effective_skip_lod1 and mi_lod_level == 1:
			continue
		if effective_skip_lod2 and mi_lod_level == 2:
			continue
		var dup: Mesh = mi.mesh.duplicate(true) as Mesh
		if dup == null:
			# Some imported mesh types (e.g. ImporterMesh) don't
			# duplicate cleanly; fall back to the original. Worst case
			# we hit the multi-surface bug for that asset.
			dup = mi.mesh
		# Per-mesh LOD level — drives the per-LOD shader boundaries
		# (lower / upper distance band with complementary dither). Each
		# LOD's surface materials all share the same boundaries.
		var bounds: Dictionary = _lod_boundaries(mi_lod_level, sp, lod_levels)
		var total_surfaces: int = dup.get_surface_count()
		# Classify each surface as close-tier or impostor-tier based
		# on vert count. Fab/Megascans tree .glbs ship LOD3 imposter
		# billboard cards as small-vert surfaces in the same mesh as
		# the high-detail bark+needle surfaces. We extract those small
		# surfaces into a separate ArrayMesh used at distance.
		var imposter_surfaces: Array = []  # Array of {arrays, src_mat}
		var blank_in_close: Array = []  # surfaces to blank in the close mesh
		if sp.min_surface_verts > 0:
			for s in dup.get_surface_count():
				if dup.surface_get_array_len(s) < sp.min_surface_verts:
					var arrays: Array = dup.surface_get_arrays(s)
					var src_mat: BaseMaterial3D = (
						mi.get_surface_override_material(s) as BaseMaterial3D)
					if src_mat == null:
						src_mat = mi.mesh.surface_get_material(s) as BaseMaterial3D
					imposter_surfaces.append(
						{"arrays": arrays, "src_mat": src_mat})
					blank_in_close.append(s)
		for s in dup.get_surface_count():
			if blank_in_close.has(s):
				# Replace with an empty material — keeps surface index
				# stable but renders nothing visible in the close mesh.
				# (We extracted this surface into the impostor mesh;
				# rendering it here would double up.)
				var blank := StandardMaterial3D.new()
				blank.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				blank.alpha_scissor_threshold = 1.0
				blank.albedo_color = Color(0, 0, 0, 0)
				dup.surface_set_material(s, blank)
				continue
			# Per-surface material precedence: MI's surface override
			# first (gltf importer parks per-surface mats here), then
			# fall through to whatever's on the mesh resource. Neither
			# path is guaranteed to be `StandardMaterial3D` — Fab
			# assets occasionally ship a different `BaseMaterial3D`
			# subtype, in which case we fall back to no textures + the
			# shader's defaults.
			var src_mat: BaseMaterial3D = (
				mi.get_surface_override_material(s) as BaseMaterial3D)
			if src_mat == null:
				src_mat = mi.mesh.surface_get_material(s) as BaseMaterial3D
			var sm := ShaderMaterial.new()
			sm.shader = shader
			if src_mat != null:
				sm.set_shader_parameter("albedo_tex", src_mat.albedo_texture)
				sm.set_shader_parameter("normal_tex", src_mat.normal_texture)
			sm.set_shader_parameter("trunk_anchor_height", sp.trunk_anchor_height)
			sm.set_shader_parameter("wind_amplitude_scale", sp.wind_amplitude_scale)
			# Live-tunable uniforms (albedo modulation + leaf grading).
			# Pushed via `_push_live_uniforms` so the same code path
			# fires both at spawn AND on the species's `changed`
			# signal (inspector edits propagate without rebuild).
			_push_live_uniforms(sm, sp)
			# Per-LOD distance band — the close-tier shader uses these
			# with a stable per-instance world-XZ hash to fade trees
			# individually across LOD boundaries (no tile-coordinated
			# pops, no see-through dither holes). See the long comment
			# block in `tree_dynamic.gdshader`.
			sm.set_shader_parameter(
				"lod_lower_boundary", bounds["lower"])
			sm.set_shader_parameter(
				"lod_upper_boundary", bounds["upper"])
			sm.set_shader_parameter(
				"lod_fade_half_width", lod_band_fade_m * 0.5)
			# Hard backstop past upper boundary + fade tail, so
			# instances that escape via numerical drift still get
			# culled.
			sm.set_shader_parameter(
				"max_render_distance_m",
				maxf(sp.max_render_distance_m, bounds["upper"] + lod_band_fade_m))
			# Register material for live updates from the species's
			# `changed` signal (see `_on_species_changed`).
			if not _species_shader_materials.has(species_path):
				_species_shader_materials[species_path] = []
			_species_shader_materials[species_path].append(sm)
			dup.surface_set_material(s, sm)
		dup_meshes.append(dup)
		# Renderable iff at least one surface didn't get extracted into
		# the impostor mesh. Multi-LOD species with `min_surface_verts > 0`
		# end up with a fully-blanked LOD3 dup mesh — its surfaces are
		# all the small billboard quads that moved into the impostor.
		var any_visible: bool = blank_in_close.size() < total_surfaces
		renderable.append(1 if any_visible else 0)
		# Build the per-variant impostor mesh from extracted surfaces.
		var imposter_mesh := ArrayMesh.new()
		for entry in imposter_surfaces:
			var arrays: Array = entry["arrays"]
			imposter_mesh.add_surface_from_arrays(
				Mesh.PRIMITIVE_TRIANGLES, arrays)
			var src_mat: BaseMaterial3D = entry["src_mat"]
			var imp_sm := ShaderMaterial.new()
			imp_sm.shader = imposter_shader
			if src_mat != null:
				imp_sm.set_shader_parameter(
					"albedo_tex", src_mat.albedo_texture)
				if src_mat.alpha_scissor_threshold > 0.0:
					imp_sm.set_shader_parameter(
						"alpha_scissor_threshold",
						src_mat.alpha_scissor_threshold)
			# Impostor shader is `unshaded`, so we don't get the
			# diffuse-darkening + AO + sky tint that the close-tier
			# `tree_dynamic.gdshader` gets through Godot's lighting
			# pipeline. Multiply species `albedo_modulation` by 0.7
			# to bring the impostor's average tone down to roughly
			# what the lit close-tier reads as in cascade_locks's
			# typical sky-light setup. Hue is preserved — only
			# brightness drops. Tune per species via the resource if
			# a particular asset's billboard has different baked
			# lighting than the rest.
			const IMPOSTER_LIGHT_FACTOR := 0.7
			imp_sm.set_shader_parameter("albedo_modulation", Vector3(
				sp.albedo_modulation.r * IMPOSTER_LIGHT_FACTOR,
				sp.albedo_modulation.g * IMPOSTER_LIGHT_FACTOR,
				sp.albedo_modulation.b * IMPOSTER_LIGHT_FACTOR))
			# Impostor's lower fade-in boundary matches the close-tier's
			# fade-out at `proxy_swap_distance_m` — same boundary value
			# + same `lod_fade_half_width` on both shaders → the
			# complementary discard rule (close-tier discards
			# `hash > alpha`, impostor discards `hash <= 1 - alpha`)
			# partitions instances disjointly. Every tree renders as
			# exactly one of {close LOD2, impostor} in the swap zone.
			imp_sm.set_shader_parameter(
				"lod_lower_boundary", sp.proxy_swap_distance_m)
			imp_sm.set_shader_parameter(
				"lod_fade_half_width", lod_band_fade_m * 0.5)
			# Impostor max-render derived from the species's own
			# `max_render_distance_m` so per-species pushes propagate
			# automatically. Cluster cards take over past this; the
			# impostor's per-instance upper fade (added in
			# `tree_imposter.gdshader`) smooths the cutoff over the
			# last `lod_band_fade_m` meters.
			imp_sm.set_shader_parameter("max_render_distance_m",
				maxf(sp.max_render_distance_m, 1000.0))
			var idx: int = imposter_mesh.get_surface_count() - 1
			imposter_mesh.surface_set_material(idx, imp_sm)
		imposter_meshes.append(imposter_mesh)
	root2.queue_free()
	_species_variant_meshes[species_path] = dup_meshes
	_species_imposter_meshes[species_path] = imposter_meshes
	_species_variant_bases[species_path] = bases
	_species_variant_lod_levels[species_path] = lod_levels
	_species_variant_renderable[species_path] = renderable
	# Vestigial — kept for legacy callers; meshes now own their
	# surface materials directly.
	_species_shader_mats[species_path] = []
	return true


## Compute the per-LOD distance band [lower, upper] for a species's
## given LOD level. Used for both:
## - the per-LOD shader uniforms (`lod_lower_boundary`,
##   `lod_upper_boundary`) that drive the per-instance world-hash
##   dither for smooth, tree-by-tree LOD transitions, AND
## - the per-MMI tile-vis range (widened by tile half-diagonal +
##   fade margin) that hard-culls whole tiles outside the band.
##
## The HIGHEST LOD level present for the species (e.g. LOD3 for Doug
## Fir, LOD0 for Birch) gets its upper boundary clamped to either
## `proxy_swap_distance_m` (if the species has impostors) or
## `max_render_distance_m` (if not), so the close-tier hands off to
## the impostor exactly where the impostor takes over.
##
## Returns Dictionary with keys `lower` (float, < 0 if no lower
## boundary) and `upper` (float, < 0 if no upper boundary).
func _lod_boundaries(lod_level: int, sp: TreeSpecies,
		all_lod_levels: PackedInt32Array) -> Dictionary:
	var min_lod := 999
	var max_lod := -1
	for lvl in all_lod_levels:
		if lvl < min_lod:
			min_lod = lvl
		if lvl > max_lod:
			max_lod = lvl
	var lower: float
	# Closest active LOD has no lower fade — renders down to camera.
	if lod_level <= min_lod:
		lower = -1.0
	else:
		lower = _band_end_for_lod(lod_level - 1, sp, max_lod)
	var upper := _band_end_for_lod(lod_level, sp, max_lod)
	return {"lower": lower, "upper": upper}


func _band_end_for_lod(lod_level: int, sp: TreeSpecies, max_lod: int) -> float:
	# The HIGHEST LOD's upper boundary is the close-tier→impostor swap
	# (or species max-render if no impostor). Lower LODs use the
	# inter-LOD boundaries from the static `lod_band_ends_m` array.
	if lod_level >= max_lod:
		if sp.proxy_swap_distance_m > 0.0:
			return sp.proxy_swap_distance_m
		if sp.max_render_distance_m > 0.0:
			return sp.max_render_distance_m
		return 1000.0  # last-resort fallback
	if lod_level < lod_band_ends_m.size():
		return lod_band_ends_m[lod_level]
	return lod_band_ends_m[lod_band_ends_m.size() - 1]


## Parse the LOD level encoded in a MeshInstance3D's name. Source
## glb assets follow `_LOD<N>` (Doug Fir: `douglas_fir_large_1_LOD0`,
## Birch: `Birch_5_LOD1_Birch_bark_0`). Default 0 if no `_LOD<N>`
## suffix is present (asset has only one LOD).
static func _parse_lod_level(name: String) -> int:
	var idx := name.find("_LOD")
	if idx < 0:
		return 0
	var n := 0
	var i := idx + 4
	while i < name.length():
		var c: int = name.unicode_at(i)
		if c < 0x30 or c > 0x39:
			break
		n = n * 10 + (c - 0x30)
		i += 1
	return n


## Compose the basis a node would have IF its scene were in the
## tree, by multiplying parent local bases up to (but not including)
## `root`. Use when you've `instantiate()`d a PackedScene off-tree
## and need a leaf's effective rotation/scale (e.g. the gltf
## importer's Z-up→Y-up parent on the SketchFab root node).
func _cumulative_basis(target: Node3D, root: Node) -> Basis:
	var b: Basis = target.transform.basis
	var p: Node = target.get_parent()
	while p != null and p != root:
		if p is Node3D:
			b = (p as Node3D).transform.basis * b
		p = p.get_parent()
	return b


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
	# `_spawn_tile` step (which creates one MultiMesh + collision body
	# per species per tile) and only write the disk cache. The runtime
	# spawns from cache when the player approaches. Without this, a
	# whole-map bake on a large map (`bull_run`, `mt_hood`,
	# `hood_river_valley`) would create hundreds of thousands of
	# MultiMesh RIDs and exhaust Godot's RID owner.
	if cache_enabled and not _bake_force_fresh and not cache_only:
		var cached: Dictionary = _try_load_tile_cache(tile)
		if not cached.is_empty():
			_spawn_tile_from_cache(tile, cached)
			return
	# Per-tile RNG hash, same shape as ground cover scatter for
	# consistency.
	var rng := RandomNumberGenerator.new()
	rng.seed = (
		(int(seed) * 73856093) ^
		(int(tile.x) * 19349663) ^
		(int(tile.y) * 83492791))
	var origin_x := float(tile.x) * tile_size_m
	var origin_z := float(tile.y) * tile_size_m
	var tile_area := tile_size_m * tile_size_m
	var raw_count := int(round(_max_trees_per_sq_m * tile_area * density_multiplier))
	var candidates := clampi(raw_count, 1, placements_per_tile_cap)
	var max_density := maxf(_max_trees_per_sq_m, 0.0001)
	var per_species_xforms: Dictionary = {}  # species_path → Array[Transform3D]
	# Per-tile placement positions for spatial-dedup spacing check.
	# Two species rolling the same XZ creates "co-located trees" —
	# visually one tree appears to animate IN AND OUT of another
	# (different species have different trunk_anchor_height, so the
	# species with anchor=1.5 sways through the species with
	# anchor=4.0's static lower trunk). Squared-distance compare is
	# fast enough to do per-candidate against a packed array.
	var placed_positions: PackedVector2Array = PackedVector2Array()
	var min_spacing_sq: float = 4.0 * 4.0  # 4 m minimum between trees
	for _i in candidates:
		var jx := rng.randf()
		var jz := rng.randf()
		var wx := origin_x + jx * tile_size_m
		var wz := origin_z + jz * tile_size_m
		var biome := _biome_at_world(wx, wz)
		if biome < 0 or not _biome_species_paths.has(biome):
			continue
		# Trees never spawn on the road biome — no exceptions, even
		# if someone accidentally wires a TreeBiomeConfig for biome 4.
		# Roads need clear sightlines for traversal + the splatmap's
		# road blur leaks ~5 m into adjacent biomes; without this
		# guard you get trees clipping through trail edges.
		if biome == 4:
			continue
		# Terrain Y at this candidate. Hoisted above the exclusion
		# checks because the zone test now needs full XYZ — see
		# `ProceduralExclusionZone._contains_world_xyz`. The height
		# is reused below for the actual placement, so no extra cost
		# in the accept path; rejection paths pay one heightmap
		# lookup that previously ran inside the spawn block.
		#
		# Slope-clipping: on slopes, sampling Y at the trunk center
		# alone leaves the trunk base floating on the downhill side
		# (terrain there sits BELOW the center sample). Sample 4
		# cardinals at ~1 m radius and take the lowest Y. The trunk
		# now buries on the uphill side and meets terrain on the
		# downhill — no float. On flat ground this collapses to the
		# center value (all samples equal) so flat-terrain placement
		# is unchanged. ~1 m is roughly the conservative trunk
		# radius for our largest species; species-aware radius could
		# come later if needed.
		var _y_c := _height_at_world(wx, wz)
		var _y_n := _height_at_world(wx, wz - 1.0)
		var _y_s := _height_at_world(wx, wz + 1.0)
		var _y_e := _height_at_world(wx + 1.0, wz)
		var _y_w := _height_at_world(wx - 1.0, wz)
		var y := minf(minf(minf(_y_c, _y_n), minf(_y_s, _y_e)), _y_w)
		# Procedural exclusion zones — POIs the user is hand-detailing.
		# `density_multiplier` returns 0.0 for full exclusion (default)
		# or a per-system thinning factor for soft-clearance zones
		# (e.g. towns). Folded into accept_p so a single bernoulli
		# rejects either hard or soft cases.
		var excl_mul: float = _ExclusionZoneRef.density_multiplier(
			get_tree(), wx, y, wz, "trees")
		if excl_mul <= 0.0:
			continue
		# Rock exclusion — big boulder species (`tree_exclusion_radius
		# > 0`) suppress trees that would clip into them. RockScatter
		# publishes per-tile exclusion arrays as it bakes; this query
		# is a tight squared-distance comparison against any rock tile
		# overlapping the candidate position. ~40 ops per call.
		#
		# Inlined (instead of `_RockScatterRef.is_point_excluded(...)`)
		# to bypass a Godot @tool quirk where calling `static func`
		# through a preload'd Script const can fail with "Nonexistent
		# function ... in base 'GDScript'" after hot-reload — the
		# static-method binding gets dropped on the stale Script. See
		# the same fix in ground_cover.gd.
		var _rock_excluded: bool = false
		for _rs in get_tree().get_nodes_in_group(&"rocks_tree_exclusion"):
			if _rs.has_method("_point_excluded") \
					and _rs._point_excluded(wx, wz):
				_rock_excluded = true
				break
		if _rock_excluded:
			continue
		# Soft road clearance: thin trees within `road_clearance_radius_m`
		# of any road pixel. Towns auto-clear because their dense road
		# networks raise the proximity score across the whole footprint.
		var road_score: float = _road_proximity_score(wx, wz)
		var road_factor: float = 1.0 - road_score * road_clearance_strength
		var biome_target: float = _biome_density.get(biome, 0.0)
		var accept_p := (biome_target / max_density) * excl_mul * road_factor
		if accept_p < 1.0 and rng.randf() > accept_p:
			continue
		if slope_cutoff > slope_thin_start:
			var slope := _slope_at_world(wx, wz)
			if slope >= slope_cutoff:
				continue
			if slope > slope_thin_start:
				var slope_t := (slope - slope_thin_start) / (slope_cutoff - slope_thin_start)
				var slope_keep := 1.0 - smoothstep(0.0, 1.0, slope_t)
				if rng.randf() > slope_keep:
					continue
		# Spatial-dedup: reject if too close to an already-placed
		# tree in this tile. Prevents two species rolling the same
		# XZ (different `trunk_anchor_height` per species → one
		# species's animated canopy sways through the other species's
		# static lower trunk — reads to the player as one motionless
		# tree with another animating one baked inside it).
		var too_close := false
		for prev in placed_positions:
			var dx := wx - prev.x
			var dz := wz - prev.y
			if dx * dx + dz * dz < min_spacing_sq:
				too_close = true
				break
		if too_close:
			continue
		var species_path := _pick_species(biome, rng.randf())
		if species_path.is_empty():
			continue
		# Cached species lookup — `load(path)` hits Godot's
		# ResourceLoader cache but still has function-call + type-cast
		# overhead. _bake_tile runs this hundreds of times per tile
		# (one per accepted placement) which adds up to a measurable
		# CPU spike during tile spawn. Local dict lookup is faster
		# and the cache lives for the whole session.
		var sp: TreeSpecies = _get_cached_species(species_path)
		if sp == null:
			continue
		# `y` was computed earlier (above the exclusion checks) for
		# the zone XYZ test; reuse here.
		var s := lerpf(sp.scale_min, sp.scale_max, rng.randf()) * sp.size_multiplier
		var basis := Basis().scaled(Vector3(s, s, s))
		if sp.random_yaw:
			basis = basis.rotated(Vector3.UP, rng.randf() * TAU)
		var xform := Transform3D(basis, Vector3(wx, y, wz))
		var arr: Array = per_species_xforms.get(species_path, [])
		arr.append(xform)
		per_species_xforms[species_path] = arr
		placed_positions.append(Vector2(wx, wz))
	if per_species_xforms.is_empty():
		if not cache_only:
			_baked_tiles[tile] = null
		return
	if cache_only:
		# Whole-map bake: skip _spawn_tile (which adds MultiMesh +
		# collision bodies to the scene) and only write the disk cache.
		# Avoids RID exhaustion on big maps (see _bake_tile docstring).
		if cache_enabled:
			_write_tile_cache(tile, per_species_xforms)
		return
	_baked_tile_placements[tile] = per_species_xforms
	var container := _spawn_tile(tile, per_species_xforms)
	_baked_tiles[tile] = container
	if cache_enabled:
		_write_tile_cache(tile, per_species_xforms)


func _spawn_tile(tile: Vector2i, per_species_xforms: Dictionary) -> Node3D:
	# Per-tile container. Visuals batch into one MultiMeshInstance3D
	# per (species, surface) — collapses thousands of per-tree draw
	# calls into a handful (one per bark / atlas surface). Collisions
	# stay individual (one StaticBody3D + CylinderShape3D per tree)
	# because the physics broadphase needs distinct bodies for the
	# CharacterBody3D's `move_and_slide` to push off, and the cylinder
	# is the cheapest shape we can give it. Branches/canopy never get
	# colliders — only the trunk.
	#
	# **Container positioned at tile center** — Godot's
	# `visibility_range_begin / _end` and per-MMI LOD selection both
	# use distance from camera to the MMI's world position. If the
	# container sits at the scatter's origin (typically world origin),
	# every MMI tests against that one point and the distant tier
	# (`min_render_distance_m > 0`) stays invisible whenever the
	# camera is near origin. Anchoring containers at their tile center
	# gives each MMI a meaningful self-position. Instance transforms
	# get stored RELATIVE to that center inside the MultiMesh.
	var container := Node3D.new()
	container.name = "TreeTile_%d_%d" % [tile.x, tile.y]
	var tile_center := Vector3(
		(float(tile.x) + 0.5) * tile_size_m,
		0.0,
		(float(tile.y) + 0.5) * tile_size_m)
	container.position = tile_center
	add_child(container)
	var spawn_collision_now := (enable_collision
		and _tile_in_collision_range(tile_center))
	var spawn_shadow_now := (cast_shadow
		and _tile_in_shadow_range(tile_center))
	var spawned_any := false
	for path in per_species_xforms.keys():
		if not _ensure_species_resources(path):
			continue
		var meshes: Array = _species_variant_meshes[path]
		var bases: Array = _species_variant_bases[path]
		var lod_levels: PackedInt32Array = (
			_species_variant_lod_levels.get(path, PackedInt32Array()))
		var renderable: PackedByteArray = (
			_species_variant_renderable.get(path, PackedByteArray()))
		var sp: TreeSpecies = _get_cached_species(path)
		var xforms: Array = per_species_xforms[path]
		if xforms.is_empty():
			continue
		_spawn_species_multimeshes(
			container, xforms, meshes, bases, lod_levels, renderable,
			sp, tile_center, spawn_shadow_now)
		if sp.proxy_swap_distance_m > 0.0:
			_spawn_species_proxy(
				_get_or_make_proxies_node(container),
				xforms, sp, tile_center)
		if (spawn_collision_now
				and sp.trunk_collision_radius > 0.0
				and sp.trunk_collision_height > 0.0):
			_spawn_species_collisions(
				_get_or_make_colliders_node(container),
				xforms, sp, tile_center)
		spawned_any = true
	if not spawned_any:
		container.queue_free()
		return null
	_baked_tile_collision[tile] = spawn_collision_now
	# Spawn-time shadow state is ALWAYS off (see the comment in
	# `_spawn_species_multimeshes`); `_refresh_shadows` flips it on
	# next frame if the tile is in range, paying the per-tile shadow-
	# caster registration cost rate-limited by `_SHADOW_FLIPS_PER_FRAME`
	# instead of stacking N tiles' worth of caster adds in the same
	# frame as a multi-tile rebuild.
	_baked_tile_shadow[tile] = false
	return container


func _tile_in_shadow_range(tile_center: Vector3) -> bool:
	if shadow_radius_m <= 0.0:
		return false
	var cam_xz := _last_player_xz
	if cam_xz.x == INF:
		# First frame: spawn with shadows so the first tile around the
		# player isn't shadow-less while we're waiting for the camera.
		return true
	var dx := tile_center.x - cam_xz.x
	var dz := tile_center.z - cam_xz.y
	return (dx * dx + dz * dz) <= shadow_radius_m * shadow_radius_m


## Cap how many tile shadow-state flips happen per frame. A flip
## toggles `cast_shadow` on every shadow-eligible MMI in the tile
## (LOD0 + LOD1 only — see the `shadow_eligible` gate in
## `_spawn_species_multimeshes`); typical forest tile is ~10–20
## MMIs after the LOD0/LOD1 filter.
##
## Cap at 1 flip per frame. The flip is now visually invisible — we
## moved the `shadow_radius_m` gate (default 100 m, off-threshold
## 130 m) outside Godot's `directional_shadow_max_distance` (80 m)
## so toggles happen in a region where the engine isn't rendering
## shadows for the tile anyway. As the tile then drifts into the
## engine's render zone, its `cast_shadow` flag is already set and
## shadows fade in via the engine's own shadow attenuation. No need
## to flip multiple tiles per frame to "keep up with the camera"
## anymore — the visual deadline is just "before the tile drifts
## into the engine shadow zone", which is many frames out at typical
## walking speeds.
const _SHADOW_FLIPS_PER_FRAME: int = 1
## Asymmetric hysteresis multiplier — tiles turn ON shadows at
## `shadow_radius_m`, but only turn OFF once they're past
## `shadow_radius_m * _SHADOW_OFF_HYSTERESIS`. Prevents tiles right
## at the boundary from flapping ON/OFF every camera step (the
## directional shadow map regenerates each flip → wasteful).
const _SHADOW_OFF_HYSTERESIS: float = 1.3


## Walk every baked tile and toggle `cast_shadow` on its MMI children
## based on whether the tile center is within `shadow_radius_m`.
## Called every frame from `_process` (NOT gated behind
## `rebuild_threshold_m` like `_refresh_collisions` is) so individual
## tiles toggle precisely when the camera crosses each one's boundary
## instead of all tiles that crossed since the last rebuild flipping
## together in one frame.
##
## Only direct-child MMIs (the close-tier surface MMIs) are toggled.
## Proxy MMIs live under a "Proxies" subnode and are intentionally
## kept OFF — distant impostors casting shadows looks worse than the
## absence of those shadows, and saves the shadow draw call cost.
static func _shadow_sort_by_distance(a: Dictionary, b: Dictionary) -> bool:
	return a["d_sq"] < b["d_sq"]


func _refresh_shadows(cam_xz: Vector2) -> void:
	if not cast_shadow:
		return
	if _baked_tiles.is_empty():
		return
	# Movement gate — skip the iteration entirely when the camera
	# hasn't moved enough to change any tile's shadow state. Saves
	# ~80 distance comps + a dict lookup per tile, every frame, when
	# the player is stationary or panning the view.
	if (cam_xz - _last_shadow_refresh_xz).length_squared() \
			< _SHADOW_REFRESH_MIN_MOVE * _SHADOW_REFRESH_MIN_MOVE:
		return
	_last_shadow_refresh_xz = cam_xz
	var on_radius_sq: float = shadow_radius_m * shadow_radius_m
	var off_radius: float = shadow_radius_m * _SHADOW_OFF_HYSTERESIS
	var off_radius_sq: float = off_radius * off_radius
	# **Two-pass distance-sorted refresh.** First pass: collect every
	# tile that needs to flip + its squared camera distance. Second
	# pass: sort by distance and flip the N closest. This guarantees
	# that the tile RIGHT IN FRONT of the player gets shadows before
	# tiles 100 m to either side — `_baked_tiles.keys()` iteration
	# order is insertion-order (effectively arbitrary), so the
	# previous round-robin would happily flip the far edge of the
	# shadow zone before the close edge → user "walks to the radius
	# edge" before the shadow they're staring at appears.
	#
	# Per-frame cost: O(active tiles) distance compute (~80 tiles,
	# trivial) + O(pending flips × log) sort. Way under a millisecond
	# even on dense forest.
	# Reuse the pooled `_shadow_pending` array — clear-and-reuse
	# instead of `var pending: Array = []` allocates a fresh Array
	# per frame plus N Dictionary entries inside it. The clear is
	# O(N) but typically frees a few-element array; the alloc-free
	# path is the win.
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
	# Use a static-func reference (cached Callable) instead of an
	# inline lambda — `sort_custom(func ... )` allocates a new
	# Callable closure on every frame's call, and `_refresh_shadows`
	# runs every frame. The static func has no closure state to
	# capture so the runtime can hand back the same Callable on
	# repeat references.
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
		for child in container.get_children():
			if not (child is MultiMeshInstance3D):
				continue
			# Only LOD0 + LOD1 MMIs are shadow-eligible (set at spawn
			# in `_spawn_species_multimeshes`). Skip the rest — flipping
			# their cast_shadow would just churn the renderer's caster
			# bookkeeping for zero shadow contribution.
			var lod_level: int = child.get_meta("lod_level", -1)
			if lod_level < 0 or lod_level > 1:
				continue
			(child as MultiMeshInstance3D).cast_shadow = new_mode
		_baked_tile_shadow[entry["tile"]] = should_have
		flips += 1


## Spawn the distant-tier impostor MMIs for one species in this tile.
## Uses the species's actual LOD3 billboard surfaces (extracted in
## `_ensure_species_resources` from the small-vert surfaces of each
## variant mesh) so the impostor reads as the real tree's silhouette,
## not a generic cone. Shares per-instance transforms with the
## close-tier MMIs so walking toward a distant tree finds the high-
## detail Doug Fir at exactly the same world-XYZ. Per-instance
## distance cull in the impostor shader handles the close↔proxy
## handoff (collapses any instance closer than `proxy_swap_distance_m`
## from the camera).
func _spawn_species_proxy(parent: Node3D, xforms: Array,
		sp: TreeSpecies, tile_center: Vector3) -> void:
	if sp.proxy_swap_distance_m <= 0.0:
		return
	var imposter_meshes: Array = _species_imposter_meshes.get(
		sp.resource_path, [])
	if imposter_meshes.is_empty():
		return
	var bases: Array = _species_variant_bases.get(sp.resource_path, [])
	for i in imposter_meshes.size():
		var mesh: Mesh = imposter_meshes[i] as Mesh
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var surface_basis: Basis = bases[i] if i < bases.size() else Basis.IDENTITY
		var surface_xform := Transform3D(surface_basis, Vector3.ZERO)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.use_custom_data = false
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for j in xforms.size():
			var placement: Transform3D = xforms[j]
			var local := placement * surface_xform
			local.origin -= tile_center
			mm.set_instance_transform(j, local)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		# Per-surface materials baked onto the impostor mesh handle
		# albedo + the per-instance distance cull. No
		# `material_override` here — that would replace ALL surfaces
		# (we want each impostor surface's own material to drive the
		# texture binding).
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# No MMI-level visibility range — the per-instance distance
		# cull in `tree_imposter.gdshader` is precise. Tile-level
		# visibility hard-popped tiles in/out as the camera crossed
		# boundaries, causing see-through gaps. Always-submit + shader
		# cull is more stable.
		parent.add_child(mmi)


## Returns true if a tile centered at `tile_center` is close enough to
## the camera that its trunk colliders should exist this frame. Used
## both at spawn time (skip building) and by `_refresh_collisions`
## (decide whether to add/remove an existing tile's Colliders node).
func _tile_in_collision_range(tile_center: Vector3) -> bool:
	if collision_radius_m <= 0.0:
		return false
	var cam_xz := _last_player_xz
	if cam_xz.x == INF:
		return false
	var dx := tile_center.x - cam_xz.x
	var dz := tile_center.z - cam_xz.y
	return (dx * dx + dz * dz) <= collision_radius_m * collision_radius_m


## All colliders for a tile live under one "Colliders" Node3D — lets
## us mass-free them with a single `queue_free()` when the tile drops
## out of `collision_radius_m`, and keeps the visual MMI children
## untouched.
func _get_or_make_colliders_node(container: Node3D) -> Node3D:
	var existing: Node3D = container.get_node_or_null("Colliders") as Node3D
	if existing != null:
		return existing
	var node := Node3D.new()
	node.name = "Colliders"
	container.add_child(node)
	return node


## All proxy (impostor) MMIs for a tile live under "Proxies". Two
## reasons to keep them out of the container's direct children:
## - `_refresh_shadows` iterates direct-child MMIs and toggles
##   cast_shadow; nesting under "Proxies" excludes them (they stay
##   off, which is what we want).
## - Lets us identify "is this MMI close-tier or impostor" by parent
##   if we ever need to.
func _get_or_make_proxies_node(container: Node3D) -> Node3D:
	var existing: Node3D = container.get_node_or_null("Proxies") as Node3D
	if existing != null:
		return existing
	var node := Node3D.new()
	node.name = "Proxies"
	container.add_child(node)
	return node




func _spawn_species_multimeshes(parent: Node3D, xforms: Array,
		meshes: Array, bases: Array, lod_levels: PackedInt32Array,
		renderable: PackedByteArray, sp: TreeSpecies,
		tile_center: Vector3, cast_shadow_now: bool) -> void:
	for i in meshes.size():
		var mesh: Mesh = meshes[i] as Mesh
		if mesh == null:
			continue
		# Skip dup meshes whose every surface was extracted into the
		# impostor (LOD3 of multi-LOD species). Creating the MMI +
		# uploading 1024 instance transforms only to render zero
		# pixels is the dominant per-tile spawn cost; skipping these
		# cuts MMI count per multi-LOD species from 4 to 3 (25 % of
		# total spawn work).
		if i < renderable.size() and renderable[i] == 0:
			continue
		var lod_level: int = lod_levels[i] if i < lod_levels.size() else 0
		var surface_basis: Basis = bases[i] if i < bases.size() else Basis.IDENTITY
		var surface_xform := Transform3D(surface_basis, Vector3.ZERO)
		var mm := MultiMesh.new()
		# Order matters for MultiMesh setup: format → flags → mesh →
		# instance_count → per-instance transforms. Setting
		# instance_count resets all transform slots; everything before
		# it is configuration that resizes / re-allocates if changed.
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.use_custom_data = false
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for j in xforms.size():
			# Compose: tree placement * (variant basis offset). The
			# basis offset bakes in the gltf importer's parent rotation
			# (Z-up → Y-up), which the per-MeshInstance3D path applied
			# via `mi.basis = bases[i]`. MultiMesh has no per-instance
			# parent, so fold it into the instance transform.
			# Subtract `tile_center` so the stored transforms are local
			# to the container (which sits at `tile_center`); see the
			# big comment in `_spawn_tile`.
			var placement: Transform3D = xforms[j]
			var local_xform := placement * surface_xform
			local_xform.origin -= tile_center
			mm.set_instance_transform(j, local_xform)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		# Tile-MMI visibility = COARSE pre-cull. The shader handles the
		# fine per-instance LOD selection + smooth crossfade via a
		# stable world-XZ hash (see `tree_dynamic.gdshader`). The
		# tile-MMI vis just hides whole tiles whose center is far
		# enough outside this LOD's band that NO instance in the tile
		# could be in-band.
		#
		# The pre-cull range is widened by `_tile_half_diag` (the max
		# distance from tile-center to any instance in the tile) +
		# `lod_band_fade_m` (the fade tail) so we don't accidentally
		# cull a tile whose corner instances should still render.
		#
		# **Hard fade mode** — engine fade is DISABLED here. Engine
		# fade was the source of the LOD see-through (independent
		# screen-space hashes per MMI coincide → holes); the per-
		# instance shader dither replaces it cleanly.
		var bounds: Dictionary = _lod_boundaries(
			lod_level, sp, lod_levels)
		var tile_half_diag: float = tile_size_m * 0.7071
		var lower_bound: float = bounds["lower"]
		var upper_bound: float = bounds["upper"]
		if lower_bound >= 0.0:
			mmi.visibility_range_begin = maxf(
				lower_bound - tile_half_diag - lod_band_fade_m, 0.0)
			mmi.visibility_range_begin_margin = 0.0
		else:
			mmi.visibility_range_begin = 0.0
			mmi.visibility_range_begin_margin = 0.0
		if upper_bound >= 0.0:
			mmi.visibility_range_end = (
				upper_bound + tile_half_diag + lod_band_fade_m)
			mmi.visibility_range_end_margin = 0.0
		else:
			mmi.visibility_range_end = 0.0  # 0 = no upper limit
			mmi.visibility_range_end_margin = 0.0
		mmi.visibility_range_fade_mode = (
			GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED)
		# Per-species LOD bias. Multiplies the engine's mesh LOD
		# threshold; higher = lower LODs picked closer to the camera.
		# Only matters if the mesh has LODs (Godot import → Generate
		# LODs, or source .glb shipped them).
		if sp.lod_bias > 0.0 and not is_equal_approx(sp.lod_bias, 1.0):
			mmi.lod_bias = sp.lod_bias
		# Tag the MMI with its LOD level so `_refresh_shadows` can
		# filter to only shadow-eligible MMIs (LOD0 + LOD1) instead of
		# toggling cast_shadow on every LOD MMI in the tile. The tag
		# stays with the MMI for its lifetime; cheaper than parsing
		# the node name or looking up by index.
		mmi.set_meta("lod_level", lod_level)
		# Spawn-time cast_shadow is ALWAYS OFF (even for shadow-
		# eligible LODs in shadow range). `_refresh_shadows` runs
		# every frame with a per-frame flip cap — letting it flip
		# new tiles ON one-at-a-time costs a few extra frames of
		# delayed shadow vs. spawning many tiles cast_shadow=ON in
		# one frame, which slams the directional shadow map's caster
		# bookkeeping with N tiles' worth of new entities at once.
		# (`cast_shadow_now` is no longer used here; kept as a param
		# for the function signature stability.)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)


func _spawn_species_collisions(parent: Node3D, xforms: Array,
		sp: TreeSpecies, tile_center: Vector3) -> void:
	# One StaticBody3D + CylinderShape3D per tree, anchored at the
	# trunk base. Trunk-only by design — no canopy/branch colliders,
	# no trimesh from the visual mesh. Cylinder is the cheapest shape
	# the physics broadphase can test against; CharacterBody3D's
	# `move_and_slide` pushes off it cleanly without needing a tighter
	# fit.
	#
	# `sp.trunk_collision_radius` / `_height` are the unit-scale values
	# (size_multiplier=1, jitter=1). The per-instance scale lives in
	# `xf.basis` (uniform Vector3(s,s,s) for trees — see _spawn_tile);
	# multiply both dimensions by it so the collider tracks the visual
	# MultiMesh transform.
	#
	# Body positions are LOCAL to `parent` (which sits at
	# `tile_center`). `xf.origin` is world coords from the bake, so we
	# subtract `tile_center` to land back in tile-local space. Basis
	# stays IDENTITY: yaw is irrelevant on a vertical cylinder and a
	# rotated cylinder would surprise the broadphase.
	for xf in xforms:
		var s: float = xf.basis.get_scale().x
		var radius: float = sp.trunk_collision_radius * s
		var height: float = sp.trunk_collision_height * s
		if radius <= 0.0 or height <= 0.0:
			continue
		var body := StaticBody3D.new()
		var world_pos: Vector3 = xf.origin + Vector3(0.0, height * 0.5, 0.0)
		body.transform = Transform3D(Basis.IDENTITY, world_pos - tile_center)
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = radius
		cyl.height = height
		cs.shape = cyl
		body.add_child(cs)
		parent.add_child(body)


# --- Species pick (cumulative-weight RNG, no clumping for trees) ---

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


# --- Biome / slope / height sampling ---

func _biome_at_world(wx: float, wz: float) -> int:
	# Splatmap A is RGBA, channels: R=Forest, G=Grassland, B=Cropland,
	# A=Bare. Roads live in a SEPARATE `road_density.rgba8` file
	# (loaded into `_splat_road`) — RGBA channels are different road
	# tiers (paved / trail / dirt etc.); take the max across channels
	# so any road-class hit suppresses trees regardless of which
	# tier matched.
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
	# Road check across all 4 channels of road_density.rgba8 — narrow
	# trail features (a 4 m trail spans only 2 splat texels at 2 m
	# spacing) often have one channel dominant and others near zero,
	# so max across channels catches every tier. Sample the trunk
	# position AND `road_buffer_m` cardinal offsets so canopy
	# overhang is also rejected (a trunk on grass right next to a
	# road would otherwise overhang the road).
	if _max_road_density_with_buffer(wx, wz) > road_threshold:
		return 4
	# Pick dominant biome channel.
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
		return -1  # all channels low → no clear biome
	return best


# Sample road density at the candidate position AND four cardinal
# offsets at `road_buffer_m`. Returns the max value across all five
# samples — any nearby road pixel suppresses the candidate. Models
# the tree's canopy radius: a trunk on grass right next to a road
# would otherwise overhang the road, even though the trunk-position
# road check returns "not road". 5 samples × 4 byte reads each = 20
# byte reads per candidate, cheap.
func _max_road_density_with_buffer(wx: float, wz: float) -> int:
	if _splat_road.size() == 0:
		return 0
	var max_rd: int = _road_density_at(wx, wz)
	if road_buffer_m > 0.0:
		max_rd = maxi(max_rd, _road_density_at(wx + road_buffer_m, wz))
		max_rd = maxi(max_rd, _road_density_at(wx - road_buffer_m, wz))
		max_rd = maxi(max_rd, _road_density_at(wx, wz + road_buffer_m))
		max_rd = maxi(max_rd, _road_density_at(wx, wz - road_buffer_m))
	return max_rd


# Soft road-clearance score (0.0–1.0) sampled from `_splat_road` at
# 8 ring offsets within `road_clearance_radius_m`. Each sample's
# road density (max across road tiers) is weighted by its inverse
# distance from the candidate — closer samples count more. Returns
# in [0, 1] where 1 = sitting on a road pixel, 0 = no road within
# the clearance radius. Caller multiplies its accept_p by
# `(1 - score * road_clearance_strength)`.
#
# Cost: 1 (center) + 8 (ring) = 9 splat reads per candidate. ~2 µs
# per candidate; ~1-2 ms per tile bake at typical density. Cheap.
func _road_proximity_score(wx: float, wz: float) -> float:
	if _splat_road.size() == 0 or road_clearance_radius_m <= 0.0:
		return 0.0
	var r: float = road_clearance_radius_m
	# Center weight = 1.0; ring at full radius weight = 0.0
	# (linear). Sum of 8 ring samples × 0.5 weight = 4.0 max ring
	# contribution; +1.0 center. Normalize against that.
	var center: float = float(_road_density_at(wx, wz)) / 255.0
	# Ring at half-radius (heavier weight) and full radius (lighter).
	var inner_r: float = r * 0.5
	var samples_inner: float = (
		float(_road_density_at(wx + inner_r, wz))
		+ float(_road_density_at(wx - inner_r, wz))
		+ float(_road_density_at(wx, wz + inner_r))
		+ float(_road_density_at(wx, wz - inner_r))) / (255.0 * 4.0)
	# Diagonal full-radius samples — catches roads on the diagonals
	# that the cardinal ring at inner_r might miss.
	var diag: float = r * 0.7071
	var samples_outer: float = (
		float(_road_density_at(wx + diag, wz + diag))
		+ float(_road_density_at(wx + diag, wz - diag))
		+ float(_road_density_at(wx - diag, wz + diag))
		+ float(_road_density_at(wx - diag, wz - diag))) / (255.0 * 4.0)
	# Weighted average: center (1.0) > inner (0.6) > outer (0.25).
	# Sum of weights = 1.0 + 0.6 + 0.25 = 1.85. Normalize to [0, 1].
	var score: float = (center + samples_inner * 0.6 + samples_outer * 0.25) / 1.85
	return clampf(score, 0.0, 1.0)


# Returns the maximum "human presence" density at a point: max across
# all road tiers (`_splat_road` 4 channels) PLUS the BuiltUp channel
# (`_splat_b` channel G). Treating BuiltUp like roads means town
# footprints — which are tagged with BuiltUp but often don't have
# road pixels through their CENTER — also trigger the road-clearance
# falloff. Without this, settlements with sparse roads (a single
# central road + outlying buildings) leave the building areas tagged
# as forest in the argmax → trees spawn through people's houses.
func _road_density_at(wx: float, wz: float) -> int:
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
	# BuiltUp channel (splat_b G) — town footprints. Treated as
	# equivalent to road density for the clearance falloff.
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
	# Bilinear-sample the canonical heightmap.r32 first — it's a
	# byte-array lookup (~50 ns) vs `Terrain3D.data.get_height` (~5–10
	# μs per call). With ~5 height queries per candidate × thousands
	# of candidates × multiple tiles per frame in `_bake_tile`, the
	# Terrain3D query path was dominating the main thread (>300 ms /
	# frame on dense bakes). The canonical heightmap IS the source of
	# Terrain3D's elevation data so they agree to within float
	# precision; sampling it directly avoids the round-trip.
	#
	# Terrain3D fallback is kept for the rare case where the canonical
	# bytes haven't loaded yet (early-spawn races).
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


# Decode one f32 sample (literal meters above sea level) from the
# canonical `.r32` byte buffer. Format-version-2; v1 used u16 and
# `vert_min/max` linear remap.
func _sample_f32_meters(x: int, z: int) -> float:
	return _hm_bytes.decode_float((z * _terrain_w + x) * 4)


func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


# --- Persistent bake cache (raw FileAccess bytes — same format as
# foliage scatter, just storing per-species lists of Transform3D).

const _CACHE_FORMAT_VERSION: int = 1
var _cache_magic: PackedByteArray = PackedByteArray([0x54, 0x52, 0x42, 0x4B])  # "TRBK"


func _compute_cache_key() -> String:
	# **Stable cache key**: only `cache_version` + `seed`. We deliberately
	# DON'T include densities, slope filters, biome contents, species
	# params, or terrain content — those would invalidate the cache on
	# any balance tweak and re-bake the whole map mid-session, which
	# defeats the purpose of caching. Bump `cache_version` (or click
	# "Clear placement cache" + re-bake) when an intentional re-roll
	# is desired.
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
	return "res://assets/foliage_bake/%s/trees/%s" % [map_id, key]


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


func _write_tile_cache(tile: Vector2i, per_species_xforms: Dictionary) -> void:
	var key := _get_cache_key()
	var entries: Array = []
	for path in per_species_xforms.keys():
		var xforms: Array = per_species_xforms[path]
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
		entries.append({"species_path": path, "transforms": t_flat})
	var data := {"cache_key": key, "tile": [tile.x, tile.y], "entries": entries}
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
		var t_flat: PackedFloat32Array = e.get("transforms", PackedFloat32Array())
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
		per_species[sp_path] = xforms
	_baked_tile_placements[tile] = per_species
	_baked_tiles[tile] = _spawn_tile(tile, per_species)


func _bake_cache_near_origin() -> void:
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[trees] cannot bake cache: terrain not loaded")
		return
	if _biome_species_paths.is_empty():
		_build_species_table()
		if _biome_species_paths.is_empty():
			return
	# Center the prebake on the camera position (editor camera in
	# editor, scene camera at runtime), falling back to world origin
	# if no camera resolves. The function's old name was a misnomer
	# — baking purely around (0,0) only helps if the player spawns
	# near origin. For any sized map, walking elsewhere hit cold tiles
	# and produced visible per-tile spawn pops.
	var center_xz := Vector2.ZERO
	var cam: Camera3D = null
	if Engine.is_editor_hint():
		cam = _get_editor_camera()
	else:
		cam = _camera
	if cam != null:
		center_xz = _xz(cam.global_position)
	var center_tile := Vector2i(
		int(round(center_xz.x / tile_size_m)),
		int(round(center_xz.y / tile_size_m)))
	var prev := _bake_force_fresh
	_bake_force_fresh = true
	var radius_tiles := int(ceil(prebake_radius_m / tile_size_m))
	var n := 0
	var total := (radius_tiles * 2 + 1) * (radius_tiles * 2 + 1)
	print("[trees] baking cache: center=%s radius=%.0fm (%d tiles, key=%s)..."
		% [center_tile, prebake_radius_m, total, _get_cache_key()])
	for tz in range(-radius_tiles, radius_tiles + 1):
		for tx in range(-radius_tiles, radius_tiles + 1):
			var tile := Vector2i(center_tile.x + tx, center_tile.y + tz)
			if _baked_tiles.has(tile):
				var existing: Node3D = _baked_tiles[tile]
				if is_instance_valid(existing):
					existing.queue_free()
				_baked_tiles.erase(tile)
				_baked_tile_placements.erase(tile)
				_baked_tile_collision.erase(tile)
				_baked_tile_shadow.erase(tile)
			_bake_tile(tile)
			n += 1
			if n % 50 == 0:
				print("[trees]   %d / %d tiles..." % [n, total])
	_bake_force_fresh = prev
	print("[trees] bake cache complete: %d tiles → %s/" % [
		n, _cache_dir_for_map(_get_cache_key())])


# Bake EVERY tile inside the active terrain regions. Use this once
# per map to fully populate the disk cache so gameplay never hits an
# on-demand bake — every tile loads from disk. Logs progress every
# ~5 % of total tiles, plus elapsed time + ETA + recent rate.
func _bake_cache_whole_map() -> void:
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[trees] cannot bake whole map: terrain not loaded")
		return
	if _biome_species_paths.is_empty():
		_build_species_table()
		if _biome_species_paths.is_empty():
			return
	_resolve_terrain3d()
	if _terrain3d == null:
		push_warning("[trees] cannot bake whole map: Terrain3D node not resolved")
		return
	# Read terrain bounds from active Terrain3D regions. Mirrors the
	# pattern used in tree_coverage_baker / tree_cluster_scatter.
	var region_size_verts: int = int(_terrain3d.get("region_size"))
	var vertex_spacing: float = float(_terrain3d.get("vertex_spacing"))
	var region_size_m := float(region_size_verts) * vertex_spacing
	var regions: Array = _terrain3d.data.get_regions_active()
	if regions.is_empty():
		push_warning("[trees] cannot bake whole map: no active Terrain3D regions")
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
	# Print every ~5 % of progress (or every 50 tiles, whichever is
	# smaller) so the cadence stays reasonable across map sizes.
	var print_every: int = maxi(1, mini(50, total / 20))
	print("[trees] bake whole map: %d × %d tiles (%d total), bounds %.0f×%.0f m, key=%s"
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
				print("[trees]   %d / %d (%.1f%%) — %.1fs elapsed, %.1f tiles/s, ETA %.0fs"
					% [n, total, pct, elapsed_s, rate, eta_s])
	_bake_force_fresh = prev
	var t_end: int = Time.get_ticks_msec()
	var total_s: float = float(t_end - t_start) / 1000.0
	print("[trees] bake whole map COMPLETE: %d tiles in %.1fs (%.1f tiles/s avg) → %s/"
		% [n, total_s, float(n) / maxf(total_s, 0.001),
		_cache_dir_for_map(_get_cache_key())])


func _clear_cache_for_map() -> void:
	var root := "res://assets/foliage_bake/%s/trees" % map_id
	var n := _delete_dir_recursive(root)
	print("[trees] cleared %d cache files from %s" % [n, root])


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
