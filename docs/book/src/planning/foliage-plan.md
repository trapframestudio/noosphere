# Foliage & Tree Scattering - Plan

**Status (2026-04-28):** ground cover scatter substantially refactored
on top of the 2026-04-27 baseline. Major additions:

- **Per-species explicit density** (`species_densities` parallel array
  on `BiomeSpeciesConfig`) replaces weight-RNG when set. Each plant
  has direct `plants/m²` control inside each biome.
- **Per-variant mesh extraction** - a single PolyHaven gltf has
  3–21 mesh variants, a single Fab gltf has 8 LOD0 variants ×3 LODs
  (LOD1/LOD2 filtered out by default `mesh_name_exclude`). Per-instance
  the bake picks a variant uniformly. ~50–100 unique meshes scattered
  per tile in dense biomes, no more "single repeated tuft".
- **Fab/Quixel asset pipeline** wired in. Auto-applies the `[0.01]`
  node scale (UE-cm → Godot-meter), uses `_B-O.png` for real alpha
  cutout. Imported 4 grass + 2 fern Fab plants.
- **Terrain3D control-map biome detection** - when a `terrain3d_path`
  is wired, foliage queries Terrain3D's actual rendered control map
  for the dominant slot at each pixel instead of doing its own
  splatmap argmax. Foliage and terrain agree exactly on what's at
  each pixel, no "ferns on a cliff face" mismatches.
- **Slope thinning** - heightmap gradient sampled per candidate;
  smoothstep falloff between `slope_thin_start` and `slope_cutoff`.
- **Inspector path-string indirection** - Godot 4.6.2 segfaults when
  `Resource` references swap in inspector arrays. All hot-edit fields
  on `FoliageSpecies` and `BiomeSpeciesConfig` are now `String` paths
  that load lazily at runtime.
- **`FoliageGlobals` resource** - wind / view-cone / density falloff
  in one inspectable `.tres`. Live tuning in editor preview.
- **Biome-tinted color map** - `terrain3d_loader.gd` writes a per-
  pixel biome tint into Terrain3D's TYPE_COLOR map. Distant terrain
  reads as the right biome (greenish for grassland, tan for bare,
  etc.) even when no foliage meshes are baked there. Free distance
  LOD trick.
- **Incremental tile baking** - `bake_per_frame_budget` caps how
  many tiles bake per frame; queue sorts by camera distance. Removes
  the 200–400 ms hitch on tile-cross at high density.
- **Tangent-warning fix** - `NORMAL_MAP` removed from the shader
  (Fab variants without UVs were causing per-frame Godot warnings
  + fallback render path).

For full tunables + the "what triggers what cost" matrix, see the
[Foliage Tuning walkthrough](../walkthroughs/foliage-tuning.md).

Editor-side terrain plugin is on TokisanGames Terrain3D -
see the [Terrain3D walkthrough](../walkthroughs/terrain3d.md).

## Remaining todos

Ground cover (parked - addressable after we sit with the current state):

- **Stones / decoration scatter.** The current shader is plant-tuned
  (wind sway, alpha cutout, view-cone collapse). Stones need a
  different shader or a `is_decoration: bool` uniform that gates
  these. Architectural notes in the previous turn's discussion.
- **Texture downsample pass.** Fab plants ship 1K PNGs (~7 MB each).
  For ~6 imported plants that's ~42 MB. Either set
  `process/size_limit=512` on the .import sidecars, or write a
  pre-process script that downsamples to 512 once.
- **Per-instance fade-in shader.** New tile bakes pop in visibly at
  the active-radius edge. Could fade instances from 0 → full scale
  over ~0.3 s based on a tile-bake-time uniform.
- **Splat-map alpha for PolyHaven plants.** Some `_diff_1k.jpg`
  textures discard via the per-species `alpha_luminance_cutoff`
  (luminance threshold on the premultiplied background). Upgrading
  to PolyHaven's 4k tier (PNGs with real alpha) would let us drop
  the luminance hack everywhere.
- **Foliage exclusion volumes.** Original parked design - Area3D
  volumes that suppress scatter for hand-detailed areas. Still not
  built; wire when the first hand-detailed location lands.

