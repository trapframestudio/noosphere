@tool
class_name TrashScatter
extends Node3D

## Procedural trash scatter — places litter / debris near roads and
## in town-style exclusion zones. Mirrors `RockScatter` shape so the
## conventions match the rest of the foliage pipeline:
##
## - **Terrain loading**: `_parse_terrain_toml` + heightmap byte
##   buffer (same as rock + tree scatter).
## - **Species lookup**: path-keyed `_species_resource_cache` so cache
##   entries survive species reorders + array edits in the inspector.
## - **Tile spawn**: each tile gets a `Node3D` container positioned at
##   `tile_center`, with per-instance transforms translated to local
##   space — same pattern rock_scatter uses, halves the per-MMI float
##   precision cost on big maps.
## - **Static species** → one `MultiMeshInstance3D` per species per
##   tile. Cheap, no collision, no physics.
## - **Physics species** → one `RigidBody3D` per instance, spawned
##   sleeping (frozen-until-hit). Layer `Layers.CONCEALMENT` so the
##   player can walk through visible piles but kicks register; bullets
##   pass through (CONCEALMENT is partial-LOS, not solid). Spawned
##   only inside `physics_active_radius_m` of the camera.
## - **Wind-responsive species** → subset of physics species with
##   `wind_susceptibility > 0`. A periodic wind tick reads the active
##   `WeatherRig`'s `wind_vector_xz()` and applies an impulse so light
##   items tumble in gusts. No-ops when calm or when no rig is in the
##   scene.

const _SLOT_PAVED: int = 8
const _SLOT_UNPAVED: int = 9
const _SLOT_TRAIL: int = 10

# Stable script ref for static-method dispatch. See `tree_scatter.gd`
# for why direct `ProceduralExclusionZone.foo()` is unsafe in @tool.
const _ExclusionZoneRef := preload("res://scripts/procedural_exclusion_zone.gd")

@export var map_id: String = "cascade_locks"
@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Node3D") var terrain3d_path: NodePath
@export var seed: int = 12345

@export_group("Tile streaming")
@export_range(8.0, 128.0, 1.0) var tile_size_m: float = 32.0
@export_range(20.0, 400.0, 5.0) var active_radius_m: float = 100.0
@export_range(2.0, 80.0, 0.5) var rebuild_threshold_m: float = 12.0
@export_range(16, 4096, 16) var placements_per_tile_cap: int = 256

@export_group("Density")
## Master multiplier on every species's effective density. 1.0 =
## as configured per-species. Drop to dial trash down across the
## whole map.
@export_range(0.0, 4.0, 0.05) var density_multiplier: float = 1.0
## Base placements/m² before per-candidate factors (road weight, zone
## boost). Real density in the world is much lower because most
## candidates land on no-road, no-zone terrain and reject. ~0.25 is
## a good baseline — paved roads with `paved_weight = 1.0` get
## visible trash without overrun.
@export_range(0.0, 5.0, 0.05) var base_density_per_sq_m: float = 0.25
## Proximity radius around a road in which trash gets road-driven
## weight. 0 = no falloff (only on-road pixels count). 8-12 m is
## typical: trash blows from the road into a several-meter strip on
## the verge but doesn't cover the whole forest floor.
@export_range(0.0, 40.0, 1.0) var road_clearance_radius_m: float = 8.0

@export_group("Organic distribution")
## A 2D Perlin noise mask multiplied into each candidate's accept
## probability. Without this the road / zone / builtup signals drive
## a uniform random sprinkle that reads as "noise pattern", not
## naturalistic — real trash forms clusters at dump-spots and rest
## stops with empty stretches in between.
##
## Mask values come from a Perlin noise sampled at world XZ, remapped
## from `[-1, 1]` to `[hotspot_floor, hotspot_ceiling]`. With the
## defaults — floor 0, ceiling 2 — the average mask across the map
## is ~1.0 (no overall density change), but ~50% of the area is below
## 1.0 (sparser than uniform), ~50% is above 1.0 (denser), and the
## bottom tail bottoms out at 0 (cold spots have no trash at all).
##
## **Floor 0 + ceiling 2** = strong clusters with visibly empty
## stretches. **Floor 0.4 + ceiling 1.6** = softer clustering, no
## hard-empty zones. **Floor 1 + ceiling 1** = uniform (disabled).
@export_range(0.0, 1.0, 0.05) var hotspot_floor: float = 0.0
## Multiplier applied to accept probability at the noise's hottest
## points. Together with `hotspot_floor`, frames the noise output
## range. Set ceiling > 1 so hotspots get extra density to compensate
## for the cold spots; ceiling = 1 with floor < 1 gives a pure
## suppression mask.
@export_range(0.5, 4.0, 0.05) var hotspot_ceiling: float = 2.0
## Frequency of the hotspot noise, in inverse meters. 0.02 ≈ 50 m
## feature size (clusters every ~30-60 m, the default — feels right
## for forest road / camp / outpost trash). 0.04 = 25 m (tighter,
## smaller clusters); 0.01 = 100 m (broader hot/cold zones).
@export_range(0.005, 0.2, 0.001) var hotspot_frequency: float = 0.02

## Per-tile damper that down-weights species each time they're
## picked, so any one species can't keep winning the roulette. After
## `n` placements of the same species in the current tile, that
## species's weight is multiplied by `1 / (1 + n × damper)` — so at
## damper = 0.5, the second placement is 67%, third is 50%, fourth
## is 40% as likely. 0 = pure roulette (current behavior, prone to
## "rows of identical bottles"); ~0.5 = noticeable variety; ~2 =
## near-strict round-robin. Per-tile state, so neighboring tiles
## still vary independently.
@export_range(0.0, 4.0, 0.1) var same_species_repeat_damper: float = 0.5

@export_group("Whole-map prebake")
## Bake all tiles whose center is within this radius of world origin
## when the user clicks "Bake placement cache". Filtered: only tiles
## whose bounds intersect a road-splat region OR a trash-positive
## exclusion zone are baked — empty-forest tiles are skipped.
@export_range(0.0, 5000.0, 50.0) var prebake_radius_m: float = 2500.0

@export_group("Physics tier")
## Physics-enabled species only spawn within this radius (camera
## origin). Outside: physics species are skipped entirely (the static
## MMI is unaffected). Smaller = fewer RigidBodies live = better perf.
@export_range(20.0, 200.0, 5.0) var physics_active_radius_m: float = 60.0

@export_group("Wind")
## Wind tick interval (seconds). At each tick, every alive physics
## body with `wind_susceptibility > 0` gets one impulse proportional
## to (wind_vector × susceptibility × random_jitter). Slower tick =
## quieter gusts; faster = more constant tumbling. 1.5 s reads as
## "occasional gust" in light wind, "steady push" in a windstorm.
@export_range(0.25, 8.0, 0.05) var wind_tick_interval_s: float = 1.5
## Impulse scalar applied per tick. Tuned at 1.0 so a 5 g paper at
## susceptibility 1 in a `windstorm` (`wind_strength` ~4) tumbles
## visibly each tick, while a 0.5 kg flipflop at susceptibility 0.4
## only stirs in the same conditions. Adjust if the global feel of
## wind is too weak or too thrashy.
@export_range(0.0, 4.0, 0.01) var wind_impulse_scale: float = 0.6

@export_group("Species")
## Paths to TrashSpecies .tres files. Same pattern as ground cover
## (paths instead of Array[Resource] to dodge inspector crashes
## on resource swaps in arrays).
@export var species_paths: Array[String] = []

@export_group("Bake cache")
## Bump to invalidate the on-disk placement cache. See `cache_version`
## docstrings on TreeScatter / RockScatter for the contract.
@export_range(1, 999, 1) var cache_version: int = 1
## On-disk placement cache. When enabled, _bake_tile checks
## `assets/foliage_bake/<map_id>/trash/<key>/<x>_<z>.bin` first;
## rolls fresh on miss + writes the cache.
@export var cache_enabled: bool = true

# Tool buttons. Lambda-wrapped so the Callable resolves at button-press
# time rather than script-load time — works around a stale-binding
# issue if the script briefly has a parse error (Godot caches
# "no such method" in the editor's method table even after the parse
# error is fixed; bare function references stay Nil until full reload).
@export_tool_button("Bake placement cache", "Save") var bake_cache_action: Callable = func(): _bake_cache_near_origin()
@export_tool_button("Bake whole map", "Save") var bake_whole_map_action: Callable = func(): _bake_cache_whole_map()
@export_tool_button("Clear placement cache", "Remove") var clear_cache_action: Callable = func(): _clear_cache_for_map()
@export_tool_button("Rebuild trash", "Reload") var force_rebuild_action: Callable = func(): _force_rebuild()
## Pre-warm species (load GLB + materials) before the first tile bake.
## Like ground_cover.gd's prewarm step. 0 disables.
@export_range(0, 32, 1) var prewarm_per_frame_budget: int = 4
## Bake N tiles per frame after the prewarm completes. Spreads
## work across frames; lower = smoother.
@export_range(0, 32, 1) var bake_per_frame_budget: int = 2

@export_group("Editor preview")
@export var editor_preview: bool = false: set = _set_editor_preview

# --- Internal state ---
var _camera: Camera3D = null
var _terrain3d: Node3D = null
var _terrain_ready: bool = false
var _hm_bytes: PackedByteArray = PackedByteArray()
var _splat_road: PackedByteArray = PackedByteArray()
# Splat B carries the BuiltUp channel (G) — non-zero in town footprints
# even where the road_density splat has 0 pixels (e.g. building
# interiors, plazas). Without splat_b, town centers would get zero road
# score and trash would only appear on the literal road pixels.
var _splat_b: PackedByteArray = PackedByteArray()
var _terrain_w: int = 0
var _terrain_h: int = 0
var _spacing_m: float = 1.0
var _extent_x: float = 0.0
var _extent_z: float = 0.0
var _last_player_xz: Vector2 = Vector2(INF, INF)

# Path-keyed species cache. Mirrors rock_scatter._species_resource_cache.
var _species_resource_cache: Dictionary = {}     # path → TrashSpecies
var _species_meshes: Dictionary = {}             # path → Array[Mesh]
var _species_materials: Dictionary = {}          # path → Array[Material]
var _baked_tiles: Dictionary = {}                # Vector2i → Node3D container
# Per-tile snapshot of `spawn_physics` at the time the tile was last
# spawned. When the camera crosses `physics_active_radius_m` for a
# tile (player walks closer to a tile spawned with MMI fallback, or
# walks away from a tile spawned with RigidBody3D), `_rebuild_active`
# notices the mismatch and re-queues the tile for re-spawn so the
# correct representation appears.
var _tile_spawn_physics: Dictionary = {}         # Vector2i → bool
var _bake_queue: Array[Vector2i] = []
var _prewarm_cursor: int = -1

