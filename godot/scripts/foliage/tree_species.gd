@tool
class_name TreeSpecies
extends Resource

## A single tree species the TreeScatter can place on the terrain.
##
## Mirrors `FoliageSpecies` for ground cover, with tree-specific
## additions: per-species wind tuning, trunk collision dimensions,
## and a max-distance cull beyond which the tree is GPU-collapsed.

## Path to the gltf scene root. The scatter instances the WHOLE
## packed scene (preserving the importer's parent transforms — Z-up
## → Y-up rotation, root scale, etc.) and then walks for the chosen
## variant's LOD0 mesh under it. Same gltf can hold many variants;
## select via `variant_prefix`.
@export_file("*.gltf", "*.glb") var pack_scene_path: String = ""

## Naming prefix that selects ONE variant out of a multi-tree pack.
## E.g. the Fab "5 Birch Trees Lowpoly LODs" pack ships variants
## "Birch", "Birch_2", "Birch_3", "Birch_4", "Birch_5"; setting
## `variant_prefix = "Birch_3"` picks the third one.
##
## The scatter walks all MeshInstance3D children, keeps those whose
## name starts with `<variant_prefix>_` AND doesn't contain `_LOD\d+_`
## (i.e. the LOD0 surfaces), and uses each as a render mesh.
@export var variant_prefix: String = ""

## Per-instance scale jitter. 1.0 = mesh's authored size.
@export_range(0.05, 4.0, 0.01) var scale_min: float = 0.85
@export_range(0.05, 4.0, 0.01) var scale_max: float = 1.15

## Random Y-axis rotation per instance. Mature trees should usually
## have this on for natural variety; saplings too.
@export var random_yaw: bool = true

## Optional uniform scale multiplier applied AFTER the variant basis.
## Use to upscale/downscale a whole species cleanly.
@export_range(0.05, 8.0, 0.01) var size_multiplier: float = 1.0

## Static albedo modulation passed to the tree shader. Default
## `Color(1, 1, 1)` is no-op. Set per-species to push toward a
## biome's palette (rare for trees — they're usually a strong color
## anchor by themselves).
##
## **Use the `leaf_*` knobs below for green-only color grading**
## instead of stomping all RGB channels via this Color. Tinting
## a tree's leaves toward yellow-green via `albedo_modulation =
## Color(1.0, 1.1, 0.9)` also dims red and bumps green on the
## brown bark — bark turns muddy green-brown. The HSV-based
## leaf grading isolates the change to genuinely green pixels.
@export var albedo_modulation: Color = Color(1.0, 1.0, 1.0, 1.0)

@export_group("Leaf color grading")
## Hue shift applied ONLY to green-dominant fragments (leaves /
## needles / atlas surfaces). Brown bark / branches pass through
## unchanged. Range −0.5..0.5 covers a full color-wheel revolution;
## useful values are tiny (~±0.05 = ±18°). Negative → blue-green
## (cooler, deeper conifer), positive → yellow-green (drier, sun-
## bleached, autumn-leaning).
@export_range(-0.5, 0.5, 0.005) var leaf_hue_shift: float = 0.0
## Saturation multiplier for green-dominant fragments. 1 = no
## change, <1 desaturated (drier / shaded look), >1 vivid.
@export_range(0.0, 2.0, 0.05) var leaf_saturation_mul: float = 1.0
## Brightness (HSV value) multiplier for green-dominant fragments.
## 1 = no change, <1 darker (dense canopy interior), >1 brighter
## (sunlit upper canopy).
@export_range(0.0, 2.0, 0.05) var leaf_value_mul: float = 1.0
## How green a fragment must be (G − max(R, B)) before the leaf
## grading applies. 0.05 catches subtle greens; 0.3 only fully
## green leaves. Tune up if bark or other elements are getting
## inappropriately graded.
@export_range(0.0, 0.5, 0.01) var leaf_threshold: float = 0.05

