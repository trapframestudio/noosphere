# Procedural trash scatter

End-to-end walkthrough of the trash / litter / debris scatter:
species categorization, road + zone-driven placement, the static-vs-
physics tier split, frozen-until-hit collision, and the wind-driven
impulse tick.

The system shares the same playbook as `rock_scatter` — tile-based
streaming around the camera, per-tile MMI for static instances,
on-disk placement cache keyed by `seed + cache_version` — but adds a
runtime physics path for items kickable by the player and a wind
tick for items the player should see tumble in a breeze.

## What it produces

Single-use litter scattered along roads, in town footprints, and
around hand-authored `ProceduralExclusionZone` regions whose
`trash_density_mul > 0`. Categories in the curated set:

- **Bottles**: 5 shapes × 3 poses each (standing / lying / crushed)
  in glass + plastic flavors.
- **Cans**: beverage cans (undamaged / damaged / 500 ml / crushed)
  + food cans (label variants, undamaged / damaged / heavy-damaged
  / rusty).
- **Smokables**: ~21 mesh variants — cigarettes, cigarette ashes,
  joints, joint ashes, cigars, cigar ashes, blunts, blunt ashes.
- **Paper**: crumples, flat sheets, colored crumples (15+
  variants).
- **Food waste**: apple cores, banana peels.
- **Broken glass**: 3 shard variants from broken bottles.
- **Misc**: masks, flipflops, chips bags, coffee cups (3 cup
  variants), tinfoil balls, matchboxes, drink containers.

Items intentionally **excluded** from the curated set: full
dumpsters, oil drums, large pre-arranged piles, construction
debris (concrete chunks, bricks, paint cans, buckets, cardboard
boxes, wood splinters, tires). These stay in the manifest /
`.tres` library on disk for future "construction debris / ruins"
zones, but they're filtered out of the scene's `species_paths`.

Three behavioral tiers drive how each species lands in the world:

| Tier | Spawn shape | Examples |
|---|---|---|
| **Static (MMI)** | `MultiMeshInstance3D` per species per tile. No collision, never moves. | Cigarettes, cigarette ash, matchboxes — tiny / light items that stick via friction. |
| **Frozen-static physics** | `RigidBody3D` with `freeze = FREEZE_MODE_STATIC`. Inert until the player's `TrashKickZone` walks into them. | Bottles (5 shapes × 3 poses), cans (beverage + food), drink containers, coffee cups, broken glass shards, food waste (apple cores, banana peels). Solid kickable items. |
| **Dynamic-sleeping physics** | `RigidBody3D`, `sleeping = true`. The wind tick wakes them with impulses for visible tumble. | Paper crumples + flat, masks, flipflops, chips bags, tinfoil balls. Light items that visibly react to wind. |

Tier choice is per-species (`TrashSpecies.physics_enabled` +
`wind_susceptibility`), not per-instance. A species's tier never
changes at runtime; only spawn vs. don't-spawn varies based on
distance.

## Pipeline overview

```
asset_downloads/Superhive/TrashKit_BLENDER_1.2/TrashKit.blend  # source pack (~700 meshes)
   ↓
scripts/extract_trashkit.py                 # Blender extractor: every named mesh → .glb
scripts/trash_species_manifest.json         # curation: 102 entries with tier + per-species tuning
scripts/generate_trash_species_tres.py      # render TrashSpecies .tres files from the manifest

godot/assets/models/trash/<category>/*.glb  # curated mesh set (~120 GLBs incl. variants), embedded textures
godot/scripts/foliage/trash_species.gd      # TrashSpecies resource (per-species tier + weights + placement knobs)
godot/resources/foliage/trash/*.tres        # 102 species (~85 wired into the scene, rest reserved for ruins zones)
godot/scripts/foliage/trash_scatter.gd      # TrashScatter Node3D — tile-streamed placement + spawn
godot/scripts/foliage/trash_kick_zone.gd    # TrashKickZone Area3D — player-side unfreeze-on-walk-into trigger

godot/scripts/weather_rig.gd                # WeatherRig.wind_vector_xz() — pulled by wind tick
godot/scripts/layers.gd                     # Layers.CONCEALMENT — physics layer trash sits on
godot/scripts/procedural_exclusion_zone.gd  # zone-driven density boost (positive trash_density_mul)
godot/scenes/player.tscn                    # TrashKickZone child wires kicking into the player rig

godot/assets/foliage_bake/<map>/trash/<key>/<x>_<z>.bin   # placement cache (LFS-tracked)
```

## Asset extraction + curation

