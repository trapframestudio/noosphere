# Distant trees (cluster impostors)

Past the close-tier `TreeScatter`'s active radius (~800 m on
cascade_locks), individual tree meshes would be sub-pixel - paying
hundreds of thousands of MMI surfaces for content the player can't
actually resolve. The distant-trees system replaces the close-tier
out to several kilometers with **pre-baked silhouette billboards**
spawned in a single `MultiMeshInstance3D` per species variant.

This is the same architecture used by Witcher 3, Horizon Zero Dawn,
and Death Stranding for their distant forest tier - one quad per
tree, real photo-baked silhouette texture, sub-millisecond GPU cost
out to the horizon.

## Pipeline

Two offline bakes + one runtime cost:

1. **Impostor textures** (one-time, headless Blender) - generates
   per-species silhouette PNGs.
2. **Coverage map** (per-map, in-editor) - bakes a per-texel forest
   density gradient mirroring the close-tier's biome lookup.
3. **Placement bake** (per-map, in-editor) - walks the coverage map,
   spawns instances into per-variant MultiMeshes.

### Bake step 1 - impostor PNGs (in-Godot pipeline)

`godot/tools/imposter_baker.gd` is a `@tool` Node3D that drives the
bake from inside the editor. Drop the script onto a Node3D in any
scene, configure `bake_glb_paths` + `bake_output_names`, and click
**Bake all impostors**. Each species emits TWO PNGs to
`godot/assets/textures/foliage/`:

- `<name>_albedo.png` — unlit base color (leaf-graded if the bake
  is given a `TreeSpecies` path with leaf grading set).
- `<name>_normal.png` — view-space surface normals encoded as
  `n × 0.5 + 0.5`, sampled at runtime so the impostor responds to
  live sun direction.

