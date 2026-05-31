# Foliage tuning surface

Single-page reference for what's tunable in the ground-cover system,
where to find each knob in the editor, and what action your edit
triggers (re-bake, scene reload, or zero-cost live update).

## File layout

```
godot/resources/foliage/
  globals.tres                     # FoliageGlobals (wind + view-cone + density falloff)
  biomes/
    forest.tres                    # BiomeSpeciesConfig - plants_per_sq_m + species_paths + species_densities
    grassland.tres
    cropland.tres
    bare.tres
    road.tres                      # opt-in: trail-side scrub on road pixels
  species/
    fern_02.tres                   # FoliageSpecies - mesh_scene_path + scale + alpha_luminance_cutoff
    moss_01.tres
    grass_med_01.tres
    wild_grass_fab.tres            # Fab/Quixel low-tier import
    lady_fern.tres
    forest_debris/                 # orphan species — sticks, dead shrubs, etc.
      dead_shrubs.tres             #   no biome references them; awaiting a future
      np_foreststick01group.tres   #   debris-only scatter (wind-static, no animation)
      np_foreststickgroup01.tres
      np_foreststicks01.tres
    ...
```

**Forest-debris convention.** Sticks, fallen branches, dead shrubs,
and similar wind-static props are kept out of `GroundCoverScatter`'s
biomes (they don't sway like living plants and previously read as
broken when the wind shader animated them). Their species `.tres`
files live under `species/forest_debris/`; the underlying GLB / GLTF
assets live under `godot/assets/models/forest_debris/`. Both
directories are present-but-unwired today - a dedicated debris
scatter that consumes them lands later.

Open any `.tres` from the FileSystem dock - its own inspector tab
opens. Edit, save, see the result. Any other scene that references
the same `.tres` picks up the change on next load.

## What each edit costs

The "Cost" column says what action makes the change visible:

- **Live** - value pushed to the GPU each frame. Inspector slider →
  next-frame visible, no rebuild.
- **Tile rebuild** - `GroundCoverScatter` re-bakes its active tile
  set. Triggered by player movement past `rebuild_threshold_m`,
  by clicking the **Rebuild tiles** inspector button, by toggling
  `editor_preview` off / on, or by entering / leaving Play mode.
  No `.res` files written.
- **Re-bake** - terrain control map regenerated. Click **Bake Now**
  on the `Terrain3DBaker` node in the test scene; rewrites
  `godot/assets/terrain/<map_id>/terrain3d/terrain3d_*.res`.

| Knob | Where it lives | Cost |
|---|---|---|
| Wind strength / speed | `globals.tres` → `wind_*` | **Live** |
| View cone full / periph angles | `globals.tres` → `cone_*_deg` | **Live** |
| Forward / rear cull radius | `globals.tres` → `radius_*` | **Live** |
| Periph / rear density | `globals.tres` → `density_*` | **Live** |
| Per-tier scatter radius (small/medium/large) | `globals.tres` → `tier_radius_*_m` | **Live** (GPU cull) |
| Soft-cull fade band width | `globals.tres` → `fade_band_m` | **Live** (GPU dither) |
| Species size tier (SMALL/MEDIUM/LARGE) | `species/<plant>.tres` → `size_tier` | **Tile rebuild** (encodes into INSTANCE_CUSTOM.y) |
| Active bake radius | `GroundCoverScatter` → `active_radius_m` | **Tile rebuild** |
| Bake budget per frame | `GroundCoverScatter` → `bake_per_frame_budget` | **Live** |
| Master density multiplier | `GroundCoverScatter` → `density_multiplier` | **Tile rebuild** |
| Species clumping strength / freq | `GroundCoverScatter` → `species_clumping*` | **Tile rebuild** |
| Cache enabled / force-rebake | `GroundCoverScatter` → "Persistent bake cache" | **Tile rebuild** |
| Bake placement cache (camera-centered) | scatter buttons | One-shot bake |
| Clear foliage cache | `GroundCoverScatter` button | Clears `res://assets/foliage_bake/<map>/` |
| Alpha cutout per species | `species/<plant>.tres` → `alpha_luminance_cutoff` | **Live** (re-binds material) |
| Plants / m² for a biome (**master**) | `biomes/<biome>.tres` → `plants_per_sq_m` | **Tile rebuild** |
| Per-species relative weights in a biome | `biomes/<biome>.tres` → `species_densities` | **Tile rebuild** |
| Species list for a biome | `biomes/<biome>.tres` → `species_paths` | **Tile rebuild** |
| Species mesh / scale / weight / variant filter | `species/<plant>.tres` | **Tile rebuild** |
| Tile size, master density, per-frame bake budget | `GroundCoverScatter` node exports | **Tile rebuild** |
| Slope thinning (`slope_thin_start` / `slope_cutoff`) | `GroundCoverScatter` exports → Slope subgroup | **Tile rebuild** |
| Splat blur / variant routing | `terrain3d_loader.gd` | **Re-bake** |
| Road threshold / encoding | `terrain3d_loader.gd` | **Re-bake** |
| Texture content (.png swap) | `_terrain3d_packed/<slot>/` | None - Asset reload |
| `uv_scale`, `normal_depth` per slot | `terrain3d_assets_pnw.tres` | None - Live shader uniforms |
| `Terrain3DMaterial` shader params | `resources/terrain/cascade_locks_material.tres` | None - Live shader uniforms |

