@tool
class_name RockSpecies
extends Resource

## A single rock species the RockScatter can place on the terrain.
##
## Mirrors `TreeSpecies` for rocks: pick one variant out of `rock_pack.glb`
## (e.g. `rock_jagged`), set per-species size + collision tier, point at
## a downsampled texture set sized to physical rock size. No wind, no
## leaf grading, no proxy/imposter swap (rocks aren't tall enough to
## need card-based far rendering — `max_render_distance_m` cull is
## sufficient).

## Path to the rock pack .glb (default: the procedurally generated
## `res://assets/models/rocks/rock_pack.glb`). The scatter walks
## children matching `<variant_prefix>_LOD<N>` and uses each as a
## per-LOD render mesh — same convention the tree scatter uses.
@export_file("*.glb", "*.gltf") var pack_scene_path: String = "res://assets/models/rocks/rock_pack.glb"

## Variant name in the pack (e.g. `rock_round`, `rock_jagged`,
## `rock_slab`, `rock_pillar`, `rock_oblong`, `rock_cluster`).
## The scatter loads the matching `<variant_prefix>_LOD0/1/2`
## meshes for the LOD chain.
@export var variant_prefix: String = "rock_round"

@export_group("Sizing")
## Per-instance scale jitter (multiplies `size_multiplier`).
## 1.0 = mesh's authored size (the procedural pack authors at
## ~1 m radius — `size_multiplier` does the real sizing work).
@export_range(0.05, 4.0, 0.01) var scale_min: float = 0.85
@export_range(0.05, 4.0, 0.01) var scale_max: float = 1.15

## Uniform scale multiplier applied AFTER the random per-instance
## scale. Drives physical rock size: 0.15 ≈ pebble (10–20 cm),
## 0.4 ≈ ankle/knee (30–50 cm), 0.8 ≈ knee/waist (60 cm – 1 m),
## 1.5+ ≈ standing-cover boulder (1.5–3 m).
@export_range(0.05, 8.0, 0.01) var size_multiplier: float = 1.0

## Random Y-axis rotation per instance. Almost always on — rocks
## look obviously cloned without it.
@export var random_yaw: bool = true

## Random tilt range (degrees) on the X / Z axes. Lets the rock
## settle off-axis so flat slabs aren't all perfectly horizontal.
## 0 = no tilt, 15 = subtle, 45 = chaotic / freshly-fractured.
@export_range(0.0, 90.0, 1.0) var random_tilt_deg: float = 15.0

## Per-instance non-uniform scale jitter on the X and Z axes (Y is
## kept as the size determinant so vertical extent stays predictable).
## 0 = uniform scale (every instance is a uniformly-scaled mesh).
## 0.25 = each instance has X and Z independently scaled by a factor
## in `[1 - 0.25, 1 + 0.25]`. Drives "same mesh, different silhouette":
## some rocks read as squashed/flattened, others as elongated wedges.
##
## Highest-impact knob for breaking up boulder-field clones — neighbors
## of the same species + variant suddenly look like distinct geological
## pieces. 0.20–0.30 typical for boulders; lower for pebbles where the
## squash isn't visible at scale.
@export_range(0.0, 0.6, 0.01) var scale_axis_jitter: float = 0.0

## Probability per-instance of an additional EXTREME tilt on top of
## `random_tilt_deg`. 0 = never; 0.15 = 15 % of rocks get the bonus
## tilt. Captures the "freshly tumbled" / "weirdly perched" rocks that
## punctuate real boulder fields without making EVERY rock look chaotic.
##
## Combined with `extreme_tilt_deg` below — a non-zero chance with
## extreme_tilt_deg=0 is a no-op.
@export_range(0.0, 1.0, 0.01) var extreme_tilt_chance: float = 0.0

## Magnitude of the extreme-tilt event in degrees. Applied AFTER the
## normal `random_tilt_deg` jitter, around the same slope-relative
## axes. 30–60° flips an asymmetric rock onto its side, dramatically
## changing its silhouette compared to default-oriented neighbors.
##
## Only meaningful when `extreme_tilt_chance > 0`.
@export_range(0.0, 90.0, 1.0) var extreme_tilt_deg: float = 0.0