Trees (shipped - see `walkthroughs/foliage-tuning.md` "Tree LOD
pipeline"):

The four-tier tree system is in. Close-tier mesh LODs (LOD0/1/2 from
the source glb), per-tree impostor billboard (extracted LOD3 surface),
canopy card cross-billboards (`TreeCoverageBaker`), and terrain shader
tint (baked density texture sampled in the override shader). LOD
selection is per-instance via a stable world-XZ hash with complementary
discard rules between adjacent LODs - solves the screen-space-dither
see-through bug, transitions read tree-by-tree instead of in tile-
coordinated waves. Doug Fir + Birch are wired (Doug Fir in forest
biome, Birch sparse in grassland).

**Out of scope (future tree work)**: more conifer species. The Fab
USD packs in `asset_downloads/` (Baltic Pine, Aspen, Beech, Black
Alder, Common Hazel, English Oak, Rowan Sapling, Aleppo Pine) are
point-instancer assets - no LOD chain, no billboard impostor surfaces.
Adding any of them needs a Blender pipeline pass: bake the point
instancer to mesh, generate a decimated LOD chain, render a multi-
angle billboard atlas, export as glb with `_LOD<N>` named MIs.
Estimated 2–6 hours per species depending on whether the billboard
bake is automated. Track when a 3D pipeline session is scheduled.

The wind-driven global shader uniforms (`foliage_wind_strength` /
`foliage_wind_speed`) drive both the ground-cover shader and the
tree close-tier shader via `WeatherRig`. The ground-cover system also
added eight globals for view-cone modulation (`player_cam_pos`,
`player_cam_forward`, `gc_radius_front`, `gc_radius_rear`,
`gc_cone_full_cos`, `gc_cone_periph_cos`, `gc_density_periph`,
`gc_density_rear`) - see the walkthrough for what they do and how
they're driven.

This doc captures **what was tried, what failed, and what's worth
preserving** so the next implementer doesn't relearn it.

---

## Goal

Place trees + ground cover (grass, ferns, flowers, weeds) across the
~4 km playable maps at densities that read as natural Pacific Northwest
forest / meadow, at 60+ fps on a mid-range desktop GPU, driven from the
already-baked terrain splatmaps so foliage respects biome boundaries
automatically.

---

## What we tried, in order

### 1. Zylann HTerrain plugin's `HTerrainDetailLayer` system *(initial)*

The terrain plugin ships a built-in detail-layer system: paint a density
mask, place card-mesh instances, configurable view distance + shadow
LOD. Worked out-of-the-box but the shader is fixed (no translucency, no
custom wind), the asset path required Z-up→Y-up + base-pivot conversion
for Megascans plants, and density-driven distribution was tied to a
chunky 32 m × 32 m chunk grid.

**Removed in PR #125.** `hterrain_baker.gd` no longer builds detail
layers; `hterrain_loader.gd` no longer writes `CHANNEL_DETAIL` masks;
the plugin's `hterrain_detail_layer.gd` was reverted byte-for-byte to
upstream. Plugin is now used only for heightmap geometry, splatmap
texturing, and collision.

### 2. PolyHaven `*_diff_alpha_*.png` billboard cards

First mesh-less attempt. `GroundFoliageScatterer` built a 3-card
asterisk mesh at runtime, mapped each species' PolyHaven
`*_diff_alpha_*.png` onto the cards.

**Failed.** The PolyHaven `_diff_alpha_*.png` files turn out to be
**UV-island atlases keyed to the gltf's blade-strip mesh** - every
individual blade strip has its own UV region across the texture, with
the various strips rendering specific 3D leaf cards within the gltf
mesh. Projecting the whole atlas onto a single flat billboard quad
produces a chaotic UV-island fan, not a plant. Visible in
[image #1 from the iteration history](#image-references).

### 3. Megascans Billboard atlases with shader cell-pick UV remap

Pivot. Megascans plants ship `*_Billboard_B-O.png` atlases that *look*
like clean N×N grids of single-plant cards. The shader was extended
with `atlas_cols` / `atlas_rows` uniforms; vertex stage hashed
`(instance_origin, card_id)` → cell index → UV remap. Per-card jitter
(XZ offset + Y rotation) added to break up the asterisk silhouette
from above.

**Partially worked, then failed.** Initial bug: per-card cell pick
showed three different plants on each asterisk. Fix: pin cell pick on
`inst_xz` only so all three cards of one asterisk show the same plant
(billboard from 3 angles).

The deeper structural failure: **Megascans Billboard atlases are not
actually grid-aligned.** Plants scatter across the image with
overlapping bounding boxes, often with fronds extending into adjacent
cells. The shader's tight cell-clamp UV produced **hard frond clips
at cell boundaries**. There's no shader-side fix without recropping
every atlas by hand, because expanding the UV range bleeds into a
*different plant* in the next cell.

### 4. Mesh-based PolyHaven plants via `GroundFoliageScatterer`

Pivot to load actual gltf plant meshes (same pattern as
`TreeScatterer`). Chunked output (96 m grid), `lod_bias = 0.6`,
`cast_shadow = OFF`, optional VR culling. 9 species across
Forest/Grassland/Cropland/Bare biomes.

**Partial success - visually correct but density was a problem.** The
math worked: at scatter step 5 + per-species density 0.4 + 25 m view
distance, ~5 visible plants/species/frame × 9 species = 45 visible at
~500 polys = 22.5k tris, well in budget. **But:**

- PolyHaven plant mesh AABBs are tiny (e.g. `moss_01_a` is 2.6 cm tall
  → subpixel even at scale 4×). Fixed by dropping moss + bumping
  per-species `instance_scale` so visible plants land at 0.5–1.0 m.
- Coverage was Forest-heavy (153k of 170k placements). User in
  Grassland saw ~30 plants/hectare ≈ 1 visible per camera frame. Fixed
  by lowering Grassland threshold (80 → 40), bumping density, adding
  Celandine + Ursinia + Periwinkle in non-Forest biomes.
- Even after densifying, Grassland still felt sparse. Likely needs
  much higher density per pixel and/or more species variety than
  PolyHaven offers in its plant catalog.

### 5. `TreeScatterer` for sparse hero props (pine, fir, saplings)

PolyHaven gltfs at ~10–30k polys per LOD0 (decimated from raw
~100k–1M). Same chunked-MMI pattern as ground foliage but at 200 m
chunks. Initial hardcoded view distance + shadow casting + fixed
elevation gates produced 9 fps with 132k trees on cascade_locks.

Iterations:
- Density step 5 → 8 → 10 (~33k trees vs 132k)
- Chunk size 96 → 200 m (5607 → 464 chunks → fewer draws)
- `lod_bias` 0.5 → 0.9 → 0.6 (after the alpha-mode bug was fixed)
- `cast_shadow` opt-in `false` (alpha-tested leaves × shadow cascades
  is the dominant cost; full fix requires shadow-proxy meshes)
- VR culling on by default at 350 m
- Opened all elevation ranges to (50, 1500) - initial gates excluded
  firs at gorge-floor altitude ⇒ "everything looks like the same pine"
- Added `FirSaplingsMedium` + `PineSaplingsSmall` for silhouette variety

**Still unworkable.** Even at ~33k trees with `cast_shadow = OFF`,
`lod_bias = 0.6`, and 350 m VR culling, the user reported continued
performance problems. PolyHaven trees are **pure 3D geometry - no
alpha-cut leaves** (their `.jpg` textures have no alpha channel; the
foliage on the tree is modeled as faceted twigs/needles), so each
visible tree is its full polygon count and there's no LOD-friendly
billboard fallback. Without a proper impostor pipeline, this density
can't go on a mid-range GPU.

---

## Key technical findings worth keeping

### PolyHaven gltf URI bug *(fixed; pipeline preserved)*

`scripts/onboard_polyhaven_trees.py` ran Blender headless with
`bpy.ops.export_scene.gltf(export_keep_originals=True)`, which
**writes URIs preserving the source-import paths** - i.e. the
`/tmp/polyhaven_<slug>_*/textures/<file>.jpg` path that the temp dir
exposed during import. By the time Godot loaded the gltf, those /tmp
dirs were gone → every `baseColorTexture` 404'd → trees rendered
white. Symptom diagnosed via `grep '/tmp/' <gltf>`.

Fix: `rewrite_gltf_uris_to_local()` post-process step in
`scripts/onboard_polyhaven_trees.py` rewrites every URI from
`<anything>/textures/<file>` → `textures/<file>` after every decimate.
Idempotent; safe to re-run.

The patched gltfs for cascade_locks's tree species (pine_tree_01,
fir_tree_01, pine_sapling_medium, fir_sapling) are committed via LFS
in `godot/assets/models/plants/`. **Reference: [PolyHaven gltf
gotchas memory](../../../../../../home/jon/.claude/projects/-home-jon-Development-projects-noosphere/memory/reference_polyhaven_gltf_gotchas.md).**

### Godot 4 gltf material extraction *(useful pattern)*

Godot 4's gltf importer attaches PBR materials as
`surface_override_material/*` on the **MeshInstance3D node**, NOT on
the Mesh resource itself. Code that does `multimesh.mesh = mi.mesh`
silently drops every material → MultiMesh draws white.

The pattern that worked (preserved in git history under both
removed scatterers, easy to re-derive):

```gdscript
var mesh: Mesh = mi.mesh.duplicate() as Mesh
for i in mesh.get_surface_count():
    var mat := mi.get_surface_override_material(i)
    if mat == null:
        mat = mesh.surface_get_material(i)
    if mat != null:
        mesh.surface_set_material(i, mat)
multimesh.mesh = mesh
```

### Auto-detect alpha mode on imported textures *(useful pattern)*

Godot 4's gltf importer commonly imports leaf-card materials with
`transparency = TRANSPARENCY_DISABLED` even when the texture has an
alpha channel. PolyHaven *plants* (non-tree) ship `_diff_alpha_*.png`
files with real alpha; the importer leaves them on opaque. Force
scissor:

```gdscript
for i in mesh.get_surface_count():
    var sm := mesh.surface_get_material(i) as StandardMaterial3D
    if sm == null or sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
        continue
    if sm.albedo_texture == null:
        continue
    var img := sm.albedo_texture.get_image()
    if img == null or img.detect_alpha() == Image.ALPHA_NONE:
        continue
    var fixed := sm.duplicate() as StandardMaterial3D
    fixed.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
    fixed.alpha_scissor_threshold = 0.5
    fixed.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh.surface_set_material(i, fixed)
```

PolyHaven trees specifically have no alpha (jpg textures, fully
modeled foliage geometry), so this fix correctly leaves their
materials opaque.

### Chunked MultiMeshInstance3D with `custom_aabb`

A single map-spanning MMI's AABB always contains the camera ⇒
VisibilityRange + frustum culling are no-ops. The pattern that
worked: bucket transforms by `Vector2i(floor(world_xz / CHUNK_SIZE_M))`,
emit one MMI per (species, chunk), set `MultiMesh.custom_aabb` to
the chunk's actual world XZ footprint so culling fires per chunk.
World-space transforms + identity MMI transform keep the math
trivial.

### Wind globals → weather pipeline *(preserved, ready to adopt)*

`project.godot` declares two `[shader_globals]`:
```
foliage_wind_strength (float, default 0.12)
foliage_wind_speed    (float, default 1.7)
```

`WeatherRig._apply_weather_to_foliage()` reads the active
`_weather_weights` blend (same source the cloud system uses), pulls
`wind_mul` from `_WEATHER_CLOUD_PRESETS`, applies a transition gust
boost, and writes:
```
strength = base × effective_wind         (linear, 0.05–0.48)
speed    = base × sqrt(effective_wind)   (sublinear, doesn't go frantic)
```

Any future foliage shader that declares
`global uniform float foliage_wind_strength;` will be auto-driven
by sim weather without further plumbing. Don't remove these.

### Tree LOD + shadow research findings

The bigger Godot 4 shadow / vegetation perf levers (cited in
[tree perf plan memory](../../../../../../home/jon/.claude/projects/-home-jon-Development-projects-noosphere/memory/project_tree_perf_plan.md)):

- `directional_shadow_max_distance` (project-wide; quadratic cost
  reduction). **Already set to 80 m via WeatherRig.**
- `directional_shadow_mode = SHADOW_PARALLEL_2_SPLITS` (default 4
  splits is much more expensive on Forward+ for marginal quality
  gains in open world). **Already set via WeatherRig.**
- `rendering/lights_and_shadows/directional_shadow/size = 2048`
  (default 4096; halves shadow render cost). **Already set.**
- Mesh-LOD via `lod_bias` on each MMI. Godot 4.3+ generates LODs at
  gltf import via meshoptimizer.
- Shadow proxy MMI per chunk: parallel `cast_shadow = SHADOWS_ONLY`
  MMI with a low-poly silhouette mesh. Godot 4 has no per-instance
  shadow-mesh API, so this is the workaround. **Not implemented.**
- Impostor billboards for distant trees. Godot 4 has no first-party
  impostor pipeline; community solutions exist (octahedral impostor
  shaders), all require a Blender bake step.

### Foliage exclusion design *(parked, never implemented)*

Plan from earlier in the session:
[foliage exclusion memory](../../../../../../home/jon/.claude/projects/-home-jon-Development-projects-noosphere/memory/project_foliage_exclusion_design.md).
TL;DR: hand-detailed areas would carve out auto foliage via
`Area3D` exclusion volumes queried at scatter-bake time. Decided in
principle, never wired up because the scatter system itself never
landed.

---

## What's still in the codebase

- **Terrain3D plugin** - replaces HTerrain on the test path; see the
  [Terrain3D walkthrough](../walkthroughs/terrain3d.md). Production
  maps still use the Rust `TerrainNode`.
- **Wind globals + WeatherRig hookup** (see above). Inert until a
  foliage shader adopts them.
- **PolyHaven plant + tree catalog** at
  `godot/assets/models/plants/<slug>_<res>.gltf/`. Mirrored at 1K/2K
  (no >2K imports per the asset-size rule). Filtered to the PNW -
  needled saplings (pine_sapling_small, fir_sapling/medium), generic
  shrubs (shrub_01-04), small-plant cards (fern_02, moss_01,
  celandine_01, dandelion_01, weed_02), grasses (grass_medium_01/02),
  forest-floor structure (tree_stump_01/02, dead_tree_trunk_01/02,
  root_cluster_01/02, pine_roots, single_root, bark_debris_01,
  dry_branches_medium_01). South African karoo flora (quiver_tree,
  searsia, leipoldtia, wild_rooibos_bush, othonna, iceplant,
  flower_gazania/heliophila/ursinia/empodium), tropical fillers
  (pachira_aquatica, island_tree_01-03, anthurium_botany,
  calathea_orbifolia), and the rocks / food / household-prop
  categories the fetch script accidentally pulled in were removed
  in a follow-up cleanup.
  Static structural assets (stumps, trunks, roots) are kept on disk
  but **not** wired into biomes - they don't belong in a wind-
  animated foliage system; reserve for a future static-prop
  scatter. All Y-up + base-pivot via PolyHaven's standard glTF.
- **Megascans plant bundles**: lady_fern, beech_fern, wild_grass,
  kikuyu_grass, ribbon_grass, field_poppy, yellow_archangel. Tier-3
  gltf + Billboard atlases + ARM/diff/normal textures. Need Z-up→Y-up
  + base-pivot conversion if used (helper was in earlier history).
- **`scripts/fetch_polyhaven_models.py`**: PolyHaven API mirror;
  enumerates `type=models` by category (trees, plants, ground cover,
  flowers, grass, nature, rocks, collections), downloads the smallest
  available glTF that doesn't exceed `--resolution`. Resumable.
- **`scripts/generate_polyhaven_species_tres.py`**: walks
  `plants/<slug>_<res>.gltf/`, emits `FoliageSpecies` `.tres` files
  pointing at the smallest resolution. Filters to tree/shrub/sapling
  tier by default; pass `--all` to include rocks/decoration.
- **`scripts/onboard_polyhaven_trees.py`**: original PolyHaven tree
  pipeline (download via Blender headless, decimate, URI-rewrite).
  Superseded by `fetch_polyhaven_models.py` for new imports but kept
  for the URI-rewrite path.
- **`scripts/generate_plant_alpha.py`**, **`extract_fab_zip.py`**,
  **`downsample_textures.py`**: general asset-prep utilities.
- **`asset_downloads/foliage_billboards/`** *(gitignored)*: copies of
  all 7 Megascans Billboard atlases for offline cropping work.

---

## What shipped (2026-04-27)

The next-attempt notes below predate the ground-cover system. For
ground cover specifically, the path that worked was:

- **CPU-side deterministic placement**, hashed per tile, baked once
  per active tile and freed when the player moves out of range.
- **GPU-side view-cone density culling** via `INSTANCE_CUSTOM.x` per
  instance + `player_cam_pos` / `player_cam_forward` global uniforms
  pushed by `player.gd` each frame.
- **Splatmap read directly from the canonical `.rgba8` files** rather
  than going through a terrain node - keeps the system decoupled from
  whichever rendering backend is in use.

See [Ground Cover Foliage walkthrough](../walkthroughs/ground-cover-foliage.md)
for the full story.

The directions below remain the right shape for **trees and larger
plants**, where the dominant cost is per-tree triangle count and only
an impostor pipeline (item 2) is likely to make PolyHaven trees viable
at distance.

## Suggested directions for trees + larger plants

Roughly ordered by promise / cost:

1. **Custom Blender meshes per species.** User offered to build proper
   asterisk billboards with hand-tuned UVs + transparent padding per
   card. Bypasses every atlas-cropping problem. Best for ground cover.
2. **Tree impostor pipeline.** Octahedral impostors baked from the
   PolyHaven trees (8-angle render → atlas → custom shader). Best
   chance of making PolyHaven trees performant at distance.
3. **TokisanGames Terrain3D - shipped 2026-04-27.** Replaces HTerrain
   on the test path; the latter was deleted in the same PR. 16-slot
   PNW asset list, splatmap → control-map converter, region-based
   on-disk format. Built-in `Terrain3DInstancer` (chunked MultiMesh,
   10-LOD, paint or code-driven) is on the table for trees + ground
   cover but the existing `GroundCoverScatter` still drives ground
   cover for now (terrain-agnostic). See the
   [Terrain3D walkthrough](../walkthroughs/terrain3d.md).
4. **GPUParticles3D for grass specifically.** The
   [foliage perf research memory](../../../../../../home/jon/.claude/projects/-home-jon-Development-projects-noosphere/memory/project_tree_perf_plan.md)
   found particles are not actually faster than MultiMesh per-frame,
   but they save scene-save bytes by regenerating positions near the
   camera each frame instead of persisting transforms. Useful for
   grass-density situations.
5. **Stay on `MultiMeshInstance3D` + lower density + compromise on
   variety.** Accept that PolyHaven trees can't be performant without
   impostors, run them at gameplay-readable density (~10k trees) only
   in immediate gameplay zones, leave the rest of the map bare.

---

## Image references

Iteration screenshots showing the failure modes lived in the
`/home/jon/.claude/image-cache/` session cache during the work. Not
preserved in repo. Failure summary:

- *PolyHaven diff_alpha cards*: chaotic UV-island fans, no recognizable
  plant shape.
- *Megascans atlas cell-pick*: hard cell-edge frond clipping.
- *Mesh-based ground cover, sparse Grassland*: ~3 visible plants per
  camera frame in non-Forest area.
- *Tree mesh scatter, "skeletal pines"*: alpha-mode bug (since fixed)
  + perf collapse from sheer poly count.
- *Tree mesh scatter, post-fix*: 9 fps with full Forest visible;
  recovered with VR + LOD but only by reducing density to "obviously
  sparse" levels.