## Per-tier scatter (size_tier)

Foliage species declare a `size_tier` (SMALL / MEDIUM / LARGE). The
tier is packed into `INSTANCE_CUSTOM.y` at bake time, and the GPU
shader culls per-instance against the tier's distance band each
frame with a 5 m soft fade. No CPU-side rebakes when the player
crosses a tier boundary.

- **SMALL** (default) - ground cover (moss, ferns, weeds, flowers,
  small grass). Visible within `globals.tres → tier_radius_small_m`
  (default 35 m). Past that, instances fade out smoothly over 5 m.
- **MEDIUM** - knee-height shrubs, dead shrubs, generic shrub_01-04.
  Visible within `tier_radius_medium_m` (default 60 m).
- **LARGE** - waist-high+ bushes (elderberry, raspberry), saplings,
  dead trunks. Visible within `tier_radius_large_m` (default 90 m).

The scatter still bakes all tiers across the full `active_radius_m`
(default 72 m); the GPU does the per-tier visibility. Adjusting any
`tier_radius_*` is **live** - no tile rebuild needed.

Tag a species' tier by editing `species/<plant>.tres` and adding
`size_tier = N` (1 = MEDIUM, 2 = LARGE; absent / 0 = SMALL).
Changing `size_tier` requires a tile rebuild because the tier is
baked into INSTANCE_CUSTOM, not re-read at render time.

## Persistent bake cache

Tile bakes are expensive (~50–100 ms per tile in a dense biome) and
re-running them on every scene open is the dominant scene-load cost.
The scatter writes each baked tile to disk and reads it back on
subsequent visits - ~100× faster than a fresh bake.

- Cache files live at
  `res://assets/foliage_bake/<map_id>/<cache_key>/<tx>_<tz>.res`
- `cache_key` is a hash of every input that affects placement
  (seed, density, biome configs, terrain artifacts). Change any of
  those and the next bake writes a fresh cache under a new key dir.
- LFS-tracked via `.gitattributes` so cache files commit cleanly.

Inspector controls under "Persistent bake cache":

- **Cache enabled** - read/write the on-disk cache. Off = always
  bake fresh, never write.
- **Force rebake** - reads disabled even if cache exists; writes
  still happen. Useful while iterating on placement logic.
- **Bake foliage cache near origin** (button) - synchronously bakes
  every tile within `prebake_radius_m` of (0, 0). Run once after
  rearranging biomes to pre-warm the player's spawn area; subsequent
  scene opens load instantly in that region.
- **Clear foliage cache for this map** (button) - deletes every
  cache dir under `res://assets/foliage_bake/<map_id>/`. Use to
  garbage-collect orphaned key dirs left behind by config changes.

## Forcing a tile rebuild without moving

`GroundCoverScatter` only rebuilds when the camera moves past
`rebuild_threshold_m` (default 4 m). To force a rebuild after editing
a biome / species `.tres`:

1. Click the **Rebuild tiles** button on `GroundCoverScatter` in the
   inspector - preferred. Tears down all baked tiles + the species
   cache and re-bakes against the current camera. Also prints a
   1000-point biome-detection histogram to the console so you can
   verify "is the area I'm looking at actually classified as
   grassland?" before wondering why grass isn't appearing.
2. Toggle `editor_preview` off, then on, on the `GroundCoverScatter`
   node.
3. Slightly nudge the editor camera in the 3D viewport (4+ meters).
4. Click into Play mode and back out - re-runs `_ready` from scratch.