@export_group("Albedo / textures")
## Static albedo modulation (multiplied with the color texture).
## Default white = no-op. Use to nudge a species toward a regional
## palette (e.g. desaturated gray for granite, warm tan for
## sandstone) without re-baking the source texture.
##
## **Live-tunable** — pushed to running materials via the species's
## `changed` signal, so inspector tweaks update immediately without
## a tile rebuild.
@export var albedo_modulation: Color = Color(1.0, 1.0, 1.0, 1.0)

## Roughness floor (multiplied with the roughness map's value).
## Default 0.7 — most rocks read as > 0.5 rough in the wild; the
## AmbientCG maps occasionally dip into low-roughness scratches that
## look fake-shiny on a granite boulder. Lower this for wet rocks
## (~0.4) or smooth river stones; raise for dry desert sandstone
## (~0.9). **Live-tunable** like `albedo_modulation`.
@export_range(0.0, 1.0, 0.01) var roughness_floor: float = 0.7

## Per-instance lightness jitter (±value). 0 = every rock identical
## brightness; 0.15 = each instance is up to 15 % darker or lighter
## than the source texture. Driven by the same world-XZ instance hash
## used for LOD dither, so the variation is stable per-position. The
## jitter shifts ALBEDO multiplicatively after the texture sample and
## `albedo_modulation`, so a per-species tint is preserved.
##
## **Live-tunable** — pushed via the `changed` signal.
@export_range(0.0, 0.5, 0.01) var albedo_value_jitter: float = 0.20

## Per-instance hue jitter in degrees. 0 = no hue shift; 6° gives a
## subtle warm/cool variation across a species without breaking the
## regional palette. Stable per-instance via the world-XZ hash.
##
## Bigger values (~15°) produce visibly mixed-mineral compositions
## ("some sandstone, some basalt"); typical use is 4–10°.
##
## **Live-tunable**.
@export_range(0.0, 60.0, 1.0) var albedo_hue_jitter_deg: float = 12.0

## Texture-set resolution tier. Loads from
## `res://assets/textures/rocks/<texture_set>/<resolution_tier>/`.
## Pick the variant matched to physical size:
##   `1k` for small rocks (Tier 0/1: pebble / ankle/knee)
##   `2k` for medium rocks (Tier 2: knee/waist boulder)
##   `4k` for large rocks (Tier 3: standing-cover boulder)
## The 4k tier is served from the source AmbientCG dir
## `res://assets/textures/terrain/<texture_set>_4K-PNG/`.
@export_enum("1k", "2k", "4k") var resolution_tier: int = 0

## Which AmbientCG rock pack to texture from. Matches the
## directory naming under `res://assets/textures/rocks/<id>/`
## (and `res://assets/textures/terrain/<id>_4K-PNG/` for 4k).
## Default set baked by `scripts/downsample_rock_textures.py`:
## Rock020, Rock028, Rock035, Rock050, Rock060, Rock064.
@export var texture_set: String = "Rock020"

@export_group("Scattering")
## Visibility cull. Rocks small enough to disappear under foliage
## should cull aggressively (50–100 m); standing-cover boulders
## stay visible out to ~800 m via the impostor tier.
@export_range(0.0, 2000.0, 10.0) var min_render_distance_m: float = 0.0
@export_range(0.0, 2000.0, 10.0) var max_render_distance_m: float = 200.0

## Camera-to-tile distance at which the close-tier LOD chain fades
## out and the impostor tier fades in. Set 0 to disable the impostor
## (species only renders close, fades out at `max_render_distance_m`).
##
## The impostor is the same LOD2 mesh rendered with the cheap
## unshaded `rock_imposter.gdshader` and `cast_shadow = OFF` — about
## 5× cheaper per pixel than the close-tier shader plus saves the
## shadow draw call. Use ~120-200 m for ground rocks, ~300+ m for
## standing-cover boulders that need to read clearly from far.
@export_range(0.0, 1500.0, 10.0) var proxy_swap_distance_m: float = 0.0