# Live physics-body registry, used by the wind tick. Holds weak refs
# (RigidBody3D instances) so freed bodies drop out naturally on next
# tick without manual cleanup. Keyed by tile so we can prune cleanly
# when a tile unloads.
var _wind_bodies_by_tile: Dictionary = {}        # Vector2i → Array[RigidBody3D]
var _wind_tick_accum: float = 0.0
var _weather_rig: WeatherRig = null
# Persistent RNG for wind jitter — randomized once at _ready, reused
# across ticks so we're not allocating + reseeding a fresh RNG on
# every wind cycle (~3-10 Hz). Visual jitter looks identical either
# way; this just spares the alloc.
var _wind_rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Hotspot noise — lazy, deterministic per `seed`. Sampling cost is one
# `get_noise_2d` per main-pass candidate; FastNoiseLite is fast enough
# that this is well below the splat-sample cost already paid.
var _hotspot_noise: FastNoiseLite = null


func _ready() -> void:
	add_to_group("trash_scatters")
	_wind_rng.randomize()
	if not Engine.is_editor_hint():
		_camera = get_viewport().get_camera_3d()
	set_process(true)


func _process(dt: float) -> void:
	var cam: Camera3D
	if Engine.is_editor_hint():
		if not editor_preview:
			return
		cam = _get_editor_camera()
	else:
		cam = _camera
		if cam == null and get_viewport() != null:
			cam = get_viewport().get_camera_3d()
	if cam == null:
		return
	# Cache the active camera (editor OR runtime) so `_tile_in_physics_range`
	# and the wind tick can read it without re-resolving. Without this,
	# `_camera` would stay null in editor preview and physics species
	# would never spawn even while the editor camera is in range.
	_camera = cam
	if not _terrain_ready and not _ensure_terrain_loaded():
		return
	if _species_resource_cache.is_empty():
		_build_species_table()
		if _species_resource_cache.is_empty():
			return
	# Prewarm before baking.
	if prewarm_per_frame_budget > 0 and _prewarm_cursor < species_paths.size():
		if _prewarm_cursor < 0:
			_prewarm_cursor = 0
		var stop: int = mini(_prewarm_cursor + prewarm_per_frame_budget,
			species_paths.size())
		while _prewarm_cursor < stop:
			_ensure_species_resources(species_paths[_prewarm_cursor])
			_prewarm_cursor += 1
		return
	var p_xz: Vector2 = Vector2(cam.global_position.x, cam.global_position.z)
	if (p_xz - _last_player_xz).length() >= rebuild_threshold_m:
		_rebuild_active(p_xz)
	if bake_per_frame_budget > 0 and not _bake_queue.is_empty():
		_drain_bake_queue(bake_per_frame_budget)
	# Wind tick — runtime only. Editor-preview keeps physics frozen so
	# the inspector experience is stable (no items drifting while you
	# tweak the scatter).
	if not Engine.is_editor_hint():
		_wind_tick_accum += dt
		if _wind_tick_accum >= wind_tick_interval_s:
			_wind_tick_accum = 0.0
			_apply_wind_tick()


func _get_editor_camera() -> Camera3D:
	# Match rock_scatter / tree_scatter — the editor's 3D viewport
	# camera lives in a separate viewport hierarchy from `get_tree()`,
	# so the only correct way to reach it is `EditorInterface`. Walking
	# `get_tree().get_root()` returns runtime viewports, NOT the editor
	# 3D viewport, so the streaming radius never moves with the editor
	# camera. Symptom (2026-05-04): in editor preview, trash only
	# spawns near world origin — the runtime camera (player spawn)
	# anchors `_last_player_xz`, and the editor viewport camera being
	# elsewhere doesn't trigger _rebuild_active. Result: trash visible
	# only inside the active radius around world origin (which happens
	# to overlap the Town zone), nowhere else.
	if not Engine.is_editor_hint():
		return null
	var vp = EditorInterface.get_editor_viewport_3d()
	return vp.get_camera_3d() if vp != null else null


# --- Terrain + splat loading ---

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
	if _terrain_w <= 0 or _terrain_h <= 0:
		return false
	_extent_x = float(_terrain_w - 1) * _spacing_m
	_extent_z = float(_terrain_h - 1) * _spacing_m
	# Heightmap (try .r32 then legacy .r16)
	if FileAccess.file_exists(dir + "heightmap.r32"):
		var h := FileAccess.open(dir + "heightmap.r32", FileAccess.READ)
		if h != null:
			_hm_bytes = h.get_buffer(h.get_length())
			h.close()
	elif FileAccess.file_exists(dir + "heightmap.r16"):
		var h2 := FileAccess.open(dir + "heightmap.r16", FileAccess.READ)
		if h2 != null:
			_hm_bytes = h2.get_buffer(h2.get_length())
			h2.close()
	# Road splat (optional — without it, only zone-driven trash spawns)
	if FileAccess.file_exists(dir + "road_density.rgba8"):
		var r := FileAccess.open(dir + "road_density.rgba8", FileAccess.READ)
		if r != null:
			_splat_road = r.get_buffer(r.get_length())
			r.close()
	# Splat B for the BuiltUp channel (G channel = slot 5). Without
	# this, town centers without explicit road pixels read as zero road
	# score and trash only spawns on literal road pixels.
	if FileAccess.file_exists(dir + "splatmap_b.rgba8"):
		var b := FileAccess.open(dir + "splatmap_b.rgba8", FileAccess.READ)
		if b != null:
			_splat_b = b.get_buffer(b.get_length())
			b.close()
	_terrain_ready = _hm_bytes.size() > 0
	return _terrain_ready


# Shared TOML reader — same shape as rock_scatter._parse_terrain_toml.
# Recognizes float / int / string values for the terrain meta fields
# we care about (width, height, spacing_m).
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


# Bilinear height sample at world XZ, returns Y meters.
func _height_at_world(wx: float, wz: float) -> float:
	if _hm_bytes.is_empty() or _terrain_w <= 0:
		return 0.0
	var u: float = clampf(wx / _spacing_m + (_terrain_w - 1) * 0.5,
		0.0, float(_terrain_w - 1))
	var v: float = clampf(wz / _spacing_m + (_terrain_h - 1) * 0.5,
		0.0, float(_terrain_h - 1))
	var x0: int = int(u)
	var z0: int = int(v)
	var x1: int = mini(x0 + 1, _terrain_w - 1)
	var z1: int = mini(z0 + 1, _terrain_h - 1)
	var fx: float = u - float(x0)
	var fz: float = v - float(z0)
	# r32 = 4 bytes per sample, r16 = 2. Detect from buffer size.
	var per_sample: int = 4 if _hm_bytes.size() == _terrain_w * _terrain_h * 4 else 2
	if per_sample == 4:
		var h00: float = _read_f32(x0, z0)
		var h10: float = _read_f32(x1, z0)
		var h01: float = _read_f32(x0, z1)
		var h11: float = _read_f32(x1, z1)
		return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
	# r16 fallback (legacy maps): u16 normalized to [0,1]. Approximate
	# Y; TerrainNode does the precise sample for collision.
	var h00b: float = _read_u16_norm(x0, z0)
	var h10b: float = _read_u16_norm(x1, z0)
	var h01b: float = _read_u16_norm(x0, z1)
	var h11b: float = _read_u16_norm(x1, z1)
	return lerpf(lerpf(h00b, h10b, fx), lerpf(h01b, h11b, fx), fz)


func _read_f32(x: int, z: int) -> float:
	var idx: int = (z * _terrain_w + x) * 4
	return _hm_bytes.decode_float(idx)


func _read_u16_norm(x: int, z: int) -> float:
	var idx: int = (z * _terrain_w + x) * 2
	return float(_hm_bytes.decode_u16(idx)) / 65535.0


