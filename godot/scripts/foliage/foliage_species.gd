@tool
class_name FoliageSpecies
extends Resource

## A single ground-cover species that the scatter system can place.
##
## Authoring: pick a `.gltf` from `res://assets/models/plants_1k/`,
## drop it into `mesh_scene` (PackedScene). The scatter system extracts
## the first MeshInstance3D's mesh + materials at bake time. Scale and
## rotation are applied per-instance; pose noise breaks up tiling.

## Path to the gltf file (e.g. `res://assets/models/plants_1k/grass_medium_01_1k.gltf/grass_medium_01_1k.gltf`).
## The scatterer `load()`s this once per species at first use and
## extracts the first MeshInstance3D + materials from the scene.
##
## **Why a path string instead of `PackedScene`:** Godot 4.6.2's
## inspector crashes when you swap a `PackedScene` Resource on a
## `.tres` (`Object was freed while a signal is being emitted` →
## `EditorInspector::_changed_callback` invalid → segfault). A path
## string never holds a Resource handle in the inspector — the
## file-picker writes a string and that's it. Fully editable, no
## crash.
@export_file("*.gltf") var mesh_scene_path: String = ""

## Optional override: assign a Mesh directly (skips the PackedScene
## extraction). Lets you point at a stripped/baked Mesh resource if one
## is prepared offline. Same path-string treatment as `mesh_scene_path`.
@export_file("*.tres", "*.res", "*.mesh") var mesh_override_path: String = ""

## Comma-separated list of substrings; any MeshInstance3D in the gltf
## whose node name contains one of these is skipped during the variant
## extraction. Default filters:
##
## - `_LOD1`, `_LOD2`, `_LOD3` — lower-detail variants bundled with
##   Fab/Quixel "low" tier gltfs (8 base variants × 4 LODs — we only
##   want LOD0 while the per-LOD MMI pipeline is still pending). LOD3
##   is the most damaging one to leak through: Fab packs it as a
##   ~14-vertex flat leaf-shape imposter whose UVs sample only the
##   leaf region of the atlas. When the per-tile variant pool rolls a
##   LOD3 entry the bake renders a leaf-silhouette card with no bark
##   geometry — looks like "the plant has leaves but no branches".
## - `Billboard` — single flat-quad impostor mesh that ships with most
##   Fab plants (e.g. `MI_<id>_Billboard`) for use beyond the
##   close-up render distance. The shader / scatter doesn't currently
##   swap to billboards at distance, so filter them entirely.
##
## Harmless on PolyHaven plant_1k assets which don't have LOD1/2/3
## or Billboard nodes.
@export var mesh_name_exclude: String = "_LOD1,_LOD2,_LOD3,Billboard"

## Drop variants whose LOD0 mesh has fewer than this many verts at load
## time. Mirrors `tree_species.gd::min_surface_verts` — Fab plant packs
## sometimes ship LOD0-tier "decoration" variants (small leaf-cluster
## fragments meant to be scattered AROUND a real plant, not used as
## the plant itself). They have full LOD0 names, no `_LOD3` suffix,
## but only ~700-1750 verts vs the bushy variants' 10k-30k. The scatter
## currently treats every variant as interchangeable, so rolling one
## of these decoration variants gives a tiny floating leaf-cluster
## with no visible woody structure — looks like "bush with no branches".
##
## **Calibration:**
## - 0 (default): off — keeps every variant, the legacy behavior.
## - 2000: drops Fab raspberry's VarA/B/C decoration meshes while
##   keeping VarD-H real bushes (16k-33k verts each).
## - Don't set above ~2000 — black_locust's VarE/VarF are real
##   1800-vert bushes that you DO want to keep.
##
## Set to 0 for grass / moss / ground-cover species where every
## variant is genuinely small (grass_pack_small_*, moss_01, etc.)
## — those packs have 12-60 vert variants by design.
@export_range(0, 8192, 1) var min_surface_verts: int = 0

## Relative likelihood within a biome's species list. The biome's full
## weight list is normalized at bake time; a species at weight 2.0
## appears twice as often as a sibling at weight 1.0.
@export_range(0.0, 10.0, 0.01) var weight: float = 1.0

