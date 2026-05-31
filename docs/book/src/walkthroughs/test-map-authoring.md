# Test-Map Authoring

**Bake terrain, bake POIs, walk the world.**

Iteration 5-14 shipped a test-map authoring pipeline that takes a
designer from "empty test map" to "playable region with squads
roaming between authored bases" in two button-clicks per map:

1. **Bake Now** on Terrain3D → terrain regions seed from canonical
   `heightmap.r32`.
2. **Bake POIs** on `PoiBaker` → `PoiMarker3D` (BASE_*) and
   `InteractionAreaMarker3D` nodes scatter into the scene.

Save the scene. Run the game. NPCs spawn at the authored bases,
squads form, the squad planner picks rest objectives at the
interaction areas, you walk between maps via the existing 2×2
portal grid. End-to-end QA, no procedural scatter at sim startup.

Companion docs:
- [Terrain3D](terrain3d.md) — for the underlying terrain
  pipeline + the **Bake Now** button on `Terrain3DBaker`.
- [Terrain3D Nav-Paint](terrain3d-nav-paint.md) — for the
  optional designer overlay over walkable terrain.
- [Interaction Areas](interaction-areas.md) — for the
  per-marker authoring surface the baker drops.

## Per-map seed identity

Each of the four test maps has a distinct macro terrain (ramp,
hills, basin, ridge — see
`crates/simn-terrain/examples/generate_test_maps.rs`) plus a
multi-octave Simplex noise overlay tuned per-map for organic
variation. The `PoiBaker` in each scene seeds with its map
number (`bake_seed = 1..=4`) so re-baking is deterministic.

| Scene | Region | Macro shape | Noise feel | `PoiBaker.bake_seed` |
|---|---|---|---|---|
| `test_map_1.tscn` | `map_a` | gentle +X ramp | forested rolling hills, gentle east slope | 1 |
| `test_map_2.tscn` | `map_b` | rolling hills | classic rolling countryside | 2 |
| `test_map_3.tscn` | `map_c` | central basin | lake bed surrounded by hills | 3 |
| `test_map_4.tscn` | `map_d` | S-shaped ridge | ridge corridor with side spurs | 4 |

## Workflow (per map)

1. **Open the scene**: `godot/scenes/test/test_map_<N>.tscn`.
2. **Select the `Terrain3D` node** in the scene tree.
3. **Click "Bake Now"** in the inspector. First click seeds the
   25 region files at `godot/assets/terrain/test_map_<N>/terrain3d/`
   from the canonical `heightmap.r32`. Subsequent clicks refuse
   to overwrite (`bake_mode = SEED_IF_EMPTY`) — flip to
   `OVERWRITE_FORCE` if you want a clean re-seed.
4. **Select the `PoiBaker` node**.
5. **Click "Bake POIs"** in the inspector. Scatters
   `BakedPOIs/Poi_<faction>_<idx>` (8 faction-owned bases),
   `BakedPOIs/Camp_<idx>` (3 neutral campsites),
   `BakedPOIs/Rest_<faction>_<idx>` (rest interaction areas), and
   `BakedPOIs/<kind>_<idx>` (work / socialize / scavenge /
   patrol_node spots), all Y-snapped to the Terrain3D ground.
   Re-clicking clears the prior `BakedPOIs` and re-bakes.
6. **Save the scene** (Ctrl+S). The baked nodes become part of
   the `.tscn`.

That's it. Run the game (Solo mode → pick a test map) and squads
will form at the baked bases.

## How the placement works

`poi_baker.gd` (the `@tool` script attached to the `PoiBaker`
node) does:

- **Stratified 4×4 grid** inside `bake_extents` (default 1.8 km
  half-size around scene origin → 3.6 km × 3.6 km bake region,
  well clear of the 2 km portal positions). Each cell holds at
  most one POI; cells are drawn without replacement using the
  seeded RNG.
- **Faction round-robin** across the `factions` array (default
  `["pwa", "linemen", "looters", "federal"]`). With 8 bases and
  4 factions, each faction gets 2 bases per map. The chosen
  base kind per faction follows the same archetype weighting
  the procedural path uses (PWA leans patrol — Checkpoint /
  Outpost; Federal leans Research / HQ; etc.).
- **Y-snap** via `Terrain3D.get_height(world_xz)`. Falls back to
  `TerrainNode.sample_height` then to `0.0` if neither resolves.
  Bake **Terrain3D first** so the snap has data to read.
