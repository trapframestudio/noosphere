# Procedural rock scatter

End-to-end walkthrough of the procedural rock + boulder scatter:
mesh + texture pipeline, scatter behavior, collision tiers, and
where to tune each knob.

The system shares the foliage scatter's playbook - tile-based active
streaming, per-instance shader LOD cull, world-XZ hash dither for
silent crossfades - but ships its own assets, shader, and tiered
collision dispatch suited to rocks.

## What it produces

Six mesh shapes × three LODs each = 18 base meshes packed into
`godot/assets/models/rocks/rock_pack.glb` (94 KB). Per-LOD vertex
counts: 194 / 66 / 27. Six PBR texture sets (color + normal +
roughness) downsampled into 1k / 2k / 4k variants. Per-species
RockSpecies resources pick a mesh shape + texture set + collision
tier; per-biome RockBiomeConfig resources weight species into a
biome's spawn pool.

A boulder field in `Bare` biome reads as ~30 rocks per 100 m²,
clustered along low-frequency noise crests so dense patches alternate
with bare ground. A forest reads as ~5 rocks per 100 m², heavily
biased toward small steppable stones with the occasional knee-high
boulder.

## Pipeline overview

```
scripts/generate_rock_pack.py            # Blender → 6 shapes × 3 LODs
   ↓
godot/assets/models/rocks/rock_pack.glb  # 94 KB, deterministic

scripts/downsample_rock_textures.py      # AmbientCG 4K → 1k + 2k variants
   ↓
godot/assets/textures/rocks/Rock0XX/{1k,2k}/{color,normal,roughness}.png
godot/assets/textures/terrain/Rock0XX_4K-PNG/...   # 4K source kept here

godot/scripts/foliage/rock_species.gd       # RockSpecies resource
godot/scripts/foliage/rock_biome_config.gd  # RockBiomeConfig resource
godot/shaders/rock_dynamic.gdshader         # PBR + per-instance LOD cull
godot/scripts/foliage/rock_scatter.gd       # RockScatter Node3D - the dispatcher
   ↓
godot/scenes/test/cascade_locks_test.tscn   # Procedural/Rocks/RockScatter
```

## Mesh generation

`scripts/generate_rock_pack.py` runs Blender headless to produce the
mesh pack:

```bash
blender --background --python scripts/generate_rock_pack.py
```

Each shape is built by adding a subdivisions-4 icosphere (642 verts),
applying anisotropic pre-scale (e.g. flat slab x=1.5, y=0.45, z=1.3),
displacing each vertex outward by fractal simplex noise sampled at
that vertex, then squashing along Y for "settled" gravity-pose. A
sphere UV unwrap projects the texture maps; smooth shading hides the
icosphere quantization at LOD0.

Per-LOD decimate ratios (0.30, 0.10, 0.04 of base) drive the LOD
chain. The naming convention `<shape>_LOD<N>` matches the parser in
both `tree_scatter.gd::_parse_lod_level` and
`rock_scatter.gd::_parse_lod_level`, so the same per-instance dither
algorithm transfers.

Six shapes ship: `rock_round`, `rock_jagged`, `rock_slab`,
`rock_pillar`, `rock_oblong`, `rock_cluster`. Each tunes its own
seed + noise frequency + settle squash. Re-running the script
produces byte-identical output (deterministic seeds), so contributors
can regenerate without diff churn.

To add a new base shape: add a `RockShape` entry to the `SHAPES`
tuple at the top of the script, give it a fresh seed, regenerate.

## Texture downsampling

`scripts/downsample_rock_textures.py` produces the 1k / 2k variants
from the existing 4K AmbientCG packs in
`godot/assets/textures/terrain/Rock0XX_4K-PNG/`:

```bash
python3 scripts/downsample_rock_textures.py            # default 6 rocks
python3 scripts/downsample_rock_textures.py Rock020 Rock060   # subset
python3 scripts/downsample_rock_textures.py --all      # all 14 source rocks
python3 scripts/downsample_rock_textures.py --force    # ignore mtime cache
```

