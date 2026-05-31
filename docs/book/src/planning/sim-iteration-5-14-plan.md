# Iteration 5-14: Test-Map Authoring Rework

**Scope:** replace bland test-map terrain with noise-varied
themes, add an editor-driven POI baker so designers can scatter
`PoiMarker3D` + `InteractionAreaMarker3D` markers into each test
map, gate `world_seed`'s automatic procedural scatter on a new
`scene_authored_pois` flag so the scene-authored layer becomes
the source of truth for base placement on test maps, and ship
the walkthrough that ties it together. End-to-end QA: walk the
2×2 region grid, watch squads form + traverse + rest at authored
areas, observe the simulation work from iterations 5-11 / 5-12 /
5-13 in something that reads as a real outdoor environment.

## Context

After iteration 5-13 shipped (nav pipeline + interaction areas),
the test maps were wired up with Terrain3D but exposed three
problems blocking end-to-end QA of the simulation work:

1. **Bland terrain.**
   `crates/simn-terrain/examples/generate_test_maps.rs` produced
   canonical heightmaps via closed-form `gen_ramp` / `gen_hills`
   / `gen_basin` / `gen_ridge` functions. The macro shapes were
   recognizable but the surfaces were too smooth to read as
   outdoor environments — nothing for NPCs to navigate around,
   no visual texture for the player to orient by.
2. **Automatic procedural POI scatter.**
   `world_seed::seed_random_world_content` placed 25–40 bases per
   region at sim startup via a 7×7 stratified grid. With
   scene-authored `PoiMarker3D` markers now present (iterations
   5-12 / 5-13), the procedural scatter sat on top of the
   scene-authored content — duplicates, clutter, no consistent
   state across runs.
3. **No editor flow for placing varied POIs.** Designers could
   hand-place markers individually, but there was no "give me a
   representative spread of bases + rest spots across this
   region" button. That slowed iteration on the squad-planner +
   interaction-area work that just landed.

Locked design (via plan-mode AskUserQuestion):
- **Terrain**: noise-layered themes — keep `gen_ramp`/`hills`/`basin`/`ridge`
  as the macro shape, add multi-octave OpenSimplex on top with
  per-map seed.
- **POI baker output**: edit-time → scene-authored `.tscn` nodes.
  Bake button mutates scene tree, user saves, deterministic per
  checkout.
- **Procedural gating**: new `scene_authored_pois` flag on
  `Region`. Test maps opt in → world_seed skips base scatter;
  `PopulationTargets` + `RegionControl` still seed.

## Phases

Six phases, each landed as its own commit.

### Phase A ✅ landed (`98ec283a29`)

**Noise-layered varied terrain.**
- Added `noise = "0.9"` as a `[dev-dependencies]` entry on
  `simn-terrain` (example-only, no runtime impact).
- Refactored `examples/generate_test_maps.rs`: each of the four
  generators kept its macro shape, with a new `add_noise_overlay`
  helper layering multi-octave OpenSimplex on top with a per-map
  seed + amplitude. `vert_min_m` / `vert_max_m` in
  `terrain.toml` now compute from the actual sample data.
- Regenerated `heightmap.r32` + `terrain.toml` for all four test
  maps. Heights range 131–170 m, well under the 200 m baseline.

### Phase B ✅ landed (`64ab5b3523`)

**`Sim::register_authored_base` API + bridge.**
- New `Sim::register_authored_base(region, pos, kind, faction) ->
  Result<Entity>` in `crates/simn-sim/src/world/mod.rs`. Mirrors
  the procedural spawn tuple (`Base`, `InFaction`, `InRegion`,
  `Position`, `Health::new_full()`), Y-snaps to attached terrain,
  and stamps the per-kind nav-obstacle footprint via
  `NavQueries::apply_obstacles` so squads route around the
  structure.
- Bridge `#[func] register_authored_base(region_name, pos, kind,
  faction) -> bool` on `SimHost` resolves the kind / faction
  strings via `BaseKind` variant names + `FactionRegistry::id_of`,
  then dispatches through `worker_or_direct_mut`.
- Tests: `crates/simn-sim/tests/authored_bases.rs` (4 tests).