@export_subgroup("Terrain awareness")
## Required terrain "rockiness" score (0–1) for this species to spawn.
## RockScatter computes the score as the local height delta within
## `terrain_sample_radius_m`, normalized by that radius — high score =
## steep nearby terrain (cliff base, mountain shoulder, talus zone).
##
## Real-world geology placement model:
##   0.0   — anywhere (pebbles, small surface stones — found on every
##           ground type from valley floor to ridge)
##   0.3   — mildly rocky terrain (medium rocks accumulate where the
##           ground undulates)
##   0.5   — near slopes / talus zones (large boulders only appear
##           where cliffs have shed material above them)
##   0.7   — steep ridge zones (only the most "boulder field"-like
##           areas; rare in any biome)
##
## Cliff-embedded species keep `slope_min` for the orthogonal "ON the
## slope" check; talus species use `terrain_min_score` for the "NEAR
## the slope but laying on flatter ground" case.
@export_range(0.0, 1.0, 0.05) var terrain_min_score: float = 0.0

## Density multiplier in rocky terrain. The accept rate scales by
## `1 + terrain_density_boost × terrain_score`, so a boost of 3.0
## means 4× density at maximum rockiness. Big species set this high
## so talus zones genuinely pile up; small species set it low (a
## little extra concentration but mainly uniform).
@export_range(0.0, 8.0, 0.1) var terrain_density_boost: float = 0.0

## Per-instance scale boost in rocky terrain. Rocks in steep terrain
## scale up by `1 + scale_terrain_boost × terrain_score`. 0 = no scale
## variation from terrain; 1 = up to 2× at max rockiness; 2 = up to
## 3×. Pairs with high `terrain_density_boost` to produce real-feeling
## boulder accumulations (more rocks AND bigger).
@export_range(0.0, 3.0, 0.05) var scale_terrain_boost: float = 0.0

@export_subgroup("Natural placement (AAA-style signals)")
## How much to align the rock's local up to the terrain normal at
## placement. 0 = pure world-up (rocks always vertical regardless of
## slope); 1 = fully aligned to local terrain normal (rock tilts to
## match the ground). Real rocks settle along the slope they sit on,
## so a non-zero value (~0.5-0.8) reads dramatically more natural
## than the previous random-tilt-only behavior. Mid-range values
## (0.5-0.7) keep some "settled at an angle" character; 1.0 reads as
## "freshly placed on the slope" which is correct for embedded
## bedrock-style boulders. Random tilt still applies on top.
@export_range(0.0, 1.0, 0.05) var terrain_alignment_factor: float = 0.7

## Density boost from terrain CONCAVITY (mean of 4 neighbors minus
## center, normalized by sample radius). Positive concavity = bowl /
## gully / cliff base — these are where real rocks accumulate by
## gravity. Negative concavity = ridge / peak — rocks shed off these.
## Composes multiplicatively with `terrain_density_boost` (slope) so
## a species with both responds to "steep AND concave" — exactly
## where talus piles form.
##
## 0 = no concavity preference (default — keeps existing species
## behavior intact). ~3-5 for satellite/pebble species (collect in
## low spots). Value of 8 = 9× density at maximum concavity.
@export_range(0.0, 8.0, 0.1) var terrain_curvature_boost: float = 0.0

## Density boost when at the BASE of a steep neighborhood — i.e. local
## terrain is gentle but a wider radius around it has steep features.
## Captures the "talus pile / cliff base" geomorphology: scree
## accumulates on the gentler ground BELOW a cliff, not on the cliff
## face itself. Composes additively with the concavity boost.
##
## 0 = ignore (default). 4-8 for boulder/cluster species that should
## pile against cliffs. Combined with `slope_max` < the cliff slope,
## this gives a clean "this big rock fell from up there and rolled
## to here" placement.
@export_range(0.0, 8.0, 0.1) var terrain_basal_boost: float = 0.0

## Per-instance scale boost when at the base of a steep neighborhood.
## Real talus accumulates BIGGER rocks at the BASE (gravity sorts —
## small debris fans out to apex, large blocks roll all the way down).
## Pairs with `terrain_basal_boost` for density: more rocks AND bigger
## rocks at cliff bases.
@export_range(0.0, 3.0, 0.05) var scale_basal_boost: float = 0.0

