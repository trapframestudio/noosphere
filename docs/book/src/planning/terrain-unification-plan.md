# Terrain Unification — Terrain3D as Single Source of Truth

**Status:** plan
**Last updated:** 2026-05-26

## Problem

Two competing terrain systems cause height mismatches (9-25m drift):

1. **TerrainNode** (gdext Rust class, `simn-godot/src/terrain.rs`) —
   reads canonical `.r32` heightmap via `simn-terrain` crate. Provides
   `HeightMapShape3D` collision + visual mesh. Feeds sim's
   `TerrainMaps` resource for NPC Y-clamping and pathfinding.

2. **Terrain3D** (native C++ addon) — renders the actual visible terrain
   from per-region `.res` files. Player walks on this surface.
   Has `Terrain3DData.get_height()` for height queries + built-in
   collision support.

POIs, cover volumes, and NPCs use TerrainNode heights. The player
sees Terrain3D. Heights disagree by 9-25m → everything floats or
sinks.

## Goal

Terrain3D becomes the single terrain system. TerrainNode is removed.
All height queries — sim pathfinding, NPC Y-clamp, POI placement,
cover, foliage — use Terrain3D as their source.

## Scope

### What must change

| System | Current source | New source | Files |
|---|---|---|---|
| POI baker Y-snap | TerrainNode → T3D fallback | T3D.data.get_height() only | `poi_baker.gd` |
| Sim TerrainMaps | TerrainNode `.r32` via `attach_region_terrain` | T3D heightmap pushed via bridge | `test_map.gd`, `real_map.gd`, `simn-godot/src/sim/mod.rs` |
| NPC Y-clamp | `TerrainMaps::ground_at` (from `.r32`) | Same resource, fed from T3D data | `population.rs`, `terrain.rs` |
| Nav grid | Built from `.r32` heightmap | Built from T3D heightmap data | `nav.rs`, `population.rs` |
| Player collision | TerrainNode `HeightMapShape3D` | Terrain3D built-in collision | Scene nodes |
| Marker runtime snap | Mixed T3D/TN | T3D.data only | Marker `.gd` scripts |
| Foliage scatter | TerrainNode `sample_height` | T3D.data.get_height() | `tree_scatter.gd`, `rock_scatter.gd`, etc. |

### What stays

- `simn-terrain` crate — still useful for canonical heightmap
  baking tools, format definitions, and the `Heightmap` struct.
  The sim's `TerrainMaps` resource still wraps `Heightmap` internally;
  we just feed it data from Terrain3D instead of the `.r32` file.
- `simn-sim` internal terrain APIs — `ground_at`, `attach_region_terrain`,
  nav grid building. These are engine-agnostic and work with any
  heightmap data source.

## Phases

### Phase A — Bridge: push Terrain3D heights to sim

New `#[func]` on SimHost: `attach_region_terrain_from_terrain3d`.
Takes the Terrain3D node, reads its `data.get_height_maps()` to
extract a dense heightmap grid, constructs an `simn_terrain::Heightmap`
from the pixel data, and calls the existing
`Sim::attach_region_terrain_with_obstacles`.

This means the sim gets Terrain3D's height data in the same format
it already understands — no changes to `TerrainMaps`, `ground_at`,
nav grid, or `clamp_npc_terrain_y`.

**Files:**
- `crates/simn-godot/src/sim/mod.rs` — new bridge func
- `godot/scripts/test_map.gd` — call new func instead of old path
- `godot/scripts/real_map.gd` — same

### Phase B — Enable Terrain3D collision, remove TerrainNode from scenes

Terrain3D has built-in collision (enable via its inspector properties).
Once enabled, remove the TerrainNode node from every scene — the
player walks on Terrain3D's collision instead.

**Files:**
- All 23 `.tscn` files (19 maps + 4 test maps)
- `crates/simn-godot/src/terrain.rs` — keep the code (it's the
  `simn-terrain` bridge) but `TerrainNode` stops being instantiated

### Phase C — Update GDScript height queries

Replace all `terrain.sample_height(x, z)` calls with
`terrain3d.data.get_height(Vector3(x, 0, z))` in:
- `test_map.gd`
- `real_map.gd`
- `base_spawner.gd`
- `loot_container_spawner.gd`
- Foliage scatters (tree, rock, ground cover, trash)
- `poi_baker.gd` (already done)
- Marker scripts (already done)

### Phase D — Clean up

- Remove `terrain_node_path` export from any remaining scripts
- Remove `TerrainNode` class registration from `simn-godot` lib.rs
  (or keep but mark deprecated)
- Update CLAUDE.md terrain critical rules
- Update `docs/book/src/walkthroughs/terrain3d.md`

## Verification

1. Build: `cargo clippy --workspace -- -D warnings`
2. Tests: `cargo test -p simn-sim` (terrain tests may need update)
3. Editor: open test_map_1, bake POIs → verify Y matches T3D surface
4. Runtime: load game → POIs/cover/NPCs sit on visible terrain
5. Player physics: walk/jump → collision works on T3D surface
6. Foliage: trees/rocks still sit on terrain (not floating)