## Biome detection: Terrain3D control map

When `terrain3d_path` is set on the `GroundCoverScatter`, biome
detection queries Terrain3D's actual control map at each candidate
position via `terrain.data.get_pixel(TYPE_CONTROL, pos)` and decodes
the dominant slot id. Whatever Terrain3D *renders* at a pixel is
what foliage *places against*. This avoids the disagreement that
happens when:

- the splatmap raw bytes have e.g. `forest=120, cliff=60`,
- terrain renders cliff (because the loader's 7×7 splat blur lifts
  cliff to ~90 from neighbors and cliff wins argmax),
- but raw-byte argmax in foliage code says forest,
- → ferns end up on a cliff face.

Slot → biome mapping:

| Terrain3D slot | Foliage biome |
|---|---|
| 0 Forest | FOREST |
| 1 Grassland | GRASSLAND |
| 3 Cropland | CROPLAND |
| 4 Bare | BARE |
| 8/9/10 Paved/Unpaved/Trail | ROAD (or suppress if no road biome configured) |
| 2/5/6/7 Water/BuiltUp/Cliff/Snow | suppress (no foliage) |
| 11–15 (variants) | inherit base slot |

Road wins early on either base or overlay (≥ 25 % blend) so the
foliage doesn't bleed onto the road surface at the 1-pixel
base/overlay swap point in the loader's road encoder.

## Slope thinning

The splatmap doesn't always agree with the geometry - a "forest"
splat pixel on a 50° slope would otherwise carpet a cliff face in
ferns. The scatter computes a 4-tap centered finite-difference
gradient on the heightmap at each candidate; smoothstep falloff
from `slope_thin_start` (default 0.6 ≈ 31°) to `slope_cutoff`
(default 1.4 ≈ 54°) controls the keep probability.

Both knobs live on `GroundCoverScatter` → Scatter density → Slope
subgroup. Cheap per candidate (4 height samples).

## Density math

`plants_per_sq_m` is the master per-biome target. Whenever
`species_densities` is also given, its entries are *relative
weights*, not absolute densities — only the ratios matter. The
biome total stays at exactly `plants_per_sq_m`; the species RNG
distribution mirrors the entry ratios.

| `species_paths[i]` | `species_densities[i]` (relative) |
|---|---|
| `wild_grass_fab.tres` | 1.8 |
| `kikuyu_grass.tres` | 1.3 |
| `flower_ursinia.tres` | 0.15 |

A biome at `plants_per_sq_m = 3.25` with the table above places
3.25 p/m² total, distributed 55 % wild_grass / 40 % kikuyu /
5 % ursinia.

You can author entries as "intuitive plants/m² targets" and they
still work — only the ratio matters; `plants_per_sq_m` is the
absolute scale.

**Legacy mode.** Set `plants_per_sq_m = 0` to fall back to "sum of
`species_densities` drives total". Useful for quick prototyping
when each entry IS the absolute target; flip back to the master
knob once tuned. With `plants_per_sq_m = 0` AND `species_densities`
empty, the per-species share comes from `FoliageSpecies.weight`.

**Per-tile candidate count.** Pre-2026-05 used the GLOBAL max
density across all biomes to size the candidate budget. Now each
tile pre-samples biome at center + 4 corners, takes the max
density present in the tile, and sizes candidates to *that*. A
road tile (0.4 p/m²) generates ~10× fewer candidates than the
same tile would have under the global-max rule, dropping per-frame
bake cost on bare/road tiles proportionally. Math:
`candidates = min(placements_per_tile_cap, tile_max_density ×
tile_area × density_multiplier)`, accept_p =
`biome.density / tile_max_density`.

Current defaults at `tile_size_m = 12` (144 m²):

| Biome | density (p/m²) | per-tile placements | Notes |
|---|---|---|---|
| Forest | 0.30 | ~43 | PNW understory: ferns + moss + ground cover, sparse bushes |
| Grassland | 3.50 | ~504 | Grass-dominant; the per-tile candidate ceiling on this map |
| Cropland | 1.00 | ~144 | Fallow / weedy |
| Bare | 0.85 | ~122 | Dryland scrub |
| Road | 0.40 | ~58 | Trail-side scrub |

## Plant source pipelines

Two import paths supported, each with its own quirks:

### PolyHaven `*_1k.gltf`
- Ships JPG diff/arm/normal textures (no alpha channel) plus a gltf
  with `alphaMode: MASK`.