### Phase C ✅ landed (`6bed9ed7aa`)

**Gate procedural seeder on `scene_authored_pois`.**
- Added `pub scene_authored_pois: bool` to `Region` in
  `crates/simn-sim/src/region.rs`, with `#[serde(default)]` for
  snapshot back-compat.
- In `world_seed::seed_random_world_content`, regions with the
  flag true skip the per-region base + camp scatter pass.
  `RegionControl` + `PopulationTargets` still seed normally.
- `default_test_graph` flips the flag true on map_a..d. Real
  DEM maps (corbett, latourell, …) stay false.
- `systems::npc_spawn` (both `spawn_npcs` and `bulk_seed_npcs`)
  added a "skip regions with zero `Base` entities" gate. Without
  this guard, `pick_spawn_pos`'s no-bases fallback clusters
  every squad at origin in a 200 m radius and the O(N²) combat
  pass collapses the per-tick budget (~10+ min for what used to
  be 11 s; caught by `offline_combat` integration test).
- Tests: `crates/simn-sim/tests/scene_authored_gating.rs` (4
  tests). Eleven existing test files updated to use a
  `legacy_procedural_graph()` helper locally with the flag off
  for tests that exercise the procedural-scatter contract.

### Phase D ✅ landed (`6bed9ed7aa`)

**Editor POI baker tool.**
- New `godot/scripts/tools/poi_baker.gd` — `@tool class_name
  PoiBaker extends Node3D`. Designer attaches one per test_map
  scene under root.
- Inspector exports: `bake_seed`, `base_count`, `camp_count`,
  `rest_areas_per_base`, `extra_interaction_areas`, `factions`,
  `bake_extents`, `terrain3d_path`.
- Inspector buttons: **Bake POIs** (clears prior `BakedPOIs`
  child, creates fresh markers under it), **Clear baked POIs**.
- Placement: stratified 4×4 grid inside `bake_extents`, faction
  round-robin, per-faction `BaseKind` weighting that matches the
  world_seed procedural archetypes. Y-snap via
  `Terrain3D.get_height` (falls back to `TerrainNode.sample_height`
  then `0.0`).
- Per-base companion rest interaction area + extra
  free-form interaction areas cycling through canonical kinds.

### Phase E ✅ landed (`6bed9ed7aa`)

**GDScript caller: PoiMarker → Sim base_spawner.gd.**
- New `godot/scripts/world/base_spawner.gd` mirrors
  `loot_container_spawner.gd` from Phase 3D — walks
  `&"poi_markers"` group, filters `BASE_*` kinds, maps
  `PoiMarker3D::Kind` integers to `BaseKind` PascalCase strings
  + `PoiMarker3D::Faction` integers to `factions.toml` ids, and
  calls `Sim::register_authored_base` per marker.
- `test_map.gd::_on_terrain_ready` invokes
  `BaseSpawner.spawn_authored_bases(tree, region_id,
  terrain_node)` after terrain is ready so Y-snap works.
- Drive-by fix: typed `Array[Dictionary]` for the
  `attach_region_interaction_areas` and
  `load_region_terrain_with_obstacles` bridge calls — the
  gdext bridge rejected untyped `Array` at runtime.

### Phase F (this commit)

**Wire it up + walkthrough + iteration plan.**
- Added `PoiBaker` Node3D to each of `test_map_1.tscn`,
  `test_map_2.tscn`, `test_map_3.tscn`, `test_map_4.tscn` with
  default inspector settings and a per-map `bake_seed` matching
  the map number. No baked POIs committed yet — designer runs
  the **Bake POIs** button in editor and saves.
- New walkthrough: `docs/book/src/walkthroughs/test-map-authoring.md`.
- New iteration plan: this file
  (`docs/book/src/planning/sim-iteration-5-14-plan.md`).
- Linked the walkthrough from `SUMMARY.md` and the planning
  README.

**Designer steps (per test map):**
1. Open `godot/scenes/test/test_map_<N>.tscn`.
2. Select `Terrain3D` → click **Bake Now** (terrain regions
   seed from canonical).
3. Select `PoiBaker` → click **Bake POIs** (markers scatter
   into `BakedPOIs` child).
