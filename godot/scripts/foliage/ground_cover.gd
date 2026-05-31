@tool
class_name GroundCoverScatter
extends Node3D
## Tile-based ground-cover scatter with GPU view-cone culling.
##
## Per-frame approach:
## - Player position is quantized to tiles (`tile_size_m` square).
## - When the player crosses a tile boundary, the active tile set is
##   recomputed: new tiles are baked, leaving tiles are freed.
## - Each tile's placements are deterministic — `hash(tile_x, tile_z)`
##   seeds an RNG; same tile coords always produce the same plants.
## - Per-instance random rolls are written to MultiMesh `INSTANCE_CUSTOM`.
##   The shader (`ground_cover_dynamic.gdshader`) reads the camera
##   forward each frame and culls instances whose roll exceeds the
##   per-position view-cone density. CPU does no per-frame work
##   beyond the tile-cross check.
##
## Decoupled from any terrain node — reads the canonical bake artifacts
## directly from disk by `map_id`:
##   res://assets/terrain/<map_id>/terrain.toml
##                                 heightmap.r32
##                                 splatmap_a.rgba8
##                                 splatmap_b.rgba8
##                                 road_density.rgba8 (optional)
##
## Splatmap channel layout (canonical source-of-truth: `simn-terrain`'s
## bake output — the files this script reads):
##   splat_a (RGBA) → Forest | Grassland | Water | Cropland
##   splat_b (RGBA) → Bare | BuiltUp | Cliff | Snow
##   road    (RGBA) → Paved | Unpaved | Trail | (unused)
##
## Terrain is assumed to be CENTERED — world (0, 0) at terrain center,
## extent = (W - 1) * spacing on each axis (matches the `simn-terrain`
## extent convention used everywhere else in the codebase).

const SHADER: Shader = preload("res://shaders/ground_cover_dynamic.gdshader")

# Stable script ref for static-method dispatch on
# `ProceduralExclusionZone.density_multiplier(...)`. Direct
# `ProceduralExclusionZone.foo()` calls are unsafe in `@tool` context
# (class_name registry can be stale across reloads).
#
# `RockScatter.is_point_excluded(...)` was previously called via a
# similar const ref; we inline the group iteration in `_bake_tile`
# now because static-method dispatch through a preload const can
# silently lose binding after hot-reload (Godot prints "Nonexistent
# function ... in base 'GDScript'"). Instance dispatch via
# `has_method` is unaffected.
const _ExclusionZoneRef := preload("res://scripts/procedural_exclusion_zone.gd")

## Logical map id; matches the subdirectory under res://assets/terrain/.
@export var map_id: String = "cascade_locks"

## Path to the player Camera3D. If empty, we look up by group "player"
## and use its first Camera3D child. Required at runtime.
@export_node_path("Camera3D") var camera_path: NodePath

## Optional path to the Terrain3D node rendering this map. When set,
## Y placement uses `terrain.data.get_height(world_pos)` so foliage
## sits on the same surface Terrain3D renders. When empty, falls
## back to direct `heightmap.r32` sampling — fine for the Rust
## `TerrainNode` path or any future renderer whose surface is
## guaranteed to match the canonical bake byte-for-byte.
##
## Why we need this: Terrain3D's region grid snaps imports to
## region boundaries, applies its own vertex_spacing math, and
## (depending on bake settings) may carry a height offset. The raw
## `.r16` Y values are what we *put in*, but the visual surface is
## whatever Terrain3D *renders*, and those can drift apart. Sampling
## via the API guarantees foliage matches the surface.
# Type-filtered against Node3D rather than Terrain3D so the script
# parses even when the Terrain3D extension hasn't loaded yet (cold
# editor open, headless `--check-only`). Runtime cast in
# `_resolve_terrain3d` still narrows to the actual node.
@export_node_path("Node3D") var terrain3d_path: NodePath

## Per-biome species configs. Order doesn't matter; each `BiomeSpeciesConfig`
## declares its own `biome` id.
@export var biome_configs: Array[BiomeSpeciesConfig] = []

## Optional `FoliageGlobals` resource. When set, its values are
## pushed to the RenderingServer every frame in editor mode and once
## in `_ready` at runtime — so the wind / view-cone / distance
## controls become live-tunable inspector knobs rather than
## project-settings boot defaults. Falls back to `project.godot`
## `[shader_globals]` when null.
@export var globals: FoliageGlobals = null

@export_group("Scatter density")
## Square tile edge length (meters). Smaller = more MMIs but tighter
## culling; larger = fewer draws but wasted bakes when player crosses.
@export_range(4.0, 64.0, 1.0) var tile_size_m: float = 16.0

## Hard ceiling on candidate placements per tile (safety bound). The
## actual count is computed from the biome densities:
##   `min(placements_per_tile_cap, max(plants_per_sq_m) × tile_area
##        × density_multiplier)`
## At tile_size_m = 16 (256 m²), 1008 ≈ 4 plants/m² before the cap
## kicks in — the on-map sweet spot per cascade-locks tuning.
@export_range(16, 8192, 16) var placements_per_tile_cap: int = 1008

## Active tile radius (meters). Tiles whose center is outside this radius
## from the player are freed. Should be ≥ `gc_radius_front` shader global
## (default 60 m) plus a half-tile buffer.
@export_range(8.0, 200.0, 1.0) var active_radius_m: float = 120.0

## Player movement threshold (meters) before the active tile set is
## recomputed. Larger = fewer rebuilds but more pop-in lag.
@export_range(0.5, 32.0, 0.5) var rebuild_threshold_m: float = 4.0

## Max number of tiles to bake per frame. The full rebuild only
## queues which tiles to bake/free; the actual bake work happens
## one tile per frame (or up to this many). Larger = fewer frames
## of pop-in after a tile-cross, smaller = smoother frame time at
## the cost of a longer settle window. Set 0 to bake the entire
## queue synchronously each rebuild (the old behaviour, may stutter
## with high-density biomes).
@export_range(0, 32, 1) var bake_per_frame_budget: int = 3

## Number of species to pre-warm per frame during scene init. Pre-warming
## calls `_ensure_species_resources()` (loads the GLB scene, builds the
## ShaderMaterial, uploads textures to GPU) for every species in
## `_species_table` BEFORE the first tile bake runs — front-loading
## the asset-load cost so the player doesn't see hitches when walking
## into tiles whose species haven't been encountered yet. With 40+
## species per biome and ~2 MB embedded textures each, on-demand
## loading produced visible hitches every time a tile rolled in a
## fresh species. Set 0 to disable (legacy on-demand behaviour).
@export_range(0, 32, 1) var prewarm_per_frame_budget: int = 4

## Master density multiplier — scales every biome's
## `plants_per_sq_m` at scatter time. 1.0 = use the per-biome
## values as configured. Drop to dial overall foliage down across
## the whole map (perf testing, "what does this map look like
## without grass"); raise to push past per-biome targets without
## editing every biome `.tres` (lush summer mode).
##
## Per-biome and per-species control still happens in the biome
## `.tres` files themselves (`species_paths`, `species_densities`,
## `plants_per_sq_m`). This slider is the cheap whole-map knob on
## top of those.
##
## **Edit triggers a tile rebuild on the next camera-cross** —
## click "Rebuild tiles" to apply immediately.
@export_range(0.0, 4.0, 0.01) var density_multiplier: float = 1.0

@export_subgroup("Clumping")
## How strongly species clump into patches instead of being uniformly
## random per candidate. 0 = uniform RNG (no clumping — every plant is
## independently sampled from the biome's species mix). 1 = noise
## fully modulates effective weights (strong patches). Default 0.6
## reads as natural meadow / understory clumping without losing
## within-cluster variety.
@export_range(0.0, 2.0, 0.05) var species_clumping: float = 0.0

## Patch size knob — frequency of the per-species noise field.
## ~1/cell_size_m. 0.05 = ~20 m patches, 0.1 = ~10 m, 0.02 = ~50 m.
## Smaller frequency = wider patches.
@export_range(0.005, 0.5, 0.005) var species_clumping_freq: float = 0.05

@export_subgroup("Road clearance")
## Soft road-clearance falloff radius (m). Within this distance of a
## road pixel, ground-cover density thins smoothly. Pairs with the
## existing road→ROAD biome routing in `_biome_at_world` (which
## handles ON-road pixels) for a gentler "near-roads-but-not-on" thin.
##
## 0 disables (default — biome routing alone is usually sufficient
## for ground cover, since towns SHOULD stay grassy unlike trees /
## big rocks). Bump to ~12 m if towns still feel too lush around
## road shoulders. Cost ~9 splat byte reads per candidate.
@export_range(0.0, 40.0, 1.0) var road_clearance_radius_m: float = 0.0
## Strength of the soft road clearance falloff. 1.0 = full kill at
## road center; 0.4 = gentle thin (towns visibly less grassy but
## still alive). Only used when `road_clearance_radius_m > 0`.
@export_range(0.0, 1.0, 0.05) var road_clearance_strength: float = 0.4

@export_subgroup("Slope")
## Slope above which foliage starts to thin. Expressed as the
## tangent of the slope angle (rise/run). 0.6 ≈ 31°, 1.0 = 45°.
## Below this, full density per biome; above the cutoff, zero.
@export_range(0.0, 4.0, 0.05) var slope_thin_start: float = 0.6
## Slope at which foliage is fully suppressed. Smoothstep ramps
## acceptance from 1.0 at `slope_thin_start` down to 0.0 at this
## value. The splatmap doesn't always know about slopes — this
## kicks foliage off steep faces even where the splat says "forest".
@export_range(0.0, 4.0, 0.05) var slope_cutoff: float = 1.4

@export_group("Determinism")
## Master seed; combined with tile coords for placement RNG.
@export var seed: int = 1337

## How many distinct variants of each species can appear in one tile.
## Default 1 = the perf-optimal "all instances of species X in tile Y
## are the same variant" mode (~12 MMIs per tile, big draw-call win).
## Set to 2–3 if the per-tile-variant uniformity reads as obvious
## "rows of identical plants" — adds proportional MMI cost (one MMI
## per (species, variant), so 2 doubles your bucket count) but breaks
## up the visual repetition. 8+ effectively re-enables per-instance
## variety at ~7× the draw calls.
@export_range(1, 8, 1) var variants_per_tile: int = 1

@export_group("Persistent bake cache")
## When true, runtime bakes write their results to
## `res://assets/foliage_bake/<map_id>/<cache_key>/<tx>_<tz>.bin` so
## subsequent visits to the same tile load from disk instead of
## re-running the bake. ~100× faster on cache hits.
##
## **Stable cache key**: only `cache_version` + `seed`. Tweaking
## densities, biome configs, species params, slope filters, terrain
## content does NOT invalidate cache — balance tweaks don't shuffle
## in-session bakes. Bump `cache_version` (or click Clear + Bake)
## when an intentional re-roll is wanted.
@export var cache_enabled: bool = true

## Bump (or click Clear + Bake) to re-roll ground cover. Pairs
## with the `cache_version` knob on TreeScatter / RockScatter — bump
## independently so you can re-roll just one layer.
@export_range(1, 999, 1) var cache_version: int = 1

# Internal toggle used by the "Bake placement cache" button to write
# fresh bakes to disk regardless of existing cache state. NOT @export
# — the equivalent inspector checkbox was removed because leaving it
# on by accident tanked perf for entire sessions; use the Rebuild
# button or bump `cache_version` to re-roll instead.
var _bake_force_fresh: bool = false

## Inspector button — bakes every tile within `prebake_radius_m` of
## the world origin synchronously, writing each to cache. Run once
## per content change to pre-warm the cache for the player's
## starting area; subsequent scene opens don't pay the bake cost in
## that region. Doesn't bake the entire map (would be tens of GB on
## cascade_locks); use sparingly.
@export_tool_button("Bake placement cache", "Save") var bake_cache_action: Callable = _bake_cache_near_origin

