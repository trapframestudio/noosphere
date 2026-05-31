@tool
class_name TrashSpecies
extends Resource

## A single trash species the TrashScatter can place on the terrain.
##
## Mirrors TreeSpecies / RockSpecies in shape but adds physics-mode
## flags for kickable items (cans, bottles).
##
## **Spawn rules** are road-driven: each species opts into which road
## types it spawns on (`spawn_paved` / `spawn_unpaved` / `spawn_trail`)
## plus a `spawn_in_zones` flag for town-style exclusion zones with
## `trash_density_mul > 0`. A species with all four false never
## places — useful for templates not yet wired up.

@export_file("*.glb", "*.gltf") var mesh_scene_path: String = ""

@export_group("Sizing")
@export_range(0.05, 4.0, 0.01) var scale_min: float = 0.85
@export_range(0.05, 4.0, 0.01) var scale_max: float = 1.15
@export_range(0.05, 8.0, 0.01) var size_multiplier: float = 1.0
@export var random_yaw: bool = true
@export_range(0.0, 90.0, 1.0) var random_tilt_deg: float = 10.0

## Pre-rotation applied around the model's local X axis BEFORE the
## random yaw and random tilt — used to "lay down" species whose mesh
## is authored standing upright (bottles, cans, paint cans, coffee
## cups). 90° tips the mesh fully onto its side (the canonical look
## for dropped litter); leave at 0 for meshes that are already lying
## / flat / crumpled (bottle_*_lying, paper, masks, banana peels).
##
## Applied around `basis.x`, so the subsequent `random_yaw` rotates
## the lean direction around the up axis — different instances tip
## different ways without us needing per-instance axis randomization.
@export_range(0.0, 90.0, 1.0) var lay_down_pretilt_deg: float = 0.0

@export_group("Terrain settling")
## Maximum slope (degrees from horizontal) at which this species can
## spawn. Above this, candidates hard-reject — a heavy bottle on a
## 30° slope would visibly roll downhill, breaking immersion. Below
## this, accept-probability gets a LINEAR FALLOFF from 100% on flat
## ground to 0% at the cap, so density naturally tapers toward the
## steep edges instead of having a sharp boundary.
##
## Tier-appropriate defaults: static / wind-light items (papers,
## cigarettes, masks) can stay on steeper slopes (~35-40° — the
## friction of thin/bendy items on tilted ground holds them); heavy
## physics items (full bottles, cans, food cans, coffee cups) cap
## lower (~20-25°) since their cylindrical/symmetric bodies actually
## roll. Set to 90.0 to disable slope filtering entirely.
@export_range(5.0, 90.0, 1.0) var max_slope_deg: float = 30.0

@export_group("Albedo / lighting")
@export var albedo_modulation: Color = Color(1.0, 1.0, 1.0, 1.0)

@export_group("Physics")
## Static (false) = MultiMeshInstance3D, no collision, no physics.
## Cheap, ideal for bulk filler trash (paper, masks, heaps, bags).
##
## Physics (true) = RigidBody3D per instance with an auto-sized
## CollisionShape3D. Heavy, ~5x cost vs. static. Reserved for items
## the player can plausibly interact with — bottles, cans, kickables.
##
## Physics-enabled species are CULLED HARDER: only spawn within the
## scatter's `physics_active_radius_m`, and unloaded outside it.
## Static species follow the regular `tile_size_m` × `active_radius_m`
## tile streaming.
@export var physics_enabled: bool = false

## Mass in kg for physics-enabled instances. ~0.05 = empty soda can,
## ~0.3 = full bottle, ~0.5 = brick, ~5 = barrel. Lighter = more
## responsive to player kicks but more sensitive to numerical jitter
## and harder to come to rest.
@export_range(0.01, 50.0, 0.01) var physics_mass: float = 0.2

## Collision shape radius for physics-enabled instances. 0 = auto-
## derive from `size_multiplier × 0.4`. Override when a specific
## item's silhouette doesn't match the size multiplier (e.g. a long
## thin bottle is taller than wide).
@export_range(0.0, 1.0, 0.01) var physics_radius: float = 0.0
@export_range(0.0, 2.0, 0.01) var physics_height: float = 0.0

## Authority model for physics state. Currently only LOCAL is wired
## (no networking yet); SERVER_AUTHORITATIVE is a marker for future
## destructible / heavy items. NONE = pure visual, no physics.
@export_enum("Local (client-only)", "Server-authoritative (future)") var physics_authority: int = 0