4. Save scene.

**Smoke test:** launch the game (Solo mode), spawn into map_a,
walk through a portal, watch the region transition. Squad
planner picks `Rest` objectives that target the authored rest
interaction areas. NPCs traverse the 2×2 region grid via the
existing portals at `±2000 m`.

## Critical files (final)

| File | Phase |
|---|---|
| `crates/simn-terrain/Cargo.toml` | A |
| `crates/simn-terrain/examples/generate_test_maps.rs` | A |
| `godot/assets/terrain/test_map_<N>/{heightmap.r32, terrain.toml}` | A |
| `crates/simn-sim/src/world/mod.rs` | B |
| `crates/simn-godot/src/sim/mod.rs` | B |
| `crates/simn-sim/tests/authored_bases.rs` | B |
| `crates/simn-sim/src/region.rs` | C |
| `crates/simn-sim/src/world_seed.rs` | C |
| `crates/simn-sim/src/systems/npc_spawn.rs` | C |
| `crates/simn-sim/tests/scene_authored_gating.rs` | C |
| `crates/simn-sim/tests/{accuracy_combat, authored_containers, factions, loot_containers, loot_restock, network_replay, npc_projectiles, npcs, offline_movement, pathfinding, terrain}.rs` | C |
| `godot/scripts/tools/poi_baker.gd` | D |
| `godot/scripts/world/base_spawner.gd` | E |
| `godot/scripts/test_map.gd` | E |
| `godot/scenes/test/test_map_<N>.tscn` (4 files) | F |
| `docs/book/src/walkthroughs/test-map-authoring.md` | F |
| `docs/book/src/planning/sim-iteration-5-14-plan.md` (this file) | F |
| `docs/book/src/architecture/crate-guide.md` | B / C |

## Verification end-to-end

1. **Phase A**: `cargo run --example generate_test_maps -p
   simn-terrain --release`. New canonical .r32 / .toml per map,
   heights 0–158 m (test_map_1), 0–131 m (test_map_2), 0–170 m
   (test_map_3), 0–140 m (test_map_4).
2. **Phase B**: `cargo test -p simn-sim --test authored_bases`
   — 4 tests green.
3. **Phase C**: `cargo test -p simn-sim` — full sim suite green
   (~49 result lines, 0 failures). Includes
   `scene_authored_gating.rs` and the legacy-graph migrations of
   the 11 dependent test files.
4. **Phase D**: open `test_map_1.tscn` in Godot, attach
   `PoiBaker`, click **Bake POIs**. Verify `BakedPOIs/Poi_<faction>_<idx>`
   children appear with gizmos. Re-click — old `BakedPOIs`
   cleared, fresh set created.
5. **Phase E**: run the game, spawn into map_a. Sim log shows
   `[test_map] registered N authored base(s)`. Tick a few
   seconds; squads form objectives matching the authored bases,
   not Y=0 origin clusters.
6. **Phase F**: walk between maps via portals, observe squad
   NPCs traversing. `mdbook build docs/book` clean. `cargo
   clippy --workspace -- -D warnings` clean.

## Out of scope (deferred)

- **Splatmap authoring for test maps.** Phase A keeps the
  default-biome fallback we landed iteration 5-13; varied biomes
  / forest cover come later.
- **Loot container migration.** Loot containers continue to
  anchor to bases via the existing path; once bases come from
  scene markers, loot anchors to those markers transparently.
- **NavObstacleMarker3D auto-bake.** The baker doesn't drop nav
  obstacle markers — those stay hand-placed since they encode
  designer-intent geometry (fences, walls).
- **POI roll-back to procedural.** If a developer wants to flip
  back to the procedural scatter, they set
  `scene_authored_pois = false` on the region in
  `default_test_graph` and re-bake; no UI-level toggle.
- **Per-region terrain themes via material.** Each test map
  shares `cascade_locks_material.tres`. Per-map material /
  biome authoring is a follow-up once a real palette lands.
- **Foliage scatters on test maps.** TreeScatter /
  RockScatter / GroundCoverScatter from cascade_locks aren't
  wired into the test maps yet.