Pillow's Lanczos resampler is deterministic per Pillow version, so
re-running the script produces byte-identical output → no LFS churn.
The script writes ONLY the 1k and 2k tiers; the 4k tier stays at the
AmbientCG source path (saves ~6 GB of duplicated LFS data). The
`RockSpecies.resolution_tier` enum maps to the right path at load
time.

| `resolution_tier` | Texture path |
|---|---|
| 0 (1k) | `res://assets/textures/rocks/<set>/1k/<channel>.png` |
| 1 (2k) | `res://assets/textures/rocks/<set>/2k/<channel>.png` |
| 2 (4k) | `res://assets/textures/terrain/<set>_4K-PNG/<set>_4K-PNG_<Channel>.png` |

Pick by physical rock size: 1k for pebbles / ankle-knee, 2k for
knee/waist boulders, 4k for standing-cover boulders the player
presses up against.

## Scatter algorithm

`RockScatter` mirrors `TreeScatter`'s tile streaming pattern:

1. Active radius around the player → set of active tiles (`tile_size_m`
   default 32 m, `active_radius_m` default 150 m).
2. Each tile bakes lazily on the bake queue, rate-limited by
   `bake_per_frame_budget` with adaptive `bake_burst_budget` for the
   initial scene-load wave.
3. Per-tile RNG hash → N candidate placements (capped at
   `placements_per_tile_cap`). Each candidate samples biome from
   `splatmap_a.rgba8`, road density from `road_density.rgba8`, slope
   via finite-difference height samples.
4. **Terrain-driven placement** - instead of synthetic noise,
   acceptance is gated by a `terrain_rocky_score` derived from the
   heightmap itself. The score is the max height delta within a
   `terrain_sample_radius_m` neighborhood (default 25 m), normalized
   by `terrain_score_saturation` (default slope 2.5 ≈ 70°). Result
   in [0, 1]: 0 = flat valley floor, 1 = cliff face / rocky ridge.
   - `RockSpecies.terrain_min_score` hard-gates: a species with
     min=0.5 only spawns where the score ≥ 0.5 (talus zones, near
     slopes). Pebbles + small set 0 (anywhere); big species set
     0.3–0.55.
   - `RockSpecies.terrain_density_boost` scales accept_p by
     `1 + boost × score`. Big species set this high (3–6) so they
     genuinely pile up in rocky areas; small species set it low
     (0.5–1.5) for moderate concentration.
   - `RockSpecies.scale_terrain_boost` scales individual rocks UP
     in rocky terrain - boulder piles contain bigger rocks than
     scattered surface stones. Set 0.5–1.2 on big species.
4a. **Per-species slope band** - `slope_min` / `slope_max` is the
   ORTHOGONAL signal: it's the candidate's POINT slope (steepness
   right here), not the neighborhood. Cliff species have
   `slope_min ≈ 1.5` so they only appear ON the cliff face itself.
   Ground species have `slope_max ≈ 1.8` so they don't appear on
   vertical surfaces. The global `slope_cutoff` (default 4.0) is the
   absolute no-spawn-above ceiling.

   **Why two slope signals**: a talus pile at the base of a cliff
   has LOW point slope (it's flat ground at the foot) but HIGH
   neighborhood slope (cliff is right there). `terrain_min_score`
   captures "near steep terrain", `slope_min` captures "ON steep
   terrain". Real-world boulder placement uses both.
5. Surviving candidates pick a species via biome's cumulative-weight
   RNG, get random scale + yaw + tilt, then snap Y so the rotated
   rock's lowest world-point lands on terrain (see "Settled-Y snap"
   below) and sink slightly so the rock reads as embedded.
6. Per-tile container holds one MMI per (species, LOD); the rock
   shader's per-instance hash dither selects exactly one LOD per
   rock per camera distance.

### Asset normalization (mesh AABB-centered at origin)