@export_group("Foliage lighting")
## Blend per-vertex normals toward world-up. 0 = mesh's authored
## normal (flat leaf-cards each light independently → "weird
## reflections" as the sun catches each card differently).
## 1 = pure +Y. ~0.4-0.6 makes the canopy light as a unified volume
## (SpeedTree / Crytek standard "capsule normal" trick). Doug Fir
## with denser canopies tolerates higher values; sparse pine
## canopies want lower values so individual frond shape still reads.
@export_range(0.0, 1.0, 0.01) var canopy_normal_up_blend: float = 0.0
## Soft NdotL fall-off intensity for back-lit foliage. 0 = no
## back-light (back-facing leaves render fully dark — current
## behavior). 1 = full back-light wrap (back-facing leaves get the
## same illumination as the front). ~0.3-0.5 simulates needle
## sub-surface scattering — back-lit canopy glows softly instead of
## going pitch black, which dramatically changes how a tree reads
## against bright sky / sunset backlight.
@export_range(0.0, 1.0, 0.01) var backlight_strength: float = 0.0
## Tint applied to the back-light contribution. Default leans
## warm-yellow to suggest sunlight transmitted through chlorophyll.
## Cooler / desaturated values for dry-season needles.
@export var backlight_color: Color = Color(0.85, 0.95, 0.55, 1.0)
## Strength of the texture-supplied normal map. 1 = use it as
## authored. 0 = flat (use vertex normal only). Lower for canopy
## materials whose normal map was authored for a flat leaf-card —
## sampling those normals on geometry that's already a leaf card
## creates erratic per-pixel highlights as the card faces shift.
## Trunk / bark surfaces should keep this at 1.0.
@export_range(0.0, 1.0, 0.01) var normal_map_strength: float = 1.0

## Canopy tint baked into the per-cell coverage texture by
## `TreeCoverageBaker`. Drives:
## - the terrain shader's distant-tree tint (terrain ALBEDO blends
##   toward this past `tree_coverage_distance_start`)
## - the canopy card cross-billboard color past
##   `card_min_distance_m`
##
## Per-cell, the baker picks ONE species via density-weighted RNG
## and uses that species's `canopy_tint` for the cell. So adjacent
## cells naturally vary — a Doug-Fir-dominant cell reads dark
## conifer green, a pine-dominant cell reads lighter yellow-green,
## a birch-dominant cell reads pale leafy green. Without per-species
## tints the whole biome reads as one flat olive color from
## distance, which makes mountains look "army camo" instead of
## "forested".
##
## Tune toward the species's actual mature-canopy color as seen
## from far away (sun-lit upper canopy, not shaded interior).
## Defaults to a generic dark conifer green so unset species don't
## visually disappear in the bake.
@export var canopy_tint: Color = Color(0.13, 0.20, 0.13)

## Per-species wind amplitude scale (passed to tree shader).
## Mature trees ~ 0.4, mid trees ~ 0.7, saplings ~ 1.0.
@export_range(0.0, 5.0, 0.05) var wind_amplitude_scale: float = 0.5

## Per-species trunk anchor — vertex Y below this gets zero wind
## bend. Use to stiffen the lower trunk while letting the canopy
## flex. Roughly the height of clear trunk before the lowest
## branches start.
@export_range(0.0, 5.0, 0.1) var trunk_anchor_height: float = 0.5

## Trunk collision shape — a vertical cylinder anchored at the
## tree's base (the spawn position). Radius covers the trunk;
## height covers the trunk + lower-canopy region the player would
## bump into. Set both to 0 to skip collision (decorative trees,
## visual-only species).
@export_range(0.0, 2.0, 0.05) var trunk_collision_radius: float = 0.3
@export_range(0.0, 30.0, 0.1) var trunk_collision_height: float = 4.0

## Distance band where this species is visible. Wired to the
## per-tile `MultiMeshInstance3D.visibility_range_begin / _end` with a
## dithered fade. Use to layer "high-detail close" + "low-poly far"
## species onto the same biome — close species sets `max_render…` to
## the swap point, far species sets `min_render…` to the same value.
##
## `min_render_distance_m = 0.0` means visible from 0 (default —
## close-tier species). `max_render_distance_m = 0.0` means no upper
## cap (far-tier species, or species whose mesh is so cheap there's
## no point culling).
@export_range(0.0, 1000.0, 10.0) var min_render_distance_m: float = 0.0
@export_range(0.0, 5000.0, 10.0) var max_render_distance_m: float = 200.0