**Lit-billboard pipeline**: the `_albedo.png` is **unlit** — applies
per-species leaf grading + species `albedo_modulation` (so each
variant's PNG matches its authored close-tier color treatment) but
NO lighting. The runtime `tree_cluster.gdshader` samples both PNGs,
rotates baked view-space normals into world space via the billboard's
per-instance basis, and runs the same `light()` model as
`tree_dynamic.gdshader` (wrap diffuse + warm transmission + sky-bias
EMISSION) against the live world sun. Distant trees track dynamic
sun direction, time-of-day, and weather lighting.

The baker auto-resolves each variant's matching `TreeSpecies` from
the output name (`pine_p3d_mature_lush_impostor` →
`pine_p3d_mature_lush.tres`), with `_1`/`_2`/`_3` numbered fallback
for assets like Doug Fir whose species files use those suffixes.
The species' `leaf_value_mul` × `leaf_saturation_mul` ×
`albedo_modulation` get pushed to the bake shader so each variant's
PNG carries its close-tier color baseline.

> **Replaced**: `scripts/bake_conifer_impostor.py` (Blender + Cycles
> with a Principled BSDF approximation of close-tier lighting).
> Cycles couldn't reproduce Godot's tonemap or shader math; the
> in-Godot bake uses Godot's own renderer, which is the only way
> to capture identical color. The script stays in tree as
> a reference for the species list + ImageMagick post-processing
> math but no longer runs.

The bake is one-time per species mesh / per close-tier leaf-grading
change — re-bake only when those change, not per-frame or per-
weather state.

> **Per-developer artifact**: the baked
> `<output>_albedo.png` + `<output>_normal.png` files in
> `godot/assets/textures/foliage/` are gitignored (same convention
> as `godot/assets/foliage_bake/` placement caches). After pulling
> a fresh checkout, run **Bake all impostors** once locally to
> generate them; the scene's `TreeClusterScatter.impostor_texture_paths`
> already references the canonical names. If we later want a map's
> distant trees to look identical across all checkouts, opt the
> PNGs back in via `.gitignore` negation as we do for `foliage_bake`.

### Bake step 2 - coverage map

`TreeCoverageBaker` (sibling of `TreeScatter`) walks the canonical
map in 4 m texels and writes RGBA8 to `tree_coverage.res`. The
**critical contract**: it must mirror the per-tree gating logic that
the close-tier uses, NOT just sample biome at the texel center.

Each texel runs N (default 12) jittered samples within its 4 m × 4 m
area. Each sample does a real biome lookup + procedural-exclusion
test + biome-density Bernoulli, exactly as `TreeScatter._bake_tile`
does per-candidate. Density alpha = fraction of samples accepted.
The dominant accepted biome's `_pick_species_tint` provides the RGB.

Why this matters: the previous implementation point-sampled biome at
the texel CENTER then Bernoulli-noised the result. A single non-
forest pixel at the center (a forest road, a splat-blend artifact)
zeroed the whole 16 m² texel - which the cluster scatter then
magnified by point-sampling one texel per ~20 m grid cell. Visible
as bare patches inside otherwise-forested mountains. Position-
jittered sampling makes alpha smoothly reflect actual forest density
across the texel.

Triggered via the **Bake tree coverage now** inspector button on
`TreeCoverageBaker`.

### Bake step 3 - placements

`TreeClusterScatter` walks the baked coverage map at `grid_m`
spacing (default 18-26 m). Each cell with `coverage_factor > 0`
spawns `trees_per_cell × coverage_factor` placements, jittered
across `grid_m × jitter_radius_mul` so cells overlap → no visible
grid pattern.

Each placement spawns N **cross-billboard quads** at evenly-spaced
fixed Y rotations (`cross_quads_per_tree`, default 2). The quads do
**not** rotate to face camera - each has a permanent orientation.
From any viewing angle, every tree shows real silhouette area
because at least one perpendicular quad is far from edge-on.

Why fixed-orientation cross-billboards beat y-axis billboards: a
camera-facing y-billboard makes every card at similar XZ rotate the
same way, so dozens of cards stack edge-on into vertical "wall of
clones" stripes. Cross-billboards spread silhouette area across
screen and read as forest depth instead of stripes.

Per-instance variation:
- **Variant pick** - world-XZ hash chooses one of the impostor PNGs.
  Stable across re-bakes so the species mix doesn't reroll.
- **Scale jitter** (`scale_jitter`, default 0.55) - independent
  width / height variation, ±50% range.
- **Per-channel hue jitter** - R, G, B independently jittered ±15%
  on top of brightness jitter. Reads as forest variance from
  distance, not painted-on uniform tint.

One MMI per impostor variant → typical map ships 3 draw calls for
the entire distant forest.

## Shader (`tree_cluster.gdshader`) — lit billboard

The shader runs the standard PBR pipeline with a custom `light()`
mirroring `tree_dynamic.gdshader`. Distant trees track dynamic sun
direction and weather lighting via per-frame `light()` evaluation
against the baked normal map.

Vertex stage:
- **Per-instance distance cull** with fade dither — collapses any
  instance outside `[min_distance_m, max_distance_m]` to vertex 0
  (no fragment work). Per-instance world-XZ hash provides the dither
  seed so fade-in/out is per-tree, not per-pixel.
- **Quad rebuild** from `MODEL_MATRIX[0]` rotation × per-instance
  width/height — bypasses the source mesh's vertex positions
  entirely.
- **Cached billboard basis** — the vertex writes `v_billboard_x`
  and `v_billboard_z` varyings so fragment can rotate baked
  view-space normals into world space without recomputing.
- **Distance-scaled ground embed** — sinks the card's bottom by
  `ground_embed_fraction + dist_norm × embed_distance_extra` of card
  height. Compensates Terrain3D's CLOD geomorphing at distance.
  Effective embed clamps to 0.6 max so trees never disappear.

Fragment stage:
- **Mipmap alpha cap** — caps the effective LOD for alpha sampling
  at `alpha_mip_cap` (default 2.0) and boosts residual alpha by
  `alpha_far_boost × (auto_mip - cap)` to compensate. Without this,
  distant trees vanish at ~600 m as the alpha border averages with
  transparent during mipmap downsampling.
- **Scatter-level HSV grade** (`leaf_hue_shift` /
  `leaf_saturation_mul` / `leaf_value_mul`) composed on top of the
  bake's per-species color. Defaults are identity; tune to drift the
  whole distant tier (autumn yellows, etc.). With `leaf_threshold =
  0` the grade applies to all canopy pixels.
- **Per-instance tint modulator** — small ±30 % per-tree color
  jitter from `COLOR.rgb` of the MMI instance, breaks up uniform
  cloned-look across adjacent trees.
- **Distant brightness scale** — final `× distant_brightness`
  multiply (mirrors `TreeScatter.close_tier_brightness`).
- **Normal basis swap** — samples `normal_tex`, decodes the baked
  view-space normal, rotates it into world space via the billboard's
  cached basis, then re-projects into view space for the standard
  light pipeline. When `has_normal_map = false` falls back to
  unshaded EMISSION display (legacy single-PNG impostors).
- **Sky-bias emission floor** — `EMISSION = ALBEDO ×
  emission_skylight_color × sky_bias` bypasses shadow attenuation,
  identical math to `tree_dynamic.gdshader` so impostors in cascade
  shadow don't crater to black while close-tier still has ambient
  lift.

`light()` mirrors `tree_dynamic.gdshader::light()`: wrap diffuse
(`wrap = 0.6`), warm transmission backlight on NdotL<0
(`backlight_color × backlight_strength`). Specular intentionally
not handled — `ROUGHNESS = 0.95` makes it negligible.

> **Iteration history**: an earlier "Stage A pre-lit" approach
> baked the close-tier sun + skylight contribution into the PNG and
> made the runtime fully unshaded — gave perfect color match at
> noon but lost dynamic lighting. Reverted because dynamic lighting
> matters more than perfect-noon match. See CLAUDE.md "Critical
> Rules" for the long-form rationale.

## Knobs

| Knob | Where | Cost | What it does |
|---|---|---|---|
| `impostor_texture_paths` | `TreeClusterScatter` | Re-bake | Array of impostor PNGs; placements distribute via stable hash |
| `grid_m` | `TreeClusterScatter` | Re-bake | World-XZ grid spacing for placement cells |
| `coverage_density_strength` | `TreeClusterScatter` | Re-bake | How aggressively partial-coverage texels spawn trees |
| `trees_per_cell` | `TreeClusterScatter` | Re-bake | Max instances per cell at full coverage |
| `jitter_radius_mul` | `TreeClusterScatter` | Re-bake | Per-cell jitter as fraction of `grid_m`; >1 overlaps neighbors |
| `cross_quads_per_tree` | `TreeClusterScatter` | Re-bake | 2 = perpendicular cross, 3 = hex-star (more depth, 3× instances) |
| `scale_jitter` | `TreeClusterScatter` | Re-bake | Per-instance width/height jitter range |
| `card_width_m` / `card_height_m` | `TreeClusterScatter` | **Live** | Card dimensions in meters |
| `min_distance_m` / `max_distance_m` | `TreeClusterScatter` | **Live** | Visibility band - past max collapses in vertex stage |
| `fade_margin_m` | `TreeClusterScatter` | **Live** | Per-instance dither fade-in width at the close edge |
| `albedo_modulation` (Color) | `TreeClusterScatter` | **Live** | Per-channel tint applied on top of baked color; default identity |
| `ground_embed_fraction` | `TreeClusterScatter` | **Live** | Bottom N % of card sinks below placement origin; counters Terrain3D LOD shifts at close edge of band |
| `embed_distance_extra` | `TreeClusterScatter` | **Live** | Extra embed added linearly toward `max_distance_m`; compensates for stronger LOD smoothing at far distances |
| `leaf_hue_shift` / `_saturation_mul` / `_value_mul` | `TreeClusterScatter` | **Live** | Scatter-level HSV grading on top of baked color. Defaults identity. With `leaf_threshold = 0` (default) applies to all canopy pixels |
| `distant_brightness` | `TreeClusterScatter` | **Live** | Final brightness multiply; mirrors `TreeScatter.close_tier_brightness` |
| `backlight_strength` | `TreeClusterScatter` | **Live** | Warm transmission backlight on NdotL<0; ~0.25 matches close-tier |
| `backlight_color` (Color) | `TreeClusterScatter` | **Live** | Backlight tint, warm chlorophyll yellow by default |
| `emission_skylight_color` (Color) | `TreeClusterScatter` | **Live** | Sky-bias emission floor; matches `tree_dynamic.gdshader` skylight bounce |
| `alpha_scissor_threshold` | shader uniform | **Live** | Lower = chunkier silhouettes survive longer |
| `alpha_mip_cap` | shader uniform | **Live** | Cap effective alpha mip; lower = sharper distant alpha |
| `alpha_far_boost` | shader uniform | **Live** | Extra alpha per LOD over the cap |
| `meters_per_texel` | `TreeCoverageBaker` | Re-bake coverage | Coverage map resolution; 4 m default |
| `samples_per_texel` | `TreeCoverageBaker` | Re-bake coverage | Position-jittered samples per texel; more = smoother alpha |

## Persistence

Per-variant placement MultiMeshes save to
`<terrain3d_dir>/distant_trees_mm_<variant>.res` and load
automatically in `_ready()`. The coverage map saves to
`<terrain3d_dir>/tree_coverage.res`. All committed via LFS so
released worlds stay consistent across updates.

The cluster scatter's **Clear** + **Bake** inspector buttons swap
the on-disk MultiMesh + spawned MMIs atomically - no scene reload
needed. Coverage re-bake is independent and only needs to run when
biome configs / road layout / exclusion zones change.

## Cross-tier handoff

The close-tier `TreeScatter`'s outer LOD reaches 250 m (its
`lod_band_ends_m` last entry). The distant tier's `min_distance_m`
sits at 600 m → 350 m of pure close-tier-only space, then a 50 m
fade-margin handoff zone (`fade_margin_m = 80`), then distant tier
to `max_distance_m` (4500 m on cascade_locks).