@export_subgroup("Anchor / satellite clustering")
## This species places FIRST per tile and emits a proximity attractor
## field that other species can subscribe to. Set on the few "hero"
## rock species (boulders, clusters, cliff chunks) that should anchor
## natural rock formations. Pebbles + small surface stones DO NOT set
## this — they're satellites.
##
## The anchor pre-pass runs before the main candidate loop so anchor
## positions are known when satellite candidates are rolled. Anchors
## still respect all per-species placement constraints (terrain score,
## slope, density curve) — `is_anchor` only affects ORDERING.
@export var is_anchor: bool = false

## Density multiplier applied to this species when within
## `satellite_anchor_radius` of a placed anchor rock. The boost
## linearly falls off from full strength at the anchor's center to
## zero at the radius edge.
##
## 0 = ignore anchors (default). 4-10 for small ground species that
## should "pile against" boulders (gives the AAA "rocks gather around
## a hero rock" look without manual placement). Composes with terrain
## boosts: a satellite that's BOTH in concave terrain AND near an
## anchor gets the multiplied effect.
@export_range(0.0, 16.0, 0.5) var satellite_anchor_boost: float = 0.0

## Radius of an anchor's attractor field, in meters. Only meaningful
## when `is_anchor = true`. Satellites within this radius get
## boosted; outside the radius, no effect. Typical 3-6 m for boulder
## anchors; larger for cliff_chunk style assets that anchor wider
## areas.
@export_range(0.5, 20.0, 0.5) var satellite_anchor_radius: float = 5.0

@export_subgroup("Anchor compound features")
## When this anchor places, roll up to N additional sibling anchors
## within `feature_cluster_radius`. Drives compound boulder features
## (multiple overlapping rocks reading as a single geological feature)
## instead of isolated single boulders. Sibling placements bypass the
## terrain-score gate (the parent anchor already vouched for the
## location) but still respect `slope_max` and exclusion zones.
##
## 0 = no compounding (default). 1–3 typical; bigger values produce
## "rocky outcrop" piles. Only meaningful when `is_anchor = true`.
@export_range(0, 6, 1) var feature_cluster_count_max: int = 0

## Radius (m) within which sibling-anchor placements are rolled.
## Should be smaller than `satellite_anchor_radius` (siblings are AT
## the feature, satellites cluster AROUND it). Typical 1.5–3 m.
@export_range(0.5, 8.0, 0.1) var feature_cluster_radius: float = 2.5

@export_subgroup("Sinking into terrain")
## **Always-on** sink baseline, in scale units. The placement Y is
## reduced by `terrain_sink_baseline × scale` regardless of slope, so
## even rocks on flat ground bury slightly into the surface — reads as
## "this rock has been here a long time" instead of "freshly dropped".
##
## 0 = no baseline sink (rock sits exactly on the heightmap).
## 0.05–0.10 is a good range for most species; bigger values are only
## meaningful for boulders that should embed visibly. Pairs with
## `terrain_sink_factor` (slope-additive) — they stack additively.
##
## The combined sink (baseline + slope) is clamped to half the rock's
## un-rotated vertical extent so we never bury more than 50 % of the
## silhouette no matter the parameters.
@export_range(0.0, 1.0, 0.01) var terrain_sink_baseline: float = 0.06

## Fraction of the rock's vertical extent to sink INTO the terrain on
## steep slopes. 0 = no slope-based sink; bigger species set this
## 0.3–0.6 so massive boulders on a 45° face don't look perched-and-
## ready-to-tumble — they sink down into the bedrock, reading as
## "embedded over geological time".
##
## Actual slope-sink amount = `terrain_sink_factor × slope_factor ×
## scale × size_multiplier`, where `slope_factor` is a smoothstep ramp
## from point slope 0.5 (no sink) to 1.6 (full sink). Stacks additively
## with `terrain_sink_baseline`.
@export_range(0.0, 1.0, 0.05) var terrain_sink_factor: float = 0.0

## Per-instance random burial — uniform `[0, max]` × vertical_extent
## added on top of the baseline + slope sinks. Drives the "natural
## variation" reading: some rocks just-fallen, some half-buried over
## geological time. The roll is deterministic via the per-tile RNG.
##
## 0 = uniform burial across the species (default). 0.3 = up to 30 %
## of the rock's vertical extent extra burial, varying per-instance.
## Set higher (0.4–0.5) on boulder species so a cluster of similar
## rocks reads as different ages-of-settling, not cloned.
##
## Total sink (baseline + slope + random) is hard-clamped at 50 % of
## the vertical extent — never bury more than half the rock.
@export_range(0.0, 0.7, 0.01) var terrain_sink_random_max: float = 0.0