- Diff JPGs are *premultiplied* - the "no leaf" atlas regions bake
  to near-black instead of being transparent.
- Each gltf bundles 3–21 mesh variants of the plant (e.g.
  `grass_medium_01` carries 17 small/mid/tall × a/b/c forms).
- All node names like `<plant>_a` or `<plant>_a_LOD0`. No `_LOD1`/`_LOD2`.
- Mesh `transform.scale` = `Vector3(1, 1, 1)` (already at meter scale).
- → use per-species `alpha_luminance_cutoff = 0.05` (default).

### Fab / Quixel `<id>_ue_low.gltf`
- Ships `_B-O.png` PNGs with **real alpha channel** + `_B.jpg`
  (alpha-less duplicate) + ARM jpg + normal jpg + billboard textures.
- Always use the `standard/<id>_tier_3_nonUE.gltf` - that's the one
  whose materials reference `_B-O.png` for `baseColorTexture`. The
  root `<id>_tier_3.gltf` references `_B.jpg` and won't cut out.
- Each gltf bundles N base variants + same N at LOD1 + same N at
  LOD2 (24 nodes total for an 8-variant species).
- LOD1/LOD2/LOD3 nodes contain `_LOD1` / `_LOD2` / `_LOD3`
  substrings - filtered by the default `mesh_name_exclude =
  "_LOD1,_LOD2,_LOD3,Billboard"` on `FoliageSpecies`. Only LOD0
  base variants reach the scatter. (LOD3 was added 2026-05-05
  after some Fab packs were found to ship LOD3 as a ~14-vert flat
  leaf-shape imposter that the scatter would render as a floating
  leaf cluster with no woody structure.)
- Some Fab packs ship LOD0-tier "decoration" variants (small leaf-
  cluster fragments meant to be scattered AROUND a real bush, not
  used as the bush itself) - full LOD0 names so the LOD filter
  doesn't catch them. Use `FoliageSpecies.min_surface_verts` to
  drop them: 0 (default) keeps every variant; 2000 drops Fab
  raspberry's `VarA`/`B`/`C` decoration meshes (704-1752 verts)
  while keeping `VarD`-`H` real bushes (5925-33,731 verts). Don't
  go above ~2000 - black_locust's `VarE`/`F` are real 1800-vert
  bushes you'd lose. Set to 0 for grass / moss / ground-cover
  species where every variant is intentionally small.
- Mesh `transform.scale` = `Vector3(0.01, 0.01, 0.01)` - Quixel
  exports vertex data at UE-cm units and applies a 1/100 transform
  to land at Godot meters. The scatter captures `mi.transform.basis.get_scale()`
  per variant and multiplies it into the per-instance basis at
  bake time, so the 0.01 is preserved automatically.
- → set per-species `alpha_luminance_cutoff = 0.0` (real alpha
  channel does the cutout).

### Adding a new species (PolyHaven)

1. Open `godot/resources/foliage/species/`, right-click → New Resource → `FoliageSpecies`.
2. Save as `<plant_name>.tres`.
3. Set `mesh_scene_path` to `res://assets/models/plants_1k/<plant>_1k.gltf/<plant>_1k.gltf`.
4. Tune `scale_min/max`, `size_multiplier`. Leave `alpha_luminance_cutoff` at default 0.05.
5. Open the biome `.tres`. Append a `res://...tres` path to `species_paths`
   AND a corresponding density to `species_densities` (same index).

### Adding a new species (Fab/Quixel)

1. Extract `<id>_ue_low.zip` to `godot/assets/models/plants_fab/<readable_name>/`.
2. Repeat steps 1–2 above.
3. Set `mesh_scene_path` to
   `res://assets/models/plants_fab/<readable_name>/standard/<id>_tier_3_nonUE.gltf`
   (the **standard subdirectory** version with the alpha-bearing PNG).
4. Set `alpha_luminance_cutoff = 0.0`.

## Distance LOD: biome-tinted terrain color

`terrain3d_loader.gd` builds the TYPE_COLOR map per pixel by argmax
over the splat bytes (Forest/Grassland/Cropland/Bare) and writes a
biome-specific tint. Terrain3D's shader does
`ALBEDO *= color_map.rgb`, so the terrain itself reads as the
right biome from afar - even where no foliage meshes are baked
because the area is outside `active_radius_m`.