- **Per-base rest area**: each base gets a sibling
  `InteractionAreaMarker3D` with `kind = "rest"`, offset 8 m on
  the X axis. The squad planner's Phase D3 logic prefers these
  over generic base positions when picking `Rest` objectives.
- **Extra interaction areas**: an additional `extra_interaction_areas`
  (default 4) markers are scattered uniformly within `bake_extents`,
  cycling through `["work", "socialize", "scavenge", "patrol_node"]`.

The bake is deterministic given the same `(bake_seed, factions,
base_count, camp_count, rest_areas_per_base,
extra_interaction_areas, bake_extents)`. Bump `bake_seed` to re-roll
the layout without changing any other knobs.

## Sim-side pickup

`test_map.gd::_on_terrain_ready` (and the synchronous fallback
when terrain is already loaded) calls:

1. `BaseSpawner.spawn_authored_bases(tree, region_id, terrain)` —
   walks `&"poi_markers"` group, filters BASE_* kinds, dispatches
   `SimHost::register_authored_base(region_name, pos, kind,
   faction)` per marker. Mirrors `LootContainerSpawner`'s
   walker shape (Phase 3D).
2. `_request_region_interaction_areas(sim)` — already existed
   from iteration 5-13 Phase D2; walks
   `&"interaction_area_markers"` and calls
   `SimHost::attach_region_interaction_areas`.

The `Sim::register_authored_base` call (iteration 5-14 Phase B)
spawns the standard base component tuple
(`Base`, `InFaction`, `InRegion`, `Position`, `Health`), Y-snaps
to attached terrain, and stamps a per-`BaseKind` nav-obstacle
footprint so squad pathfinding routes around the structure.

## Why this exists (the procedural-scatter pivot)

Pre-iteration-5-14, `world_seed::seed_random_world_content`
scattered 25–40 bases per region in a 7×7 stratified grid at sim
startup. That worked when nothing else owned base placement, but
once `PoiMarker3D` + `InteractionAreaMarker3D` markers existed
(iterations 5-12 / 5-13), the procedural scatter sat *on top* of
scene-authored content — duplicates, clutter, no consistent
state across runs.

Iteration 5-14 Phase C added a `Region::scene_authored_pois`
flag. When true (the four test maps in `default_test_graph` flip
it on), `world_seed` skips the per-region base + camp scatter.
`RegionControl` + `PopulationTargets` still seed normally; the
squad planner + spawn budget all work the same. Bases come from
the scene via `register_authored_base` instead.

The `spawn_npcs` system also gained a "skip regions with zero
`Base` entities" gate — without bases, the no-bases fallback in
`pick_spawn_pos` clusters every squad at origin in a 200 m
radius and the O(N²) combat pass collapses the per-tick budget
(10+ minutes for what used to be 11 s; caught by the
`offline_combat` integration test).

See:
- `docs/book/src/planning/sim-iteration-5-14-plan.md` for the
  full iteration plan.
- `docs/book/src/architecture/crate-guide.md` for the sim-side
  API surface (`scene_authored_pois`, `register_authored_base`).
- `crates/simn-sim/tests/scene_authored_gating.rs` for the
  gate contract.

## Limitations / follow-ups

- **`PoiBaker.bake_extents` defaults to 1800 m half-size** to
  stay clear of the 2 km portal positions. If you bump it past
  that, scattered POIs may land inside the transition cubes.
- **Terrain3D segfault on `region_size` from .tscn** (per
  `CLAUDE.md` Critical Rules) — leave `region_size` *out* of
  the `.tscn` and set it via the baker's `bake_region_size`
  export instead. Same workaround for `vertex_spacing`.
- **Foliage scatters not wired up yet** on test maps.
  TreeScatter / RockScatter / GroundCoverScatter from cascade_locks
  haven't been added — the test maps stay bare-terrain for now.
- **Visual-only `TerrainNode` hidden, not removed.** The
  `Terrain` (TerrainNode) child of each test map keeps
  `visible = false` but is still **load-bearing**: its
  `grid_dims()` / `spacing_m()` accessors and `terrain_loaded`
  signal are what gate `_request_region_terrain`'s live-Terrain3D
  push to the sim (see [terrain.md](terrain.md) "Live-Terrain3D
  push"). Removing the node would force the sim back onto the
  canonical `.r32` Y-snap, which drifts ~9–18 m from what
  Terrain3D actually renders + collides on — entities spawn
  underground. The node also still hosts the canonical-source
  collision used by `loot_container_spawner.gd` and the
  Y-sample query used by `poi_baker.gd` as the canonical anchor.
  Production maps that migrate fully to Terrain3D-only will
  need their own live-push variant before this node can go away.