## Radius (in meters) baked by the "Bake foliage cache near origin"
## button. 256 m at 16 m tile size = 256 tiles, ~5 MB cache.
@export_range(32.0, 1024.0, 32.0) var prebake_radius_m: float = 256.0

## Inspector button — bakes EVERY tile inside the active Terrain3D
## regions for this map. Slow on large maps; useful for first-time
## map setup so gameplay never hits an on-demand bake. Also the
## target of `Terrain3DBaker.Rebake Vegetation`.
@export_tool_button("Bake whole map", "Save") var bake_whole_map_action: Callable = _bake_cache_whole_map

## Inspector button — deletes every tile cache file under
## `res://assets/foliage_bake/<map_id>/`. Use after rearranging
## biome configs if the orphaned key dirs are eating disk.
@export_tool_button("Clear placement cache", "Remove") var clear_cache_action: Callable = _clear_cache_for_map

@export_group("Editor")
## When true, the scatter runs continuously in the editor: the active
## tile set tracks the editor's 3D viewport camera, the same view-cone
## globals are pushed each frame, and tiles bake/free as you fly around.
## Off by default so opening an unrelated scene doesn't pay the bake
## cost. The baked MMIs are NOT marked as scene members in editor mode
## — they exist as transient children only, so saving the scene won't
## inflate the .tscn with placement data.
@export var editor_preview: bool = false : set = _set_editor_preview

## Inspector button — tears down all baked tiles and re-bakes the
## active set against the editor camera. Useful after editing a
## biome / species / globals `.tres` since tiles only otherwise
## rebuild when the camera crosses `rebuild_threshold_m`.
@export_tool_button("Rebuild tiles", "Reload") var force_rebuild_action: Callable = _force_rebuild

## Verbose diagnostic output. Off by default — gates the per-species
## gltf node-tree dump and the per-rebuild status prints. Errors and
## genuine warnings (`push_warning`) ignore this flag; only the
## chatty info-level prints are silenced.
@export var verbose: bool = false

# --- Internal state ---

# Cached references resolved on first use.
var _camera: Camera3D = null
# Cached Terrain3D node (resolved from `terrain3d_path`). When non-null,
# `_height_at_world` queries `_terrain3d.data.get_height(...)` instead
# of sampling `_hm_bytes` directly. See `terrain3d_path` export docs.
var _terrain3d: Node3D = null

# Terrain bake artifacts loaded from disk.
var _hm_bytes: PackedByteArray = PackedByteArray()
var _splat_a: PackedByteArray = PackedByteArray()
var _splat_b: PackedByteArray = PackedByteArray()
var _splat_road: PackedByteArray = PackedByteArray()
var _terrain_w: int = 0
var _terrain_h: int = 0
var _spacing_m: float = 1.0
var _vert_min: float = 0.0
var _vert_max: float = 0.0
var _extent_x: float = 0.0
var _extent_z: float = 0.0
# True once `_load_terrain_artifacts()` succeeded; gates all bake calls.
var _terrain_ready: bool = false
# Cached `_terrain3d != null and is_instance_valid(_terrain3d)` result.
# Set in `_resolve_terrain3d()`; read by every hot-path biome / height
# query so we don't pay `is_instance_valid` thousands of times per
# tile bake on the same object.
var _terrain3d_valid: bool = false
# Reusable 4-byte buffer for the Terrain3D control-map decode in
# `_biome_via_control_map`. Allocated once instead of per-call (a
# tile bake calls that ~4000 times — the GC churn was measurable).
var _bvc_buf: PackedByteArray = PackedByteArray()

# Tile state. Each tile owns a list of MMIs (one per species used).
var _baked_tiles: Dictionary = {}  # Vector2i → Array[MultiMeshInstance3D]
var _last_player_xz: Vector2 = Vector2(INF, INF)
# Pending tile bakes — populated by `_rebuild_active`, drained N per
# frame in `_process` per `bake_per_frame_budget`. Spreads the bake
# cost across frames so a tile-cross doesn't stall the renderer.
var _bake_queue: Array[Vector2i] = []

# Prewarm cursor — index of next species in `_species_table` to load.
# `_process` advances this by `prewarm_per_frame_budget` each frame
# until it hits `_species_table.size()`. Tile bakes are GATED on this
# completing (see `_drain_bake_queue`) so the first round of bakes
# doesn't pay the asset-load tax. -1 = not started yet.
var _prewarm_cursor: int = -1

# Per-species cached resources, keyed by species index in the flat
# species table (built from biome_configs at first bake).
var _species_table: Array[FoliageSpecies] = []
# Per-species ShaderMaterial registry — populated as materials are
# created in `_make_shader_material` so the species's `changed`
# signal callback can re-push leaf grading + albedo modulation
# uniforms without a full rebuild. Without this, edits to a
# species's `leaf_hue_shift` / `albedo_modulation` / etc. in the
# inspector wouldn't take effect until the next force_rebuild.
var _species_shader_materials: Dictionary = {}  # path → Array[ShaderMaterial]
# Tracks which species we've already connected `changed` to.
# `is_connected(callable.bind(...))` doesn't match a previously-bound
# connection (each `bind()` returns a fresh Callable), so we'd
# otherwise stack a fresh connection on every tile bake → dozens of
# duplicate signal handlers per species. This dict short-circuits.
var _species_changed_connected: Dictionary = {}  # path → true
# Per-(biome_id) species index list + cumulative weight table for O(1) sampling.
var _biome_species_idx: Dictionary = {}        # int biome_id → PackedInt32Array
var _biome_species_cumweight: Dictionary = {}  # int biome_id → PackedFloat32Array
# Per-biome target density in plants/m² (mirrors
# `BiomeSpeciesConfig.plants_per_sq_m`).
var _biome_density: Dictionary = {}            # int biome_id → float
# `max(plants_per_sq_m)` across configured biomes — used to size the
# per-tile candidate count and to normalize the per-instance
# acceptance probability.
var _max_plants_per_sq_m: float = 0.0
# Per-species mesh-variant arrays + per-variant ShaderMaterial.
# A single PolyHaven gltf contains many MeshInstance3D children
# (e.g. 17 grass variants — small/mid/tall × a/b/c forms). Each
# variant is its own Mesh + Material in these tables; per-instance
# the bake picks a random variant index. The MMI for each
# (species, variant) pair gets that variant's mesh + material.
var _species_meshes: Dictionary = {}     # int idx → Array[Mesh]
var _species_materials: Dictionary = {}  # int idx → Array[ShaderMaterial]
# Per-variant Basis captured from the source MeshInstance3D's
# transform. Carries:
#   - scale (PolyHaven Vector3.ONE; Fab/Quixel Vector3(0.01, 0.01, 0.01)
#     to convert UE-cm vertex data to Godot-meter)
#   - rotation (PolyHaven identity; Fab/Quixel +90° around X to convert
#     UE's Z-up frame to Godot's Y-up — without this Fab grass renders
#     sideways).
# Composed at bake as `final_basis = per_instance_basis * variant_basis`
# so the variant transform applies to the mesh first (mesh → Godot
# frame), then per-instance scale jitter + random yaw on top.
var _species_mesh_bases: Dictionary = {}  # int idx → Array[Basis]
# Per-variant source-mesh node name from the gltf (e.g.
# "SM_wf0oefeja_VarA"). Carried solely so MMI nodes can name themselves
# with the actual asset variant, making it possible to mouseover a
# problem plant in the editor and identify which species + variant is
# rendering it without re-running the diagnostic dumper.
var _species_mesh_names: Dictionary = {}    # int idx → Array[StringName]
# Per-species clumping noise field. Each species in `_species_table`
# gets its own `FastNoiseLite` (different seed) sampled at the
# candidate's world XZ. Effective weight for the candidate's species
# pick = `base_weight × (1 + species_clumping × noise_value)`. Where
# species A's noise is high, A wins more often → patches of A. With
# `species_clumping = 0` the noise is ignored and selection falls
# back to pure cumulative-weight RNG.
var _species_noise: Array[FastNoiseLite] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		# Editor preview is opt-in; defer everything to _process so the
		# scatter doesn't pay setup cost on scenes that aren't being
		# foliage-tuned. Toggling `editor_preview` re-enters _process.
		return
	if not _ensure_terrain_loaded():
		return
	_resolve_camera()
	_resolve_terrain3d()
	if globals != null:
		globals.apply_to_renderer()
	if _camera == null:
		push_warning("GroundCoverScatter: no camera resolved; idle.")
		return
	_build_species_table()
	if _species_table.is_empty():
		push_warning("GroundCoverScatter: biome_configs is empty; nothing to scatter.")
		return
	_rebuild_active(_xz(_camera.global_position))
	if verbose:
		print("GroundCoverScatter: ready — %d tiles, %d species across %d biomes"
			% [_baked_tiles.size(), _species_table.size(), _biome_species_idx.size()])


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
	# Lazy init — handles editor mode (no _ready) and tracks config
	# changes after the scene is open.
	if not _terrain_ready and not _ensure_terrain_loaded():
		return
	_resolve_terrain3d()
	if _species_table.is_empty():
		_build_species_table()
		if _species_table.is_empty():
			return
	# Push the camera globals every frame in editor mode (player.gd does
	# this itself at runtime). Same shader uniforms either way. The
	# `FoliageGlobals` resource pushes the wind / view-cone family on
	# the same cadence so inspector edits are live.
	if Engine.is_editor_hint():
		_push_camera_globals(cam)
		if globals != null:
			globals.apply_to_renderer()
	var p_xz := _xz(cam.global_position)
	# Prewarm pass — load every species's GLB scene + textures over
	# `prewarm_per_frame_budget` species/frame BEFORE we start baking
	# tiles. Front-loads the asset-load cost into the first ~half-
	# second instead of leaking it as hitches when the player walks
	# into tiles using fresh species. Once cursor reaches the end of
	# the species table, bake queue drains as normal.
	if prewarm_per_frame_budget > 0 and _prewarm_cursor < _species_table.size():
		if _prewarm_cursor < 0:
			_prewarm_cursor = 0
		var stop := mini(_prewarm_cursor + prewarm_per_frame_budget,
			_species_table.size())
		while _prewarm_cursor < stop:
			_ensure_species_resources(_prewarm_cursor)
			_prewarm_cursor += 1
		# Don't bake tiles yet — let the prewarm finish first so the
		# initial round of bakes pays zero asset-load cost.
		return
	if (p_xz - _last_player_xz).length() >= rebuild_threshold_m:
		_rebuild_active(p_xz)
	# Drain a few queued tile bakes per frame regardless of whether
	# the player just crossed a tile boundary — keeps the catch-up
	# work happening while the player is moving.
	if bake_per_frame_budget > 0 and not _bake_queue.is_empty():
		_drain_bake_queue(bake_per_frame_budget)


# --- Editor preview ---

func _set_editor_preview(v: bool) -> void:
	editor_preview = v
	if not Engine.is_editor_hint():
		return
	if v:
		# Force the next _process to do a full rebuild from the editor
		# camera. _process handles lazy init.
		_last_player_xz = Vector2(INF, INF)
		set_notify_transform(true)
		set_process(true)
	else:
		# Tear down baked tiles so the scene tree returns to clean state.
		for k in _baked_tiles.keys():
			for mmi in _baked_tiles[k]:
				if is_instance_valid(mmi):
					mmi.queue_free()
		_baked_tiles.clear()
		_bake_queue.clear()
		_last_player_xz = Vector2(INF, INF)