Every rock `.glb` ships with each mesh's AABB center at `(0, 0, 0)`.
The procedural `rock_pack.glb` runs `scripts/recenter_glb_meshes.py`
as a post-export pass (called by `generate_rock_pack.py`); the
hand-imported `rock_pack_extra.glb` was processed through the same
script when introduced.

**Why this matters.** For our MultiMesh pipeline the per-instance
`Transform3D` is the ONLY transform applied between mesh-local
vertex coordinates and world space — there's no scene-graph node
offset between them. If a mesh's vertex centroid sits at `(+2.5,
+0.4, -1.7)` (say, because Blender baked an object's grid layout
position into the vertex data on export), every rock renders 2.5 m
east and 1.7 m north of where the scatter placed its origin. The
rocks then look like they "float" or "sink" arbitrarily — but
actually they're at the wrong horizontal position.

The recenter script reads each POSITION accessor's `min`/`max`,
subtracts the center from every vertex, and rewrites the .glb. Any
new rock pack added to the project must run through this pass before
being committed.

### Settled-Y snap (avoiding floating rocks)

Naïvely placing a rock at `y = terrain_height(x, z)` floats it off the
ground whenever the mesh's local origin isn't at the rock's bottom.
Different rock packs use different conventions:

- **Procedural icosphere pack** (`rock_pack.glb`): mesh centered around
  origin, AABB y-range roughly `[-1, +1]` × native units. Many shapes
  are deliberately asymmetric — `rock_slab` is half-extents
  `(1.5, 1.35, 0.31)`, a true flat slab.
- **Extra packs** (`rock_pack_extra.glb`): some meshes (`extra_round_*`,
  `extra_pebble_*`) have origin AT THE BASE, AABB y-range `[0, +h]`.

The scatter approximates each rock as an **ellipsoid inscribed in its
AABB** and projects that onto world-Y to find the lowest world-Y offset:

```
u = basis.y / scale                          # world-Y direction in mesh-local
extent = sqrt((u.x·hx)² + (u.y·hy)² + (u.z·hz)²) × scale
center_world_y = (basis × aabb.center).y
lowest_y_offset = center_world_y − extent
```

For a sphere (`hx = hy = hz`): `extent` is rotation-invariant — equals
`r × scale`. For a slab (`hz << hx, hy`): `extent` collapses when the
slab face goes vertical, so the rock snaps lower into the ground when
laid flat. For an icosphere with origin at center, `lowest_y_offset =
−r × scale`. For an `extra_round_*` mesh with origin at base, the AABB
center is at `+h/2`, the ellipsoid extent is `h/2`, and `lowest_y_offset
≈ 0` — the rock sits with its base at terrain. All correct.

**Lesson learned, twice (2026-05-04).** First we tried "transform the
8 AABB corners through the basis and take the min Y." That over-lifted
spherical rocks by `(√3 − 1) × r × scale` because the AABB box has
corners the mesh doesn't fill — on a scale-4 boulder, ~2 m of float.
Then we tried un-rotated `aabb.position.y × scale`. That works for
spheres but over-lifts asymmetric rocks: a tilted `rock_slab` has its
flat face vertical, so its real world-Y span is 0.31 × scale ≈ 30 cm
unit, but the un-rotated math snaps to 1.35 × scale ≈ 1.4 m unit,
leaving the rock floating by a meter. The ellipsoid projection is the
generalization that's right for both cases.

### Sinking into terrain (the "embedded over time" look)

Three stacking sinks pull the rock down INTO the terrain so it doesn't
read as freshly placed:

- `terrain_sink_baseline` (default 0.06 of scale) — **always-on**
  burial that applies on flat ground and slopes alike. Tuning point
  for "rock has been sitting here for centuries" vs "freshly fallen
  boulder". Default is a subtle ~6 % of the rock's scale.
- `terrain_sink_factor` (per-species, default 0; large_boulder = 0.4)
  — **slope-additive** burial that ramps via `smoothstep(0.5, 1.6)`
  on point slope. Bigger boulders on cliff faces sink deeper so they
  don't read as perched-and-ready-to-tumble.
- `terrain_sink_random_max` (per-species, default 0; boulders = 0.35–0.45)
  — **per-instance random** burial uniformly in `[0, max]` ×
  vertical_extent, deterministic via the per-tile RNG. Drives the
  "natural variation" reading: in a boulder cluster some rocks are
  freshly fallen, some half-buried over geological time, even though
  the species is identical.

All three sum and clamp to **half the rock's vertical extent**, so no
parameter combination can bury more than 50 % of the silhouette.

### Footprint-aware snap (avoiding downhill float)

A point-sample of the heightmap at the rock's center XZ is fine for
small rocks but breaks on big rocks across slopes: terrain at the
center is the average elevation, but the downhill perimeter is lower —
so the rock floats on the downhill side even though it touches at
center. The scatter samples 9 points (center + 8 perimeter at the
rock's horizontal half-extent) and snaps to the **min** terrain Y.
This guarantees the rock either touches or buries on the downhill
side, with the uphill side embedded into the slope. Cheap (~9
heightmap reads per placement); skipped for tiny rocks (radius < 0.5 m)
where slope variation is invisible.

### Road clearance (footprint-aware)

The center-only `biome == road → reject` check catches "rock dropped
on the asphalt" but misses big boulders placed 1–2 m off the road
edge whose body still drapes across it. The placement code samples
the road-density splatmap at the same 9 footprint points used for
terrain-Y snap (center + 8 perimeter at the rock's horizontal radius)
and rejects placements where any sample exceeds the
`road_max_density_byte` threshold (default 30 / 255). Tighter than
the binary biome check, and proportional to rock size — a small
pebble can sit at the road edge but a huge boulder can't.

### Compound boulder features (anchor sibling clustering)

`is_anchor` species can spawn **sibling anchors** within a small
neighborhood, producing compound boulder features instead of isolated
rocks scattered across a slope. Two knobs:

- `feature_cluster_count_max` (default 0): roll up to N additional
  same-species anchors after the parent places. 1–3 typical;
  `large_cluster` = 3 produces "rocky outcrop" piles.
- `feature_cluster_radius` (default 2.5 m): radius within which
  siblings spawn. Smaller than `satellite_anchor_radius` (siblings
  are AT the feature; satellites cluster AROUND it).

Siblings bypass the terrain-score gate and density-acceptance roll
(parent vouched for the location) but still respect `slope_min/max`,
biome, and the road-footprint check. They're full-fledged anchors —
published as `tree_exclusion_radius` zones, registered for satellite
proximity boosts. Combined with `terrain_sink_random_max` for varied
burial and the wide `scale_min/max` ranges (boulders 0.4 → 3.5), the
result reads as a single geological feature instead of N cloned
rocks at the same elevation.

**Forced size diversity within a cluster.** Each sibling N out of
total siblings gets a *distinct tier* of the `[scale_min, scale_max]`
range — sibling 0 rolls in `[0, 1/N]`, sibling 1 in `[1/N, 2/N]`,
etc. Guarantees every cluster contains a small/medium/large mix
instead of relying on lucky uniform rolls. (Without this, three
siblings independently rolling `lerpf(min, max, randf())` cluster
near the mean — and `scale_terrain_boost` is deterministic by
terrain feature, so identical-position siblings get identical
boosts, dragging the whole cluster toward one size.)

### Breaking up clones in boulder fields

Three knobs work together to make adjacent rocks of the same species
+ variant read as visually distinct geological pieces. Without them,
boulder fields read as obvious clones even when scale_min/max varies.

**Per-instance HSV jitter** (`albedo_value_jitter`, `albedo_hue_jitter_deg`).
The rock shaders apply per-instance hue + value shifts at fragment
time using an independent world-XZ hash channel (decorrelated from
the LOD-dither hash). Defaults bumped 2026-05-04 to `0.20` / `12°`
after subtle defaults read as still-cloned. Live-tunable via the
species's `changed` signal — dial in the editor with no rebake.

**Per-instance non-uniform scale** (`scale_axis_jitter`). Currently we
apply uniform scale `(s, s, s)` for the size determinant, then jitter
X and Z independently within ±jitter (Y stays as the size determinant
so vertical extent stays predictable). At `0.25`, the same mesh reads
as squashed-flat in one instance, elongated-wedge in the next. The
**highest-leverage knob** for breaking up clones. The ellipsoid Y-snap
math uses `basis.y.length()` instead of `basis.x.length()` so the
sink/footprint math holds under non-uniform scale.

**Extreme-tilt event** (`extreme_tilt_chance`, `extreme_tilt_deg`).
Per-instance probability of an extra big tilt (30–60°) on top of
`random_tilt_deg`. Captures the "freshly tumbled" / "weirdly perched"
rocks that punctuate real boulder fields without making EVERY rock
look chaotic. Boulder species default `chance = 0.15–0.20`, `deg =
50–60`. Asymmetric meshes (`rock_slab`, `rock_oblong`) read as
fundamentally different shapes when their long axis flips horizontal.

Tile churn on player movement: if camera moves more than
`rebuild_threshold_m`, recompute the active set and queue any
newly-revealed tiles for bake; tiles that fall outside `active_radius_m`
free their MMIs + collision bodies in one `queue_free`.

## Collision tiers

`RockSpecies.collision_tier` is the dispatch enum. `RockScatter`
inspects it at spawn time and picks the right StaticBody3D shape +
collision layer:

| Tier | Layer | Shape | Use case |
|---|---|---|---|
| 0 NONE | - | none | Pebbles / gravel - no body created |
| 1 STEPPABLE | `CONCEALMENT` | sphere | Ankle/knee - player walks through, bullets get partial occlusion |
| 2 CROUCH_COVER | `SOLID` | capsule | Knee/waist - full block on bullets + movement |
| 3 STAND_COVER | `SOLID` | capsule (taller, wider) | Waist+ + clusters - same as crouch but bigger silhouette |

Tier 1 lands on the `CONCEALMENT` layer as a deliberate compromise
(the existing layer is excluded from `PLAYER_MOVE_MASK`, so player
walks through; included in `WEAPON_HIT_MASK`, so bullets get the
`concealment_visibility ≈ 50 %` partial-occlusion treatment). The
proper long-term fix is a dedicated `STEPPABLE_SOLID` layer that
fully blocks bullets while still letting the player step over -
deferred to combat / weapon-penetration work, see
`memory/project_rock_collision_tier_b.md`.

Per-tile collision is gated by `collision_radius_m` (default 80 m) -
tiles past that range render the rocks but skip the StaticBody3D /
CollisionShape3D allocation. As the camera moves, tiles dynamically
gain / lose colliders so RID + broadphase counts stay bounded.

## What each knob costs

- **Live** - pushed to running materials via the species's `changed`
  signal; visible next frame, no rebuild needed. Ideal for iterating
  on look-and-feel.
- **Tile rebuild** - RockScatter rebakes affected tiles. Triggered by
  player movement past `rebuild_threshold_m`, the **Rebuild rocks**
  inspector button, or toggling `editor_preview` off/on.
- **Asset regenerate** - re-run `generate_rock_pack.py` and/or
  `downsample_rock_textures.py`; commit the resulting LFS-tracked
  binaries.

| Knob | Location | Cost |
|---|---|---|
| `albedo_modulation` (regional palette tint) | `RockSpecies.tres` | **Live** |
| `albedo_value_jitter` / `albedo_hue_jitter_deg` | `RockSpecies.tres` | **Live** |
| `roughness_floor` (per-species roughness) | `RockSpecies.tres` | **Live** |
| Per-instance scale jitter (`scale_min/max`) | `RockSpecies.tres` | Tile rebuild |
| `size_multiplier` (physical rock size) | `RockSpecies.tres` | Tile rebuild |
| `random_tilt_deg` / `terrain_alignment_factor` | `RockSpecies.tres` | Tile rebuild |
| `scale_axis_jitter` (non-uniform per-instance scale) | `RockSpecies.tres` | Tile rebuild |
| `extreme_tilt_chance` / `extreme_tilt_deg` | `RockSpecies.tres` | Tile rebuild |
| `road_max_density_byte` (footprint-perimeter road clearance) | `RockScatter` node | Tile rebuild |
| `resolution_tier` / `texture_set` | `RockSpecies.tres` | Tile rebuild |
| `collision_tier` | `RockSpecies.tres` | Tile rebuild (collisions re-spawn) |
| `terrain_min_score` / `terrain_density_boost` | `RockSpecies.tres` | Tile rebuild |
| `scale_terrain_boost` | `RockSpecies.tres` | Tile rebuild |
| `terrain_sink_baseline` / `terrain_sink_factor` / `terrain_sink_random_max` | `RockSpecies.tres` | Tile rebuild |
| `feature_cluster_count_max` / `feature_cluster_radius` (anchor compounding) | `RockSpecies.tres` | Tile rebuild |
| `slope_min` / `slope_max` | `RockSpecies.tres` | Tile rebuild |
| `min/max_render_distance_m` | `RockSpecies.tres` | Tile rebuild |
| `proxy_swap_distance_m` (impostor swap) | `RockSpecies.tres` | Tile rebuild |
| Biome `rocks_per_sq_m` baseline | `RockBiomeConfig.tres` | Tile rebuild |
| Per-species `rock_densities[i]` | `RockBiomeConfig.tres` | Tile rebuild |
| `tile_size_m` / `active_radius_m` | `RockScatter` node | Tile rebuild |
| `lod_band_ends_m` / `lod_band_fade_m` | `RockScatter` node | Tile rebuild |
| `shadow_radius_m` / `max_shadow_lod` | `RockScatter` node | Live (refresh) |
| `cast_shadow` / `enable_collision` | `RockScatter` node | Live (refresh) |
| Mesh shape / vert count | `scripts/generate_rock_pack.py` | Asset regenerate |
| Texture downsample resolution | `scripts/downsample_rock_textures.py` | Asset regenerate |

## Placement cache (gitignored)

Rock, tree, and ground-cover placements are baked to per-tile `.bin`
files under `godot/assets/foliage_bake/<map>/<system>/<key>/<tx>_<tz>.bin`.
That whole tree is **gitignored** (`.gitignore` excludes
`godot/assets/foliage_bake/`). Bakes are derived deterministically from
`seed + cache_version` and the scatter scripts, so every checkout can
regenerate the same world cheaply — no LFS bandwidth burned shipping
binary tile data that's reproducible from a few ints.

The contract that keeps regeneration safe:

- **Cache key is stable**: `cache_version` (default 1) + `seed` only.
  Tweaking density, biome configs, species params, slope filters,
  terrain_density_boost, etc. does NOT invalidate the cache. Existing
  baked tiles keep their positions across the session — balance tweaks
  don't shuffle in-progress work.
- **Color grading + look-and-feel stay live** regardless of cache
  state - `albedo_modulation`, `roughness_floor`, leaf grading,
  textures, weather, ambient: all push to running materials via the
  `species.changed` signal or via global uniforms. Iterate freely.
- **Re-roll** by clicking **Clear placement cache** + **Bake placement
  cache** on the relevant scatter, or by bumping `cache_version` and
  re-baking. Each scatter has its OWN `cache_version` so you can
  re-roll just the rocks without disturbing trees or ground cover (and
  vice versa).

**First-time setup workflow** (when authoring or pulling a map):
1. Place each scatter with `editor_preview = true`. Confirm densities
   + species look right by walking the test scene.
2. For each scatter, click **Bake placement cache** - bakes
   `prebake_radius_m` of tiles around the **camera's current
   position** synchronously. (TreeScatter also has a **Bake whole
   map** button that walks every tile in the terrain bounds, ignoring
   the radius - preferred for a complete map.)
3. Walk the world. Bakes persist on your local disk; no commit needed.

**Shipping a stable bake** (when a map is final and we want every
checkout / player to see the exact same forest): negate the map's
bake dir in `.gitignore`:

```
!/godot/assets/foliage_bake/<map_id>/
!/godot/assets/foliage_bake/<map_id>/**
```

Then `git add godot/assets/foliage_bake/<map_id>/` (LFS handles the
`.bin` content automatically) and commit. From that point the map's
placements travel with the repo.

**Tweak workflow**:
- Look-and-feel: live, no rebuild.
- Position-affecting tweak: cached tiles stay; new tiles use new
  params (visible drift on the bake boundary, but you can ignore or
  selectively re-bake). Click **Clear placement cache** + bake to
  redo the whole map cleanly.

## Optimization mirror with TreeScatter

RockScatter applies the same performance pipeline as TreeScatter:

- **Per-instance world-XZ hash dither** for LOD selection - each rock
  picks ONE LOD via stable hash; complementary discard rules at
  boundaries partition cleanly with no see-through gaps.
- **Impostor tier** (`rock_imposter.gdshader`): unshaded LOD2 rendered
  with `cast_shadow = OFF`. ~5× cheaper per-pixel than the close-tier
  shader plus saves the shadow draw call. Same per-instance dither
  for the close-tier↔impostor swap.
- **Distance-sorted shadow refresh** - every frame, sort tiles by
  camera distance and flip `cast_shadow` on/off closest-first, capped
  at `_SHADOW_FLIPS_PER_FRAME = 1`. Movement gate skips the work
  entirely when the player isn't translating.
- **Asymmetric hysteresis** - tiles turn ON at `shadow_radius_m`,
  turn OFF only past `shadow_radius_m × 1.3`. Prevents flapping at
  the boundary.
- **Skip non-shadow LODs** - `max_shadow_lod = 1` by default, so
  LOD2 MMIs never get their `cast_shadow` flipped (saves the
  property-set churn on tiles that flip in/out of shadow range).
- **Adaptive bake budget** - `bake_per_frame_budget = 2` steady
  state, `bake_burst_budget = 6` while the queue depth exceeds 32
  tiles. Initial scene-load drains fast; mid-walk rebuilds stay
  smooth.

## Default species + biome assignment

Eight starter species ship in `godot/resources/foliage/rocks/`. Ground
species cap at `slope_max = 1.8`; cliff species use `slope_min ≥ 1.4`.

| Species | Tier | Texture | terrain_min | terrain_boost | Notes |
|---|---|---|---|---|---|
| `pebble_round` | 0 NONE | Rock020 (1k) | 0.0 | 0.6 | Surface gravel - everywhere, mildly denser in rocky terrain |
| `small_jagged` | 1 STEP | Rock028 (1k) | 0.0 | 1.5 | Loose stones - anywhere, concentrate in talus |
| `medium_slab` | 2 CROUCH | Rock051 (2k) | 0.3 | 3.0 | Mildly-rocky terrain only |
| `medium_oblong` | 2 CROUCH | Rock050 (2k) | 0.3 | 3.5 | Same, denser in real talus |
| `large_boulder` | 3 STAND | Rock060 (4k) | 0.5 | 5.0 | Talus zones only |
| `large_cluster` | 3 STAND | Rock058 (4k) | 0.55 | 6.0 | Rocky outcrops only |
| `cliff_chunk` | 3 STAND | Rock041 (4k) | 0 (slope_min=1.6) | 4.0 | ON cliff faces |
| `cliff_slab` | 3 STAND | Rock051 (4k) | 0 (slope_min=1.4) | 3.5 | ON cliff faces |

**No more `boulder_field` species** - boulder fields are an
emergent property of high `terrain_rocky_score` terrain (where all
rock species concentrate at once), not a separate species.

Three biome configs:

| Biome | Density | Mix |
|---|---|---|
| `biome_forest_rocks` (Forest) | 0.0085 / m² | mostly pebble + small, very rare large |
| `biome_grassland_rocks` (Grassland) | 0.012 / m² | small + occasional medium + clusters |
| `biome_bare_rocks` (Bare) | 0.045 / m² | dense, every tier represented, boulder fields |

Cropland + Road biomes intentionally have no rock config - crops are
cleared, roads need clear sightlines.

## Tuning recipes

**Make a region rockier**: bump the biome's `rocks_per_sq_m` (and
proportionally raise the per-species `rock_densities`). For boulder
fields, raise `terrain_density_boost` on the large species so they
favor steep / cliffy terrain (the natural geological signature).

**Make big-rock formations more / less dramatic**: tune
`scale_terrain_boost` on the large species - higher values make
rocks scale up further in rocky terrain (talus pile look). Pair with
a higher `terrain_min_score` so the big formations only appear in
genuinely steep / boulder-fall geometry.

**Tune a regional palette** (granite vs sandstone): set
`albedo_modulation` on the species to a tint Color. Default white =
no-op; warm tan ≈ Color(1.05, 0.95, 0.85), cool gray ≈
Color(0.9, 0.92, 0.95). Hue and saturation affect the diffuse tone
without re-baking the source texture.

**Add per-instance variation within a species** so two adjacent rocks
of the same species don't read as obvious clones: bump
`albedo_value_jitter` (lightness range) and `albedo_hue_jitter_deg`
(hue range). Defaults are subtle (0.12 / 6°); 0.18 / 12° gives a
visibly mixed-mineral feel for boulder species. Live-tunable, no
rebuild needed — adjust until you can pan the camera across a rocky
slope and the silhouette reads as "many distinct rocks" rather than
"one rock copied".

**Bury rocks deeper for an older / weathered look**: raise
`terrain_sink_baseline` (default 0.06) to 0.10–0.15 on species that
should look ancient and embedded. Pair with a lower
`random_tilt_deg` so the rocks read as settled, not freshly placed.
The combined sink is hard-clamped at 50 % of vertical extent — past
that the value has no further effect.

**Tighten LOD pop**: drop `lod_band_fade_m` below 20 (default) for
sharper hand-offs at the cost of more visible per-rock LOD switches
in the fade zone.

**Add a new shape**: edit `scripts/generate_rock_pack.py`, add a
`RockShape("my_shape", seed=1007, ...)` to the `SHAPES` tuple, run
the script. New shape names will be `my_shape_LOD0/1/2`. Wire into a
`RockSpecies.tres` via `variant_prefix = "my_shape"`.

**Add a new texture set**: download the AmbientCG pack into
`godot/assets/textures/terrain/Rock0XX_4K-PNG/`, then run
`python3 scripts/downsample_rock_textures.py Rock0XX` to generate
the 1k + 2k variants. Reference via `texture_set = "Rock0XX"` on a
RockSpecies.

## Known limits + follow-ups

- **Tier 1 collision uses CONCEALMENT layer.** Bullets pass through
  partially. Promote to dedicated `STEPPABLE_SOLID` layer when combat
  needs hard bullet block on small rocks. See
  `memory/project_rock_collision_tier_b.md` for the full plan.
- **No bake cache.** TreeScatter has a per-tile binary cache for fast
  scene reopens; rocks bake faster (smaller density, simpler meshes)
  so it wasn't worth the complexity for the first cut. Add later if
  scene-load latency becomes an issue at higher densities.
- **No shadow refresh tiering.** Rocks always cast shadows on all
  active LODs. The shadow draw cost is small (small meshes, per-
  instance shader cull means only one LOD per rock is actually
  rendered), but if the player density doubles or rock counts spike,
  copy `tree_scatter.gd::_refresh_shadows` over and gate by
  `shadow_radius_m`.
- **Single-set texturing per species.** A species references one
  texture set across its LODs (the GPU mipmap chain handles distance
  appropriately). If a species needs different textures at different
  LODs (e.g. dim distant impostor), spawn two species at different
  `min/max_render_distance_m` bands.