## Multiplier on Godot's mesh LOD threshold (`lod_bias` on the per-
## tile `MultiMeshInstance3D`). Higher = LOD picks lower levels of
## detail at closer distances → more aggressive simplification.
##
## - 1.0 = engine default. Heavy meshes hold LOD0 for too long.
## - 2.0–4.0 = good for tall foreground trees with auto-generated
##   LODs. The canopy covers a lot of screen even at 50 m, so the
##   default threshold rarely demotes them.
## - 8.0+ = aggressive; useful for the far-tier species in a layered
##   setup, or when the near-camera vert budget is tight.
##
## Only meaningful if the species's mesh has LODs (Godot import →
## Meshes → "Generate LODs" enabled, OR the source .glb ships with
## an internal LOD chain).
@export_range(0.1, 16.0, 0.1) var lod_bias: float = 1.0

@export_group("Per-species LOD overrides")
## Force-skip LOD1 for THIS species regardless of the global
## `TreeScatter.skip_lod1` flag. Use when a species's LOD1 mesh has
## quality issues (missing branches, broken UVs, etc.) but its
## LOD0/LOD2/LOD3 are fine. Per-species flags OR with global flags —
## you can never re-enable a globally-skipped LOD via the species,
## only force ADDITIONAL skips.
@export var force_skip_lod1: bool = false
## Force-skip LOD2 for THIS species regardless of the global
## `TreeScatter.skip_lod2` flag. Same semantics as `force_skip_lod1`.
## Common need: a species whose LOD2 strips too much canopy detail
## (e.g. doug fir LOD2 loses branches) — set this true and the
## scatter falls through to LOD3 / proxy at the LOD1→LOD2 boundary.
@export var force_skip_lod2: bool = false

## Drop surfaces with fewer than this many verts at load time —
## targets the LOD3 imposter quad some Fab/Megascans trees pack as
## an extra surface in the same mesh. Set to 0 to disable for
## genuinely lowpoly species (lowpoly Pine, distant silhouette
## meshes) where every surface is small.
##
## Calibration: real Fab Doug Fir bark/needle surfaces are
## thousands of verts; their LOD3 billboard is 4–24. Lowpoly pine
## meshes are 16–24 verts total. So use 64 for high-poly species,
## 0 for lowpoly.
@export_range(0, 1024, 1) var min_surface_verts: int = 64

@export_group("Proxy mesh (distant LOD)")
## Lowpoly mesh used for placements past `proxy_swap_distance_m`.
## The same per-instance transforms drive both close + proxy renders,
## so a Doug Fir at world (X, Y, Z) appears at exactly (X, Y, Z)
## whether you're 50 m away (high-detail glb) or 1500 m away
## (lowpoly silhouette). Walking toward the forest swaps mesh quality
## without shifting tree positions.
##
## Leave empty to skip the proxy tier (species only renders close,
## fades out at `max_render_distance_m`).
@export_file("*.gltf", "*.glb") var proxy_pack_scene_path: String = ""

## Variant prefix for the proxy pack — same semantics as
## `variant_prefix` but applied to `proxy_pack_scene_path`. Empty =
## use every kept MeshInstance3D in the pack.
@export var proxy_variant_prefix: String = ""

## Camera-to-tile distance at which the high-detail mesh fades out
## and the proxy fades in. With `VISIBILITY_RANGE_FADE_SELF` on both
## MMIs, the swap is dithered over a short margin around this value
## so it reads as "tree gradually loses detail" rather than "tree
## pops to a card".
##
## 0 = no proxy. Set on species that ship a proxy mesh.
@export_range(0.0, 2000.0, 10.0) var proxy_swap_distance_m: float = 0.0

## Uniform scale on the proxy mesh per instance. Lowpoly proxy
## meshes are usually authored at canopy-mesh scale (5–10 m) while
## the high-detail mesh is full-tree scale (30–50 m), so a
## multiplier ~3–6× lets the proxy match the real tree silhouette
## the player will eventually walk up to.
@export_range(0.1, 10.0, 0.05) var proxy_scale_multiplier: float = 1.0

## Per-surface vert threshold for the proxy mesh's billboard filter.
## Default 0 (no filter) since proxies are intentionally lowpoly.
@export_range(0, 1024, 1) var proxy_min_surface_verts: int = 0