# Inspector "Rebuild tiles" button. Tears down all baked tiles and
# re-runs the active set against whatever camera is current (editor
# viewport in editor mode, player camera at runtime). Called via
# the `force_rebuild_action` `@export_tool_button` hook.
func _force_rebuild() -> void:
	for k in _baked_tiles.keys():
		for mmi in _baked_tiles[k]:
			if is_instance_valid(mmi):
				mmi.queue_free()
	_baked_tiles.clear()
	_bake_queue.clear()
	_last_player_xz = Vector2(INF, INF)
	_invalidate_cache_key()
	# Clear the cached species table so resource edits (e.g. species
	# .tres mesh path swaps) re-resolve on next bake.
	# Disconnect species changed-signals before dropping refs.
	# `disconnect` requires the EXACT bound callable used in connect
	# — match it by reconstructing `.bind(species_path)`.
	for path in _species_shader_materials.keys():
		for s in _species_table:
			if s != null and s.resource_path == path:
				var cb := _on_species_changed.bind(path)
				if s.changed.is_connected(cb):
					s.changed.disconnect(cb)
				break
	_species_shader_materials.clear()
	_species_changed_connected.clear()
	_species_table.clear()
	_prewarm_cursor = -1
	_biome_species_idx.clear()
	_biome_species_cumweight.clear()
	_biome_density.clear()
	_max_plants_per_sq_m = 0.0
	_species_meshes.clear()
	_species_noise.clear()
	_species_materials.clear()
	_species_mesh_bases.clear()
	_species_mesh_names.clear()
	if not _terrain_ready:
		_ensure_terrain_loaded()
	_resolve_terrain3d()
	var rebuild_camera: Camera3D = null
	if Engine.is_editor_hint():
		rebuild_camera = _get_editor_camera()
	else:
		rebuild_camera = _camera
	if rebuild_camera != null:
		_rebuild_active(_xz(rebuild_camera.global_position))
	if verbose:
		print("GroundCoverScatter: rebuild complete (%d tiles)" % _baked_tiles.size())
	# Debug: sample 1000 random points within the active radius and
	# print biome-detection distribution. Quickly reveals "every
	# pixel reads as Forest" type bugs vs "biome is detected but
	# species are too small to see" — the user complaint was the
	# latter, this confirms which.
	if rebuild_camera != null:
		_debug_print_biome_distribution(_xz(rebuild_camera.global_position))