## How strongly this item responds to wind. 0 = ignore (default; cans
## and bottles are too heavy for wind to move). 1 = full sensitivity
## — light papers and plastic bags get tossed every gust.
##
## Only meaningful when `physics_enabled = true`. The trash scatter
## reads `WeatherRig.wind_vector_xz()` once per wind tick (~1 Hz) and
## applies an impulse of `wind_vector × susceptibility × jitter` to
## each wind-susceptible body in the active radius. Body wakes from
## sleep on impulse, tumbles, and re-sleeps when at rest.
##
## Pair with low `physics_mass` for visible movement (a 5 g paper
## crumple at susceptibility 1 visibly tumbles in a light breeze;
## a 0.5 kg flipflop at susceptibility 0.4 only stirs in a windstorm).
@export_range(0.0, 1.0, 0.05) var wind_susceptibility: float = 0.0

@export_group("Natural placement (AAA-style signals)")
## How much to align the trash's local up to the terrain normal.
## 0 = always world-up (trash sticks straight up regardless of slope);
## 1 = fully aligned. Most trash items rest on the ground at the slope
## angle, so 0.6-0.85 reads natural. Set 0 only for items that should
## stay vertical (standing bottle, vertical can).
@export_range(0.0, 1.0, 0.05) var terrain_alignment_factor: float = 0.7

## This species places FIRST and emits a satellite-attractor field.
## Set on "hero" trash that should anchor pile formations (heaps,
## trashbags, big debris, abandoned containers). Smaller items
## (cans, bottles, papers) DO NOT set this — they're satellites that
## cluster around anchors.
##
## Anchors place rarely (per the species's road weights); satellites
## get density-boosted within `satellite_anchor_radius` of any anchor.
## Result: piles instead of uniform pepper-spray. Same architecture
## as RockScatter.
@export var is_anchor: bool = false

## Density multiplier when within `satellite_anchor_radius` of a
## placed anchor. Linear falloff from full strength at center to
## zero at the radius edge. 0 = ignore anchors (default). 4-10 for
## small ground species that should pile against heaps.
@export_range(0.0, 16.0, 0.5) var satellite_anchor_boost: float = 0.0

## Radius of an anchor's attractor field, in meters. Only meaningful
## when `is_anchor = true`. Typical 1.5-3 m for trash piles (smaller
## than rock anchors since trash items are smaller).
@export_range(0.5, 10.0, 0.5) var satellite_anchor_radius: float = 2.5

## Density boost when on a road EDGE (gradient between road and
## non-road splat values). Real-world trash concentrates at gutters,
## sidewalk edges, and along road verges — not in the road center
## or far from it. This signal peaks where the road-splat gradient
## is strongest.
##
## 0 = ignore (uniform on-road distribution, default). 4-8 for items
## that visibly drift to road edges (papers, bags, small debris).
## Items that get HIT by traffic (cans, bottles) keep this lower.
@export_range(0.0, 8.0, 0.1) var road_edge_boost: float = 0.0

## Density boost from terrain CONCAVITY — concave bowls/dips collect
## blown trash via wind. Same signal RockScatter uses but applied
## here for wind-pattern realism. 0 = ignore (default). 2-5 for
## light items (paper, plastic) that wind blows into low spots.
@export_range(0.0, 8.0, 0.1) var terrain_curvature_boost: float = 0.0

@export_group("Spawn rules")
## Road-type opt-ins. Trash density at a candidate is composed as
## `paved × paved_w + unpaved × unpaved_w + trail × trail_w + zone_boost`
## where each `_w` is this species's `road_*_weight` and only fires
## if the splat there has the matching road type. So a "soda bottle"
## species might set paved_weight=1.0 + unpaved_weight=0.5 + trail=0.1
## + spawn_in_zones=true.
@export_range(0.0, 4.0, 0.05) var paved_weight: float = 1.0
@export_range(0.0, 4.0, 0.05) var unpaved_weight: float = 0.4
@export_range(0.0, 4.0, 0.05) var trail_weight: float = 0.1
@export var spawn_in_zones: bool = true

## Weight on the BuiltUp splat channel (splat_b.G) — town footprints,
## plazas, parking lots, sidewalks. Anchor piles (heaps, trashbags,
## rubble) want this HIGH (typical 1.5-2.5) so they cluster in towns.
## Small loose items can set this MODERATE (0.4-0.8) so they're still
## present in town centers without explicit road pixels. 0 = ignore.
##
## Anchor placement also auto-suppresses on actual road pixels via
## `(1 - road_density)` so a high builtup_weight doesn't put piles on
## the asphalt itself — they cluster at curbs / lots / next to buildings.
@export_range(0.0, 4.0, 0.05) var builtup_weight: float = 0.0

## Weight on the Bare splat channel (splat_b.R) — empty lots, dirt
## patches, exposed soil with no vegetation. Anchor piles set this
## HIGH (typical 1.0-2.0) — abandoned dump-spots and overgrown
## construction lots. Small loose items rarely care (low / 0). 0 =
## ignore.
@export_range(0.0, 4.0, 0.05) var bare_weight: float = 0.0

@export_group("Visibility")
@export_range(0.0, 500.0, 5.0) var max_render_distance_m: float = 80.0