The mesh source is a single Blender file (Superhive's TrashKit) with
~700 named mesh assets across 20 collections (bags, barrels, bottles,
boxes, buckets, cans, paint cans, container debris, garbage bins,
generic, pallets, prefabs, rubble, smokables, tires, wood splinters).
Most are not appropriate for a procedural ground scatter — full
dumpsters, big oil drums, large pre-arranged piles. The pipeline:

1. **Extract** every named mesh from the source `.blend` as a
   standalone `.glb` with embedded textures via
   `scripts/extract_trashkit.py`. Output goes to a staging directory
   under `/tmp/`; ~4.6 GB total. **Not committed wholesale** — only
   the curated subset lands in `godot/assets/models/trash/`.
2. **Curate** the subset in `scripts/trash_species_manifest.json`:
   each entry names a `glb` (relative path under `godot/assets/models/trash/`),
   a `tier` (`static` / `physics` / `physics_wind`), and per-species
   tuning (mass, road weights, anchor radius, render distance). The
   current manifest holds ~50 entries — enough variety for the scatter,
   small enough that per-tile MMI count stays bounded.
3. **Generate** species `.tres` files via
   `scripts/generate_trash_species_tres.py` — derives stable UIDs
   from species names so re-runs don't churn UIDs, applies tier
   defaults so most entries only override unique fields. Prints the
   `species_paths` array for pasting into the `TrashScatter` node.

Items intentionally **not** in the scatter (because they're too big
for ambient placement or earmarked for a different system):

- Full dumpsters / garbage bins (`bin_*` categories, ~19 meshes) —
  hand-placed as POIs.
- 50-gallon oil drums (`barrels/barrel_metal_*`, `barrel_plastic_*`)
  — hand-placed; some get repurposed as explosive props in a future
  pass.
- `prefab_lg` (large pre-arranged trash piles) — overlap with the
  scatter's anchor / satellite system, would compete for placement.
- Container debris bodies — too large; set-piece material.

## Mesh tier breakdown

The scene-active set has ~85 species (manifest holds 102 — the 17
rejected categories stay on disk for future ruins / construction-
debris zones). Approximate breakdown:

| Tier | Approx. count | Examples |
|---|---|---|
| Static MMI | ~22 | `cigaret_butt` + 7 cigarette variants, `cigaret_ash` + 2 ash variants, `joint_e/f/g`, `joint_ash_a/b`, `cigar_b/c`, `cigar_ash_a/b`, `blunt_d`, `blunt_ash_a/b`, `matchbox`, `matchbox_b` |
| Frozen-static physics (kickable) | ~40 | `bottle_glass_*` (3), `bottle_plastic_*` (2), `bottle_b/c/d/e_standing/lying/crushed` (12), `bottle_a_c_lying/e_crushed` (2), `can_soda*` (3), `can_food_*` (5+), `can_beverage_*` (4), `apple_a/b`, `banana_a/b`, `bottle_broken_a/b/c`, `drink_a` |
| Dynamic-sleeping physics (wind) | ~20 | `paper_crumple_a/b/c/e`, `paper_flat`, `paper_flat_b/c`, `paper_cumplecol_a/b/c`, `mask_covid`, `flipflop`, `flipflop_b`, `chips_bag`, `chips_bag_b`, `coffee_cup`, `coffee_cup_b/c`, `tinfoil_ball`, `tinfoil_b` |

## Placement signals

Per-candidate weights and accept-probability compose from these
splat / terrain / noise reads:

1. **Road proximity** (`_road_proximity_score`). 9-sample weighted
   average of the road density splat (`road_density.rgba8`) plus
   `splatmap_b.rgba8`'s G channel (BuiltUp), with falloff bounded by
   `road_clearance_radius_m`. Picks up trash near a road, not just
   on the road surface itself.
2. **Zone boost** (`ProceduralExclusionZone.trash_zone_boost`).
   Hand-authored zones (towns, camps, outposts) carry a
   `trash_density_mul` that opts them into the trash spawn even
   when no road pixel exists.
3. **Road edge strength** (`_road_edge_strength`). Peaks at gutters
   and curbs (where the splat goes from 1 to 0 in a few meters); zero
   in the road interior and zero in the open. Drives "papers along
   road verges" placement (`TrashSpecies.road_edge_boost`).
4. **Terrain curvature** (`_terrain_curvature`). Concavity score from
   neighboring height samples. Light trash blows into bowls and
   dips; ridges shed it (`TrashSpecies.terrain_curvature_boost`).
5. **Anchor proximity**. Hero items (heaps, trashbags, big debris
   with `is_anchor = true`) place first in a pre-pass and broadcast
   an attractor radius. Smaller satellite species get a density
   boost inside that radius (`TrashSpecies.satellite_anchor_boost`).
   Result: piles instead of evenly-spaced pepper-spray.
6. **Slope filter**. Per-species `max_slope_deg` rejects placements
   on terrain steeper than the species can plausibly rest on — a
   heavy bottle on a 30° slope would visibly roll downhill, so its
   cap is around 22°; a cigarette butt or crumpled paper sticks to
   anything up to ~38°. Below the cap, accept-probability gets a
   linear falloff from 100% on flat ground to 0% at the cap, so
   density tapers smoothly toward steeper edges instead of having a
   sharp boundary. Combined with the existing
   `terrain_curvature_boost`, trash naturally pools on flat / concave
   ground at the foot of slopes — the same way real-world litter
   collects.
7. **Hotspot noise mask** (`_hotspot_mask_at`). 2D Perlin noise
   sampled at world XZ, remapped from `[-1, 1]` into
   `[hotspot_floor, hotspot_ceiling]`, multiplied into accept-
   probability *before* the clamp. The whole point is to break the
   uniform "random sprinkle" pattern the road / zone signals would
   otherwise produce — with the defaults (floor=0, ceiling=2,
   frequency=0.02 → ~50 m feature size), the average across the map
   is ~1 (no overall density change), but ~50% of the area drops
   below 1 and the bottom tail bottoms out at 0, so cold spots are
   genuinely empty and hot spots are recognizable dump spots / camp
   leftovers / road-pullout litter pools. Tunable per-scatter to
   trade off how dramatic the clustering reads.
8. **Same-species repeat damper** (`same_species_repeat_damper`).
   Per-tile counter that down-weights each species's roulette weight
   by `1 / (1 + n × damper)` after `n` placements of that species in
   the current tile. At the default `0.5`, the second pick of a
   species is 67% as likely, third is 50%, fourth is 40% — naturally
   cycles the roulette through the species pool instead of letting
   the highest-scoring species win every roll. Per-tile state, so
   neighboring tiles vary independently.

Each candidate's accept probability is `clamp(accept_p, 0, 1)` so
dense tiles can't overflow the per-tile candidate cap.

## Tier-1: static MMI tile spawn

Same shape as `rock_scatter`. One `MultiMeshInstance3D` per species
per tile, transforms translated to local at insert time so the MMI's
buffer holds tile-relative coords (cheap on f32 precision for big
maps). Container is `Node3D` named `TrashTile_<x>_<y>` parented under
the scatter node. **No `owner` is set** so the spawned subtree never
persists into the .tscn file when the user saves the scene.

Static spawn happens for every active tile regardless of distance to
the camera (subject to `active_radius_m`). Cheap.

## Tier-2: physics RigidBody3D spawn

Physics species spawn one `RigidBody3D` per instance, gated by
`physics_active_radius_m` (default 60 m around the camera). Body
**initial state** depends on whether the species reacts to wind:

- **Non-wind** (`wind_susceptibility = 0` — bottles, cans, food
  cans, drinks, coffee cups): `freeze = true` with
  `freeze_mode = FREEZE_MODE_STATIC`. The body acts as a static
  collider and **never simulates** until the `TrashKickZone` Area3D
  on the player explicitly unfreezes it (see "Kicking" below).
  `sleeping = true` alone wasn't enough — Godot wakes the body on
  `add_child` / first physics tick / contact, and on any sloped
  terrain the body would then roll downhill before sleeping again.

- **Wind** (`wind_susceptibility > 0` — papers, masks, chips bag,
  flipflops, tinfoil ball, coffee cup variants): stays dynamic,
  spawned `sleeping = true`. The wind tick wakes them with
  impulses; high `linear_damp = 2.5` / `angular_damp = 3.5` lets
  them settle quickly between gusts.

### Kicking

`TrashKickZone` (an `Area3D` at `godot/scripts/foliage/trash_kick_zone.gd`)
sits under the player's `CharacterBody3D` and bridges the gap between
the player and the frozen tier. The zone's `collision_mask` includes
`Layers.CONCEALMENT` (the trash layer) so it sees frozen trash
overlapping the player's volume — the player's CharacterBody3D
itself doesn't, by design, since bottles shouldn't physically block
walking.

On `body_entered`:

1. If the body isn't a `RigidBody3D` or isn't currently frozen, bail.
2. If the parent CharacterBody3D's `velocity.length()` is below
   `min_kick_speed` (default `0.5 m/s`), bail. This prevents trash
   that streams in next to a stationary player from immediately
   unfreezing + falling + rolling — the player must actively walk
   into the trash to wake it.
3. Compute kick direction: horizontal offset from the zone's origin
   to the body's origin, plus a `vertical_lift` bias so the body
   tumbles forward instead of just skidding.
4. `freeze = false` (BEFORE the impulse — `apply_central_impulse`
   silently no-ops on a frozen body in Godot 4).
5. `apply_central_impulse(dir * player_speed * 0.5 * impulse_strength)`.
   Magnitude scales with player speed: walking nudges, sprinting
   throws.

Defaults (`impulse_strength = 2.5`, `vertical_lift = 0.4`,
`min_kick_speed = 0.5`) are tuned so a soda can scoots a few meters
when walked through and a brick barely budges. Tune per-scene by
editing the `TrashKickZone` node on the player.

Once unfrozen, the body simulates normally — gravity pulls it down
to its actual rest pose (one side of the cylinder for a bottle), it
rolls if the terrain is sloped, and `linear_damp = 4.0` /
`angular_damp = 6.0` bleed energy quickly so it settles within a
few seconds. Once at rest, Godot's auto-sleep kicks in and the body
drops to ~zero CPU again — but it stays unfrozen, so a second kick
on a previously-kicked body works as expected.

Outside this radius the placements are still rolled and written to
the disk cache, but no body spawns. Two things happen out there
instead:

- The cached transforms are spawned as a static `MultiMeshInstance3D`
  fallback — the brick/bottle/can is **visible** at distance, just
  inert (no collision, no kickability). Without this fallback the
  far world would visibly contain only the 3 `physics_enabled = false`
  species (cigarettes, ash, matchbox) — every other species would
  pop into existence as the player walked within 60 m. The MMI uses
  the same mesh + material the RigidBody3D path would use.
- `_tile_spawn_physics[tile]` records the spawn-mode the tile last
  used. When the player crosses `physics_active_radius_m` toward
  that tile, `_rebuild_active` notices the mismatch, frees the
  MMI-fallback container, and re-queues the tile for re-spawn so
  it comes back as real RigidBody3Ds (and walks back the other way
  on retreat — the boundary works in both directions).

Each body's setup:

- `collision_layer = Layers.CONCEALMENT`. Player + NPC bodies pass
  through trash for movement (no awkward "blocked by a soda can"),
  but kicks register and weapon-fire raycasts treat trash as partial
  concealment, not solid cover.
- `collision_mask = SOLID | CONCEALMENT`. Trash falls onto terrain
  and rests against rocks; trash interacts with itself (a kicked can
  bounces off a brick); trash ignores NPC hitboxes.
- `sleeping = true`, `can_sleep = true`. Frozen-until-hit. Godot
  auto-wakes a sleeping body on collision, so the player kicking a
  bottle wakes it without any manual signal wiring. Idle sleeping
  bodies cost effectively zero CPU.
- `linear_damp` / `angular_damp` per regime (above). Bleed energy
  so kicked / wind-tossed items come to rest within seconds rather
  than rolling forever.
- Auto-sized `BoxShape3D` matching the mesh AABB exactly, with the
  collider positioned at the AABB's geometric center (not the
  mesh's authored origin). Box (vs. the previous capsule)
  uniformly handles every trash shape — bottles / cans (cylinder),
  apples (sphere), papers (flat) — without per-species long-axis
  configuration. The capsule's hemispherical ends made cylinders
  roll too easily, and its 0.4× radius multiplier left the visible
  mesh extending past the collider; bullets near the silhouette
  edge would miss entirely.

The container `Node3D` is positioned at `tile_center` and per-instance
transforms are translated into its local frame. Rocks do this too;
it halves the float-precision pressure on instance positions when
the player is far from world origin.

## Tier-3: wind tick

Physics species with `wind_susceptibility > 0` get registered into
`_wind_bodies_by_tile[tile]` at spawn. The scatter ticks
`wind_tick_interval_s` (default 1.5 s) in `_process`; each tick:

1. Resolve the active `WeatherRig` via the `weather_rigs` group.
   No-op if no rig is in the scene (e.g. minimal test maps).
2. Read `rig.wind_vector_xz()` — horizontal wind direction × strength.
   Same `wind_mul × transition_boost` blend the foliage shader uses,
   so physics gusts are in lockstep with visible foliage sway.
3. For each registered body, apply
   `wind_impulse_scale × susceptibility × jitter(0.6, 1.4) × mass × wind_xz`
   as a central impulse. Multiplying by `mass` keeps Δv consistent
   across mass differences (a 5 g paper accelerates the same as a
   80 g bag for the same susceptibility). The applied impulse wakes
   sleeping bodies automatically.

Editor preview leaves the wind tick disabled — the inspector
experience stays stable, no items drifting while the user tweaks
sliders.

## Cache contract

Same shape as `rock_scatter`'s cache. Magic `"TRSH"`, format version
2 (v1 caches are still readable; the format bump is for future
compatibility and is documentation-only today). Cache keyed by
`md5(cache_version | seed)[:16]` — only those two values participate.
Bumping `cache_version` (or clicking **Clear placement cache** then
**Bake placement cache**) is the only way to re-roll positions;
species-density tweaks alone don't invalidate.

The cache stores transforms world-absolute and re-derives `is_physics`
from current species at spawn time, so flipping a species's
`physics_enabled` between cache write and read picks up the new tier
on the next tile load without bumping `cache_version`.

## Authoring workflow

1. **Add a species**: copy an existing `.tres` under
   `godot/resources/foliage/trash/`. Set `mesh_scene_path` to a GLB
   in `godot/assets/models/trash/`. Pick a tier:
   - Pile / dirt-tier item → `physics_enabled = false`,
     `is_anchor = true` if it's a hero pile.
   - Solid kickable → `physics_enabled = true`, `physics_mass` per
     real-world weight (0.05 kg can, 0.4 kg bottle, 0.6 kg box,
     1.5 kg brick), `wind_susceptibility = 0`.
   - Wind-blown light item → `physics_enabled = true`, low mass
     (0.02–0.1 kg), `wind_susceptibility` 0.4–1.0.

   **Lay-down pretilt** (`lay_down_pretilt_deg`): set to `90.0` for
   any species whose source mesh is authored standing upright
   (bottles, cans, paint cans, coffee cups, drink containers). The
   scatter pre-rotates the basis around its local X axis by this
   angle BEFORE applying random yaw, so each instance spawns lying
   fully on its side — and the subsequent yaw rotates the
   long-axis direction so siblings face different ways. Set to `0.0`
   for meshes that are already lying / crumpled / flat
   (bottle_*_lying, bottle_*_crushed, paper crumples, masks, banana
   peels, etc.) — tipping them further would lift one edge
   unnaturally.

   **Ground-snap.** After all rotations are composed, the placement
   origin lifts by the rotated AABB's lowest world-Y corner so the
   mesh just touches terrain. A bottle authored origin-at-base, when
   tipped 90°, would otherwise extend `radius` below the placement
   origin and bury half the cylinder; the lift is computed
   per-instance from the final rotated basis so it tracks any random
   tilt jitter too. Lift-only (never lower), so meshes whose lowest
   point is already at or above origin keep their authored offset.
2. **Wire it into the scatter**: add the `.tres` path to the
   `species_paths` array on the `TrashScatter` node in your map
   scene. Order doesn't matter for placement (anchors place first
   regardless of array position).