# Diagnostic helper: sample biome detection at random points and
# print a histogram. Used by `_force_rebuild`.
func _debug_print_biome_distribution(center_xz: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var counts: Dictionary = {}
	for _i in 1000:
		var ang := rng.randf() * TAU
		var r := rng.randf() * active_radius_m
		var bx := center_xz.x + cos(ang) * r
		var bz := center_xz.y + sin(ang) * r
		var b := _biome_at_world(bx, bz)
		counts[b] = counts.get(b, 0) + 1
	var lines: Array[String] = []
	for k in counts.keys():
		var label: String
		match k:
			-1: label = "suppress / off-map"
			BiomeSpeciesConfig.BiomeId.FOREST: label = "FOREST"
			BiomeSpeciesConfig.BiomeId.GRASSLAND: label = "GRASSLAND"
			BiomeSpeciesConfig.BiomeId.CROPLAND: label = "CROPLAND"
			BiomeSpeciesConfig.BiomeId.BARE: label = "BARE"
			BiomeSpeciesConfig.BiomeId.ROAD: label = "ROAD"
			_: label = "biome_%d" % k
		lines.append("  %s: %d" % [label, counts[k]])
	print("GroundCoverScatter: biome sample (1000 pts within %d m of camera)\n%s"
		% [int(active_radius_m), "\n".join(lines)])


func _get_editor_camera() -> Camera3D:
	# `EditorInterface` is only available inside @tool scripts; we are
	# one. Returns null when no 3D viewport is active (e.g. while the
	# user is in the 2D / Script editor).
	var vp := EditorInterface.get_editor_viewport_3d()
	if vp == null:
		return null
	return vp.get_camera_3d()


func _push_camera_globals(cam: Camera3D) -> void:
	var fwd := -cam.global_transform.basis.z
	RenderingServer.global_shader_parameter_set("player_cam_pos", cam.global_position)
	RenderingServer.global_shader_parameter_set("player_cam_forward", fwd)


# --- Terrain artifact load ---

func _ensure_terrain_loaded() -> bool:
	if _terrain_ready:
		return true
	var dir := "res://assets/terrain/%s/" % map_id
	var meta := _parse_terrain_toml(dir + "terrain.toml")
	if meta.is_empty():
		push_warning("GroundCoverScatter: failed to parse %sterrain.toml" % dir)
		return false
	_terrain_w = int(meta.get("width", 0))
	_terrain_h = int(meta.get("height", 0))
	_spacing_m = float(meta.get("spacing_m", 1.0))
	# vert_min/vert_max are gameplay-metadata in v2 (storage is f32
	# meters in `.r32`). Kept for the per-tile AABB Y-range hint
	# below; tile-cull box only needs *some* bound, not the actual
	# per-tile min/max.
	_vert_min = float(meta.get("vert_min_m", 0.0))
	_vert_max = float(meta.get("vert_max_m", 0.0))
	if _terrain_w <= 0 or _terrain_h <= 0:
		push_warning("GroundCoverScatter: invalid terrain dimensions in %s" % dir)
		return false
	# Extent uses the (W-1)*spacing convention — matches the renderer
	# (HeightMapShape3D, ArrayMesh) and the sim layer's heightmap
	# sampling. Off-by-half-cell here propagates into Y placement
	# errors that compound on slopes.
	_extent_x = float(_terrain_w - 1) * _spacing_m
	_extent_z = float(_terrain_h - 1) * _spacing_m

	_hm_bytes = _read_bytes(dir + "heightmap.r32")
	_splat_a = _read_bytes(dir + "splatmap_a.rgba8")
	_splat_b = _read_bytes(dir + "splatmap_b.rgba8")
	# Optional — older bakes may not have it.
	_splat_road = _read_bytes(dir + "road_density.rgba8")

	if _hm_bytes.size() != _terrain_w * _terrain_h * 4:
		push_warning("GroundCoverScatter: heightmap size mismatch (got %d, expected %d)"
			% [_hm_bytes.size(), _terrain_w * _terrain_h * 4])
		return false
	if _splat_a.size() != _terrain_w * _terrain_h * 4:
		push_warning("GroundCoverScatter: splatmap_a size mismatch")
		return false
	if _splat_b.size() != _terrain_w * _terrain_h * 4:
		push_warning("GroundCoverScatter: splatmap_b size mismatch")
		return false
	_terrain_ready = true
	return true


# Minimal TOML reader for the flat schema in our terrain.toml. Each
# terrain consumer (Terrain3DLoader, GroundCoverScatter, anything else
# that needs to know map dimensions) keeps its own copy so no consumer
# pulls in the others' dependencies.
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


# --- Camera resolution ---

func _resolve_camera() -> void:
	if not camera_path.is_empty():
		_camera = get_node_or_null(camera_path) as Camera3D
		if _camera != null:
			return
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_camera = _find_first_camera(players[0])


# Resolve the Terrain3D node from `terrain3d_path`, if set. Safe to
# call repeatedly — the cached reference is only re-resolved when
# null. Stored as Node3D (untyped against the Terrain3D class) so
# this script can compile in headless / `--check-only` contexts where
# the Terrain3D extension hasn't loaded.
func _resolve_terrain3d() -> void:
	if _terrain3d != null and is_instance_valid(_terrain3d):
		_terrain3d_valid = true
		return
	if terrain3d_path.is_empty():
		_terrain3d_valid = false
		return
	_terrain3d = get_node_or_null(terrain3d_path) as Node3D
	_terrain3d_valid = (_terrain3d != null and is_instance_valid(_terrain3d))


func _find_first_camera(n: Node) -> Camera3D:
	if n is Camera3D:
		return n
	for c in n.get_children():
		var cam := _find_first_camera(c)
		if cam != null:
			return cam
	return null


# --- Species table build ---

func _build_species_table() -> void:
	# Disconnect species changed-signals before dropping refs, then
	# clear the per-species ShaderMaterial registry. Forces a fresh
	# signal connection on next material create.
	for path in _species_shader_materials.keys():
		for s in _species_table:
			if s != null and s.resource_path == path:
				if s.changed.is_connected(_on_species_changed):
					s.changed.disconnect(_on_species_changed)
				break
	_species_shader_materials.clear()
	_species_table.clear()
	_prewarm_cursor = -1
	_biome_species_idx.clear()
	_biome_species_cumweight.clear()
	_biome_density.clear()
	_max_plants_per_sq_m = 0.0
	_species_meshes.clear()
	_species_noise.clear()
	_species_materials.clear()
	_species_mesh_bases.clear()
	_species_mesh_names.clear()
	if biome_configs.is_empty():
		return
	for cfg in biome_configs:
		if cfg == null or cfg.species_paths.is_empty():
			continue
		var idx_list := PackedInt32Array()
		var cum_list := PackedFloat32Array()
		var cum := 0.0
		# Per-species explicit densities take over when the parallel
		# array length matches species_paths. Each species's slice of
		# the cumulative-weight table is its declared p/m². The
		# biome's effective density is the sum (overrides the field).
		# When mismatched / empty, fall back to legacy
		# `species.weight` × biome.plants_per_sq_m behaviour.
		var use_explicit_densities: bool = (
			cfg.species_densities.size() == cfg.species_paths.size())
		# Resolve each species path → FoliageSpecies. Paths instead of
		# `Array[FoliageSpecies]` to dodge the Godot 4.6.2 inspector
		# crash on Resource swaps inside arrays. Loaded once here, then
		# the FoliageSpecies sits in `_species_table` and is reused for
		# every tile bake.
		for i in cfg.species_paths.size():
			var path: String = cfg.species_paths[i]
			if path.is_empty():
				continue
			var sp: FoliageSpecies = load(path) as FoliageSpecies
			if sp == null:
				push_warning("GroundCoverScatter: biome %d failed to load species at %s"
					% [cfg.biome, path])
				continue
			var contribution: float
			if use_explicit_densities:
				contribution = cfg.species_densities[i]
			else:
				contribution = sp.weight
			if contribution <= 0.0:
				continue
			var idx := _species_table.size()
			_species_table.append(sp)
			idx_list.append(idx)
			cum += contribution
			cum_list.append(cum)
		if idx_list.size() == 0:
			continue
		_biome_species_idx[cfg.biome] = idx_list
		_biome_species_cumweight[cfg.biome] = cum_list
		# Effective density: `plants_per_sq_m` IS the master per-biome
		# total whenever it's > 0. `species_densities` (when given) is
		# the *relative* distribution among species — scaling every
		# entry by the same factor doesn't change which species gets
		# picked (cumulative-weight RNG only cares about ratios), so
		# we can leave `cum_list` untouched and just set
		# `effective_density = plants_per_sq_m` to drive per-tile
		# candidate count + acceptance probability.
		#
		# Pre-2026-05: the sum of `species_densities` overrode
		# `plants_per_sq_m` when both were given, which made the field
		# silently dead and unpredictable for tuning. The new contract
		# is "plants_per_sq_m is what you set, period" — easy to
		# expose in a future in-game foliage-density slider.
		#
		# Legacy fallback: when `plants_per_sq_m` is left at 0 AND
		# species_densities is given, use the sum so old biome
		# resources without an explicit field still work.
		var effective_density: float
		if use_explicit_densities:
			effective_density = (
				cfg.plants_per_sq_m if cfg.plants_per_sq_m > 0.0 else cum)
		else:
			effective_density = cfg.plants_per_sq_m
		_biome_density[cfg.biome] = effective_density
		_max_plants_per_sq_m = maxf(_max_plants_per_sq_m, effective_density)
	# Build per-species clumping noise — one FastNoiseLite per slot in
	# `_species_table`, all at the same frequency but different seeds
	# so each species has its own patch layout. Sampled in
	# `_pick_species` to bias the cumulative-weight RNG.
	for i in _species_table.size():
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n.frequency = species_clumping_freq
		# Combine master seed with species index so the same species
		# in different scenes produces the same noise pattern (handy
		# for art consistency across maps), and so seed changes give
		# fresh patches.
		n.seed = (int(seed) * 1009) ^ (i * 31337)
		_species_noise.append(n)


# Lazy mesh + material extraction per species. Pulls **every**
# MeshInstance3D out of the gltf — PolyHaven plant gltfs typically
# bundle 3–21 size/shape variants per file (e.g. grass_medium_01
# carries 17 small/mid/tall × a/b/c forms). We treat each as an
# interchangeable variant and the bake picks one per instance.
func _ensure_species_resources(idx: int) -> void:
	if _species_meshes.has(idx):
		return
	var sp: FoliageSpecies = _species_table[idx]
	var meshes: Array[Mesh] = []
	var materials: Array[ShaderMaterial] = []
	var mesh_bases: Array[Basis] = []
	var mesh_names: Array[StringName] = []
	# Optional: a pre-baked Mesh override forces a single-variant
	# species.
	if not sp.mesh_override_path.is_empty():
		var override_mesh: Mesh = load(sp.mesh_override_path) as Mesh
		if override_mesh != null:
			meshes.append(override_mesh)
			materials.append(_make_shader_material(null, sp))
			mesh_bases.append(Basis.IDENTITY)
			mesh_names.append(StringName("override"))
	if meshes.is_empty() and not sp.mesh_scene_path.is_empty():
		var packed: PackedScene = load(sp.mesh_scene_path) as PackedScene
		if packed == null:
			push_warning("GroundCoverScatter: species %d failed to load %s"
				% [idx, sp.mesh_scene_path])
			_species_meshes[idx] = []
			_species_materials[idx] = []
			_species_mesh_bases[idx] = []
			_species_mesh_names[idx] = []
			return
		var root: Node = packed.instantiate()
		var mis: Array[MeshInstance3D] = []
		_find_all_mesh_instances(root, mis)
		# Filter out variants by name substring — by default this drops
		# `_LOD1` / `_LOD2` nodes that Fab/Quixel "low" tier gltfs ship
		# alongside the LOD0 base variants. See FoliageSpecies.mesh_name_exclude.
		var excludes: PackedStringArray = PackedStringArray()
		for tok in sp.mesh_name_exclude.split(","):
			var t: String = tok.strip_edges()
			if not t.is_empty():
				excludes.append(t)
		if not excludes.is_empty():
			var filtered: Array[MeshInstance3D] = []
			for mi in mis:
				var skip := false
				for ex in excludes:
					if mi.name.find(ex) >= 0:
						skip = true
						break
				if not skip:
					filtered.append(mi)
			mis = filtered
		# Diagnostic: dump full scene tree + per-MeshInstance3D info so
		# we can see what the gltf importer actually produced. Fires
		# once per species at first ensure_resources call. Hundreds of
		# lines per species in dense maps; gated behind `verbose` so
		# the Output panel stays readable by default.
		if verbose:
			print("[gc-diag] species %s root_tree:" % sp.resource_path)
			_dump_node_tree(root, "  ")
			print("[gc-diag]   _find_all_mesh_instances → %d entries" % mis.size())
			for mi in mis:
				if mi.mesh == null:
					continue
				var aabb_dbg := mi.mesh.get_aabb()
				print("[gc-diag]   '%s' parent='%s' tx_origin=%s aabb_center=%s aabb_size=%s surfs=%d" % [
					mi.name,
					(mi.get_parent().name if mi.get_parent() != null else "<null>"),
					mi.transform.origin,
					aabb_dbg.position + aabb_dbg.size * 0.5,
					aabb_dbg.size, mi.mesh.get_surface_count()])
		for mi in mis:
			if mi.mesh == null:
				continue
			# Vertex-count floor — drops decoration / imposter LOD0
			# variants that some Fab packs ship as small leaf-cluster
			# meshes (no `_LOD3` suffix to filter on, but only ~700
			# verts vs a real bush's 10k-30k). See
			# `FoliageSpecies.min_surface_verts` for the rationale.
			if sp.min_surface_verts > 0:
				var v_total: int = 0
				for s_i in mi.mesh.get_surface_count():
					v_total += (mi.mesh as Mesh).surface_get_array_len(s_i)
				if v_total < sp.min_surface_verts:
					if verbose:
						print("[gc-skip] %s '%s' verts=%d < min_surface_verts=%d"
							% [sp.resource_path.get_file(),
							mi.name, v_total, sp.min_surface_verts])
					continue
			# Working copy of the source mesh so we can attach our
			# shader materials without touching the import-side
			# resource (Godot 4 stores materials as node overrides,
			# not on the Mesh itself).
			var mesh: Mesh = (mi.mesh as Mesh).duplicate() as Mesh
			# Per-surface shader material build. CGTrader bushes
			# (np_bushes01/04/05/07) ship each variant as a single
			# Mesh with two primitives — surface 0 is the trunk
			# textured with a `bark*` material, surface 1 is the leaf
			# cards textured with a separate `Branch*` leaf-atlas
			# material. Earlier versions of this code only sampled
			# surface 0's material and stomped the resulting shader_mat
			# onto every surface, which sent leaf-card UVs into the
			# bark atlas (mostly transparent + brown chunks → leaf
			# cards rendered as sparse cutouts, looked like floating
			# leaf clouds with no trunk). Build one shader_mat per
			# surface so each primitive renders against its own
			# source texture.
			#
			# `first_shader_mat` doubles as a fallback for the
			# `materials.append(...)` registry (the per-species
			# shader-material registry is keyed by species, not
			# surface, so we record one representative material per
			# variant — surface 0's, matching the legacy contract).
			var first_shader_mat: ShaderMaterial = null
			for s in mesh.get_surface_count():
				var mat_source: StandardMaterial3D = (
					mi.get_surface_override_material(s) as StandardMaterial3D)
				if mat_source == null:
					mat_source = mesh.surface_get_material(s) as StandardMaterial3D
				# Diagnostic for the "leaves render solid black" case.
				# When the gltf importer fails to surface a base color
				# slot (broken material binding, surface_override loss,
				# or atlas-shared mesh that lost its albedo_texture
				# pointer), the shader receives null `albedo_tex` and
				# samples to black with proper alpha cutout — looks
				# exactly like the symptom we keep hitting on UMP /
				# PolyHaven imports. Loud warning lets the user identify
				# the offender from the Output panel rather than visually
				# inspecting every species in-world.
				if mat_source == null:
					push_warning("[gc] %s '%s' surface %d has no source material — shader will render black"
						% [sp.resource_path, mi.name, s])
				elif mat_source.albedo_texture == null:
					push_warning("[gc] %s '%s' surface %d source material has NULL albedo_texture — shader will render black (likely a broken gltf base-color binding)"
						% [sp.resource_path, mi.name, s])
				var surf_mat: ShaderMaterial = _make_shader_material(mat_source, sp)
				mesh.surface_set_material(s, surf_mat)
				if first_shader_mat == null:
					first_shader_mat = surf_mat
			meshes.append(mesh)
			materials.append(first_shader_mat)
			# Capture the node's scale (Quixel/Fab assets often carry
			# a 0.01 scale to convert UE-cm vertex data to Godot-meter
			# scale; without this the scatter renders them at 100×).
			# Full basis (rotation + scale). Quixel/Fab gltfs apply a
			# +90° X-axis rotation + 0.01 scale on each variant node
			# to convert UE's Z-up cm-units into Godot's Y-up meters
			# — discarding the rotation makes grass render sideways.
			mesh_bases.append(mi.transform.basis)
			mesh_names.append(StringName(mi.name))
		if root != null:
			root.queue_free()
	if meshes.is_empty():
		push_warning("GroundCoverScatter: species %d has no mesh." % idx)
	# Per-variant report — one line per loaded variant with its source
	# node name, vert count, mesh-local size, and approximate world-space
	# size after the variant_basis + size_multiplier are applied. Lets
	# you spot "leaf-cluster fragment" vs "real bush" variants at a
	# glance from the Output panel without having to mouseover MMIs.
	if verbose and not meshes.is_empty():
		var sp_label: String = sp.resource_path.get_file()
		print("[gc-load] %s: %d variants" % [sp_label, meshes.size()])
		for vi in meshes.size():
			var m: Mesh = meshes[vi]
			var v_total: int = 0
			for s_i in m.get_surface_count():
				v_total += m.surface_get_array_len(s_i)
			var ab: AABB = m.get_aabb()
			var v_basis: Basis = mesh_bases[vi]
			var sz_world: Vector3 = (v_basis * ab.size).abs() * sp.size_multiplier
			print("[gc-load]   v%d %-32s verts=%6d  mesh-local=%.2f×%.2f×%.2f  ~world=%.2f×%.2f×%.2f"
				% [vi, mesh_names[vi], v_total,
				ab.size.x, ab.size.y, ab.size.z,
				sz_world.x, sz_world.y, sz_world.z])
	_species_meshes[idx] = meshes
	_species_materials[idx] = materials
	_species_mesh_bases[idx] = mesh_bases
	_species_mesh_names[idx] = mesh_names


# Build a ground-cover ShaderMaterial wrapping the source's textures.
func _make_shader_material(mat_source: StandardMaterial3D,
		sp: FoliageSpecies) -> ShaderMaterial:
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = SHADER
	if mat_source != null:
		shader_mat.set_shader_parameter("albedo_tex", mat_source.albedo_texture)
		# PolyHaven gltf PBR import puts the _arm.jpg in the metallic
		# texture slot (the importer samples R/G/B for AO/Roughness/
		# Metallic when the source is a packed ORM channel). Fall back
		# to ao_texture / roughness_texture if it landed elsewhere.
		var arm: Texture2D = mat_source.metallic_texture
		if arm == null:
			arm = mat_source.ao_texture
		if arm == null:
			arm = mat_source.roughness_texture
		shader_mat.set_shader_parameter("arm_tex", arm)
		# normal_tex used to be plumbed here; the shader uniform was
		# removed (see ground_cover_dynamic.gdshader) because its mere
		# declaration triggered Godot's "this mesh needs tangents"
		# warning on Fab "low" tier variants that ship without UVs.
	if sp != null:
		# Live-tunable uniforms (albedo modulation + leaf grading +
		# alpha cutoff). Pushed via `_push_live_uniforms` so the same
		# code path fires both at spawn AND on `species.changed`
		# (inspector edits propagate without rebuild).
		_push_live_uniforms(shader_mat, sp)
		# Register the material in the per-species registry + connect
		# the species's `changed` signal so subsequent inspector
		# edits re-push uniforms to all materials of this species.
		if not _species_shader_materials.has(sp.resource_path):
			_species_shader_materials[sp.resource_path] = []
		_species_shader_materials[sp.resource_path].append(shader_mat)
		# Connect once-per-species, tracked via dict because
		# `is_connected(bound_callable)` doesn't match earlier bound
		# connections — each `.bind(...)` returns a fresh Callable.
		if not _species_changed_connected.get(sp.resource_path, false):
			sp.changed.connect(_on_species_changed.bind(sp.resource_path))
			_species_changed_connected[sp.resource_path] = true
	return shader_mat


# Single source of truth for live-tunable uniforms. Called at
# material-create time AND from `_on_species_changed` after the
# user edits the species in the inspector.
func _push_live_uniforms(sm: ShaderMaterial, sp: FoliageSpecies) -> void:
	sm.set_shader_parameter(
		"alpha_luminance_cutoff", sp.alpha_luminance_cutoff)
	var mod := sp.albedo_modulation
	sm.set_shader_parameter(
		"albedo_modulation", Vector3(mod.r, mod.g, mod.b))
	sm.set_shader_parameter("leaf_hue_shift", sp.leaf_hue_shift)
	sm.set_shader_parameter(
		"leaf_saturation_mul", sp.leaf_saturation_mul)
	sm.set_shader_parameter("leaf_value_mul", sp.leaf_value_mul)
	sm.set_shader_parameter("leaf_threshold", sp.leaf_threshold)


# Re-push live uniforms to all materials registered for this species
# whenever the inspector changes one of its `@export` properties.
# Without this, leaf_hue_shift / leaf_saturation_mul / etc. wouldn't
# take effect until the user clicked Rebuild.
func _on_species_changed(species_path: String) -> void:
	var sp: FoliageSpecies = null
	for s in _species_table:
		if s != null and s.resource_path == species_path:
			sp = s
			break
	if sp == null:
		return
	var mats: Array = _species_shader_materials.get(species_path, [])
	for sm_v in mats:
		var sm: ShaderMaterial = sm_v as ShaderMaterial
		if sm == null or not is_instance_valid(sm):
			continue
		_push_live_uniforms(sm, sp)


## Walk the parent chain from `target` up to but not including
## `root`, accumulating each Node3D ancestor's local transform.
## Returns the resulting position — the cumulative translation that
## a vertex at (0, 0, 0) in target's local space would end up at
## inside the imported scene root.
static func _node_origin_in_subtree(target: Node3D, root: Node) -> Vector3:
	var pos := target.transform.origin
	var p: Node = target.get_parent()
	while p != null and p != root:
		if p is Node3D:
			pos = (p as Node3D).transform * pos
		p = p.get_parent()
	return pos


func _dump_node_tree(n: Node, indent: String) -> void:
	var info := "%s%s [%s]" % [indent, n.name, n.get_class()]
	if n is Node3D:
		info += " pos=%s" % (n as Node3D).transform.origin
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var m := (n as MeshInstance3D).mesh
		info += " mesh.surfs=%d aabb_size=%s" % [m.get_surface_count(), m.get_aabb().size]
	print(info)
	for c in n.get_children():
		_dump_node_tree(c, indent + "  ")


func _find_all_mesh_instances(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_find_all_mesh_instances(c, out)


# --- Active tile management ---

func _rebuild_active(player_xz: Vector2) -> void:
	_last_player_xz = player_xz
	if not _terrain_ready:
		return

	var radius_tiles := int(ceil(active_radius_m / tile_size_m))
	var center_tile := Vector2i(
		int(floor(player_xz.x / tile_size_m)),
		int(floor(player_xz.y / tile_size_m)))

	var wanted: Dictionary = {}  # Vector2i → true
	var r_sq := active_radius_m * active_radius_m
	for dz in range(-radius_tiles, radius_tiles + 1):
		for dx in range(-radius_tiles, radius_tiles + 1):
			var tile := center_tile + Vector2i(dx, dz)
			var tcx := (float(tile.x) + 0.5) * tile_size_m
			var tcz := (float(tile.y) + 0.5) * tile_size_m
			var d_sq := (tcx - player_xz.x) ** 2 + (tcz - player_xz.y) ** 2
			if d_sq <= r_sq:
				wanted[tile] = true

	# Free tiles that left the active set.
	for k in _baked_tiles.keys():
		if not wanted.has(k):
			for mmi in _baked_tiles[k]:
				if is_instance_valid(mmi):
					mmi.queue_free()
			_baked_tiles.erase(k)

	# Drop any queued bakes that left the active set (player walked
	# back, no point baking tiles we'd just free again).
	_bake_queue = _bake_queue.filter(func(t: Vector2i) -> bool:
		return wanted.has(t))

	# Queue tiles that newly entered the active set, sorted by
	# distance from the player so the closest tiles bake first.
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

	# bake_per_frame_budget = 0 → bake everything synchronously
	# (the old behaviour, useful for benchmarking or when the user
	# explicitly wants no settle window).
	if bake_per_frame_budget <= 0:
		_drain_bake_queue(_bake_queue.size())


# Bake up to `count` queued tiles. Returns the number actually baked.
# Called from `_process` per `bake_per_frame_budget`.
func _drain_bake_queue(count: int) -> int:
	var baked := 0
	while baked < count and not _bake_queue.is_empty():
		var tile: Vector2i = _bake_queue[0]
		_bake_queue.remove_at(0)
		# Tile may have been freed in the meantime (player teleported)
		# — skip without consuming budget if so.
		if not _baked_tiles.has(tile):
			_bake_tile(tile)
		baked += 1
	return baked


func _bake_tile(tile: Vector2i, cache_only: bool = false) -> void:
	# `cache_only` is the whole-map-bake escape hatch: skip MMI
	# instantiation and `_baked_tiles` registration, just run placement
	# RNG and write the cache file. The runtime spawns from cache when
	# the player approaches. Without this, a whole-map bake at small
	# tile sizes (`ground_cover` defaults to 16 m) creates hundreds of
	# thousands of MultiMesh RIDs and exhausts Godot's RID owner.
	#
	# Cache fast path. Skipped when `_bake_force_fresh` is on — useful while
	# iterating on placement logic but disable once happy. Also skipped
	# in `cache_only` mode: re-running a whole-map bake should always
	# refresh disk, never spawn MMIs from an existing cache file.
	if cache_enabled and not _bake_force_fresh and not cache_only:
		var cached: Dictionary = _try_load_tile_cache(tile)
		if not cached.is_empty():
			_spawn_mmis_from_cache(tile, cached)
			return

	# Per-tile RNG: hash combines master seed + tile coords. Same tile
	# always produces the same plants.
	var rng := RandomNumberGenerator.new()
	rng.seed = (
		(int(seed) * 73856093) ^
		(int(tile.x) * 19349663) ^
		(int(tile.y) * 83492791))

	var per_species_xforms: Dictionary = {}
	var per_species_rolls: Dictionary = {}
	# Per-tile variant pick: each species in this tile uses ONE variant
	# (deterministic from the tile RNG). Cuts MMI count from ~90/tile
	# (one MMI per (species, variant) bucket) down to ~12/tile (one
	# per species). Variant variety happens across tiles — adjacent
	# tiles draw different variants for the same species, which in
	# motion reads as natural meadow variation. Within a single tile,
	# all instances of e.g. periwinkle look the same; with 16 m tiles
	# this is a small enough patch that it isn't visually obvious.
	#
	# `variants_per_tile` allows 2-N variants per species per tile if
	# the user wants more within-tile variety at proportional MMI cost.
	var per_species_variant_pool: Dictionary = {}  # sp_idx → Array[int]

	var origin_x := float(tile.x) * tile_size_m
	var origin_z := float(tile.y) * tile_size_m

	# Candidate count = (max biome density present in *this tile*) ×
	# tile area × density_multiplier, clamped by the safety cap. The
	# per-instance Bernoulli filter normalizes back down via
	# `biome_target / tile_max_density`, so a tile fully inside one
	# biome accepts ~all candidates; tiles spanning a biome boundary
	# fall back to the highest sampled density.
	#
	# Pre-2026-05: the candidate count used the GLOBAL max density
	# across all biomes (`_max_plants_per_sq_m`), so a road tile at
	# 0.4 plants/m² would generate the same ~896 candidates as a
	# grassland tile at 3.5 plants/m² and waste 88% of them on
	# rejected accept_p rolls — running the full per-candidate
	# pipeline (terrain Y, exclusion zones, rock exclusion, road
	# clearance, slope thinning) on each. Per-tile pre-sampling cuts
	# the candidate budget proportionally on every non-grassland tile.
	#
	# Sample biome at center + 4 corners; take the max effective
	# density. 5 lookups vs hundreds of full-pipeline candidates is
	# a clear win. Worst case (a thin biome strip falling between
	# all 5 samples) under-densifies the strip slightly — acceptable
	# given how smooth our biome maps are at 16 m tile scale.
	#
	# No CPU-side per-tier filtering: each instance's `size_tier` is
	# packed into `INSTANCE_CUSTOM.y` and the shader culls per-tier at
	# render time using `gc_tier_radius_{small,medium,large}` globals.
	# That keeps tile contents stable across player movement (no
	# rebake when a tile crosses a tier boundary) and lets the shader
	# do a soft fade-out instead of the hard pop the CPU filter caused.
	var tile_area := tile_size_m * tile_size_m
	var tile_max_density: float = 0.0
	const _SAMPLE_FRACS := [
		Vector2(0.5, 0.5),  # center
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(0.0, 1.0), Vector2(1.0, 1.0),  # corners
	]
	for sf in _SAMPLE_FRACS:
		var sx: float = origin_x + sf.x * tile_size_m
		var sz: float = origin_z + sf.y * tile_size_m
		var sb: int = _biome_at_world(sx, sz)
		if sb < 0:
			continue
		var sd: float = _biome_density.get(sb, 0.0)
		if sd > tile_max_density:
			tile_max_density = sd
	if tile_max_density <= 0.0:
		# No plant-supporting biome touches this tile (water / cliff /
		# snow / built-up everywhere) — bail before allocating buckets.
		# Mirrors the existing "no candidates accepted" empty-result
		# path lower in this function: the 5 biome lookups are cheap
		# enough that re-running them on every player approach is fine,
		# and skipping the cache write keeps water/cliff tiles from
		# accumulating empty .bin files in the LFS-tracked cache dir.
		if not cache_only:
			_baked_tiles[tile] = []
		return
	var raw_count := int(round(
		tile_max_density * tile_area * density_multiplier))
	var candidates := clampi(raw_count, 1, placements_per_tile_cap)
	var max_density := tile_max_density

	for _i in candidates:
		var jx := rng.randf()
		var jz := rng.randf()
		var wx := origin_x + jx * tile_size_m
		var wz := origin_z + jz * tile_size_m
		var biome := _biome_at_world(wx, wz)
		if biome < 0:
			continue
		if not _biome_species_idx.has(biome):
			continue
		# Terrain Y at this candidate. Hoisted above the exclusion
		# check because the zone test needs full XYZ; reused below
		# for placement so the rejection path costs one heightmap
		# lookup per skipped candidate.
		var y := _height_at_world(wx, wz)
		# Procedural exclusion zones — POIs the user is hand-detailing.
		# `density_multiplier` returns 0.0 for full exclusion (default)
		# or a per-system thinning factor (e.g. towns may keep 50 %
		# ground cover while killing trees + rocks entirely).
		var excl_mul: float = _ExclusionZoneRef.density_multiplier(
			get_tree(), wx, y, wz, "ground_cover")
		if excl_mul <= 0.0:
			continue
		# Rock exclusion — big boulder species suppress ground cover
		# that would grow inside them. Same per-tile exclusion array
		# RockScatter publishes for trees; ferns / grass species
		# share the lookup. ~40 ops per candidate call.
		#
		# Inlined to bypass a Godot @tool quirk where calling a
		# `static func` through a `const preload(...)` script ref
		# can fail with "Nonexistent function ... in base 'GDScript'"
		# after hot-reload (the static-method binding gets dropped on
		# the stale Script object). Instance dispatch via
		# `has_method` is unaffected.
		var _rock_excluded: bool = false
		for _rs in get_tree().get_nodes_in_group(&"rocks_tree_exclusion"):
			if _rs.has_method("_point_excluded") \
					and _rs._point_excluded(wx, wz):
				_rock_excluded = true
				break
		if _rock_excluded:
			continue
		# Soft road clearance — gentle thin within
		# `road_clearance_radius_m` of any road pixel. OFF by default
		# (the biome routing already handles on-road pixels); enable
		# to dial back ground cover near road shoulders / town fringes.
		var road_score: float = _road_proximity_score(wx, wz)
		var road_factor: float = 1.0 - road_score * road_clearance_strength
		# Acceptance probability scales linearly with biome target. A
		# biome at `_max_plants_per_sq_m` accepts everything; a biome
		# at half that accepts ~50 %. `excl_mul` thins further inside
		# soft-clearance exclusion zones (towns, etc.).
		var biome_target: float = _biome_density.get(biome, 0.0)
		var accept_p := (biome_target / max_density) * excl_mul * road_factor
		if accept_p < 1.0 and rng.randf() > accept_p:
			continue
		# Slope thinning. The splat-derived biome doesn't always agree
		# with the geometry — a "forest" splat pixel on a steep slope
		# would otherwise carpet a cliff face in ferns. Sample a 2 m
		# centered finite-difference height gradient and apply a
		# smoothstep falloff between `slope_thin_start` and
		# `slope_cutoff`.
		if slope_cutoff > slope_thin_start:
			var slope := _slope_at_world(wx, wz)
			if slope >= slope_cutoff:
				continue
			if slope > slope_thin_start:
				var slope_t := (slope - slope_thin_start) / (slope_cutoff - slope_thin_start)
				var slope_keep := 1.0 - smoothstep(0.0, 1.0, slope_t)
				if rng.randf() > slope_keep:
					continue
		var sp_idx := _pick_species(biome, rng.randf(), wx, wz)
		if sp_idx < 0:
			continue
		_ensure_species_resources(sp_idx)
		var meshes: Array = _species_meshes.get(sp_idx, [])
		if meshes.is_empty():
			continue
		# Per-tile variant pool. First instance of each species in this
		# tile builds a small pool of `variants_per_tile` variant
		# indices; each candidate then picks one from the pool. Pool
		# size 1 = "all instances same variant" (perf-optimal). Larger
		# pools add visual variety at the cost of more MMI buckets.
		var pool: Array = per_species_variant_pool.get(sp_idx, [])
		if pool.is_empty():
			var n_variants: int = meshes.size()
			var pool_size: int = clampi(variants_per_tile, 1, n_variants)
			for _vi in pool_size:
				pool.append(rng.randi() % n_variants)
			per_species_variant_pool[sp_idx] = pool
		var var_idx: int = pool[rng.randi() % pool.size()]
		var sp: FoliageSpecies = _species_table[sp_idx]
		# `y` was computed earlier (above the exclusion check) for
		# the zone XYZ test; reuse here.
		# Per-variant unit scale (Quixel/Fab 0.01, PolyHaven 1.0)
		# multiplied by per-species jitter + size_multiplier.
		# Compose: variant_basis (mesh-local → Godot frame: includes
		# UE→Godot rotation + cm→m scale for Fab) applied first, then
		# per-instance scale jitter + random yaw on top. Order matters
		# — yawing in mesh-local frame would rotate around the wrong
		# axis on Fab assets.
		var variant_bases: Array = _species_mesh_bases.get(sp_idx, [])
		var v_basis: Basis = (variant_bases[var_idx]
			if var_idx < variant_bases.size() else Basis.IDENTITY)
		var basis := Basis()
		var s := lerpf(sp.scale_min, sp.scale_max, rng.randf()) * sp.size_multiplier
		basis = basis.scaled(Vector3(s, s, s))
		if sp.random_yaw:
			basis = basis.rotated(Vector3.UP, rng.randf() * TAU)
		basis = basis * v_basis
		var xform := Transform3D(basis, Vector3(wx, y, wz))
		var roll := rng.randf()
		# Bucket by (species, variant) — one MMI per pair, one mesh
		# per MMI as Godot requires.
		var bucket_key := Vector2i(sp_idx, var_idx)
		if not per_species_xforms.has(bucket_key):
			per_species_xforms[bucket_key] = [] as Array
			per_species_rolls[bucket_key] = [] as Array
		per_species_xforms[bucket_key].append(xform)
		per_species_rolls[bucket_key].append(roll)

	if per_species_xforms.is_empty():
		if not cache_only:
			_baked_tiles[tile] = []
		return

	if cache_only:
		# Whole-map bake: skip the MMI / scene-tree work entirely and
		# jump straight to the cache write below. Avoids RID exhaustion
		# on large maps (see _bake_tile docstring).
		if cache_enabled:
			_write_tile_cache(tile, per_species_xforms, per_species_rolls)
		return

	var mmis: Array[MultiMeshInstance3D] = []
	# Per-tile custom AABB so frustum culling fires on each tile rather
	# than on a single map-spanning AABB. The Y range is generous
	# because we don't track per-tile height bounds; renderer culling
	# only cares that the AABB contains the actual mesh fragments.
	var tile_aabb := AABB(
		Vector3(origin_x, _vert_min - 50.0, origin_z),
		Vector3(tile_size_m, (_vert_max - _vert_min) + 100.0, tile_size_m))
	for key_v in per_species_xforms.keys():
		var key: Vector2i = key_v
		var sp_idx_b: int = key.x
		var var_idx_b: int = key.y
		var xforms: Array = per_species_xforms[key]
		var rolls: Array = per_species_rolls[key]
		var sp_meshes: Array = _species_meshes.get(sp_idx_b, [])
		if var_idx_b >= sp_meshes.size():
			continue
		# Pack the species's tier into INSTANCE_CUSTOM.y so the shader
		# can do per-tier distance culling at render time. SMALL=0,
		# MEDIUM=1, LARGE=2. INSTANCE_CUSTOM.z = bake-time stamp (in
		# seconds since engine start) for per-instance fade-in: shader
		# scales the mesh from 0 → full size over the first 0.5 s after
		# bake, eliminating the hard pop when a fresh tile enters
		# visible range.
		var sp_for_custom: FoliageSpecies = _species_table[sp_idx_b]
		var tier_f: float = float(sp_for_custom.size_tier)
		var bake_time_s: float = float(Time.get_ticks_msec()) / 1000.0
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = sp_meshes[var_idx_b]
		mm.instance_count = xforms.size()
		mm.custom_aabb = tile_aabb
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
			mm.set_instance_custom_data(i, Color(
				rolls[i], tier_f, bake_time_s, 0.0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Descriptive name: species file + variant node name. Lets the
		# user mouse over a problem plant in the editor scene tree and
		# immediately read which species + variant it came from.
		var sp_b: FoliageSpecies = _species_table[sp_idx_b]
		var sp_label_b: String = (sp_b.resource_path.get_file()
			if sp_b != null and not sp_b.resource_path.is_empty()
			else "sp%d" % sp_idx_b)
		var var_names_b: Array = _species_mesh_names.get(sp_idx_b, [])
		var var_label_b: String = (str(var_names_b[var_idx_b])
			if var_idx_b < var_names_b.size()
			else "v%d" % var_idx_b)
		mmi.name = "Tile_%d_%d_%s_%s" % [
			tile.x, tile.y, sp_label_b, var_label_b]
		# NOTE: ground cover MMIs sit at the scatter's world origin
		# (instance transforms inside the MultiMesh are absolute world
		# coords, not tile-local). Adding `visibility_range_end` here
		# would measure distance from camera to origin — not to the
		# tile — so every MMI would cull as soon as the camera is past
		# the tier radius from origin (player at terrain center is
		# already 600 m up, so EVERY MMI vanishes). Skip the MMI-level
		# cull; per-instance shader cull (`gc_tier_radius_*`) handles
		# the precise per-tree distance check. Trees position their
		# per-tile container at tile center (re-baked to local) so
		# they CAN use this; ground cover hasn't been refactored that
		# way and the vert cost is small enough that it doesn't need
		# the outer cull anyway.
		add_child(mmi)
		# Deliberately NOT setting `mmi.owner = edited_scene_root`. Without
		# an owner, Godot treats these as transient runtime children —
		# they show up in the scene tree but do not save into the .tscn,
		# so editor preview can't bloat the scene file.
		mmis.append(mmi)
	_baked_tiles[tile] = mmis

	# Persist to disk so subsequent visits hit the fast path. The save
	# is cheap (binary `.res` via ResourceSaver) but still meaningful
	# at scale — skip if disabled or if the bake produced nothing.
	if cache_enabled and not per_species_xforms.is_empty():
		_write_tile_cache(tile, per_species_xforms, per_species_rolls)


func _pick_species(biome: int, r: float, wx: float, wz: float) -> int:
	var idx_list: PackedInt32Array = _biome_species_idx[biome]
	var cum: PackedFloat32Array = _biome_species_cumweight[biome]
	if cum.size() == 0:
		return -1
	# When clumping is off (or noise array not built), fall back to
	# the original cumulative-weight RNG.
	if species_clumping <= 0.0 or _species_noise.is_empty():
		var total := cum[cum.size() - 1]
		var target := r * total
		for i in cum.size():
			if target <= cum[i]:
				return idx_list[i]
		return idx_list[idx_list.size() - 1]
	# Noise-modulated cumulative weight. Per-species effective weight =
	# `base_weight × max(0, 1 + clumping × noise(x, z))`. Patches
	# emerge naturally because each species has its own noise field —
	# where species A's noise is high, A wins more often.
	var n_species := idx_list.size()
	var eff_weights := PackedFloat32Array()
	eff_weights.resize(n_species)
	var total_eff := 0.0
	var prev_cum := 0.0
	for i in n_species:
		var base_w: float = cum[i] - prev_cum
		prev_cum = cum[i]
		var sp_idx: int = idx_list[i]
		var noise_val := 0.0
		if sp_idx < _species_noise.size():
			noise_val = _species_noise[sp_idx].get_noise_2d(wx, wz)
		var eff: float = base_w * maxf(0.0, 1.0 + species_clumping * noise_val)
		eff_weights[i] = eff
		total_eff += eff
	if total_eff <= 0.0:
		return idx_list[0]
	var target_eff := r * total_eff
	var acc := 0.0
	for i in n_species:
		acc += eff_weights[i]
		if target_eff <= acc:
			return idx_list[i]
	return idx_list[n_species - 1]


# --- Splatmap / heightmap sampling (raw byte indexing) ---

# Convert centered-world XZ to source-pixel coords; returns (-1,-1) if
# outside the map.
func _world_to_pixel(wx: float, wz: float) -> Vector2i:
	var u := (wx + _extent_x * 0.5) / _spacing_m
	var v := (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 or u > float(_terrain_w - 1) or v > float(_terrain_h - 1):
		return Vector2i(-1, -1)
	return Vector2i(int(u), int(v))


# Returns dominant biome id at this world XZ, or -1 if foliage
# should be suppressed (water, road, cliff, snow, builtup).
#
# When `_terrain3d` is wired up, queries Terrain3D's control map
# directly — whatever Terrain3D *renders* at that pixel is what we
# use. This avoids drift between foliage and terrain: the loader
# applies a 7×7 splat blur before encoding the control map, so the
# rendered base slot at a pixel can disagree with raw splat argmax
# (cliff weight 50 in raw → 90 after blur from neighbors → cliff
# wins on terrain side, but raw forest weight 100 still wins on
# foliage side → ferns on cliff faces / paved roads). Reading
# Terrain3D's control map sidesteps the disagreement entirely.
#
# Falls back to raw splat argmax when no Terrain3D is configured.
func _biome_at_world(wx: float, wz: float) -> int:
	# `_terrain3d_valid` is the cached `is_instance_valid` result —
	# refreshed in `_resolve_terrain3d`. Saves ~3 μs per call vs the
	# raw `is_instance_valid` check, which adds up at ~4000 calls
	# per tile bake.
	if _terrain3d_valid:
		return _biome_via_control_map(wx, wz)
	return _biome_via_splat(wx, wz)


# Map a Terrain3D texture slot id (0..15) to a foliage `BiomeId`
# or -1 to suppress. Mirrors the slot layout in
# `terrain3d_assets_pnw.tres` and `terrain3d_loader.gd`.
func _slot_to_biome(slot: int) -> int:
	match slot:
		0:  # Forest
			return BiomeSpeciesConfig.BiomeId.FOREST
		1:  # Grassland
			return BiomeSpeciesConfig.BiomeId.GRASSLAND
		3:  # Cropland
			return BiomeSpeciesConfig.BiomeId.CROPLAND
		4:  # Bare
			return BiomeSpeciesConfig.BiomeId.BARE
		8, 9, 10:  # Paved / Unpaved / Trail
			if _biome_species_idx.has(BiomeSpeciesConfig.BiomeId.ROAD):
				return BiomeSpeciesConfig.BiomeId.ROAD
			return -1
		_:
			# 2 Water, 5 BuiltUp, 6 Cliff, 7 Snow → suppress.
			# 11..15 (variants) only appear as overlay in our bake;
			# the base they sit on decides foliage. Defensive default
			# is suppress in case a variant ends up as base via auto-
			# shader fallback.
			return -1


# Constant matching `Terrain3DRegion.TYPE_CONTROL`. Hardcoded as 1
# rather than referenced symbolically so this script parses without
# the Terrain3D extension loaded (headless `--check-only` doesn't
# have addon classes).
const _T3D_TYPE_CONTROL := 1


# Query Terrain3D's control map at world XZ, decode the packed
# uint32 (base + overlay + blend), and translate to a foliage
# biome.
func _biome_via_control_map(wx: float, wz: float) -> int:
	var col: Color = _terrain3d.data.get_pixel(_T3D_TYPE_CONTROL,
		Vector3(wx, 0.0, wz))
	# `get_pixel` returns NaN .r outside region coverage — treat as
	# off-map (suppress).
	if is_nan(col.r):
		return -1
	# The control image is `FORMAT_RF` with each pixel storing a
	# `uint32` reinterpret-cast to `float32` (Terrain3D's encoding —
	# see `Terrain3DUtil.as_float` in `terrain3d_loader.gd`). Round-
	# trip via the cached `_bvc_buf` (allocated once in `_ready`,
	# resize is a no-op after first use) to avoid per-call alloc
	# churn — this fires ~4000× per tile bake.
	if _bvc_buf.size() != 4:
		_bvc_buf.resize(4)
	_bvc_buf.encode_float(0, col.r)
	var control: int = _bvc_buf.decode_u32(0)
	# Bit layout matches the shader's DECODE_* macros:
	#   base_id    = (control >> 27) & 0x1F
	#   overlay_id = (control >> 22) & 0x1F
	#   blend      = (control >> 14) & 0xFF   (0..255)
	var base_id: int = (control >> 27) & 0x1F
	var overlay_id: int = (control >> 22) & 0x1F
	var blend: int = (control >> 14) & 0xFF
	# Hard-priority road check on either layer. The loader's road
	# encoder swaps base/overlay around the 50 % point, which means
	# at the 1-pixel boundary one side reads as base=road and the
	# other as base=biome with overlay=road — a clean geometric
	# step. Treating any meaningful road in either slot as ROAD
	# closes the boundary so foliage doesn't bleed onto the road
	# surface at exactly that one pixel.
	const _SLOT_PAVED_LO := 8
	const _SLOT_PAVED_HI := 10
	const _ROAD_OVERLAY_BLEND_THRESHOLD := 64  # 25 % overlay
	var base_is_road := base_id >= _SLOT_PAVED_LO and base_id <= _SLOT_PAVED_HI
	var overlay_is_road := overlay_id >= _SLOT_PAVED_LO and overlay_id <= _SLOT_PAVED_HI
	if base_is_road or (overlay_is_road and blend > _ROAD_OVERLAY_BLEND_THRESHOLD):
		if _biome_species_idx.has(BiomeSpeciesConfig.BiomeId.ROAD):
			return BiomeSpeciesConfig.BiomeId.ROAD
		return -1
	# Pick the dominant slot. blend > 128 → overlay shows more.
	var dominant_id: int = base_id if blend < 128 else overlay_id
	# Variant slots (11..15) don't have a biome of their own — they
	# sit as overlays on cliff faces / forest floors via the loader's
	# variant pass. Fall through to the base when a variant ends up
	# dominant so e.g. "forest base + strong nordic_moss overlay"
	# still places forest plants, not nothing.
	if dominant_id >= 11 and dominant_id <= 15:
		dominant_id = base_id
	return _slot_to_biome(dominant_id)


# Raw-splat argmax fallback, used when no Terrain3D is wired up
# (e.g. the Rust `TerrainNode` path). Identical logic to what the
# previous `_biome_at_world` did before the control-map switch.
func _biome_via_splat(wx: float, wz: float) -> int:
	var pix := _world_to_pixel(wx, wz)
	if pix.x < 0:
		return -1
	var byte_idx := (pix.y * _terrain_w + pix.x) * 4
	if byte_idx + 3 >= _splat_a.size():
		return -1
	# Splat_a: R=Forest, G=Grassland, B=Water, A=Cropland
	var w_forest := int(_splat_a[byte_idx])
	var w_grass := int(_splat_a[byte_idx + 1])
	var w_water := int(_splat_a[byte_idx + 2])
	var w_crop := int(_splat_a[byte_idx + 3])
	# Splat_b: R=Bare, G=BuiltUp, B=Cliff, A=Snow
	var w_bare := int(_splat_b[byte_idx])
	var w_built := int(_splat_b[byte_idx + 1])
	var w_cliff := int(_splat_b[byte_idx + 2])
	var w_snow := int(_splat_b[byte_idx + 3])
	var w_road := 0
	if _splat_road.size() > byte_idx + 2:
		w_road = maxi(maxi(int(_splat_road[byte_idx]),
				int(_splat_road[byte_idx + 1])),
			int(_splat_road[byte_idx + 2]))
	# **Hard-priority road check.** Roads are narrow features (a
	# 4 m trail spans only 2 splat texels at 2 m spacing) so their
	# weights often lose an argmax contest against the wide-area
	# biome they pass through — forest weight 150 vs trail weight
	# 80 at the same pixel routes to forest, and ferns end up on
	# the trail. Routing on absolute threshold instead claims road
	# pixels for the road biome (or suppress) regardless of the
	# competing biome weight.
	if w_road > 50:
		if _biome_species_idx.has(BiomeSpeciesConfig.BiomeId.ROAD):
			return BiomeSpeciesConfig.BiomeId.ROAD
		return -1
	# Argmax across everything else. Sentinel kinds in the negative
	# range are suppress slots; positives map directly to BiomeId.
	const _KIND_SUPPRESS_WATER := -2
	const _KIND_SUPPRESS_BUILT := -3
	const _KIND_SUPPRESS_CLIFF := -4
	const _KIND_SUPPRESS_SNOW := -5
	# Threshold 20/255 (~8%) — below this everything reads as
	# background noise and we skip placing.
	var best_w := 20
	var best_kind := -1
	if w_forest > best_w:
		best_w = w_forest
		best_kind = BiomeSpeciesConfig.BiomeId.FOREST
	if w_grass > best_w:
		best_w = w_grass
		best_kind = BiomeSpeciesConfig.BiomeId.GRASSLAND
	if w_crop > best_w:
		best_w = w_crop
		best_kind = BiomeSpeciesConfig.BiomeId.CROPLAND
	if w_bare > best_w:
		best_w = w_bare
		best_kind = BiomeSpeciesConfig.BiomeId.BARE
	if w_water > best_w:
		best_w = w_water
		best_kind = _KIND_SUPPRESS_WATER
	if w_built > best_w:
		best_w = w_built
		best_kind = _KIND_SUPPRESS_BUILT
	if w_cliff > best_w:
		best_w = w_cliff
		best_kind = _KIND_SUPPRESS_CLIFF
	if w_snow > best_w:
		best_w = w_snow
		best_kind = _KIND_SUPPRESS_SNOW
	if best_kind < 0:
		return -1
	return best_kind


# Returns the world-space Y of the terrain surface at (wx, wz).
# Prefers `_terrain3d.data.get_height()` so foliage sits on the
# rendered surface (accounts for region snap, vertex_spacing, height
# offset). Falls back to direct `heightmap.r32` sampling if no
# Terrain3D was wired up.
func _height_at_world(wx: float, wz: float) -> float:
	if _terrain3d != null and is_instance_valid(_terrain3d):
		# `data.get_height` returns world Y at the given world XZ —
		# the .y component of the input is ignored by Terrain3D.
		# NaN comes back outside region coverage; return 0 so
		# out-of-region foliage at least lands at sea level rather
		# than vanishing into the void.
		var h: float = _terrain3d.data.get_height(Vector3(wx, 0.0, wz))
		if is_nan(h):
			return 0.0
		return h
	# Fallback: bilinear sample the canonical heightmap.r32 (literal
	# f32 meters; no vert_min/max remap needed in v2).
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
	var h_top := lerpf(h00, h10, fx)
	var h_bot := lerpf(h01, h11, fx)
	return lerpf(h_top, h_bot, fz)


# Approximate slope (rise / run) at world XZ via 4-tap centered
# finite difference on the height surface. Returns the magnitude
# of the gradient — independent of slope direction. 2 m sample
# step (one terrain texel) keeps the estimate local without
# becoming pixel-noisy.
#
# Fast path samples raw heightmap texels at integer offsets from the
# candidate's pixel — no bilinear interp. The original 4×
# `_height_at_world` calls did 16 byte reads + 12 lerps; this does
# Road proximity score in [0, 1]: 1 = sitting on a road, 0 = no road
# within `road_clearance_radius_m`. 9 splat reads (center + 4 inner
# cardinal + 4 outer diagonal), weighted by inverse distance to the
# candidate. Mirrors `tree_scatter._road_proximity_score`. Returns 0
# fast if the road clearance feature is disabled (radius 0).
func _road_proximity_score(wx: float, wz: float) -> float:
	if _splat_road.size() == 0 or road_clearance_radius_m <= 0.0:
		return 0.0
	var r: float = road_clearance_radius_m
	var center: float = float(_road_density_at(wx, wz)) / 255.0
	var inner_r: float = r * 0.5
	var samples_inner: float = (
		float(_road_density_at(wx + inner_r, wz))
		+ float(_road_density_at(wx - inner_r, wz))
		+ float(_road_density_at(wx, wz + inner_r))
		+ float(_road_density_at(wx, wz - inner_r))) / (255.0 * 4.0)
	var diag: float = r * 0.7071
	var samples_outer: float = (
		float(_road_density_at(wx + diag, wz + diag))
		+ float(_road_density_at(wx + diag, wz - diag))
		+ float(_road_density_at(wx - diag, wz + diag))
		+ float(_road_density_at(wx - diag, wz - diag))) / (255.0 * 4.0)
	var score: float = (center + samples_inner * 0.6 + samples_outer * 0.25) / 1.85
	return clampf(score, 0.0, 1.0)


# Returns "human presence" density: max across road tiers AND the
# BuiltUp channel (splat_b G). See tree_scatter._road_density_at for
# the rationale — town footprints often have BuiltUp tagging without
# road pixels through the centre.
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


# 8 byte reads + 4 subtracts. `_bake_tile` calls this thousands of
# times per tile when slope thinning is enabled.
func _slope_at_world(wx: float, wz: float) -> float:
	if _hm_bytes.is_empty() or _terrain_w <= 0 or _terrain_h <= 0:
		return 0.0
	var u := (wx + _extent_x * 0.5) / _spacing_m
	var v := (wz + _extent_z * 0.5) / _spacing_m
	var x := clampi(int(u), 0, _terrain_w - 1)
	var z := clampi(int(v), 0, _terrain_h - 1)
	var xl := maxi(x - 1, 0)
	var xr := mini(x + 1, _terrain_w - 1)
	var zd := maxi(z - 1, 0)
	var zu := mini(z + 1, _terrain_h - 1)
	# f32 meters straight from the .r32; no vert_min/max remap.
	var h_l := _sample_f32_meters(xl, z)
	var h_r := _sample_f32_meters(xr, z)
	var h_d := _sample_f32_meters(x, zd)
	var h_u := _sample_f32_meters(x, zu)
	# Step is 1 texel = `_spacing_m` meters in each direction; the
	# central-difference normalises the divisor to (2 × step) for both
	# axes.
	var inv_2step := 1.0 / (2.0 * _spacing_m)
	var dx := (h_r - h_l) * inv_2step
	var dz := (h_u - h_d) * inv_2step
	return sqrt(dx * dx + dz * dz)


# Decode one f32 sample (literal meters) from the canonical `.r32`
# byte buffer. Format-version-2; v1 used u16 + `vert_min/max` remap.
func _sample_f32_meters(x: int, z: int) -> float:
	return _hm_bytes.decode_float((z * _terrain_w + x) * 4)


func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


# --- Persistent bake cache ---

## Compute the cache invalidation key from every input that affects
## placement. Anything not hashed here is implicitly assumed not to
## change placement (e.g. shader uniforms).
func _compute_cache_key() -> String:
	# **Stable cache key**: only `cache_version` + `seed`. See the
	# field docstring on `cache_version` for the full rationale —
	# balance tweaks don't shuffle in-session bakes.
	var ctx := PackedStringArray()
	ctx.append("v%d" % cache_version)
	ctx.append(str(seed))
	return "|".join(ctx).md5_text().substr(0, 16)


## Cache file format magic — used to detect mismatched / corrupt
## files. Bumps when the binary layout below changes. (`const` can't
## hold a `PackedByteArray` literal in GDScript, so it lives as a
## module-level `var` initialised once.)
var _cache_magic: PackedByteArray = PackedByteArray([0x46, 0x42, 0x4B, 0x43])  # "FBKC"
const _CACHE_FORMAT_VERSION: int = 1

## Memoized cache key — `_compute_cache_key` iterates every biome's
## species + densities + hashes terrain.toml, so calling it once per
## tile (twice, with the write path) was a measurable per-tile cost.
## Computed lazily on first use, invalidated by `_force_rebuild` /
## `_build_species_table`.
var _cached_key: String = ""


func _get_cache_key() -> String:
	if _cached_key.is_empty():
		_cached_key = _compute_cache_key()
	return _cached_key


func _invalidate_cache_key() -> void:
	_cached_key = ""


func _cache_dir_for_map(key: String) -> String:
	return "res://assets/foliage_bake/%s/%s" % [map_id, key]


func _cache_path_for_tile(tile: Vector2i, key: String) -> String:
	# `.bin` instead of `.res` — these are raw FileAccess writes via
	# `var_to_bytes`, not Godot Resource files. Saves us the UID-
	# resolution warning storm that came with the Resource path.
	return "%s/%d_%d.bin" % [_cache_dir_for_map(key), tile.x, tile.y]


## Try to load + validate a tile cache. Returns the parsed data dict
## or an empty Dictionary on miss / mismatch (Godot's "warnings as
## errors" mode forbids `Variant` returns). Dict shape matches
## `_write_tile_cache`.
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
		per_species_rolls: Dictionary) -> void:
	var key := _get_cache_key()
	var buckets: Array = []
	for k_v in per_species_xforms.keys():
		var k: Vector2i = k_v
		var sp_idx: int = k.x
		var var_idx: int = k.y
		var sp: FoliageSpecies = _species_table[sp_idx]
		if sp.resource_path.is_empty():
			continue
		var xforms: Array = per_species_xforms[k]
		var rolls: Array = per_species_rolls[k]
		var t_flat := PackedFloat32Array()
		t_flat.resize(xforms.size() * 12)  # 9 basis floats + 3 origin
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
		var c_flat := PackedFloat32Array()
		c_flat.resize(rolls.size())
		for i in rolls.size():
			c_flat[i] = float(rolls[i])
		buckets.append({
			"species_path": sp.resource_path,
			"variant_idx": var_idx,
			"size_tier": int(sp.size_tier),
			"transforms": t_flat,
			"rolls": c_flat,
		})
	var data := {
		"cache_key": key,
		"map_id": map_id,
		"tile": [tile.x, tile.y],
		"buckets": buckets,
	}
	var dir := _cache_dir_for_map(key)
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var path := _cache_path_for_tile(tile, key)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[gc] failed to open cache for write: %s" % path)
		return
	var blob := var_to_bytes(data)
	f.store_buffer(_cache_magic)
	f.store_32(_CACHE_FORMAT_VERSION)
	f.store_64(blob.size())
	f.store_buffer(blob)
	f.close()


## Spawn MMIs from a cached tile dict. Mirrors the MMI-spawn loop in
## `_bake_tile`.
func _spawn_mmis_from_cache(tile: Vector2i, cache: Dictionary) -> void:
	var origin_x := float(tile.x) * tile_size_m
	var origin_z := float(tile.y) * tile_size_m
	var tile_aabb := AABB(
		Vector3(origin_x, _vert_min - 50.0, origin_z),
		Vector3(tile_size_m, (_vert_max - _vert_min) + 100.0, tile_size_m))
	var mmis: Array[MultiMeshInstance3D] = []
	var bake_time_s: float = float(Time.get_ticks_msec()) / 1000.0
	var buckets: Array = cache.get("buckets", [])
	for b_idx in buckets.size():
		var b: Dictionary = buckets[b_idx]
		var sp_path: String = b.get("species_path", "")
		var var_idx: int = b.get("variant_idx", 0)
		var tier_f: float = float(b.get("size_tier", 0))
		var sp: FoliageSpecies = load(sp_path) as FoliageSpecies
		if sp == null:
			continue
		var sp_idx := _species_table.find(sp)
		if sp_idx < 0:
			sp_idx = _species_table.size()
			_species_table.append(sp)
		_ensure_species_resources(sp_idx)
		var sp_meshes: Array = _species_meshes.get(sp_idx, [])
		if var_idx >= sp_meshes.size():
			continue
		var t_flat: PackedFloat32Array = b.get("transforms", PackedFloat32Array())
		var rolls: PackedFloat32Array = b.get("rolls", PackedFloat32Array())
		var n: int = rolls.size()
		if t_flat.size() != n * 12:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = sp_meshes[var_idx]
		mm.instance_count = n
		mm.custom_aabb = tile_aabb
		for i in n:
			var xf := Transform3D(
				Basis(
					Vector3(t_flat[i * 12 + 0], t_flat[i * 12 + 1], t_flat[i * 12 + 2]),
					Vector3(t_flat[i * 12 + 3], t_flat[i * 12 + 4], t_flat[i * 12 + 5]),
					Vector3(t_flat[i * 12 + 6], t_flat[i * 12 + 7], t_flat[i * 12 + 8])),
				Vector3(t_flat[i * 12 + 9], t_flat[i * 12 + 10], t_flat[i * 12 + 11]))
			mm.set_instance_transform(i, xf)
			mm.set_instance_custom_data(i, Color(rolls[i], tier_f, bake_time_s, 0.0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sp_label_c: String = (sp.resource_path.get_file()
			if not sp.resource_path.is_empty()
			else "sp%d" % sp_idx)
		var var_names_c: Array = _species_mesh_names.get(sp_idx, [])
		var var_label_c: String = (str(var_names_c[var_idx])
			if var_idx < var_names_c.size()
			else "v%d" % var_idx)
		mmi.name = "Tile_%d_%d_%s_%s" % [
			tile.x, tile.y, sp_label_c, var_label_c]
		add_child(mmi)
		mmis.append(mmi)
	_baked_tiles[tile] = mmis


## Inspector button: bake every tile within `prebake_radius_m` of the
## origin, writing each to cache. Synchronous — blocks the editor for
## a few seconds depending on radius. Run once per content change to
## pre-warm the player's spawn area.
func _bake_cache_near_origin() -> void:
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[gc] cannot bake cache: terrain not loaded")
		return
	if _species_table.is_empty():
		_build_species_table()
		if _species_table.is_empty():
			push_warning("[gc] cannot bake cache: empty species table")
			return
	# Force a fresh bake regardless of existing cache, then write the
	# results — this is how the user "rebuilds" their cache for an area.
	var prev_force := _bake_force_fresh
	_bake_force_fresh = true
	var radius_tiles := int(ceil(prebake_radius_m / tile_size_m))
	var n := 0
	var total := (radius_tiles * 2 + 1) * (radius_tiles * 2 + 1)
	print("[gc] baking foliage cache: radius=%.0fm (%d tiles, key=%s)..."
		% [prebake_radius_m, total, _get_cache_key()])
	for tz in range(-radius_tiles, radius_tiles + 1):
		for tx in range(-radius_tiles, radius_tiles + 1):
			var tile := Vector2i(tx, tz)
			# Free any existing tile so the bake always runs fresh.
			if _baked_tiles.has(tile):
				for mmi in _baked_tiles[tile]:
					if is_instance_valid(mmi):
						mmi.queue_free()
				_baked_tiles.erase(tile)
			_bake_tile(tile)
			n += 1
			if n % 100 == 0:
				print("[gc]   %d / %d tiles..." % [n, total])
	_bake_force_fresh = prev_force
	print("[gc] bake cache complete: %d tiles → %s/" % [
		n, _cache_dir_for_map(_get_cache_key())])


# Bake EVERY tile inside the active Terrain3D regions. Mirrors
# `tree_scatter._bake_cache_whole_map` — used both as a manual tool
# button and as the target of `Terrain3DBaker.Rebake Vegetation`.
func _bake_cache_whole_map() -> void:
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[gc] cannot bake whole map: terrain not loaded")
		return
	if _species_table.is_empty():
		_build_species_table()
		if _species_table.is_empty():
			push_warning("[gc] cannot bake whole map: empty species table")
			return
	if _terrain3d == null or not is_instance_valid(_terrain3d):
		push_warning("[gc] cannot bake whole map: Terrain3D node not resolved")
		return
	var region_size_verts: int = int(_terrain3d.get("region_size"))
	var vertex_spacing: float = float(_terrain3d.get("vertex_spacing"))
	var region_size_m := float(region_size_verts) * vertex_spacing
	var regions: Array = _terrain3d.data.get_regions_active()
	if regions.is_empty():
		push_warning("[gc] cannot bake whole map: no active Terrain3D regions")
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
	var prev_force := _bake_force_fresh
	_bake_force_fresh = true
	var t_start: int = Time.get_ticks_msec()
	var print_every: int = maxi(1, mini(100, total / 20))
	print("[gc] bake whole map: %d × %d tiles (%d total), bounds %.0f×%.0f m, key=%s"
		% [n_tx, n_tz, total, world_max_x - world_min_x,
		world_max_z - world_min_z, _get_cache_key()])
	var n: int = 0
	for tz in range(tile_min_z, tile_max_z + 1):
		for tx in range(tile_min_x, tile_max_x + 1):
			var tile := Vector2i(tx, tz)
			# `cache_only=true` skips MMI instantiation — we're populating
			# disk cache, not visualising. Runtime spawns from cache when
			# the player gets close. Pre-existing scene-tree MMIs from
			# the editor preview pass are intentionally left alone; they
			# stay as the visible preview while the cache rebuilds.
			_bake_tile(tile, true)
			n += 1
			if n % print_every == 0 or n == total:
				var t_now: int = Time.get_ticks_msec()
				var elapsed_s: float = float(t_now - t_start) / 1000.0
				var pct: float = 100.0 * float(n) / float(total)
				var rate: float = float(n) / maxf(elapsed_s, 0.001)
				var eta_s: float = float(total - n) / maxf(rate, 0.001)
				print("[gc]   %d / %d (%.1f%%) — %.1fs elapsed, %.1f tiles/s, ETA %.0fs"
					% [n, total, pct, elapsed_s, rate, eta_s])
	_bake_force_fresh = prev_force
	var t_end: int = Time.get_ticks_msec()
	var total_s: float = float(t_end - t_start) / 1000.0
	print("[gc] bake whole map COMPLETE: %d tiles in %.1fs (%.1f tiles/s avg) → %s/"
		% [n, total_s, float(n) / maxf(total_s, 0.001),
		_cache_dir_for_map(_get_cache_key())])


## Inspector button: deletes every cache file under
## `res://assets/foliage_bake/<map_id>/`. Useful after rearranging
## biome configs if the orphaned key dirs are eating disk.
func _clear_cache_for_map() -> void:
	var root := "res://assets/foliage_bake/%s" % map_id
	var n := _delete_dir_recursive(root)
	print("[gc] cleared %d cache files from %s" % [n, root])


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