Default tints (alpha 0.5 = neutral wetness):

| Biome | tint (RGB) |
|---|---|
| Forest | `(0.88, 0.95, 0.82)` subtle cool green |
| Grassland | `(0.95, 0.97, 0.85)` subtle warm green |
| Cropland | `(0.95, 0.90, 0.83)` subtle warm tan |
| Bare | `(0.97, 0.94, 0.88)` subtle sandy |
| Water/BuiltUp/Cliff/Snow | `(1, 1, 1)` neutral - their own textures dominate |

Tints stay close to white (≥ 0.88) so they nudge hue without
darkening albedo meaningfully. Three octaves of noise (large /
medium / small) modulate per-pixel brightness ±15% to read as
patchy ground cover from distance - bright spots = sunlit clumps,
dark spots = shadowed patches. Noise is baked into the static
image, zero runtime cost.

Triggers a re-bake when changed. Tunable in
`terrain3d_loader.gd._build_biome_color_image()` constants
(`TINT_*`, `_NOISE_AMP`).

## Per-species color grading: `albedo_modulation`

Each `FoliageSpecies` has an `albedo_modulation: Color` field
(default `Color(1, 1, 1, 1)` = no-op). The ground cover shader
does `ALBEDO *= albedo_modulation` per fragment - so plants can
be hue-shifted to match the terrain they sit on without re-baking
textures.

Defaults are auto-derived by `scripts/derive_foliage_modulation.py`,
which:

1. Samples each terrain slot's mean RGB (the
   `_terrain3d_packed/<slot>/<slot>_alb_ht.png` files)
2. Maps biomes to slots (`BIOME_SLOTS` in the script)
3. Walks the biome `.tres` files for species → biome density
4. Computes a weighted-average biome color per species
5. Luminance-normalizes (preserves brightness, shifts hue)
6. Mixes toward white by `--strength` (default 1.0) and rewrites
   the `albedo_modulation = Color(...)` line in each species `.tres`

```
python3 scripts/derive_foliage_modulation.py --dry-run            # preview
python3 scripts/derive_foliage_modulation.py                      # apply at strength 1.0
python3 scripts/derive_foliage_modulation.py --strength 1.3       # warmer
python3 scripts/derive_foliage_modulation.py --strength 0.5       # subtler
```

`EXCLUDED_BIOMES = {"road"}` in the script blacklists biomes
whose ground colour shouldn't influence foliage tinting (asphalt /
packed-dirt textures aren't "natural plant habitat" - tinting
foliage toward them dirties the plants). Species that grow ONLY
in an excluded biome get the identity modulation; species shared
across excluded + non-excluded biomes are weighted by the
non-excluded biomes alone.

After running the script, **restart the editor** before hitting
Rebuild - Godot caches `.tres` resources, and the running editor
holds the old values until the cache is dropped.

Per-species hand-tuning: edit `albedo_modulation` directly on the
species `.tres` (the script overwrites on re-run, so save your
custom values elsewhere if you want them sticky).

## Performance

Tile bake math at the current defaults (`tile_size_m = 12`,
`active_radius_m = 50`):

- 144 m² per tile × ~50 tiles in active set ≈ 7200 m² covered
- Grassland (densest) at 8 p/m² → ~1152 candidates per tile
- Per-tile bake cost ~17 ms (biome lookup + slope + RNG + transform)

Two perf-relevant exports on `GroundCoverScatter`:

- **`bake_per_frame_budget`** (default 2): caps how many tiles
  bake per frame. The full active-set diff still runs every
  rebuild, but actual bake work spreads across frames. Set 0 for
  synchronous baking (old behaviour, may stutter on tile-cross).
  Tiles in the queue sort by distance from camera so the closest
  pop in first; tiles that leave the active radius before being
  baked are dropped.
- **`placements_per_tile_cap`** (default 2048, raised to 4000 in
  the test scene): hard ceiling. If a biome's `species_densities`
  sum × `tile_area` exceeds this, the cap kicks in and the actual
  density drops below target.

GPU-side: the shader does view-cone density culling - instances
whose `INSTANCE_CUSTOM.x` roll exceeds the cone-aware density curve
collapse to a degenerate point at their model origin. CPU pays no
per-frame cost beyond the tile-cross check. Globals driving the
cone live in `globals.tres` and push every frame in editor mode.

### Tangent regen