3. **Bake the cache**: in the editor, select the `TrashScatter`
   node, click **Bake whole map** (or **Bake placement cache** for
   just near-origin). The walk-through prints how many tiles were
   baked vs. skipped (empty forest tiles get skipped).
4. **Iterate**: density tweaks (per-species weights, base density,
   road clearance radius) take effect immediately on next tile bake
   — no cache rebuild needed. Position-affecting changes (seed,
   cache version, anchor radii) need a **Clear placement cache** +
   **Bake** cycle.

## Known rough edges

- **Capsule collision is approximate.** Bottles roll well; flat
  things like masks and flipflops jitter slightly when colliding
  edge-on because the capsule doesn't match their silhouette. A
  per-species `ConvexPolygonShape3D` derived from the GLB would fix
  this but isn't worth the bake cost yet — most flat items have
  `wind_susceptibility > 0` and tumble before settling, masking the
  jitter.
- **Wind tick pulls every body in range every tick.** At ~50 wind-
  susceptible bodies in radius (typical), this is ~50 impulse calls
  per tick = nothing. If we ever support hundreds, sub-sample the
  list per tick.
- **Single map_id.** The scatter doesn't react to map switches at
  runtime; it loads the configured `map_id` once. Production maps
  instance their own `TrashScatter` so this is fine; if a single
  scene ever needs multiple maps' worth of trash, the load path
  will need to re-resolve.