@export_subgroup("Slope targeting")
## Minimum terrain slope this species spawns on. The scatter computes
## slope from finite differences on the heightmap; flat ground ≈ 0,
## steep cliffs ≈ 2-4. Default 0 = spawn anywhere; set ~1.5+ for
## "cliff face" species that should only appear on visibly steep
## terrain. Pairs with `slope_max` to define a band.
##
## Use case: large cliff-chunk boulders dressing the rocky outcrops
## around a map's cliff faces. Set `slope_min = 1.8` and the species
## won't spawn on flat ground at all, only on the steep faces where
## the geological reading is "rocky exposed bedrock".
@export_range(0.0, 4.0, 0.05) var slope_min: float = 0.0
## Maximum terrain slope this species spawns on. The scatter has its
## own global `slope_cutoff` that filters everything above it; this
## per-species cap is normally lower (e.g. 1.8 for ground rocks that
## shouldn't appear on cliffs). Default 4.0 = effectively unlimited.
@export_range(0.0, 4.0, 0.05) var slope_max: float = 4.0

@export_group("Collision tier")
## Hard-coded tier index that drives the scatter's collision
## dispatch. See `RockScatter._spawn_species_collisions`.
##
##   0 — NONE        : no collision body created. Pebbles / gravel.
##   1 — STEPPABLE   : ankle-knee. Player walks through (CONCEALMENT
##                     layer for now per Option A; see memory note
##                     on STEPPABLE_SOLID promotion). Bullets pass
##                     through partially (concealment_visibility).
##   2 — CROUCH_COVER: knee-waist. SOLID layer; full block on
##                     bullets and movement. StaticBody3D + sphere /
##                     capsule shape sized off the rock's bounds.
##   3 — STAND_COVER : waist+ + clusters. SOLID layer; same as
##                     CROUCH_COVER but with a taller / wider shape
##                     scaled to the bigger silhouette.
##
## Pick the tier per-species, NOT per-instance — a "small_rock"
## species is uniformly tier 1, a "boulder" species is uniformly
## tier 3. Fine-grained per-instance variation is unnecessary
## because per-instance scale already varies physical size within
## a species ~30 %.
@export_enum("None", "Steppable (CONCEALMENT)", "Crouch cover (SOLID)", "Standing cover (SOLID)") var collision_tier: int = 0

## Override the collision shape's nominal radius / height in
## meters. Set both to 0 to auto-derive from the species's
## `size_multiplier` (radius ≈ size_multiplier × 0.5,
## height ≈ size_multiplier × 0.8). Override when a specific
## variant's silhouette doesn't match the size multiplier
## (e.g. a `rock_pillar` is taller than wide).
@export_range(0.0, 5.0, 0.05) var collision_radius_override: float = 0.0
@export_range(0.0, 8.0, 0.05) var collision_height_override: float = 0.0

@export_subgroup("Inter-system exclusion")
## Radius (meters) within which TreeScatter will skip placing trees
## around each rock of this species. 0 = no exclusion (the default —
## small rocks don't push trees away). Set on big species
## (`large_boulder`, `large_cluster`, `boulder_field`, `cliff_*`)
## where a tree growing through the rock is visually jarring.
##
## RockScatter publishes per-tile exclusion zones as it bakes; a
## TreeScatter sharing the scene queries the `rocks_tree_exclusion`
## node group via `RockScatter.is_tree_excluded()` and skips any
## tree candidate landing inside one. A few caveats:
##
## - Rocks must be baked BEFORE the trees in that area for the
##   exclusion to apply on first reveal. RockScatter typically
##   bakes faster than TreeScatter (smaller tiles, higher per-frame
##   budget), so this works in practice — but on initial scene
##   load you may see one or two tree clips that resolve on the
##   next rebuild.
## - The check is cheap: a squared-distance comparison against the
##   per-tile exclusion arrays. Cost scales with rocks-with-exclusion
##   count, not total rock count.
@export_range(0.0, 8.0, 0.1) var tree_exclusion_radius: float = 0.0