Some Fab gltf surfaces don't ship tangent arrays even with
`meshes/ensure_tangents=true` in the .import. The shader uses
normal-map sampling which requires tangent space, and Godot logs
a per-frame warning + falls back to a slow path. The scatter
defensively rebuilds every variant mesh through
`SurfaceTool.generate_tangents()` at first species load - ~50 ms
one-time cost per species, then cached.

## Why standalone `.tres` instead of inline sub-resources

Earlier the biomes + species were inline `sub_resource` blocks in
the test scene. Editing a species in the inspector would fire the
parent biome's `property_list_changed` signal, which Godot 4.6.2's
inspector then re-binds against - and if the original sub-resource
gets freed mid-signal, the editor crashes (`Object was freed or
unreferenced while a signal is being emitted`).

The bug fires on any editor-time **`Resource` swap** - including
inside `Array[Resource]` array editors. The fix used everywhere in
this system is **path-string indirection**:

- `FoliageSpecies.mesh_scene_path: String` (not `mesh_scene: PackedScene`).
- `BiomeSpeciesConfig.species_paths: Array[String]` (not `species: Array[FoliageSpecies]`).
- `GroundCoverScatter.terrain3d_path: NodePath` (already path-based).

The scatter `load()`s each path lazily and caches. The inspector
never holds a `Resource` handle on the swappable side, so the bug
can't fire. UX cost: drag-and-drop from FileSystem onto a string
field still works (Godot inserts the `res://` path).

## Variant extraction + size variation

A single source gltf becomes N `Mesh` resources in
`_species_meshes[idx]: Array[Mesh]`, one per surviving variant after
the `mesh_name_exclude` filter. Per-instance the bake picks a uniform-
random variant index and buckets by `(species, variant)` - one MMI
per pair, one `Mesh` per MMI as Godot requires.

So `wild_grass_fab` → 8 MMIs in a tile that places it; `grass_med_01`
(PolyHaven, 17 variants) → up to 17 MMIs. With current grassland
species mix that's ~50 unique grass meshes scattered per tile - what
makes a meadow read as a real meadow rather than a single repeated
tuft.

`scale_min/max` jitter applies on top of variant size (variants are
already different sizes - small/mid/tall/large for grass), so the
final per-instance scale is `lerp(scale_min, scale_max, rng) ×
size_multiplier × variant_node_scale`.

## Tree LOD pipeline

Trees use a three-tier pipeline tuned for forests dense enough to read
as canopy from kilometers away while still being walkable up close
without LOD pop-ins. The per-tree impostor-billboard tier was dropped
in favor of pushing the close mesh chain further out and letting the
canopy cluster cards take over at ~800 m:

| Tier | Distance band (default) | Source | Vert cost / tree |
|---|---|---|---|
| LOD0 / LOD1 / LOD2 / LOD3 close mesh | 0–220 / 220–500 / 500–850 / 850–~900 m | per-MI `_LOD<N>` from glb (or Godot-generated for Pure3D) | 5K → 2K → 1K → ~250 |
| Canopy card cross-billboard | 800 m+ | per-species albedo + normal PNG pair baked by `godot/tools/imposter_baker.gd` (see [`walkthroughs/distant-trees.md`](distant-trees.md)), placed by `TreeClusterScatter`. **Lit billboard** — runtime shader runs the same `light()` model as close-tier so distant trees track dynamic sun direction + weather lighting. Per-species color baked into PNG; lighting computed per-frame. | ~6 (one card per ~26 m grid cell) |
| Terrain shader tint | horizon backstop | baked per-biome into `tree_coverage.res` | 0 (one extra texture sample) |

The cluster cards sample one of the 14 baked impostor PNGs (paths
listed on `TreeClusterScatter.impostor_texture_paths`) so the distant
silhouette matches the actual species mix on the ground.

### LOD selection - per-instance world-hash dither

The close-tier shader (`tree_dynamic.gdshader`) and the impostor shader
(`tree_imposter.gdshader`) share a single LOD-selection scheme: each
LOD MMI declares its `lod_lower_boundary` / `lod_upper_boundary` (the
inter-LOD transition distances) plus a `lod_fade_half_width`, and the
vertex shader picks **per-instance** between "render this tree" and
"collapse to a degenerate triangle" using a stable hash of the
instance's world XZ:

```glsl
float h = fract(sin(dot(inst_world.xz, vec2(12.9898, 78.233))) * 43758.5453);
// Close-side LOD discards if hash > alpha
// Far-side LOD  discards if hash <= 1 - alpha
```