# Single-pixel road density at world XZ. Returns 0-1 = max across the
# 4 road_density channels (paved / unpaved / trail / reserved). Strictly
# road-only — BuiltUp lives on splat_b.G and is read separately via
# `_builtup_at` so anchor placement can distinguish "town interior" from
# "actual road surface" (anchors should clump in towns AT THE EDGES of
# roads, not on the asphalt itself).
func _road_density_at(wx: float, wz: float) -> float:
	if _terrain_w <= 0 or _splat_road.is_empty():
		return 0.0
	var u: float = (wx + _extent_x * 0.5) / _spacing_m
	var v: float = (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 or u >= float(_terrain_w) or v >= float(_terrain_h):
		return 0.0
	var x: int = int(u)
	var z: int = int(v)
	var i: int = (z * _terrain_w + x) * 4
	if i + 3 >= _splat_road.size():
		return 0.0
	var d: int = maxi(maxi(int(_splat_road[i]), int(_splat_road[i + 1])),
		maxi(int(_splat_road[i + 2]), int(_splat_road[i + 3])))
	return float(d) / 255.0


# Per-channel road densities at world XZ. Returns Vector3 of
# (paved, unpaved, trail) each in 0-1. Drives per-species weight
# composition: a paved-only species like a cardboard box reads only
# x; a trail-tolerant species like a cigarette butt reads all three
# at different scale. The single-scalar `_road_density_at` collapses
# this to max-of-channels for early-reject + edge detection.
func _road_channels_at(wx: float, wz: float) -> Vector3:
	if _terrain_w <= 0 or _splat_road.is_empty():
		return Vector3.ZERO
	var u: float = (wx + _extent_x * 0.5) / _spacing_m
	var v: float = (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 or u >= float(_terrain_w) or v >= float(_terrain_h):
		return Vector3.ZERO
	var x: int = int(u)
	var z: int = int(v)
	var i: int = (z * _terrain_w + x) * 4
	if i + 2 >= _splat_road.size():
		return Vector3.ZERO
	return Vector3(
		float(_splat_road[i]) / 255.0,       # R = paved
		float(_splat_road[i + 1]) / 255.0,   # G = unpaved
		float(_splat_road[i + 2]) / 255.0)   # B = trail


# 9-sample weighted proximity per road channel — same falloff curve
# as `_road_proximity_score` (center * 1.0 + inner ring * 0.6 +
# outer ring * 0.25, normalized by 1.85). Returns Vector3 of
# (paved, unpaved, trail) each in 0-1.
func _road_channels_proximity(wx: float, wz: float) -> Vector3:
	var r: float = road_clearance_radius_m if road_clearance_radius_m > 0.0 else 8.0
	var center: Vector3 = _road_channels_at(wx, wz)
	var inner_r: float = r * 0.5
	var inner: Vector3 = (
		_road_channels_at(wx + inner_r, wz)
		+ _road_channels_at(wx - inner_r, wz)
		+ _road_channels_at(wx, wz + inner_r)
		+ _road_channels_at(wx, wz - inner_r)) * 0.25
	var diag: float = r * 0.7071
	var outer: Vector3 = (
		_road_channels_at(wx + diag, wz + diag)
		+ _road_channels_at(wx + diag, wz - diag)
		+ _road_channels_at(wx - diag, wz + diag)
		+ _road_channels_at(wx - diag, wz - diag)) * 0.25
	var score: Vector3 = (center + inner * 0.6 + outer * 0.25) / 1.85
	return Vector3(
		clampf(score.x, 0.0, 1.0),
		clampf(score.y, 0.0, 1.0),
		clampf(score.z, 0.0, 1.0))


# BuiltUp density — splat_b.G. Town footprints, plazas, paved areas
# without explicit road pixels (parking lots, sidewalks, courtyards).
# Drives anchor placement preference (heaps + bags pile in built-up
# areas, NOT on actual roads).
func _builtup_at(wx: float, wz: float) -> float:
	if _terrain_w <= 0 or _splat_b.is_empty():
		return 0.0
	var u: float = (wx + _extent_x * 0.5) / _spacing_m
	var v: float = (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 or u >= float(_terrain_w) or v >= float(_terrain_h):
		return 0.0
	var x: int = int(u)
	var z: int = int(v)
	var i: int = (z * _terrain_w + x) * 4
	if i + 1 >= _splat_b.size():
		return 0.0
	return float(_splat_b[i + 1]) / 255.0


# Bare-ground density — splat_b.R. Empty lots, dirt patches, exposed
# soil with no significant vegetation. Reasonable home for trash piles
# (someone dumped it, nothing growing to hide it).
func _bare_at(wx: float, wz: float) -> float:
	if _terrain_w <= 0 or _splat_b.is_empty():
		return 0.0
	var u: float = (wx + _extent_x * 0.5) / _spacing_m
	var v: float = (wz + _extent_z * 0.5) / _spacing_m
	if u < 0.0 or v < 0.0 or u >= float(_terrain_w) or v >= float(_terrain_h):
		return 0.0
	var x: int = int(u)
	var z: int = int(v)
	var i: int = (z * _terrain_w + x) * 4
	if i >= _splat_b.size():
		return 0.0
	return float(_splat_b[i]) / 255.0


# 9-sample BuiltUp proximity score — same falloff pattern as
# `_road_proximity_score` but for builtup pixels. Used by the anchor
# pre-pass so heaps / bags get weighted into entire town footprints,
# not just on the literal builtup pixels.
func _builtup_proximity_score(wx: float, wz: float) -> float:
	var r: float = road_clearance_radius_m if road_clearance_radius_m > 0.0 else 8.0
	var center: float = _builtup_at(wx, wz)
	var inner_r: float = r * 0.5
	var samples_inner: float = (
		_builtup_at(wx + inner_r, wz)
		+ _builtup_at(wx - inner_r, wz)
		+ _builtup_at(wx, wz + inner_r)
		+ _builtup_at(wx, wz - inner_r)) * 0.25
	var diag: float = r * 0.7071
	var samples_outer: float = (
		_builtup_at(wx + diag, wz + diag)
		+ _builtup_at(wx + diag, wz - diag)
		+ _builtup_at(wx - diag, wz + diag)
		+ _builtup_at(wx - diag, wz - diag)) * 0.25
	var score: float = (center + samples_inner * 0.6 + samples_outer * 0.25) / 1.85
	return clampf(score, 0.0, 1.0)


# Road proximity score with falloff — 9-sample weighted average so
# trash near a road (not on it) still gets some score.
func _road_proximity_score(wx: float, wz: float) -> float:
	var r: float = road_clearance_radius_m if road_clearance_radius_m > 0.0 else 8.0
	var center: float = _road_density_at(wx, wz)
	var inner_r: float = r * 0.5
	var samples_inner: float = (
		_road_density_at(wx + inner_r, wz)
		+ _road_density_at(wx - inner_r, wz)
		+ _road_density_at(wx, wz + inner_r)
		+ _road_density_at(wx, wz - inner_r)) * 0.25
	var diag: float = r * 0.7071
	var samples_outer: float = (
		_road_density_at(wx + diag, wz + diag)
		+ _road_density_at(wx + diag, wz - diag)
		+ _road_density_at(wx - diag, wz + diag)
		+ _road_density_at(wx - diag, wz - diag)) * 0.25
	var score: float = (center + samples_inner * 0.6 + samples_outer * 0.25) / 1.85
	return clampf(score, 0.0, 1.0)


# Road edge strength: peaks at gutters/curbs. Drives "papers cluster
# along road verges" placement.
func _road_edge_strength(wx: float, wz: float) -> float:
	if _splat_road.is_empty() and _splat_b.is_empty():
		return 0.0
	var r: float = 1.5
	var c_sum: float = _road_density_at(wx, wz)
	var n_sum: float = _road_density_at(wx, wz - r)
	var s_sum: float = _road_density_at(wx, wz + r)
	var e_sum: float = _road_density_at(wx + r, wz)
	var w_sum: float = _road_density_at(wx - r, wz)
	var max_d: float = maxf(maxf(absf(c_sum - n_sum), absf(c_sum - s_sum)),
		maxf(absf(c_sum - e_sum), absf(c_sum - w_sum)))
	return clampf(max_d, 0.0, 1.0)


# Hotspot mask sampled in world space. Deterministic per `seed`,
# remapped from raw Perlin `[-1, 1]` into `[hotspot_floor, hotspot_ceiling]`
# so the user's two range knobs map directly to "how dramatic the
# clustering is". Lazy-initialized — `seed` / `hotspot_frequency`
# changes after first sample are picked up here.
func _hotspot_mask_at(wx: float, wz: float) -> float:
	if _hotspot_noise == null:
		_hotspot_noise = FastNoiseLite.new()
		_hotspot_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	# Cheap to (re)set — Godot stores these without recomputing the
	# field, only the next sample reflects the new params.
	_hotspot_noise.seed = seed ^ 0xC0FFEE
	_hotspot_noise.frequency = hotspot_frequency
	var n: float = (_hotspot_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
	return lerpf(hotspot_floor, hotspot_ceiling, n)


# Slope acceptance factor at world XZ for a species's `max_slope_deg`
# cap. Returns 1.0 on flat ground, linearly falls to 0.0 at the cap,
# 0.0 above. Used to reject placements where physics would roll the
# item downhill (heavy bottles, cans, food cans on steep terrain).
# Tied to the same heightmap sample as `_terrain_normal_at` — slope
# tracks the actual terrain shape that the player walks on.
func _slope_factor_at(wx: float, wz: float, max_slope_deg: float) -> float:
	if _hm_bytes.is_empty() or max_slope_deg <= 0.0:
		return 1.0
	var n: Vector3 = _terrain_normal_at(wx, wz)
	var slope_deg: float = rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
	var t: float = slope_deg / max_slope_deg
	return maxf(0.0, 1.0 - t)


# Terrain concavity at world XZ. Positive = bowl/dip (collects
# blown trash); zero or negative = ridge/peak (sheds).
func _terrain_curvature(wx: float, wz: float) -> float:
	if _hm_bytes.is_empty():
		return 0.0
	var r: float = 2.0
	var h0: float = _height_at_world(wx, wz)
	var h_n: float = _height_at_world(wx, wz - r)
	var h_s: float = _height_at_world(wx, wz + r)
	var h_e: float = _height_at_world(wx + r, wz)
	var h_w: float = _height_at_world(wx - r, wz)
	var mean_n: float = (h_n + h_s + h_e + h_w) * 0.25
	var concavity: float = (mean_n - h0) / r
	return clampf(concavity / 0.3, 0.0, 1.0)


# Terrain normal at world XZ. Used for slope-aware alignment so trash
# sits flat on the ground rather than vertically through a 30° slope.
func _terrain_normal_at(wx: float, wz: float) -> Vector3:
	if _hm_bytes.is_empty():
		return Vector3.UP
	var r: float = 1.0
	var h_l: float = _height_at_world(wx - r, wz)
	var h_r: float = _height_at_world(wx + r, wz)
	var h_d: float = _height_at_world(wx, wz - r)
	var h_u: float = _height_at_world(wx, wz + r)
	return Vector3(-(h_r - h_l), 2.0 * r, -(h_u - h_d)).normalized()


# Build a Basis whose Y axis aligns with `up`. Identity for vertical
# `up`; rotated otherwise.
func _basis_with_up(up: Vector3) -> Basis:
	var dot: float = Vector3.UP.dot(up)
	if dot > 0.99999:
		return Basis.IDENTITY
	if dot < -0.99999:
		return Basis(Vector3.RIGHT, PI)
	var axis: Vector3 = Vector3.UP.cross(up).normalized()
	var angle: float = acos(clampf(dot, -1.0, 1.0))
	return Basis(axis, angle)


# Build a trash placement transform with terrain-normal alignment +
# random yaw + small random tilt in slope-relative axes. Ground-snaps
# the final origin so the rotated mesh's lowest AABB extent touches
# terrain Y rather than burying itself — critical for items with
# `lay_down_pretilt_deg = 90` (bottles, cans, cups) where naive
# placement leaves half the cylinder below the ground.
func _build_trash_transform(sp: TrashSpecies, path: String, wx: float,
		y: float, wz: float, s: float, rng: RandomNumberGenerator) -> Transform3D:
	var aligned_up: Vector3 = Vector3.UP
	if sp.terrain_alignment_factor > 0.0:
		var t_normal: Vector3 = _terrain_normal_at(wx, wz)
		aligned_up = Vector3.UP.lerp(t_normal,
			sp.terrain_alignment_factor).normalized()
	var basis: Basis = _basis_with_up(aligned_up).scaled(Vector3(s, s, s))
	# Lay-down pretilt: tip the model `lay_down_pretilt_deg` around its
	# local X axis BEFORE the yaw, so the subsequent yaw randomizes the
	# lean direction. Used to keep nominally-upright meshes (bottles,
	# cans, coffee cups) from standing ramrod-straight. No-op when 0.
	if sp.lay_down_pretilt_deg > 0.0:
		basis = basis.rotated(basis.x.normalized(),
			deg_to_rad(sp.lay_down_pretilt_deg))
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
	# Ground-snap. The AABB-corners-after-basis method is tight for the
	# box-shaped trash kit (bottles, cans, cups, papers) — corners map
	# directly to the rotated bounding box. Slightly under-buries
	# cylindrical items in the AABB-corner gap, but never over-lifts. We
	# only LIFT (never lower) — meshes whose lowest extent is already
	# above origin keep their authored offset, matching the legacy
	# placement behavior for un-tilted species.
	var ground_lift: float = _ground_lift_for_basis(path, basis)
	return Transform3D(basis, Vector3(wx, y + ground_lift, wz))


# Returns the Y offset to add to a placement origin so the rotated
# mesh's lowest AABB extent ends up at world Y=0 relative to the
# placement. Positive = lift mesh up; negative = lower mesh.
#
# Math: the lowest world-Y of a rotated AABB equals the rotated center
# minus the projected half-extent. The half-extent in world-Y is
# `|basis.x.y| × hx + |basis.y.y| × hy + |basis.z.y| × hz` — each
# mesh-local axis contributes its half-size weighted by how much that
# axis points in the world-Y direction after the basis transform. This
# is the closed-form of "transform each AABB corner, take min Y" and
# is exact for box-shaped meshes (bottles, cans, cups, papers — the
# AABB is tight on cylinders too). Slightly over-lifts roundish meshes
# where the AABB has empty corners (apples, balls) — bounded by
# `(sqrt(3) − 1) × radius ≈ 0.73 R` at 45°-on-multiple-axes, but at
# our `random_tilt_deg = 10°` jitter the over-lift is millimeters and
# not visible.
#
# This intentionally returns negative when the mesh is authored with
# origin BELOW its lowest extent (origin floats above the mesh) — that
# lowers the placement origin so the mesh's lowest point sits on the
# terrain rather than floating up.
func _ground_lift_for_basis(path: String, basis: Basis) -> float:
	var meshes: Array = _species_meshes.get(path, [])
	if meshes.is_empty():
		return 0.0
	var aabb: AABB = meshes[0].get_aabb()
	var hx: float = aabb.size.x * 0.5
	var hy: float = aabb.size.y * 0.5
	var hz: float = aabb.size.z * 0.5
	var center_world_y: float = (basis * aabb.get_center()).y
	var half_extent_world_y: float = (
		absf(basis.x.y) * hx
		+ absf(basis.y.y) * hy
		+ absf(basis.z.y) * hz)
	var min_y: float = center_world_y - half_extent_world_y
	return -min_y


# Cheap probe — does this tile have any signal that might generate a
# placement? Checks road, builtup, bare, AND zone since each of the
# four can independently drive trash placement.
func _tile_has_road_or_zone(tile: Vector2i) -> bool:
	var origin_x: float = float(tile.x) * tile_size_m
	var origin_z: float = float(tile.y) * tile_size_m
	for sx in 3:
		for sz in 3:
			var wx: float = origin_x + (float(sx) + 0.5) * tile_size_m / 3.0
			var wz: float = origin_z + (float(sz) + 0.5) * tile_size_m / 3.0
			if _road_density_at(wx, wz) > 0.0:
				return true
			if _builtup_at(wx, wz) > 0.0:
				return true
			if _bare_at(wx, wz) > 0.0:
				return true
			var probe_y: float = _height_at_world(wx, wz)
			var boost: float = _ExclusionZoneRef.trash_zone_boost(
				get_tree(), wx, probe_y, wz)
			if boost > 0.0:
				return true
	return false


# --- Species table + resource loading ---

func _build_species_table() -> void:
	_species_resource_cache.clear()
	_prewarm_cursor = -1
	for path in species_paths:
		if path.is_empty():
			continue
		# Force-reload from disk (CACHE_MODE_REPLACE) instead of using
		# Godot's own resource cache — otherwise edits to .tres files
		# (max_render_distance_m, paved_weight, etc.) don't propagate
		# until the editor restarts. The user-facing "Rebuild trash"
		# button calls _force_rebuild → _species_resource_cache.clear()
		# but Godot's internal load cache might still hand back the
		# resource as it was at session start.
		var sp: TrashSpecies = ResourceLoader.load(
			path, "", ResourceLoader.CACHE_MODE_REPLACE) as TrashSpecies
		if sp == null:
			push_warning("TrashScatter: failed to load %s" % path)
			continue
		_species_resource_cache[path] = sp


func _get_cached_species(path: String) -> TrashSpecies:
	if _species_resource_cache.has(path):
		return _species_resource_cache[path]
	var sp: TrashSpecies = load(path) as TrashSpecies
	if sp != null:
		_species_resource_cache[path] = sp
	return sp


func _ensure_species_resources(path: String) -> void:
	if _species_meshes.has(path):
		return
	var sp: TrashSpecies = _get_cached_species(path)
	if sp == null or sp.mesh_scene_path.is_empty():
		_species_meshes[path] = []
		_species_materials[path] = []
		return
	var packed: PackedScene = load(sp.mesh_scene_path) as PackedScene
	if packed == null:
		push_warning("TrashScatter: species %s failed to load %s"
			% [path, sp.mesh_scene_path])
		_species_meshes[path] = []
		_species_materials[path] = []
		return
	var root: Node = packed.instantiate()
	var meshes: Array[Mesh] = []
	var materials: Array[Material] = []
	_collect_meshes(root, meshes, materials)
	root.queue_free()
	_species_meshes[path] = meshes
	_species_materials[path] = materials


func _collect_meshes(n: Node, out_meshes: Array[Mesh],
		out_mats: Array[Material]) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		if mi.mesh != null:
			out_meshes.append(mi.mesh)
			var mat: Material = mi.get_surface_override_material(0)
			if mat == null and mi.mesh.get_surface_count() > 0:
				mat = mi.mesh.surface_get_material(0)
			out_mats.append(mat)
	for c in n.get_children():
		_collect_meshes(c, out_meshes, out_mats)


# --- Tile management ---

func _tile_at(wx: float, wz: float) -> Vector2i:
	return Vector2i(int(floorf(wx / tile_size_m)),
					int(floorf(wz / tile_size_m)))


func _rebuild_active(p_xz: Vector2) -> void:
	_last_player_xz = p_xz
	var center: Vector2i = _tile_at(p_xz.x, p_xz.y)
	var r_tiles: int = int(ceilf(active_radius_m / tile_size_m))
	var desired: Dictionary = {}
	var r_sq: float = active_radius_m * active_radius_m
	for dz in range(-r_tiles, r_tiles + 1):
		for dx in range(-r_tiles, r_tiles + 1):
			var t: Vector2i = Vector2i(center.x + dx, center.y + dz)
			var t_center_x: float = (float(t.x) + 0.5) * tile_size_m
			var t_center_z: float = (float(t.y) + 0.5) * tile_size_m
			var dx_m: float = t_center_x - p_xz.x
			var dz_m: float = t_center_z - p_xz.y
			if dx_m * dx_m + dz_m * dz_m <= r_sq:
				desired[t] = true
	# Free tiles outside the active radius. ALSO free + re-queue any tile
	# whose physics-range membership flipped since it last spawned —
	# without this, a tile spawned at distance with the MMI fallback for
	# its physics species would never gain its RigidBody3Ds when the
	# player walks closer (it'd stay in `_baked_tiles` and skip the
	# re-queue path below).
	for t in _baked_tiles.keys():
		var should_free: bool = false
		if not desired.has(t):
			should_free = true
		else:
			var t_cx: float = (float(t.x) + 0.5) * tile_size_m
			var t_cz: float = (float(t.y) + 0.5) * tile_size_m
			var should_phys: bool = _tile_in_physics_range(
				Vector3(t_cx, 0.0, t_cz))
			if _tile_spawn_physics.get(t, false) != should_phys:
				should_free = true
		if should_free:
			var c: Node = _baked_tiles[t]
			if c != null and is_instance_valid(c):
				c.queue_free()
			_baked_tiles.erase(t)
			_wind_bodies_by_tile.erase(t)
			_tile_spawn_physics.erase(t)
	for t in desired:
		if not _baked_tiles.has(t) and not _bake_queue.has(t):
			_bake_queue.append(t)


func _drain_bake_queue(count: int) -> int:
	var done: int = 0
	while done < count and not _bake_queue.is_empty():
		var t: Vector2i = _bake_queue.pop_front()
		_bake_tile(t)
		done += 1
	return done


func _bake_tile(tile: Vector2i, cache_only: bool = false) -> void:
	if _species_resource_cache.is_empty():
		return

	# Cache fast path. `cache_only` is the whole-map-bake escape hatch
	# — roll fresh + write the cache, don't spawn.
	if cache_enabled and not cache_only:
		var cached: Dictionary = _try_load_tile_cache(tile)
		if not cached.is_empty():
			_spawn_tile_from_cache(tile, cached)
			return

	var origin_x: float = float(tile.x) * tile_size_m
	var origin_z: float = float(tile.y) * tile_size_m
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = ((int(seed) ^ int(cache_version) * 1009)
		^ (int(tile.x) * 73856093)
		^ (int(tile.y) * 19349663))

	var tile_center: Vector3 = Vector3((float(tile.x) + 0.5) * tile_size_m,
		0.0, (float(tile.y) + 0.5) * tile_size_m)
	var spawn_physics: bool = _tile_in_physics_range(tile_center)

	var tile_area: float = tile_size_m * tile_size_m
	var raw_count: int = int(round(base_density_per_sq_m * tile_area * density_multiplier))
	var candidates: int = clampi(raw_count, 1, placements_per_tile_cap)

	# path → Array[Transform3D]
	var static_xforms: Dictionary = {}
	# Array of [path, Transform3D] tuples
	var physics_placements: Array = []

	# ==== ANCHOR PRE-PASS ====
	# Hero items (heaps, bags, big debris with `is_anchor = true`)
	# place first, broadcasting attractor radii. Smaller satellite
	# trash piles around them in the main pass. Same architecture as
	# RockScatter — separate RNG so anchor layout is stable when
	# satellite weights change.
	#
	# Empty anchor pool early-out: when `species_paths` contains no
	# is_anchor species (the default for the "loose litter only"
	# config — bags / heaps / piles are hand-placed in scenes
	# instead), skip the entire pre-pass + cluster machinery. Keeps
	# the architecture in place for maps that DO want auto-placed
	# anchors without paying its CPU cost otherwise.
	var anchor_positions: PackedFloat32Array = PackedFloat32Array()
	var anchor_radii: PackedFloat32Array = PackedFloat32Array()
	var _has_anchor_species: bool = false
	for path in species_paths:
		var sp_check: TrashSpecies = _get_cached_species(path)
		if sp_check != null and sp_check.is_anchor:
			_has_anchor_species = true
			break
	var anchor_rng: RandomNumberGenerator = RandomNumberGenerator.new()
	anchor_rng.seed = (rng.seed ^ 0x7A5C0FF1)
	var anchor_attempts: int = maxi(candidates / 8, 4)
	if not _has_anchor_species:
		anchor_attempts = 0
	# Anchor candidates that land directly on a road pixel get hard-
	# rejected. Cars run over roads; piles don't survive there.
	# Threshold of 0.15 (= 38/255) catches the painted-on shoulders +
	# splat-bleed from rasterization without rejecting candidates that
	# fall in a 1-2 m clearance band along the road verge — exactly
	# where curbside trash bags belong. Use the per-pixel value, NOT
	# the 9-sample proximity score.
	const _ANCHOR_ROAD_REJECT_THRESHOLD: float = 0.15
	# **Cluster shape**. Anchors are RARE — at most one cluster per
	# 32 m tile, and even high-signal tiles only get a cluster ~50%
	# of the time. Within a cluster, follow-ups place tightly
	# (≤1 m from seed) so a "trash dumped here" pile reads as a
	# real clump, not three loosely-related items 5 m apart.
	# Follow-ups exclude the seed species so a bag-seeded cluster
	# gets heap + rubble alongside, never 3 identical bags.
	const _MAX_CLUSTERS_PER_TILE: int = 1
	const _ANCHOR_PILES_PER_CLUSTER: int = 2
	const _ANCHOR_CLUSTER_RADIUS_M: float = 1.0
	# Per-tile probability that ANY cluster places, even when signal
	# qualifies. Keeps the map-wide anchor density visibly sparse —
	# clusters become a thing you notice in places, not a wallpaper.
	const _CLUSTER_TILE_PROB: float = 0.5
	var _clusters_placed: int = 0
	# Roll once per tile to gate cluster placement entirely.
	var _tile_allows_cluster: bool = anchor_rng.randf() < _CLUSTER_TILE_PROB
	# Cap attempts per tile aggressively — with the 50% gate above
	# and a single cluster per tile, more attempts just burn CPU
	# without changing the outcome on no-signal tiles. Was
	# `candidates / 8` (~32 tries on a dense tile).
	var _anchor_max_tries: int = mini(anchor_attempts, 6)
	for _ai in _anchor_max_tries:
		if not _tile_allows_cluster:
			break
		if _clusters_placed >= _MAX_CLUSTERS_PER_TILE:
			break
		var awx: float = origin_x + anchor_rng.randf() * tile_size_m
		var awz: float = origin_z + anchor_rng.randf() * tile_size_m
		var aroad_pixel: float = _road_density_at(awx, awz)
		if aroad_pixel >= _ANCHOR_ROAD_REJECT_THRESHOLD:
			continue
		var aroad: float = _road_proximity_score(awx, awz)
		var abuiltup: float = _builtup_proximity_score(awx, awz)
		var abare: float = _bare_at(awx, awz)
		var ay: float = _height_at_world(awx, awz)
		var azone: float = _ExclusionZoneRef.trash_zone_boost(
			get_tree(), awx, ay, awz)
		# Early-reject when no anchor-relevant signal is present anywhere
		# nearby. Anchors specifically don't care about pure on-road
		# pixels — those aren't a reason to spawn a pile.
		if abuiltup <= 0.0 and abare <= 0.0 and azone <= 0.0:
			continue
		# Edge gradient + curvature shape WHERE in a town the anchor
		# lands (curbs, drainage, lots — vs. the middle of an open
		# parking lot).
		var aedge: float = 0.0
		if aroad > 0.0:
			aedge = _road_edge_strength(awx, awz)
		var acurvature: float = _terrain_curvature(awx, awz)
		# Soft falloff for candidates near a road but not directly on
		# it — the hard reject above handles "on the road"; this just
		# softens the per-meter approach so anchors prefer 2-3 m from
		# the curb over 0.5 m from the curb.
		var road_suppress: float = maxf(1.0 - aroad_pixel, 0.0)
		var anchor_weights: Array[float] = []
		var anchor_paths_for_weights: Array[String] = []
		var atotal: float = 0.0
		for path in species_paths:
			var sp: TrashSpecies = _get_cached_species(path)
			if sp == null or not sp.is_anchor:
				continue
			anchor_paths_for_weights.append(path)
			# Anchor placement signals: builtup + bare are primary.
			var w: float = sp.builtup_weight * abuiltup
			w += sp.bare_weight * abare
			if sp.spawn_in_zones:
				w += azone
			w += sp.road_edge_boost * aedge
			w += sp.terrain_curvature_boost * acurvature
			# SUPPRESS placement on actual road pixels. (Anchors no
			# longer get a `paved_weight * road_proximity` term — that
			# was the reason heaps + bags landed in road centers.)
			w *= road_suppress
			anchor_weights.append(w)
			atotal += w
		if atotal <= 0.0:
			continue
		var aroll: float = anchor_rng.randf() * atotal
		var apicked_path := ""
		var acum: float = 0.0
		for i in anchor_weights.size():
			acum += anchor_weights[i]
			if aroll < acum:
				apicked_path = anchor_paths_for_weights[i]
				break
		if apicked_path.is_empty():
			continue
		var asp: TrashSpecies = _get_cached_species(apicked_path)
		var aaccept: float = clampf(anchor_weights[anchor_paths_for_weights.find(apicked_path)], 0.0, 1.0)
		# Slope filter — anchors on steep terrain would tip / roll, and
		# the cluster around them inherits the location, so the gate
		# matters here too.
		aaccept *= _slope_factor_at(awx, awz, asp.max_slope_deg)
		if aaccept <= 0.0 or anchor_rng.randf() > aaccept:
			continue
		# Place the SEED anchor at the candidate position.
		var as_scale: float = lerpf(asp.scale_min, asp.scale_max,
			anchor_rng.randf()) * asp.size_multiplier
		var axform: Transform3D = _build_trash_transform(
			asp, apicked_path, awx, ay, awz, as_scale, anchor_rng)
		# Always record the placement regardless of `spawn_physics`. The
		# decision about how to render it (RigidBody3D vs. visual MMI
		# fallback) happens in `_spawn_tile` based on whether the tile is
		# in physics range AT SPAWN TIME, not at bake time. Gating placement
		# rolls on the bake-time camera position made cached far-away tiles
		# silently lose all `physics_enabled = true` species — see fix
		# 2026-05-05.
		if asp.physics_enabled:
			physics_placements.append([apicked_path, axform])
		else:
			var aarr: Array = static_xforms.get(apicked_path, [])
			aarr.append(axform)
			static_xforms[apicked_path] = aarr
		anchor_positions.append(awx)
		anchor_positions.append(awz)
		anchor_radii.append(asp.satellite_anchor_radius)
		_clusters_placed += 1
		# === CLUSTER PASS ===
		# Spawn `_ANCHOR_PILES_PER_CLUSTER` more anchors inside the
		# seed's cluster radius. The follow-up species pool EXCLUDES
		# the seed species — otherwise the highest-weight species
		# (e.g. trashbag_a at builtup_weight=2.5) wins the same roll
		# every iteration and the cluster is just 4 identical bags
		# stacked at one spot. Excluding the seed forces variety:
		# bag seed ends up with heap + rubble pile + prefab next to
		# it instead of bag + bag + bag.
		var seed_species_idx: int = anchor_paths_for_weights.find(apicked_path)
		var cluster_total: float = atotal - (anchor_weights[seed_species_idx] if seed_species_idx >= 0 else 0.0)
		for _cp in _ANCHOR_PILES_PER_CLUSTER:
			if cluster_total <= 0.0:
				break
			var dx: float = (anchor_rng.randf() * 2.0 - 1.0) * _ANCHOR_CLUSTER_RADIUS_M
			var dz: float = (anchor_rng.randf() * 2.0 - 1.0) * _ANCHOR_CLUSTER_RADIUS_M
			var cwx: float = awx + dx
			var cwz: float = awz + dz
			# Stay inside the tile bounds — anchors crossing the edge
			# break the per-tile cache contract.
			if cwx < origin_x or cwx >= origin_x + tile_size_m:
				continue
			if cwz < origin_z or cwz >= origin_z + tile_size_m:
				continue
			# Same on-road hard reject as the seed.
			if _road_density_at(cwx, cwz) >= _ANCHOR_ROAD_REJECT_THRESHOLD:
				continue
			# Slope check — even though the seed passed, a cluster member
			# offset by `_ANCHOR_CLUSTER_RADIUS_M` can land on a notably
			# different slope (e.g. seed at the foot of a hill, member
			# crossing onto the slope itself). Use the eventual species's
			# `max_slope_deg`; pick by the same roulette as below so the
			# check tracks whatever species we're about to place.
			# Re-pick species, EXCLUDING the seed species. Same weight
			# table as the seed pass, just zeroed for the seed entry.
			var croll: float = anchor_rng.randf() * cluster_total
			var cpath := ""
			var ccum: float = 0.0
			for i in anchor_weights.size():
				if i == seed_species_idx:
					continue
				ccum += anchor_weights[i]
				if croll < ccum:
					cpath = anchor_paths_for_weights[i]
					break
			if cpath.is_empty():
				continue
			var csp: TrashSpecies = _get_cached_species(cpath)
			if _slope_factor_at(cwx, cwz, csp.max_slope_deg) <= 0.0:
				continue
			# Slight tilt + scale jitter so the cluster doesn't look
			# like a stamp pattern.
			var cy: float = _height_at_world(cwx, cwz)
			var cs_scale: float = lerpf(csp.scale_min, csp.scale_max,
				anchor_rng.randf()) * csp.size_multiplier
			var cxform: Transform3D = _build_trash_transform(
				csp, cpath, cwx, cy, cwz, cs_scale, anchor_rng)
			# See note on the seed-anchor placement above: always record
			# the placement; the spawn-side decides the representation.
			if csp.physics_enabled:
				physics_placements.append([cpath, cxform])
			else:
				var carr: Array = static_xforms.get(cpath, [])
				carr.append(cxform)
				static_xforms[cpath] = carr
			# Don't broadcast a separate satellite radius for cluster
			# members — the seed's radius covers the whole cluster
			# area already (small items will pile around the seed,
			# which is at the cluster center).

	# ==== MAIN PASS ====
	# Per-tile species placement count, fed into the repeat-damper so
	# the same species can't keep winning the roulette. Reset per tile
	# so neighboring tiles vary independently.
	var species_count: Dictionary = {}
	for _i in candidates:
		var jx: float = rng.randf()
		var jz: float = rng.randf()
		var wx: float = origin_x + jx * tile_size_m
		var wz: float = origin_z + jz * tile_size_m
		# Per-channel road proximity (paved, unpaved, trail). Driving
		# main-pass weights per-channel is what keeps cardboard boxes
		# OFF forest trails (box.trail_weight=0 → 0 contribution from
		# the trail channel) while still letting cigarettes appear
		# on trails (cig.trail_weight nonzero).
		var road_chans: Vector3 = _road_channels_proximity(wx, wz)
		var road: float = maxf(maxf(road_chans.x, road_chans.y), road_chans.z)
		var builtup: float = _builtup_proximity_score(wx, wz)
		var bare: float = _bare_at(wx, wz)
		var y: float = _height_at_world(wx, wz)
		var zone_boost: float = _ExclusionZoneRef.trash_zone_boost(
			get_tree(), wx, y, wz)

		# Reject only when there's NO signal at all anywhere — small
		# items want road OR town interior OR bare patch.
		if road <= 0.0 and builtup <= 0.0 and bare <= 0.0 and zone_boost <= 0.0:
			continue

		var edge_score: float = 0.0
		if road > 0.0:
			edge_score = _road_edge_strength(wx, wz)
		var curvature: float = _terrain_curvature(wx, wz)
		# Anchor proximity: closest anchor's normalized falloff [0..1].
		var best_anchor_prox: float = 0.0
		var pi: int = 0
		while pi < anchor_positions.size():
			var ax: float = anchor_positions[pi]
			var az: float = anchor_positions[pi + 1]
			var ar: float = anchor_radii[pi / 2]
			var ddx: float = wx - ax
			var ddz: float = wz - az
			var d_sq: float = ddx * ddx + ddz * ddz
			var ar_sq: float = ar * ar
			if d_sq < ar_sq:
				var d: float = sqrt(d_sq)
				var prox: float = 1.0 - d / ar
				if prox > best_anchor_prox:
					best_anchor_prox = prox
			pi += 2

		# Pick a species via cumulative weight. Anchors are excluded
		# from the main pass (they were placed in pre-pass).
		var weights: Array[float] = []
		var paths_for_weights: Array[String] = []
		var total: float = 0.0
		for path in species_paths:
			var sp: TrashSpecies = _get_cached_species(path)
			if sp == null or sp.is_anchor:
				continue
			paths_for_weights.append(path)
			var w: float = 0.0
			# Per-channel road affinity. Each species sets paved /
			# unpaved / trail weights independently — a cardboard
			# box has unpaved=0 + trail=0 so it never spawns on
			# forest tracks; a cigarette butt has trail>0 so it
			# can occasionally land on a trail.
			w += sp.paved_weight * road_chans.x
			w += sp.unpaved_weight * road_chans.y
			w += sp.trail_weight * road_chans.z
			# Town affinity (small items still spawn in builtup areas
			# without explicit road pixels — interior alleys, plazas).
			w += sp.builtup_weight * builtup
			# Bare-ground affinity (rare for small items, nonzero for
			# heavy debris like rusty cans).
			w += sp.bare_weight * bare
			if sp.spawn_in_zones:
				w += zone_boost
			w += sp.road_edge_boost * edge_score
			w += sp.terrain_curvature_boost * curvature
			if sp.satellite_anchor_boost > 0.0 and best_anchor_prox > 0.0:
				w += sp.satellite_anchor_boost * best_anchor_prox \
					* maxf(road + zone_boost, 0.1)
			# Same-species damper: each placement of this species in
			# the current tile divides its weight by `1 + n × damper`,
			# so the roulette naturally favors variety. See the
			# `same_species_repeat_damper` export docstring.
			if same_species_repeat_damper > 0.0:
				var cnt: int = species_count.get(path, 0)
				if cnt > 0:
					w /= 1.0 + float(cnt) * same_species_repeat_damper
			weights.append(w)
			total += w
		if total <= 0.0:
			continue
		var roll: float = rng.randf() * total
		var picked_path := ""
		var cum: float = 0.0
		for i in weights.size():
			cum += weights[i]
			if roll < cum:
				picked_path = paths_for_weights[i]
				break
		if picked_path.is_empty():
			continue
		var sp: TrashSpecies = _get_cached_species(picked_path)

		# **Decoupled accept-probability**. Old code used the picked
		# species's individual weight as accept_p — on weak-signal
		# tiles (forest trails, dirt patches) most species have weight
		# ~0.05 → 95 % rejection, and the few species with the highest
		# trail/unpaved weights (cigaret_butt, cigaret_ash, matchbox)
		# won the lottery by sheer statistical edge. Result: trails
		# only ever showed cigarettes and matchboxes regardless of
		# how the rest of the manifest was tuned.
		#
		# New formula: accept_p = location signal strength (max of
		# per-channel road, builtup, bare, zone). This answers "does
		# trash belong at this spot?" — once accepted, the roulette
		# picks WHICH species to place using per-channel weights as
		# preference. So a paved-road tile places ~all candidates
		# (high accept_p) with paper / can / bottle dominating the
		# pick (high paved_weight); a trail tile places ~half the
		# candidates with wood_splinter / can_food_rusty / cigaret
		# spread per their trail_weight ratios.
		var accept_p: float = maxf(maxf(road_chans.x, road_chans.y), road_chans.z)
		accept_p = maxf(accept_p, builtup * 0.9)
		accept_p = maxf(accept_p, bare * 0.6)
		accept_p = maxf(accept_p, zone_boost)
		# Multiply by the hotspot mask BEFORE clamping. The mask can go
		# above 1.0 in hotspots — the clamp prevents over-acceptance,
		# but only after the mask has had a chance to claw back density
		# in concentrated areas. Without the order being mask-then-clamp,
		# a peak-on-the-road candidate (already at accept_p = 1.0) would
		# never feel the hotspot boost.
		accept_p *= _hotspot_mask_at(wx, wz)
		# Slope falloff: reject placements where physics would roll the
		# item downhill. Per-species cap, so cigarettes / papers can
		# stay on steeper slopes than bottles / cans. Applied AFTER the
		# hotspot mask so a hotspot doesn't push trash up an unstable
		# hillside; settled-trash naturally clusters on flat areas at
		# the foot of slopes.
		accept_p *= _slope_factor_at(wx, wz, sp.max_slope_deg)
		accept_p = clampf(accept_p, 0.0, 1.0)
		if rng.randf() > accept_p:
			continue

		# NOTE: physics species are NOT skipped when out of physics range
		# at bake time. The placement is always recorded; `_spawn_tile`
		# decides at spawn time whether to render it as a RigidBody3D
		# (in physics range) or as a static MMI fallback (out of range).
		# Without this, baking the whole map with the camera in one spot
		# silently dropped every `physics_enabled = true` species from
		# every tile farther than `physics_active_radius_m` from the
		# camera — leaving distant tiles with only the 3 static species
		# (cigarettes, ash, matchbox).
		var s: float = lerpf(sp.scale_min, sp.scale_max, rng.randf()) * sp.size_multiplier
		var xform: Transform3D = _build_trash_transform(sp, picked_path, wx, y, wz, s, rng)

		if sp.physics_enabled:
			physics_placements.append([picked_path, xform])
		else:
			var arr: Array = static_xforms.get(picked_path, [])
			arr.append(xform)
			static_xforms[picked_path] = arr
		species_count[picked_path] = species_count.get(picked_path, 0) + 1

	# Persist to cache regardless of whether we're spawning.
	if cache_enabled:
		_write_tile_cache(tile, static_xforms, physics_placements)
	if cache_only:
		# Whole-map / near-origin bake path: write the cache and STOP.
		# Crucially, do NOT add `_baked_tiles[tile]` here — that would
		# make `_rebuild_active` think the tile is already in its
		# spawned-tiles set, so it'd skip queueing the tile for actual
		# spawn when the player walks within active_radius. The on-disk
		# cache is enough — the next live `_bake_tile` (cache_only=false)
		# reads it via `_try_load_tile_cache` and spawns from there.
		return

	_spawn_tile(tile, static_xforms, physics_placements, spawn_physics)


func _tile_in_physics_range(tile_center: Vector3) -> bool:
	if _camera == null or not is_instance_valid(_camera):
		return false
	var dx: float = tile_center.x - _camera.global_position.x
	var dz: float = tile_center.z - _camera.global_position.z
	return dx * dx + dz * dz <= physics_active_radius_m * physics_active_radius_m


func _spawn_tile(tile: Vector2i,
		static_xforms: Dictionary,
		physics_placements: Array,
		spawn_physics: bool) -> void:
	# Container at tile_center. Per-instance transforms are translated
	# to local at insert time, halving float-precision pressure on big
	# maps (same pattern rock_scatter uses).
	var container: Node3D = Node3D.new()
	container.name = "TrashTile_%d_%d" % [tile.x, tile.y]
	var tile_center: Vector3 = Vector3(
		(float(tile.x) + 0.5) * tile_size_m, 0.0,
		(float(tile.y) + 0.5) * tile_size_m)
	container.position = tile_center
	add_child(container)
	# DO NOT set owner — that persists the spawned tiles into the
	# scene file on every Save, which previously blew up the .tscn to
	# 600k lines and 60k MMI nodes (one prior session). Spawned nodes
	# stay runtime-only, same as RockScatter / TreeScatter.

	# Static MMIs — one per species per tile. Per-species
	# `max_render_distance_m` becomes the MMI's visibility_range_end so
	# distant tiles' static trash culls aggressively even when the tile
	# itself is in active_radius. The half-tile-diagonal margin keeps
	# instances on the far edge of the tile from popping at exactly
	# their species's render distance.
	var tile_half_diag: float = tile_size_m * 0.7071
	for path in static_xforms.keys():
		_spawn_static_mmi(container, path, static_xforms[path],
			tile_center, tile_half_diag)

	# Out of physics range: render physics species as static MMIs (visual
	# fallback, no collision, no kickability). When the player crosses
	# `physics_active_radius_m` toward this tile, `_rebuild_active`
	# notices the spawn-physics state changed and re-queues the tile so
	# it re-spawns with real RigidBody3Ds. Without this fallback, every
	# tile beyond ~60 m would visibly contain only the 3 static species
	# (cigarettes, ash, matchbox); bricks / bottles / cans / boxes would
	# be invisible until the player walked right up to them.
	if not spawn_physics:
		var phys_buckets: Dictionary = _bucket_physics_by_path(physics_placements)
		for path in phys_buckets.keys():
			_spawn_static_mmi(container, path, phys_buckets[path],
				tile_center, tile_half_diag)
		_baked_tiles[tile] = container
		_tile_spawn_physics[tile] = false
		return
	var tile_bodies: Array[RigidBody3D] = []
	for entry in physics_placements:
		var path: String = entry[0]
		var xform: Transform3D = entry[1]
		_ensure_species_resources(path)
		var meshes: Array = _species_meshes.get(path, [])
		var mats: Array = _species_materials.get(path, [])
		if meshes.is_empty():
			continue
		var sp: TrashSpecies = _get_cached_species(path)
		var rb: RigidBody3D = RigidBody3D.new()
		rb.mass = maxf(sp.physics_mass, 0.01)
		# CONCEALMENT layer = partial LOS occlusion + physics interaction.
		# Player can walk through visible piles but kicks register;
		# bullets pass through without stopping. See `Layers.gd`.
		rb.collision_layer = Layers.CONCEALMENT
		# Mask: collide with terrain + other solid world geometry +
		# concealment-layer items (so trash interacts with itself). NPCs
		# pass through (LAYER_NPC_HITBOX excluded) — NPCs shouldn't get
		# blocked by a soda can.
		rb.collision_mask = Layers.SOLID | Layers.CONCEALMENT
		# Two regimes for physics species:
		#   - WIND (wind_susceptibility > 0, e.g. paper, masks, chips
		#     bag, coffee cup): stays dynamic + sleeping so the wind
		#     tick can apply impulses and the body tumbles. Wakes
		#     on impulse, settles via damping.
		#   - NON-WIND (bottles, cans, food cans, drinks): freeze =
		#     STATIC so the body never simulates at all. Without
		#     freeze, `sleeping = true` doesn't reliably hold across
		#     `add_child` / first physics tick — bodies wake from
		#     gravity + the tiny gap between collision-shape lowest
		#     extent and terrain, then roll downhill on any slope
		#     ("the world's trash drifting away on a gentle breeze").
		#
		# Kickability is wired via `trash_kick_zone.gd` (Area3D on the
		# player) — it sees CONCEALMENT-layer trash overlapping the
		# player's volume and unfreezes + impulses bodies the player
		# actually walks into. Until kicked, frozen trash stays put.
		if sp.wind_susceptibility > 0.0:
			rb.sleeping = true
			rb.can_sleep = true
			rb.linear_damp = 2.5
			rb.angular_damp = 3.5
		else:
			rb.freeze = true
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			rb.linear_damp = 4.0
			rb.angular_damp = 6.0
		var local_xf: Transform3D = xform
		local_xf.origin -= tile_center
		rb.transform = local_xf
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = meshes[0]
		if not mats.is_empty() and mats[0] != null:
			mi.material_override = mats[0]
		rb.add_child(mi)
		# Box collider, tight to the mesh AABB. Box (vs. the previous
		# capsule) handles all trash shapes uniformly — bottles / cans
		# (cylinder), apples (sphere), papers (flat) — without needing
		# per-species long-axis config. The capsule's hemispherical
		# ends made cylinders roll too easily and its 0.4× radius
		# multiplier left mesh extending past the collider.
		#
		# Position the collider at the AABB center in mesh-local space
		# — without this offset, the collider centers on the mesh's
		# AUTHORED origin (often the base for upright meshes), so its
		# lowest extent is half the mesh short of where the visual
		# mesh actually sits. Player would walk through the mesh near
		# the ground / bullets would miss.
		var aabb: AABB = meshes[0].get_aabb()
		var sx: Vector3 = xform.basis.get_scale()
		var col: CollisionShape3D = CollisionShape3D.new()
		col.position = aabb.get_center()
		var box_shape: BoxShape3D = BoxShape3D.new()
		box_shape.size = Vector3(
			aabb.size.x * sx.x,
			aabb.size.y * sx.y,
			aabb.size.z * sx.z)
		# Floor at 2 cm so a tiny crushed cigarette doesn't get a
		# zero-volume collider (Godot warns + ignores).
		box_shape.size = box_shape.size.max(Vector3(0.02, 0.02, 0.02))
		col.shape = box_shape
		rb.add_child(col)
		container.add_child(rb)
		# Register wind-eligible bodies for the tick. Items with
		# wind_susceptibility = 0 (cans, bottles) skip the registration
		# so the wind tick doesn't iterate them.
		if sp.wind_susceptibility > 0.0:
			rb.set_meta("wind_susceptibility", sp.wind_susceptibility)
			tile_bodies.append(rb)

	if not tile_bodies.is_empty():
		_wind_bodies_by_tile[tile] = tile_bodies
	_baked_tiles[tile] = container
	_tile_spawn_physics[tile] = true


# Build a static MMI for a single species's placements and parent it
# under `container`. Shared by static_xforms entries and by the
# out-of-physics-range fallback for physics species. Returns silently
# if the species has no usable mesh (e.g. failed prewarm).
func _spawn_static_mmi(container: Node3D, path: String, xs: Array,
		tile_center: Vector3, tile_half_diag: float) -> void:
	_ensure_species_resources(path)
	var meshes: Array = _species_meshes.get(path, [])
	var mats: Array = _species_materials.get(path, [])
	if meshes.is_empty():
		return
	var sp: TrashSpecies = _get_cached_species(path)
	var mesh: Mesh = meshes[0]
	var mat: Material = mats[0] if not mats.is_empty() else null
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xs.size()
	for i in xs.size():
		var local: Transform3D = xs[i]
		local.origin -= tile_center
		mm.set_instance_transform(i, local)
	var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	if mat != null:
		mmi.material_override = mat
	if sp != null and sp.max_render_distance_m > 0.0:
		mmi.visibility_range_end = (
			sp.max_render_distance_m + tile_half_diag)
		mmi.visibility_range_fade_mode = (
			GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED)
	container.add_child(mmi)


# Group `physics_placements` (an Array of [path, Transform3D] pairs)
# into a `path → Array[Transform3D]` dict, so each species's xforms
# can flow into a single MMI when out of physics range.
func _bucket_physics_by_path(physics_placements: Array) -> Dictionary:
	var out: Dictionary = {}
	for entry in physics_placements:
		var path: String = entry[0]
		var xf: Transform3D = entry[1]
		var arr: Array = out.get(path, [])
		arr.append(xf)
		out[path] = arr
	return out


# --- Wind tick ---

# Resolve the active WeatherRig, caching the lookup. Returns null when
# the scene has no rig (e.g. minimal test scene); the wind tick early-
# returns in that case. Re-resolves if the cached rig is freed (e.g.
# scene reload between sessions).
func _resolve_weather_rig() -> WeatherRig:
	if _weather_rig != null and is_instance_valid(_weather_rig):
		return _weather_rig
	var nodes: Array = get_tree().get_nodes_in_group("weather_rigs")
	for n in nodes:
		var wr := n as WeatherRig
		if wr != null:
			_weather_rig = wr
			return wr
	_weather_rig = null
	return null


func _apply_wind_tick() -> void:
	if _wind_bodies_by_tile.is_empty():
		return
	var rig: WeatherRig = _resolve_weather_rig()
	if rig == null:
		return
	var wind_xz: Vector2 = rig.wind_vector_xz()
	if wind_xz.length_squared() < 1e-4:
		return
	# `wind_impulse_scale` × wind magnitude × per-body susceptibility ×
	# random jitter (0.6-1.4) gives a noticeable but uneven gust pattern.
	# Multiply by mass when applying so heavy items get proportionally
	# bigger force (impulse = momentum change; we want consistent Δv).
	#
	# Hoist the constant wind direction vector out of the inner loop —
	# only `dv * rb.mass` differs per body. Saves a Vector3 construct
	# per body per tick.
	var wind_dir := Vector3(wind_xz.x, 0.0, wind_xz.y)
	var stale_keys: Array = []
	for tile in _wind_bodies_by_tile.keys():
		var arr: Array = _wind_bodies_by_tile[tile]
		var alive_count: int = 0
		for rb in arr:
			if rb == null or not is_instance_valid(rb):
				continue
			alive_count += 1
			var sus: float = rb.get_meta("wind_susceptibility", 0.0)
			if sus <= 0.0:
				continue
			var jitter: float = _wind_rng.randf_range(0.6, 1.4)
			var dv: float = wind_impulse_scale * sus * jitter
			# Convert Δv (m/s) to impulse (kg·m/s) for the body's mass.
			rb.apply_central_impulse(wind_dir * (dv * rb.mass))
		if alive_count == 0:
			stale_keys.append(tile)
	for k in stale_keys:
		_wind_bodies_by_tile.erase(k)


# --- On-disk placement cache ---

# Cache format v2: identical to v1 except entries key by `species_path`
# (string) instead of an indexed table position. v1 caches loaded by v2
# code still work because v1 already stored species_path strings — the
# version bump is documentation-only. Bumped here in case a future
# format change isn't backward-compatible.
const _CACHE_FORMAT_VERSION: int = 2
# `PackedByteArray([...])` isn't a constant expression in GDScript, so
# this stays a `var`. Read-only by convention.
var _cache_magic: PackedByteArray = PackedByteArray([0x54, 0x52, 0x53, 0x48])  # "TRSH"

func _get_cache_key() -> String:
	# Same contract as TreeScatter / RockScatter: only `cache_version`
	# + `seed` go into the key. Committed worlds stay consistent across
	# species/density tweaks; bump cache_version (or Clear + Bake) for
	# an intentional re-roll.
	#
	# **Not cached** — the previous version held this in `_cached_key`
	# computed once per session. If the user changed `cache_version`
	# in the inspector AND a partial editor / script reload reset
	# `_cached_key` between operations, writers and readers ended up
	# on different keys: whole-map bake wrote to dir K_old, live reads
	# checked dir K_new, every cache hit became a miss. Tiles near
	# the camera then re-rolled fresh (writing K_new) so they showed
	# up; everywhere else stayed at K_old on disk and never streamed
	# in. Recomputing is microseconds — md5 of a tiny string —
	# fine to call per cache op.
	var ctx: PackedStringArray = PackedStringArray()
	ctx.append("v%d" % cache_version)
	ctx.append(str(seed))
	return "|".join(ctx).md5_text().substr(0, 16)


func _cache_dir_for_key(key: String) -> String:
	return "res://assets/foliage_bake/%s/trash/%s/" % [map_id, key]


func _cache_path_for_tile(tile: Vector2i, key: String) -> String:
	return _cache_dir_for_key(key) + "%d_%d.bin" % [tile.x, tile.y]


func _try_load_tile_cache(tile: Vector2i) -> Dictionary:
	var path: String = _cache_path_for_tile(tile, _get_cache_key())
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var magic: PackedByteArray = f.get_buffer(4)
	if magic != _cache_magic:
		f.close()
		return {}
	var version: int = f.get_32()
	# Accept v1 + v2 (payload schema is identical for our purposes).
	if version != 1 and version != _CACHE_FORMAT_VERSION:
		f.close()
		return {}
	var len_bytes: int = f.get_64()
	var blob: PackedByteArray = f.get_buffer(len_bytes)
	f.close()
	var data: Variant = bytes_to_var(blob)
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = data
	if d.get("cache_key", "") != _get_cache_key():
		return {}
	return d


func _write_tile_cache(tile: Vector2i, static_xforms: Dictionary,
		physics_placements: Array) -> void:
	var entries: Array = []
	# Static placements: bucketed by path
	for path in static_xforms.keys():
		var xs: Array = static_xforms[path]
		entries.append({"species_path": path, "is_physics": false,
			"transforms": _flatten_xforms(xs)})
	# Physics placements: bucket by path
	var phys_by_path: Dictionary = {}
	for entry in physics_placements:
		var path: String = entry[0]
		var xf: Transform3D = entry[1]
		var arr: Array = phys_by_path.get(path, [])
		arr.append(xf)
		phys_by_path[path] = arr
	for path in phys_by_path.keys():
		entries.append({"species_path": path, "is_physics": true,
			"transforms": _flatten_xforms(phys_by_path[path])})

	var data: Dictionary = {
		"cache_key": _get_cache_key(),
		"tile": [tile.x, tile.y],
		"entries": entries,
	}
	var blob: PackedByteArray = var_to_bytes(data)
	var dir: String = _cache_dir_for_key(_get_cache_key())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path: String = _cache_path_for_tile(tile, _get_cache_key())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("TrashScatter: failed to write %s" % path)
		return
	f.store_buffer(_cache_magic)
	f.store_32(_CACHE_FORMAT_VERSION)
	f.store_64(blob.size())
	f.store_buffer(blob)
	f.close()


func _flatten_xforms(xs: Array) -> PackedFloat32Array:
	var t_flat: PackedFloat32Array = PackedFloat32Array()
	t_flat.resize(xs.size() * 12)
	for i in xs.size():
		var xf: Transform3D = xs[i]
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
	return t_flat


func _spawn_tile_from_cache(tile: Vector2i, cached: Dictionary) -> void:
	var static_xforms: Dictionary = {}
	var physics_placements: Array = []
	for entry in cached.get("entries", []):
		var sp_path: String = entry.get("species_path", "")
		if sp_path.is_empty() or not _species_resource_cache.has(sp_path):
			continue  # species removed since cache write
		var t_flat: PackedFloat32Array = entry.get("transforms",
			PackedFloat32Array())
		var n: int = t_flat.size() / 12
		var xforms: Array = []
		for i in n:
			var b: int = i * 12
			var basis: Basis = Basis(
				Vector3(t_flat[b + 0], t_flat[b + 1], t_flat[b + 2]),
				Vector3(t_flat[b + 3], t_flat[b + 4], t_flat[b + 5]),
				Vector3(t_flat[b + 6], t_flat[b + 7], t_flat[b + 8]))
			var origin: Vector3 = Vector3(
				t_flat[b + 9], t_flat[b + 10], t_flat[b + 11])
			xforms.append(Transform3D(basis, origin))
		# Re-determine physics state from current species (NOT cache).
		# Species can flip physics_enabled between cache write + read
		# without bumping cache_version; the placement positions stay
		# valid either way, only the spawn shape changes.
		var sp: TrashSpecies = _get_cached_species(sp_path)
		if sp != null and sp.physics_enabled:
			for xf in xforms:
				physics_placements.append([sp_path, xf])
		else:
			static_xforms[sp_path] = xforms

	var tile_center: Vector3 = Vector3((float(tile.x) + 0.5) * tile_size_m,
		0.0, (float(tile.y) + 0.5) * tile_size_m)
	var spawn_physics: bool = _tile_in_physics_range(tile_center)
	_spawn_tile(tile, static_xforms, physics_placements, spawn_physics)


# --- Tool buttons ---

func _bake_cache_near_origin() -> void:
	if not Engine.is_editor_hint():
		return
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[trash] cannot bake: terrain not loaded")
		return
	# ALWAYS reload species fresh from disk before baking. The previous
	# `if _species_resource_cache.is_empty(): _build_species_table()`
	# guard meant this button used STALE in-memory species values across
	# a session — user edits a .tres file, clicks Bake, cache gets
	# written with the pre-edit weights. Symptom: only cigarettes /
	# matchboxes in cache despite weight rebalances. Always-rebuild
	# costs ~36 disk loads per click, irrelevant for an editor button.
	_species_resource_cache.clear()
	_species_meshes.clear()
	_species_materials.clear()
	_build_species_table()
	for path in species_paths:
		_ensure_species_resources(path)
	var radius: float = maxf(prebake_radius_m, active_radius_m)
	var radius_tiles: int = int(ceilf(radius / tile_size_m))
	var n: int = 0
	var skipped: int = 0
	print("[trash] baking near-origin cache: radius=%.0fm, key=%s..."
		% [radius, _get_cache_key()])
	for tz in range(-radius_tiles, radius_tiles + 1):
		for tx in range(-radius_tiles, radius_tiles + 1):
			var t: Vector2i = Vector2i(tx, tz)
			var t_cx: float = (float(tx) + 0.5) * tile_size_m
			var t_cz: float = (float(tz) + 0.5) * tile_size_m
			if t_cx * t_cx + t_cz * t_cz > radius * radius:
				continue
			if not _tile_has_road_or_zone(t):
				skipped += 1
				continue
			_bake_tile(t, true)
			n += 1
	print("[trash] baked %d tiles, skipped %d empty (key=%s)"
		% [n, skipped, _get_cache_key()])


func _bake_cache_whole_map() -> void:
	if not Engine.is_editor_hint():
		return
	if not _terrain_ready and not _ensure_terrain_loaded():
		push_warning("[trash] cannot bake whole map: terrain not loaded")
		return
	# Force-reload species (see _bake_cache_near_origin for the rationale).
	_species_resource_cache.clear()
	_species_meshes.clear()
	_species_materials.clear()
	_build_species_table()
	for path in species_paths:
		_ensure_species_resources(path)
	# DIAGNOSTIC: print the loaded species table so we know which weights
	# the bake is actually using — confirms hot-reload caught the latest
	# .tres edits. If this prints stale numbers, Godot didn't reload the
	# resources properly.
	print("[trash] species table for bake (showing key weights):")
	for path in species_paths:
		var sp: TrashSpecies = _species_resource_cache.get(path)
		if sp == null:
			continue
		print("  %s: paved=%.2f unpaved=%.2f trail=%.2f builtup=%.2f bare=%.2f"
			% [path.get_file().get_basename(),
				sp.paved_weight, sp.unpaved_weight, sp.trail_weight,
				sp.builtup_weight, sp.bare_weight])
	var half_w: float = _extent_x * 0.5
	var half_h: float = _extent_z * 0.5
	var tx_min: int = int(floorf(-half_w / tile_size_m))
	var tx_max: int = int(ceilf(half_w / tile_size_m))
	var tz_min: int = int(floorf(-half_h / tile_size_m))
	var tz_max: int = int(ceilf(half_h / tile_size_m))
	var n: int = 0
	var skipped: int = 0
	var total: int = (tx_max - tx_min + 1) * (tz_max - tz_min + 1)
	print("[trash] whole-map bake: %d candidate tiles (extent %.0f×%.0fm, key=%s)..."
		% [total, _extent_x, _extent_z, _get_cache_key()])
	for tz in range(tz_min, tz_max + 1):
		for tx in range(tx_min, tx_max + 1):
			var t: Vector2i = Vector2i(tx, tz)
			if not _tile_has_road_or_zone(t):
				skipped += 1
				continue
			_bake_tile(t, true)
			n += 1
	print("[trash] whole-map: baked %d tiles, skipped %d empty"
		% [n, skipped])


func _clear_cache_for_map() -> void:
	if not Engine.is_editor_hint():
		return
	var dir: String = _cache_dir_for_key(_get_cache_key())
	var abs_dir: String = ProjectSettings.globalize_path(dir)
	var n: int = 0
	var d: DirAccess = DirAccess.open(abs_dir)
	if d == null:
		print("[trash] no cache dir to clear: %s" % abs_dir)
		return
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if not d.current_is_dir() and name.ends_with(".bin"):
			d.remove(name)
			n += 1
		name = d.get_next()
	d.list_dir_end()
	print("[trash] cleared %d cached tiles from %s" % [n, abs_dir])


func _force_rebuild() -> void:
	for t in _baked_tiles.keys():
		var c: Node = _baked_tiles[t]
		if c != null and is_instance_valid(c):
			c.queue_free()
	_baked_tiles.clear()
	_tile_spawn_physics.clear()
	_wind_bodies_by_tile.clear()
	_bake_queue.clear()
	_last_player_xz = Vector2(INF, INF)
	# Flush the species resource caches too so newly-saved .tres files
	# (e.g. after bumping `paved_weight` or `max_render_distance_m`)
	# actually get picked up by subsequent bakes. Otherwise the in-
	# memory `_species_resource_cache` holds the values from the very
	# first `_build_species_table()` call of the session, and inspector
	# tweaks to species need a full editor restart to take effect.
	# Symptom (2026-05-04): user retunes species weights, hits Rebuild
	# trash, fresh-rolled tiles still spawn with the OLD weight
	# distribution because the species cache was stale.
	_species_resource_cache.clear()
	_species_meshes.clear()
	_species_materials.clear()
	_prewarm_cursor = -1


func _set_editor_preview(v: bool) -> void:
	editor_preview = v
	if not Engine.is_editor_hint():
		return
	if v:
		set_process(true)
	for t in _baked_tiles.keys():
		var c: Node = _baked_tiles[t]
		if c != null and is_instance_valid(c):
			c.queue_free()
	_baked_tiles.clear()
	_tile_spawn_physics.clear()
	_wind_bodies_by_tile.clear()
	_bake_queue.clear()
	_last_player_xz = Vector2(INF, INF)