Both tiers run the SAME `light()` model (wrap diffuse + warm
transmission + sky-bias EMISSION) so dynamic sun direction
propagates uniformly across the LOD boundary. Color matching is
achieved by:

1. The bake captures each species' authored close-tier color
   treatment (leaf grading + `albedo_modulation`) using
   `imposter_baker.gd`'s auto-resolve from `<name>_impostor →
   <name>.tres`. Doug Fir's numbered variants (`_1` / `_2` / `_3`)
   are tried as fallbacks. Bake output is UNLIT albedo so per-frame
   lighting can act on it.
2. `TreeScatter.close_tier_brightness` (default 0.75) tunes the
   close tier down to match the impostors' lit baseline.
3. `TreeClusterScatter.distant_brightness` + scatter-level HSV
   grading nudges distant trees to match the close tier.
4. Both scatters expose composable color-grade extras
   (`extra_leaf_hue_shift` etc. on `TreeScatter`; `leaf_hue_shift`
   etc. on `TreeClusterScatter`) so a project-wide green-shift
   (autumn, rain) can be applied to both tiers with the same value.
5. The runtime impostor shader's `backlight_strength` /
   `backlight_color` / `emission_skylight_color` mirror close-tier
   so the lighting math stays bit-similar across the boundary.

The chromatic language also flows through `canopy_tint` on each
`TreeSpecies` (consumed by the coverage baker into per-cell tint)
plus the per-species color baked into the impostor PNG. The
`albedo_modulation` shader uniform on the cluster stays available
but defaults to identity — the LOD-ring color gap that the old
warm-correction default was masking no longer exists once both
tiers share lighting math.