The two discard rules are **complementary** by construction - at any
distance in a fade zone, every tree renders as exactly one of {close
LOD, far LOD}, the population shifts smoothly with distance, and
combined pixel coverage stays at exactly 100 %.

**This is the load-bearing detail** that fixes the "see-through trees
while walking" bug. `VISIBILITY_RANGE_FADE_SELF` (Godot's built-in
LOD dither) uses an independent **screen-space** hash per MMI; two
MMIs cross-dithering at 50 % each coincide on ~25 % of pixels →
visible holes through the canopy that shift with the camera. A
**world-space per-instance** hash, shared with the neighbor LOD via
complementary discard rules, has no such collisions.

It's per-instance (not per-pixel) so a single tree always renders
fully as one LOD - no fragmented silhouettes.

### Knobs

On `TreeScatter` in the scene (per-map override of the script defaults):

- `lod_band_ends_m = (220, 500, 850)` - inter-LOD distances.
  Element N is the boundary between LOD N and LOD N+1. The HIGHEST
  LOD's upper boundary is derived from `max_render_distance_m` on
  the species (the per-tree impostor tier was dropped, so
  `proxy_swap_distance_m = 0` on every species file).
- `lod_band_fade_m = 100` - total fade-zone width per boundary
  (shader sees `lod_fade_half_width = lod_band_fade_m / 2`). Wider =
  individual trees still pop at their own hash-determined distance,
  but the *population* of switching trees is spread over more meters
  → soft visual gradient instead of a band.
- `active_radius_m = 900` / `prebake_radius_m = 960` - bake horizon
  for the close-tier MMIs (cluster cards take over past this).
- `shadow_radius_m = 250` - only trees inside this radius cast
  directional shadows. Tracks the sun's
  `directional_shadow_max_distance` (250 m, 4-split with ratios
  0.08 / 0.22 / 0.5).
- `bake_per_frame_budget = 4` - steady-state tile bake rate.
- `bake_burst_budget = 16` - kicks in while `_bake_queue.size() > 32`
  (initial scene load, fast camera movement) so the wave drains in a
  few frames instead of trickling.

In each `TreeSpecies` (`doug_fir_*.tres`, `pine_*.tres`, `birch_*.tres`):

- `proxy_swap_distance_m = 0` - billboard-tier disabled. Left in place
  as a knob for future re-enable but every shipping species sets 0.
- `max_render_distance_m ≈ 900` - hard cull backstop, unified across
  species. Tracks `TreeScatter.active_radius_m`.
- `min_surface_verts = 0` - billboard surface extraction off. Was
  used to split the impostor billboard out of the close-tier mesh
  back when the per-tree impostor existed; with that tier dropped,
  every authored surface stays in the close mesh.
- `albedo_modulation = Color(0.65, 0.72, 0.55, 1)` for Doug Fir -
  matches the muted forest-tint canopy cards render at, so the close
  trees blend visually with their distant counterparts.
- `trunk_collision_radius` / `trunk_collision_height` - set BOTH to
  `0.0` to skip collision spawn for that species. Convention: any
  variant authored at sapling scale (Doug Fir `small_*`, Pine
  `sapling_*`) is walk-through. Mature trunks need physical
  blockers; thin saplings would just be annoying obstacles in dense
  forest. The spawn code in `tree_scatter.gd` checks
  `<= 0.0 / > 0.0` on either dim and skips the StaticBody3D + cylinder
  shape entirely.

### Foliage lighting (per-species, live-pushed)

Four uniforms on `tree_dynamic.gdshader` live under the species's
"Foliage lighting" export group; `TreeScatter._push_live_uniforms`
pushes them every frame in editor mode so changes are zero-rebake:

- `canopy_normal_up_blend` (0–1, default 0) — blends per-vertex
  NORMAL toward object-up above `trunk_anchor_height`. Leaf cards
  light independently as the sun catches each quad's authored
  normal, producing salt-and-pepper specular sparkle on dense
  canopies. Blending toward +Y makes the canopy light as a unified
  volume (SpeedTree / Crytek "capsule normal" trick). 0.4–0.6 for
  full Doug Fir canopies; lower for sparse pines so individual
  fronds still get directional shading.
- `backlight_strength` (0–1, default 0) + `backlight_color`
  (default warm-yellow) — drives the wrap-diffuse + transmission
  contribution in the custom `light()` function. 0 = back-lit
  needles render fully dark (current default). ~0.3–0.5 simulates
  needle SSS — back-lit canopy glows softly against bright sky.