## Per-instance scale jitter range. 1.0 = mesh's authored size.
@export_range(0.05, 4.0, 0.01) var scale_min: float = 0.85
@export_range(0.05, 4.0, 0.01) var scale_max: float = 1.15

## If true, rotate around Y by a per-instance random angle.
@export var random_yaw: bool = true

## Optional uniform scale multiplier — useful when a species' authored
## size is too small or too large relative to others in the same biome.
@export_range(0.05, 8.0, 0.01) var size_multiplier: float = 1.0

## Premultiplied-background discard threshold for the ground cover
## shader. PolyHaven's plant_1k JPGs have no alpha channel — the
## "no leaf" atlas regions are baked to near-black, and the shader
## discards pixels with luminance below this value. Per-species
## because some plants ship as solid-coverage textures (fern, moss)
## and need ~0; others ship as atlas with dark backgrounds and need
## ~0.10–0.15 to cut the background cleanly.
##
## Defaults to 0.05 — cuts true-black pixels (almost every plant_1k
## diff JPG has min luminance 0.0 in the background regions, so this
## catches them with 0.05 of compression-noise slack). Lower toward
## 0.0 for solid-coverage textures (fern_02). Raise toward 0.15+ if
## a particular atlas has a grey background instead of black. Set
## to 0.0 to disable luminance cutoff entirely (relies on the
## texture's real alpha channel, if any).
@export_range(0.0, 0.5, 0.005) var alpha_luminance_cutoff: float = 0.05

## Static albedo modulation — the shader does `ALBEDO *= modulation`
## per fragment. Default `Color(1, 1, 1)` is a no-op. Bump channels
## above 1.0 to brighten / saturate, drop below 1.0 to mute.
##
## Defaults are derived per species by `scripts/derive_foliage_modulation.py`,
## which samples the terrain textures the species typically sits on
## and computes a luminance-normalized hue nudge (preserves brightness,
## shifts colour toward the biome's palette so plants look like they
## belong on the ground beneath them). Re-run the script to refresh
## defaults after biome / texture changes; values can be hand-tuned
## per species too.
@export var albedo_modulation: Color = Color(1.0, 1.0, 1.0, 1.0)

@export_group("Leaf color grading")
## HSV-based color grading applied ONLY to green-dominant fragments
## (leaves), leaving the dirt-flecks / bare-soil bleed in foliage
## atlases untouched. Tunes leaf appearance per species without the
## `albedo_modulation` Color stomping all RGB channels (which dims
## red/blue too — soil flecks go muddy).
##
## See `tree_species.gd` for the same knobs with full per-knob
## documentation; same behavior, same shader function.
##
## - `leaf_hue_shift`: hue rotation. Useful range ~±0.05 (±18°).
##   Negative → blue-green, positive → yellow-green.
## - `leaf_saturation_mul`: 1 = no change, <1 muted, >1 vivid.
## - `leaf_value_mul`: 1 = no change, <1 darker, >1 brighter.
## - `leaf_threshold`: how green a fragment must be (G − max(R, B))
##   before grading kicks in. 0.05 catches subtle greens.
@export_range(-0.5, 0.5, 0.005) var leaf_hue_shift: float = 0.0
@export_range(0.0, 2.0, 0.05) var leaf_saturation_mul: float = 1.0
@export_range(0.0, 2.0, 0.05) var leaf_value_mul: float = 1.0
@export_range(0.0, 0.5, 0.01) var leaf_threshold: float = 0.05

## Per-tier scatter radius (set on `FoliageGlobals.tier_radius_*`).
## SMALL species only spawn within `tier_radius_small_m` of the player,
## MEDIUM within `tier_radius_medium_m`, LARGE within
## `tier_radius_large_m`. Lets the scatter avoid spawning grass at 80m
## while still drawing bushes that far. Default SMALL — covers
## ground-cover plants (moss, ferns, weeds, flowers, small grass).
## Set to MEDIUM for shrubs/bushes, LARGE for saplings/dead trunks/
## anything with significant vertical silhouette.
enum SizeTier { SMALL = 0, MEDIUM = 1, LARGE = 2 }
@export var size_tier: SizeTier = SizeTier.SMALL