- `normal_map_strength` (0–1, default 1) — scales the texture
  normal map's perturbation amount (mixes toward flat 0.5,0.5,1.0).
  Lower for canopy materials whose normal map was authored for a
  flat leaf card; trunk/bark stays at 1.0.

### Custom `light()` function (replaces standard pipeline)

`tree_dynamic.gdshader` defines its own `light()`. When a shader
defines `light()`, Godot bypasses the engine's default Lambert /
Burley diffuse AND the BACKLIGHT path — so transmission is handled
entirely inside `light()` (via `backlight_strength` + `backlight_color`)
and `BACKLIGHT` is not written from `fragment()`. Two contributions:

1. **Wrap diffuse** (`wrap = 0.6`) — extends NdotL past 90° so the
   shadow side of a leaf still receives partial sun. Leaves transmit
   and bounce internally enough that even back-to-sun fronds aren't
   pitch black under direct light.
2. **Back transmission** — when NdotL < 0, light passes through the
   leaf and exits the camera-side, tinted by `backlight_color`.
   View-independent (true SSS is view-coupled, but at 5+ m canopy
   distances the constant-tint approximation reads correctly).

`fragment()` also writes a small `EMISSION` skylight bounce
(`ALBEDO * vec3(0.20, 0.22, 0.25) * sky_bias`) that bypasses shadow
attenuation, so trunks under cascade shadow stay legible against the
bright canopy even at the new 250 m shadow distance. Roughness
raised to 0.95 (was 0.85) to kill specular hotspots on flat leaf
cards now that transmission carries the foliage look.

### Per-tile spatial dedup

`_bake_tile` rejects any candidate within 4 m (squared-distance
compare) of an already-placed tree in the same tile. Two species
rolling near-identical XZ produced "co-located trees" — different
species have different `trunk_anchor_height`, so one species's
animated canopy visibly swayed through the other species's static
lower trunk, reading as a duplicate stretching tree drifting
alongside the static base.

### Tile-MMI vis = coarse hard pre-cull

The MMI's `visibility_range_*` is now a **hard pre-cull** (no engine
fade), widened by `tile_size_m × √2/2 + _LOD_BAND_FADE` so corner
instances aren't wrongly culled. The shader handles the actual fading
per-instance. This combination - coarse tile-MMI cull plus fine
per-instance shader cull - is the cheapest accurate setup we found:
the tile cull saves vert-shader work on whole tiles outside the band,
and the shader cull picks correctly within tiles even though the
tile-center distance can be ~90 m off from any individual tree's
distance (`tile_size = 128 m`).

### Asset prep gotcha

Three packs ship with the per-MI `_LOD<N>` chain + billboard impostor
surfaces our pipeline expects:

| Pack | Variants | Source |
|---|---|---|
| Doug Fir | 9 (small/medium/large × 3) | `plants_fab/tree_douglas_fir/` (Fab USD pre-prepped through Blender into per-size .glbs) |
| Birch | 5 (Birch + Birch_2..5; only the 4 numbered ones used) | `trees/birch_lod_pack/` (Sketchfab) |
| Pine | 15 (sapling/small/medium/large/big × 3) | `trees/pine_lod_pack/` (Sketchfab `pine_trees_pack_lowpoly_game_ready_lods.glb`) |

The other Fab tree packs in `asset_downloads/` (Baltic Pine, Aspen,
Beech, Black Alder, Common Hazel, English Oak, Rowan Sapling, Aleppo
Pine) are USD point-instancer assets - no LOD chain, no billboard
surfaces. Adding any of them needs Blender pipeline work: bake the
point instancer to mesh, generate decimated LOD chain, render
multi-angle billboard atlas, export as glb with `_LOD<N>` named MIs.
See the "Out of scope" note in `planning/foliage-plan.md`.

### Materials persistence gotcha

`TreeCoverageBaker._bind_runtime` **does not** call
`ResourceSaver.save(mat, mat.resource_path)` on the Terrain3DMaterial.
Terrain3DMaterial filters user-defined uniforms when serialising -
saving wipes any inspector tweaks to other override-shader uniforms
(`tree_coverage_distance_*`, bumpiness, lum_match, etc.). The baker
re-applies texture + origin + size from disk in `_ready()`, so disk
persistence of the material is unnecessary.
