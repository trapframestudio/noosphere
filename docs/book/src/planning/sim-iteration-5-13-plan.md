# Iteration 5-13 — Nav Pipeline + Interaction Areas

**Status:** Phase A shipped (paint pipeline → sim → e2e + walkthrough); Phases B / C / D in flight.
**Last updated:** 2026-05-21
**Scope:** designer-paintable nav data via Terrain3D, programmatic POI obstacle stamping, a sparse waypoint graph that lets the offline tier path through painted/stamped overrides instead of bee-lining, **and** placeable interaction-area markers (rest spots, work spots, generic "do X here" descriptors) that give NPCs more instructions for what to do at POIs. Replaces *task #18 (Navmesh pipeline)* and *task #17 (POI obstacle stamp)* and bundles in the new "POI interaction areas" ask as Phase D.

This doc retires once Phase D ships; until then it's the authoritative iteration plan for the nav-pipeline + interaction-areas arc.

---

## Why this exists

After iteration 5-12 the sim has working online pathfinding (uniform-grid A*, `crates/simn-sim/src/nav.rs::GridNavQuery`) built from heightmap slope + `FeatureClass`. It also has a working offline tier that *moves* NPCs between bases. Three gaps remain:

1. **No designer overrides.** Heightmap-only nav has two failure modes the sim can't fix on its own: false negatives where slope or `FeatureClass::Cliff` blocks a cell the designer wants walkable (goat paths, fords); and false positives where geometrically open terrain is intentionally off-limits (fenced compound interior, story-critical no-go, ravine floors that are nominally flat but uninteresting). Today there's no surface for a designer to say "yes, NPCs walk here" or "no, NPCs do not enter here."
2. **No hand-placed obstacle stamping.** Buildings, fences, jersey barriers, dropped trucks, POI props with footprints don't appear in the heightmap-derived nav. NPCs walk through them.
3. **Offline tier ignores nav entirely.** `crates/simn-sim/src/offline_tier.rs::offline_movement` bee-lines between Base positions; `pick_offline_target` filters by region + faction, never by reachability. An offline NPC will happily walk through a cliff or a lake when the player isn't looking. Once we add painted blocks this gets worse: the offline tier picks blocked bases as targets and freezes.

The user's framing for this iteration: **paint nav data in Terrain3D in Godot, then have that data accurately reflect to the sim for both online and offline simulations.** All three gaps above are in scope; the fix composes cleanly with the existing `GridNavQuery` and with the eventual indoor `NavigationRegion3D` work tracked in [`npc-traversal-plan.md`](npc-traversal-plan.md) §2.

Phase ordering reflects what blocks what: the sim-side data path (Phase A) is the spine; POI stamping (Phase B) layers in via the same `nav_mask` infrastructure; the offline waypoint graph (Phase C) consumes the painted/stamped grid to give offline NPCs real pathing.

---

## Architectural decisions (locked)

These were settled before the plan was approved; capturing them here so a fresh implementer doesn't re-litigate.

- **Three-state override per cell**, not a single bit. The enum is `NavOverride { Default = 0, ForceBlocked = 1, ForceWalkable = 2 }`. Covers both heightmap-nav failure modes (false-negative AND false-positive). Storage cost = one byte per nav cell; merge logic is two `if` branches at grid-build time.
- **Painter authoring**: two dedicated Terrain3D slots (slot 14 = `nav_block`, slot 15 = `nav_walkable`). Either non-zero weight → byte set. If both are painted on the same cell, **block wins** (safer default; matches the conservative direction for AI behavior).
- **Bundled with task #17 (POI obstacle stamping).** Designer paint and programmatic POI stamps go into the same conceptual layer (the override). POI stamping never persists to the canonical file — it merges *in memory* at `attach_region_terrain` time. The merge rule: POI `block` overlays cells unless the painter declared `ForceWalkable` (painter wins, because designer intent is the more deliberate signal). POI `walkable` is permitted but rare (mainly for fords / catwalks attached to a placed structure).
- **Offline tier gets a real sparse waypoint graph**, not just gate-by-cell. Built at `attach_region_terrain` time from the walkable cells. Stored alongside `GridNavQuery` in `NavQueries`. Offline NPCs path along it instead of bee-lining.
- **Canonical file `nav_mask.r8`** lives in `godot/assets/terrain/<map_id>/` next to `features.r8`. Same row-major NW-up convention, same blake3-validated load pattern. Optional — absent file is "no overrides anywhere."
- **No live re-bake on paint.** `GridNavQuery` rebuilds only on `attach_region_terrain`. Designer paints, hits **Sync to Canonical**, restarts the sim (or triggers a region detach/attach cycle from the dev panel). Live rebuild is out of scope; it's deferred until the broader cover-system invalidation work lands.
- **No snapshot of nav grid or waypoint graph.** Both are content, rebuilt from `Heightmap` + `nav_mask.r8` on every attach. Same persistence contract as the existing nav grid (Phase 1 of `npc-traversal-plan.md`).
- **Determinism over flexibility.** Two same-seed sims attaching the same map produce identical nav grids and waypoint graphs. The bake step is deterministic. No floating-point gradient noise driving cell selection.

---

## Format: `nav_mask.r8`

Single canonical file per map.

- **Path**: `godot/assets/terrain/<map_id>/nav_mask.r8`.
- **Layout**: raw bytes, `W * H` length, row-major, NW-major. Same orientation as `features.r8` and `heightmap.r32`. Dimensions match `TerrainMetadata.width` × `TerrainMetadata.height`.
- **Byte values**:
  - `0` → `NavOverride::Default` (defer to slope + feature class).
  - `1` → `NavOverride::ForceBlocked`.
  - `2` → `NavOverride::ForceWalkable`.
  - any other value → `Default` + one `tracing::warn_once` log naming the unknown byte and the offending offset (drift insurance against future schema extensions).
- **No header.** Length is `width * height`; format version + blake3 hash live in `terrain.toml`.
- **Absent file with `nav_mask_blake3 == ""`** = no overrides. Loader sets `Heightmap.nav_mask = None`. Existing maps (and the test maps) continue to work unchanged.

`terrain.toml` extension:

```toml
# existing fields …
nav_mask_format_version = 1
nav_mask_blake3 = "<blake3 hex of nav_mask.r8>"
```

Both new fields are `#[serde(default)]` on the Rust side (`0` and `""`) so every shipped `terrain.toml` parses without edits.

---

## Type contracts

These are the load-bearing types a fresh implementer needs to know. They land in Phase A1 + B2 + C1.

```rust
// crates/simn-terrain/src/nav_mask.rs  (Phase A1)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NavOverride {
    Default = 0,
    ForceBlocked = 1,
    ForceWalkable = 2,
}

pub const NAV_MASK_FORMAT_VERSION: u8 = 1;

pub fn decode(b: u8) -> NavOverride {
    match b {
        0 => NavOverride::Default,
        1 => NavOverride::ForceBlocked,
        2 => NavOverride::ForceWalkable,
        _ => { /* warn_once + */ NavOverride::Default }
    }
}
```

```rust
// crates/simn-terrain/src/heightmap.rs  (Phase A1)
pub struct Heightmap {
    // … existing fields …
    /// Phase A1: optional per-cell `NavOverride` mask. `None` for maps
    /// without authored overrides; `Some(bytes)` when `nav_mask.r8`
    /// loaded successfully. Length = `width * height` when present.
    nav_mask: Option<Vec<u8>>,
}

impl Heightmap {
    /// `Default` when the mask is absent or the offset is OOB.
    pub fn nav_override_at(&self, col: usize, row: usize) -> NavOverride { /* … */ }
}
```

```rust
// crates/simn-sim/src/nav.rs  (Phase B2 + C1)
pub struct NavObstacle {
    pub center: [f32; 2],   // world-space XZ
    pub extents: [f32; 2],  // half-size XZ
    pub kind: NavOverride,  // ForceBlocked or ForceWalkable (Default rejected)
}

pub struct WaypointGraph {
    pub nodes: Vec<[f32; 2]>,                    // world-space XZ
    pub edges: HashMap<u32, Vec<(u32, f32)>>,    // node_idx → (neighbor_idx, dist)
}

impl WaypointGraph {
    pub fn build_from_grid(grid: &GridNavQuery, spacing_m: f32) -> Self;
    pub fn nearest_node(&self, pos_2d: [f32; 2]) -> Option<u32>;
    pub fn path(&self, start: u32, goal: u32) -> Option<Vec<u32>>;
}

impl GridNavQuery {
    /// Phase B2: stamp obstacles into the in-memory grid. Merge rule:
    /// painter `ForceWalkable` wins over POI `block`; POI `walkable`
    /// overwrites the cell regardless. Painter `ForceBlocked` and POI
    /// `block` are both blocks (no precedence needed).
    pub fn apply_obstacles(&mut self, obstacles: &[NavObstacle]);
}
```

```rust
// crates/simn-sim/src/offline_tier.rs  (Phase C2 schema additions)
pub struct OfflineNpc {
    // … existing fields …
    /// Phase C2: resolved waypoint-graph path from `travel_start_2d` to
    /// `target_2d`. Indices into the per-region `WaypointGraph.nodes`.
    /// Empty when bee-lining (no graph available or single-cell hop).
    #[serde(default)]
    pub waypoint_chain: Vec<u32>,
    #[serde(default)]
    pub waypoint_chain_idx: u32,
}
```

---

## Phase A — Paint pipeline → sim consumes (online)

**Goal:** an authored `nav_mask.r8` flows from Terrain3D paint → canonical file → `Heightmap::load` → `GridNavQuery::from_heightmap`. Online NPCs reroute around painted blocks on the very next tick after `attach_region_terrain`. Offline tier untouched in this phase.

### A1 — Sim-side data path

Smallest meaningful slice — proves the data model without touching the editor.

**Scope.**
- `crates/simn-terrain/src/nav_mask.rs` (new): `NavOverride` enum, `NAV_MASK_FORMAT_VERSION`, `decode(b: u8)` per the contracts above.
- `crates/simn-terrain/src/metadata.rs`: add `#[serde(default)] pub nav_mask_format_version: u8`, `#[serde(default)] pub nav_mask_blake3: String` to `TerrainMetadata`.
- `crates/simn-terrain/src/heightmap.rs`:
  - `Heightmap` gains private `nav_mask: Option<Vec<u8>>` field.
  - `Heightmap::load` reads `nav_mask.r8` best-effort (mirror the `features.r8` load: length check vs metadata, blake3 check vs metadata, on mismatch return `Err` with the same "hash mismatch" / "size mismatch" message shape).
  - Public `pub fn nav_override_at(&self, col: usize, row: usize) -> NavOverride`. Returns `Default` when `nav_mask.is_none()` or `(col, row)` OOB.
- `crates/simn-sim/src/nav.rs::GridNavQuery::from_heightmap`: per cell, query `heightmap.nav_override_at(col, row)` and apply:
  - `Default` → existing `cell_passable(...)` logic.
  - `ForceBlocked` → `cells[idx] = false` regardless of slope / feature class.
  - `ForceWalkable` → `cells[idx] = true` regardless.
  - `cell_class` byte stays as-is so `TravelStyle::cell_cost_mult` keeps working (a road-hugger still prefers the forced-walkable cell if it sits on `PavedRoad`).
- Add `cell_override: Vec<u8>` field to `GridNavQuery` caching the raw byte per cell. Needed by Phase B2's merge rule (so `apply_obstacles` can re-check the painter's intent without re-querying the heightmap).

**Tests** (`crates/simn-sim/src/nav.rs::tests`).
- Extend the `flat_heightmap(...)` helper to accept `Option<Vec<u8>>` for the mask.
- `nav_mask_force_block_routes_around` — paint a vertical wall, query path, assert detour.
- `nav_mask_force_walkable_overrides_cliff` — synthesize a `Cliff` feature row, paint `ForceWalkable`, assert the cell is passable.
- `nav_mask_absent_is_noop_back_compat` — `Heightmap` with `nav_mask = None` produces the same grid as the pre-A1 build (regression guard).

**Acceptance.**
- `cargo test -p simn-terrain` + `cargo test -p simn-sim --test pathfinding --lib nav` green.
- `cargo clippy --workspace -- -D warnings` clean.
- Existing `terrain.toml` files load without edits (the two new fields default to `0` / `""`).

**Files touched.** `crates/simn-terrain/src/{nav_mask.rs (new), metadata.rs, heightmap.rs, lib.rs}`, `crates/simn-sim/src/nav.rs`.

### A2 — Terrain3D exporter + bake binary write `nav_mask.r8`

Wires the painted data to disk and round-trips it back to Terrain3D.

**Scope.**
- `godot/scripts/terrain/terrain3d_exporter.gd::export_canonical()`:
  - In the splat-build loop, accumulate per-cell bytes into a `PackedByteArray` of length `W * H`.
  - Slot 14 (`nav_block`) with any nonzero weight on the cell → byte `1` (`ForceBlocked`).
  - Slot 15 (`nav_walkable`) with any nonzero weight on the cell → byte `2` (`ForceWalkable`).
  - Both painted on the same cell → byte `1` (block wins).
  - Stage `nav_mask.r8.tmp`, atomic-rename to `nav_mask.r8`. Recompute blake3 via the existing `TerrainHash` helper.
  - Extend `_rewrite_toml` to write `nav_mask_format_version = 1` + `nav_mask_blake3 = "<hex>"`.
- Rename slot 14 and 15 in the project's Terrain3D asset list to `nav_block` and `nav_walkable` (visible to designers in the paint palette). Document the rename in the walkthrough.
- `crates/simn-terrain/src/bake.rs::bake_map`: when building canonical from a DEM, write an all-zeros `nav_mask.r8` + matching blake3 + `nav_mask_format_version = 1` in `terrain.toml` so freshly baked maps are self-consistent on first load (no missing-file warnings).
- ~~`godot/scripts/terrain/terrain3d_loader.gd` (the reverse path — re-seed Terrain3D regions from canonical when a designer deletes a `regions/*.res` file): read `nav_mask.r8` if present and stamp slot 14 / 15 weights into the control word for any nonzero cell. Round-trip completeness so paint isn't lost when regions are re-seeded from canonical.~~ **Deferred from v1.** The loader's existing `_variant_for` noise pass auto-assigns slots 14 and 15 to decoration variants (`nordic_moss`, `mine_rock_wall`) — co-opting those slots for nav requires retiring or relocating two visual variants and providing distinct textures, which is an art-pass / asset-tuning change rather than a code change. Documented limitation for v1: nav painting is **one-way** (Terrain3D → canonical). Designers should keep their `regions/*.res` files; deleting them and re-seeding from canonical loses painted nav overrides. A follow-up iteration that adds visual nav-paint textures + restricts decoration variants to slots 11–13 closes the loop.

**Tests.**
- Integration test in `crates/simn-terrain/tests/nav_mask_io.rs`: bake a tiny map (use the existing `tools/bakes/test_map.toml` fixture if one exists, else build one inline), mutate one byte of `nav_mask.r8` on disk, reload via `Heightmap::load`, assert a `Err` with `"nav_mask_blake3"` in the message. Mirrors the existing `features.r8` integrity-check test.
- Bake-binary smoke: `cargo run -p simn-terrain --bin bake_map -- <fixture>` succeeds and produces `nav_mask.r8` of `width * height` zero bytes.

**Acceptance.**
- `cargo test -p simn-terrain` green.
- `cargo run -p simn-terrain --bin bake_map -- tools/bakes/<existing>.toml` produces a self-consistent map.
- Headless Godot opens the project without GDScript parse errors after the exporter / loader changes: `godot --headless --quit --path godot 2>&1 | grep -i error` is empty.

**Files touched.** `godot/scripts/terrain/{terrain3d_exporter.gd, terrain3d_loader.gd}`, `crates/simn-terrain/src/bake.rs`, `crates/simn-terrain/tests/nav_mask_io.rs` (new).

### A3 — End-to-end paint → A* routes around test + designer walkthrough

Closes Phase A with a runnable demonstration + the docs a designer needs.

**Scope.**
- `crates/simn-sim/tests/nav_mask_e2e.rs` (new): build a 32×32 flat `Heightmap`, hand-construct an `nav_mask` `Vec<u8>` that blocks a corridor (column 16, rows 5..25), call `Sim::attach_region_terrain`, query `path_in_region` from `(0, 0, 0)` to `(60, 0, 0)`, assert the returned waypoints route around the blocked column (no waypoint with `x ≈ 32 m` and `z` in the blocked range).
- `docs/book/src/walkthroughs/terrain3d-nav-paint.md` (new): designer recipe.
  - "Paint slot 14 over cells NPCs must avoid; paint slot 15 over cells NPCs must enter regardless of slope/water."
  - "Click **Sync to Canonical** on the `Terrain3DBaker` node. Exporter writes `nav_mask.r8` + updates `terrain.toml`."
  - "Restart the sim or use the dev panel to detach + reattach the region. Online NPCs reroute on the next tick."
  - "If you delete a `regions/*.res` file and re-seed from canonical, slot 14/15 paint comes back from `nav_mask.r8`."
- `docs/book/src/planning/npc-traversal-plan.md`: append a "Phase 2A — designer-painted outdoor overrides" section linking this iteration plan + the walkthrough. (See "Cross-doc updates" below for the exact text.)

**Acceptance.**
- `cargo test -p simn-sim --test nav_mask_e2e` green.
- `mdbook build docs/book` clean.
- A docs-keeper pass confirms cross-links resolve.

**Files touched.** `crates/simn-sim/tests/nav_mask_e2e.rs` (new), `docs/book/src/walkthroughs/terrain3d-nav-paint.md` (new), `docs/book/src/planning/npc-traversal-plan.md`, `docs/book/src/SUMMARY.md` (link the walkthrough).

---

## Phase B — POI obstacle stamping (task #17 bundled in)

**Goal:** designers and procedural placement systems can drop physical obstacles (buildings, fences, barriers, props with footprints) into a region and have them appear in the nav grid without re-baking the canonical `nav_mask.r8`. POI obstacles live as scene markers; the bridge enumerates them on map load and the sim stamps them into the in-memory grid at attach time.

### B1 — Obstacle authoring surface

**Scope.**
- `godot/scripts/world/nav_obstacle_marker.gd` (new), modeled on `godot/scripts/world/loot_container_marker.gd`:
  - `extends Node3D`.
  - `@export var extents: Vector3 = Vector3(1.0, 1.0, 1.0)` — half-size AABB. Y is ignored (nav is 2D); kept for editor-gizmo readability.
  - `@export_enum("block", "walkable") var override_kind: String = "block"`.
  - On `_enter_tree`, joins the group `&"nav_obstacle_markers"`.
  - Editor gizmo via `_process` + `_get_property_list` to mirror `loot_container_marker`'s scaffolding — wireframe AABB visible in the editor at the marker's transform.
- **No `.tscn` fixture** — `class_name NavObstacleMarker3D` registration is enough for the "Add Node" search to find it (same pattern as `LootContainerMarker3D`). Designers `Ctrl+A` → search "NavObstacleMarker3D" → drop.
- Document the marker in the walkthrough (one paragraph: "drop a NavObstacleMarker, set extents, set override_kind = block for buildings / fences / etc.").

**Tests.** Not directly testable from Rust; covered by the integration test in B2.

**Files touched.** `godot/scripts/world/nav_obstacle_marker.gd` (new), `godot/scenes/world/nav_obstacle_marker.tscn` (new), `docs/book/src/walkthroughs/terrain3d-nav-paint.md` (append).

### B2 — Bridge enumeration + sim stamp

**Scope.**
- `crates/simn-sim/src/nav.rs`:
  - `pub struct NavObstacle` per the type contract above.
  - `impl GridNavQuery { pub fn apply_obstacles(&mut self, obstacles: &[NavObstacle]); }` — walks each obstacle's AABB → cell indices → flips per the merge rule. The merge consults `cell_override[idx]` (cached in A1):
    - POI `ForceBlocked` ⇒ `cells[idx] = false` unless `cell_override[idx] == ForceWalkable as u8`.
    - POI `ForceWalkable` ⇒ `cells[idx] = true` always (rare; intended for catwalk overlays attached to placed structures).
- `crates/simn-sim/src/world/mod.rs`:
  - New `pub fn attach_region_terrain_with_obstacles(&mut self, region: RegionId, heightmap: Heightmap, obstacles: &[NavObstacle]) -> Result<()>` that calls `NavQueries::build_for(region, heightmap)` then `query.apply_obstacles(obstacles)`.
  - Keep the existing `attach_region_terrain` as a thin wrapper that calls the new variant with `&[]` so back-compat is preserved everywhere.
- `crates/simn-godot/src/sim/mod.rs`:
  - New `#[func] attach_region_terrain_with_obstacles(region_name: GString, obstacles: Array<Dictionary>)`. Each dict carries `pos: Vector3`, `extents: Vector3`, `override_kind: String`. Decodes into `Vec<NavObstacle>` then calls the sim method.
  - Existing `attach_region_terrain` keeps its signature (Godot-side back-compat); a separate callable for the obstacle-aware variant.
- Godot-side caller: extend the existing map-load path (likely in `game_session.gd` or wherever `load_region_terrain` is currently called) to walk `get_tree().get_nodes_in_group(&"nav_obstacle_markers")`, filter by region (containment in the region's AABB or by `region` metadata on the marker — pick one and document it), build the dictionary array, call the new `#[func]`.
  - **B2 v1 wires the bridge surface only.** The Godot-side walker is deferred until production maps actually drop `NavObstacleMarker3D` nodes (task #16's job, or the first per-map authoring pass). Calling `load_region_terrain` (the back-compat path) is equivalent to calling `load_region_terrain_with_obstacles` with an empty array, so no caller changes break.

**Tests** (`crates/simn-sim/src/nav.rs::tests`).
- `poi_block_overlays_walkable_cells` — flat heightmap, no painter mask, apply one `ForceBlocked` obstacle covering a 2-cell strip; assert the cells flip to blocked.
- `painter_force_walkable_wins_over_poi_block` — paint a cell `ForceWalkable`, apply a POI `block` over the same cell; assert the cell stays walkable.
- `poi_block_propagates_through_aabb_cells` — apply an obstacle with extents = (4, _, 4) (so it covers a 4×4 cell block at 2 m cells); assert all 16 cells flipped.
- Optionally: `poi_walkable_creates_catwalk` — synthesize a Cliff feature row, apply POI `walkable`, assert the row becomes passable.

**Acceptance.**
- `cargo test -p simn-sim` green.
- `cargo clippy --workspace -- -D warnings` clean.
- The new bridge function is callable from GDScript without a parse error.

**Files touched.** `crates/simn-sim/src/nav.rs`, `crates/simn-sim/src/world/mod.rs`, `crates/simn-godot/src/sim/mod.rs`, `godot/scripts/<map-loader>.gd` (whichever file calls `attach_region_terrain`).

---

## Phase C — Offline tier waypoint graph

**Goal:** offline NPCs path along a sparse waypoint graph derived from the walkable cells, instead of bee-lining between Base positions. They avoid painted/stamped blocks; they pick reachable target bases; their visible position (when projected back to online) lands somewhere that makes geographic sense given the painted geometry.

### C1 — Build + store

**Scope.**
- `crates/simn-sim/src/nav.rs`:
  - `pub struct WaypointGraph { nodes: Vec<[f32; 2]>, edges: HashMap<u32, Vec<(u32, f32)>> }` per the type contract.
  - `pub fn WaypointGraph::build_from_grid(grid: &GridNavQuery, spacing_m: f32) -> Self`:
    - Sample walkable cells on a uniform stride (every `spacing_m / cell_size_m` cells, round up). Default `spacing_m = 32.0` (16 cells at 2 m). Each sample that's walkable becomes a node at the cell's world-XZ center.
    - For each node, attempt edges to its 8 grid-neighbors at the same stride. Bresenham-trace between the two node cells on the underlying nav grid; if every intermediate cell is walkable, add a bidirectional edge with cost = straight-line distance. Otherwise no edge.
    - Result: per-region graph with `O((W/16) * (H/16))` nodes and up to 8× as many edges. For a 1000×1000 grid → ~62 × 62 = ~3.8k nodes, ~30k edges. Build cost: a few hundred Bresenham traces, well under 100 ms even on a cold cache.
  - `pub fn nearest_node(&self, pos_2d: [f32; 2]) -> Option<u32>` (linear scan; nodes-per-region is small enough this is fine).
  - `pub fn path(&self, start: u32, goal: u32) -> Option<Vec<u32>>` using the existing `pathfinding` crate's `astar` against the edges.
  - `pub fn reachable(&self, start: u32, goal: u32) -> bool` — cheap BFS short-circuit when `pick_offline_target` only needs the yes/no.
- `crates/simn-sim/src/resources.rs::NavQueries`:
  - Add `waypoints: HashMap<RegionId, Arc<WaypointGraph>>` alongside the existing `by_region: HashMap<RegionId, Arc<GridNavQuery>>`.
  - Extend `build_for(region, heightmap)` to also call `WaypointGraph::build_from_grid` and stash the result.
  - Public getter `get_waypoints(region) -> Option<&Arc<WaypointGraph>>`.

**Tests.**
- `waypoint_graph_connects_adjacent_nodes_on_open_grid` — flat 32×32 grid, build with `spacing_m = 8.0`; assert all 4×4 = 16 nodes mutually reachable.
- `waypoint_graph_skips_pairs_with_blocked_cell_between` — paint a vertical wall between two nodes; assert no direct edge, but a multi-hop path exists.
- `waypoint_graph_handles_islands` — two disjoint walkable regions; assert `reachable` returns false across the gap.
- `waypoint_graph_size_under_budget_on_large_grid` — guard against accidental quadratic blowup; e.g. on a 500×500 grid, node count ≤ 1k and build time < 100 ms.

**Files touched.** `crates/simn-sim/src/nav.rs`, `crates/simn-sim/src/resources.rs`.

### C2 — `offline_movement` consults the graph

**Scope.**
- `crates/simn-sim/src/offline_tier.rs`:
  - `OfflineNpc` gains `#[serde(default)] pub waypoint_chain: Vec<u32>` + `#[serde(default)] pub waypoint_chain_idx: u32` per the contract.
  - `pick_offline_target` gains a `nav: &NavQueries` parameter. After pool selection, filter candidates by `WaypointGraph::reachable(start_node, candidate_node)`. If filter empties the pool, fall back to the unfiltered pool with `tracing::warn_once` per region (so a stranded NPC still picks *something* rather than freezing).
  - `offline_movement`:
    - When picking a new target, also resolve `WaypointGraph::path(start_node, goal_node)`. Store the chain in `waypoint_chain` + `waypoint_chain_idx = 0`. Compute total chain length in meters; set `arrival_offline_tick` to current offline tick + ceil(length / OFFLINE_WALK_SPEED_M_PER_S / OFFLINE_TICK_SECONDS).
    - When advancing toward a target with a non-empty `waypoint_chain`, interpolate between `nodes[chain[idx]]` and `nodes[chain[idx + 1]]`; on segment arrival, advance `waypoint_chain_idx`. On chain exhaustion, clear `target_2d` (existing behavior continues).
    - When the chain is empty (no graph or single-cell hop), keep the existing bee-line code path as a fallback so the system is robust against future regressions / missing data.
- Plumb `&NavQueries` into the `offline_movement` system signature (it's already `Res<X>` plumbing in Bevy ECS — small change).

**Tests** (`crates/simn-sim/src/offline_tier.rs::tests` + a new integration test).
- `offline_npc_routes_around_painted_block` — paint a vertical block between Base A and Base B, spawn an offline NPC near A targeting B, tick offline movement, assert the NPC's `position_2d` traces a path *around* the block instead of through it (sample positions, verify they avoid the blocked cells).
- `offline_npc_picks_reachable_base` — paint a block isolating Base C from Base A; assert offline NPC at A targets B (reachable) not C (unreachable).
- `offline_npc_stranded_falls_back` — synthesize a setup where no candidate is reachable; assert the NPC picks *some* target and emits the warn-once log (via a test logger).
- Snapshot round-trip: deserialize an `OfflineNpc` snapshot written before C2 (no `waypoint_chain` field); assert it loads with `waypoint_chain = vec![]`, `waypoint_chain_idx = 0`.

**Acceptance.**
- `cargo test -p simn-sim` green (including `--include-ignored` for the existing long-running offline-tier scenarios fixed in iteration 5-12).
- Determinism harness still passes: `cargo test -p simn-sim --test determinism` green.
- Snapshot round-trip from a pre-C2 sim binary into a post-C2 sim binary loads without errors.

**Files touched.** `crates/simn-sim/src/nav.rs` (paths on `WaypointGraph`), `crates/simn-sim/src/offline_tier.rs`, `crates/simn-sim/src/world/mod.rs` (system schedule wiring if needed).

---

## Phase D — Placeable interaction areas

**Goal.** Designers drop scene-placed `InteractionAreaMarker3D` nodes (kind string, extents, capacity, faction) and the sim consumes them as queryable interaction points. NPCs can be directed to a specific area via existing `SquadObjective::Rest`-style mechanics extended with an `area_id`. Arrival increments occupancy, an `Interaction` world event fires, NPC stays for a duration, departure decrements occupancy.

**v1 scope (minimal):** no new objective kinds. Reuse `Rest` / `Guard` / `Investigate` with `area_id` parameterization. New objective kinds (`Work`, `Socialize`) and per-personality routing (lazy → rest-prefer, hardworking → work-prefer) deferred to a follow-up iteration.

**Locked design decisions** (per the mid-iteration plan-mode round):
- **Dedicated marker class** (`InteractionAreaMarker3D`), not an extension of `PoiMarker3D`. PoiMarker's `Kind` enum already carries 18 values; growing it for interactions would make it the catch-all marker. Lower coupling, easier to evolve.
- **Free-form `interaction_kind: String`** (extensible, modder-friendly). Sim recognizes a canonical set (`"rest"`, `"work"`, `"socialize"`, `"scavenge"`, `"guard_post"`, `"patrol_node"`, `"campfire"`, `"workbench"`); unknown kinds resolve to a generic "visit" with low utility — designers can invent new kinds without code changes.
- **Capacity + faction supported** on the marker. Per-area occupancy counter tracks `reserve` / `release` calls; the resource enforces capacity.
- **Persistence is transient** — like `NavQueries`, the resource is content rebuilt from scene markers on each region attach. No snapshot of `InteractionAreas`.

### D1 — Marker authoring

**Scope.**
- `godot/scripts/world/interaction_area_marker.gd` (new), modeled on `loot_container_marker.gd`. `@tool class_name InteractionAreaMarker3D extends Node3D`.
  - `@export var interaction_kind: String = "rest"`
  - `@export var extents: Vector3 = Vector3(1.5, 0, 1.5)` — XZ footprint half-size; Y ignored
  - `@export var capacity: int = 1`
  - `@export var faction: String = ""` — empty = any
  - `@export var area_id: String = ""` — auto-derived from scene path + node name when empty
  - `@export var tags: Dictionary = {}`
  - `@export var show_debug_visual: bool = true`
  - Group `&"interaction_area_markers"`
  - Editor gizmo: BoxMesh wireframe (size = `extents * 2`) + Label3D billboard showing `interaction_kind`. Color-coded by canonical kind (rest=green, work=blue, generic=gray).
- **No `.tscn` fixture** — `class_name InteractionAreaMarker3D` registration suffices, same pattern as `NavObstacleMarker3D` and `LootContainerMarker3D`. Designers add via "Add Node" search.

**Tests.** Not directly testable from Rust; covered by D3.

**Files touched.** `godot/scripts/world/interaction_area_marker.gd` (new), `godot/scenes/world/interaction_area_marker.tscn` (new).

### D2 — Bridge enumeration + sim resource ✅ landed

**Status (2026-05-21).** Shipped. `InteractionArea` +
`InteractionAreas` live in `crates/simn-sim/src/resources.rs`;
`Sim::{attach_region_interaction_areas, reserve_interaction_area,
release_interaction_area, interaction_areas_in_region}` in
`world/mod.rs`; bridge `#[func] attach_region_interaction_areas`
in `simn-godot/src/sim/mod.rs` with the
`parse_interaction_areas` helper. GDScript callers added to
`real_map.gd` + `test_map.gd` (the per-map `_request_region_terrain`
path); group `&"interaction_area_markers"` walked on map load.
Five `interaction_areas.rs` tests cover registration, capacity,
release, faction filter, duplicate-id last-wins.
**Deviation from plan.** GDScript caller landed in the per-map
scripts (`real_map.gd` / `test_map.gd::_request_region_terrain`)
rather than `game_session.gd::_enter_region` — both maps already
own the per-region terrain enumeration so it sits naturally
next to `_collect_nav_obstacles`. Same end-effect.

**Scope.**
- `crates/simn-sim/src/resources.rs`: new `InteractionArea` + `InteractionAreas` (per the type contract block below). Default-initialized resource inserted at sim construction; lifecycle matches `NavQueries`.
- `crates/simn-sim/src/world/mod.rs`: new methods
  - `Sim::attach_region_interaction_areas(region, areas: Vec<InteractionArea>)` — clears + replaces the region's set; rebuilds `by_id` index.
  - `Sim::reserve_interaction_area(area_id, faction) -> bool` — increments occupancy if capacity allows AND faction matches (empty area faction matches any). Returns false on rejection.
  - `Sim::release_interaction_area(area_id)` — decrements occupancy; saturates at zero.
- `crates/simn-godot/src/sim/mod.rs`: new `#[func] attach_region_interaction_areas(region_name, areas: Array<Dictionary>)`. Each dict carries `id: String, kind: String, pos: Vector3, extents: Vector3, faction: String, capacity: int, tags: Dictionary`. Decodes into `Vec<InteractionArea>`, resolves the region id from `region_name`, calls the sim method.
- Godot caller in `game_session.gd::_enter_region`: walks `get_tree().get_nodes_in_group(&"interaction_area_markers")`, filters by region (containment via the same pattern Phase B2 uses for `nav_obstacle_markers`), builds the dict array, calls the new `#[func]`.

**Tests** in `crates/simn-sim/tests/interaction_areas.rs` (new):
- `register_and_query_areas` — attach three areas; verify `by_region` count + `by_id` resolution.
- `reserve_respects_capacity` — capacity=2 area accepts 2 reservations, rejects the 3rd.
- `release_frees_slot` — after capacity reached + a release, the next reserve succeeds.
- `faction_filter` — area with `faction = "pwa"` rejects reserve with `FactionId(looters)` (negative) and accepts `FactionId(pwa)` (positive).

**Files touched.** `crates/simn-sim/src/resources.rs`, `crates/simn-sim/src/world/mod.rs`, `crates/simn-godot/src/sim/mod.rs`, `godot/scripts/game_session.gd` (the existing map-load path).

### D3 — Squad picks rest areas + InteractionStarted/Ended events ✅ landed

**Status (2026-05-21).** Shipped.
`SquadObjective::Rest::area_id: Option<String>` field added,
`build_rest` consults a new `pick_rest_area` helper that filters
the per-region `InteractionAreas` set on `kind == "rest"` +
faction match + free capacity + 150 m radius (constant
`REST_INTERACTION_AREA_PREFER_RADIUS_M`). Reserve/release
lifecycle is symmetric — the planner reserves on assignment and
releases on objective swap (cohesion override, expiration,
squad death). `WorldEventKind::{InteractionStarted, InteractionEnded}`
variants added; `tick_npc_goals` emits Started on first
arrival per (npc, area) via the `InteractionAreas.started`
dedupe set; the planner emits Ended for every Started NPC on
objective swap.
**Deviation from plan.** Two follow-ups deferred: (1) PDA log
toast bridging — the events flow on the world-event bus
already, downstream PDA wiring lands separately; (2) the full
integration tests (`squad_picks_rest_area_over_base`,
`interaction_started_fires_on_arrival`) need a real ECS squad
spawned with `set_population_target_for_test` + cohesion +
positions — the substrate-level coverage in
`squad_planner::tests::pick_rest_area_*` + `interaction_areas`
tests proves the picker/dedupe/release machinery without
that ECS scaffolding. Re-attempt the integration tests when the
spawn helpers gain a "place this squad here at tick N" affordance.

**Scope.**
- `crates/simn-sim/src/resources.rs::SquadObjective::Rest`: add `area_id: Option<String>` field. Existing un-`area_id`'d `Rest` objectives keep working (base-position fallback). `#[serde(default)]` keeps snapshot back-compat.
- `crates/simn-sim/src/systems/squad_planner.rs::pick_objective`: when scoring `Rest` candidates, prefer interaction areas with `kind == "rest"` over generic base positions if within ~150 m of the squad centroid AND the area's faction matches the squad's. On assignment, call `Sim::reserve_interaction_area` (best-effort — if the reservation fails because another squad got there first, fall back to the base-position `Rest`). On objective change / expiration / squad death, release the reservation.
- `crates/simn-sim/src/world_event_bus.rs`: new `WorldEventKind::InteractionStarted { npc_id, area_id: String, kind: String }` and `InteractionEnded { npc_id, area_id: String }`. Fired by `tick_npc_goals` when an NPC arrives at / leaves an area (within arrival radius matching the area's `extents`).
- PDA log surfaces both as toasts ("Squad PWA-3 resting at the river camp").

**Tests** in `interaction_areas.rs`:
- `squad_picks_rest_area_over_base` — set up faction bases + one rest interaction area near a squad centroid; tick `squad_planner`; assert the assigned `Rest` objective's `area_id == Some(rest_area_id)` and the area's occupancy ticked up.
- `interaction_started_fires_on_arrival` — paste the squad next to a rest area, tick `tick_npc_goals`, drain the world event queue, assert at least one `InteractionStarted` matching the area.

**Files touched.** `crates/simn-sim/src/resources.rs`, `crates/simn-sim/src/systems/squad_planner.rs`, `crates/simn-sim/src/systems/tick_npc_goals.rs` (or wherever arrival logic lives), `crates/simn-sim/src/world_event_bus.rs`, tests in `crates/simn-sim/tests/interaction_areas.rs`.

### D4 — Walkthrough + crate-guide / plan updates ✅ landed

**Status (2026-05-21).** Shipped.
`docs/book/src/walkthroughs/interaction-areas.md` walks the
designer through marker authoring, the canonical kind
vocabulary, the in-editor gizmo colors, and the sim-side
event flow; links to nav-paint + POI authoring as the two
sibling layers. SUMMARY + walkthroughs README updated.
Crate-guide D2 + D3 paragraphs above already cover the
implementation surface.

### D4 scope (as originally planned, retained for posterity)

**Scope.**
- `docs/book/src/walkthroughs/interaction-areas.md` (new): designer recipe — drop a marker, set `interaction_kind` + `extents` + `capacity`, restart sim, NPCs visit. Documents the canonical kind vocabulary and the "unknown kinds resolve to generic visit" contract.
- `docs/book/src/architecture/crate-guide.md`: paragraph describing the `InteractionAreas` resource + `attach_region_interaction_areas` bridge surface + `SquadObjective::Rest::area_id` extension.
- `docs/book/src/SUMMARY.md`: link the new walkthrough.

**Files touched.** `docs/book/src/walkthroughs/interaction-areas.md` (new), `docs/book/src/architecture/crate-guide.md`, `docs/book/src/SUMMARY.md`.

### Type contracts (Phase D)

```rust
// crates/simn-sim/src/resources.rs  (Phase D2)
pub struct InteractionArea {
    pub id: String,
    pub kind: String,
    pub pos: [f32; 3],
    pub extents: [f32; 2],
    pub faction: Option<FactionId>,
    pub capacity: u32,
    pub occupants: u32,
    pub tags: HashMap<String, String>,
}

pub struct InteractionAreas {
    pub by_region: HashMap<RegionId, Vec<InteractionArea>>,
    pub by_id: HashMap<String, (RegionId, usize)>,
}
```

```rust
// crates/simn-sim/src/resources.rs  (Phase D3 — Rest gains area_id)
pub enum SquadObjective {
    // … existing variants …
    Rest {
        base_pos: [f32; 3],
        expires_at: u64,
        #[serde(default)]
        area_id: Option<String>,
    },
    // …
}

// crates/simn-sim/src/world_event_bus.rs  (Phase D3)
pub enum WorldEventKind {
    // … existing variants …
    InteractionStarted { npc_id: NpcId, area_id: String, kind: String },
    InteractionEnded { npc_id: NpcId, area_id: String },
}
```

---

## Designer workflow (end-to-end)

This is the contract a level designer follows. It belongs in the walkthrough; capturing here so the implementer matches the doc.

1. Open the map scene in Godot (e.g. `godot/scenes/maps/cascade_locks.tscn`).
2. Select the `Terrain3D` node. Switch to the paint tool.
3. Pick **slot 14 ("nav_block")** and paint over cells NPCs must not enter (fence interiors, ravine bottoms, story-critical no-go). Default brush, any nonzero weight counts.
4. Pick **slot 15 ("nav_walkable")** and paint over cells NPCs must enter even when slope or feature class would block them (goat paths, fords, scripted routes).
5. For hand-placed obstacles (buildings, jersey barriers, jersey trucks), drop **NavObstacleMarker** nodes from `godot/scenes/world/nav_obstacle_marker.tscn` at their footprint. Set `extents = Vector3(half_w, _, half_d)` and `override_kind = "block"`.
6. Click **Sync to Canonical** on the `Terrain3DBaker` node. The exporter writes `nav_mask.r8` + updates `terrain.toml`'s `nav_mask_blake3`. NavObstacleMarker positions live in the scene (no canonical file).
7. Restart the sim (or detach + reattach the region from the dev panel). `Heightmap::load` picks up the mask; `attach_region_terrain_with_obstacles` rebuilds `GridNavQuery` + `WaypointGraph` honoring the mask, then stamps the obstacles. Online NPCs reroute on the next tick; offline NPCs pick reachable bases on the next offline tick.

## Cross-doc updates this iteration owns

These are the doc edits the implementer must land alongside the code:

- **`docs/book/src/planning/npc-traversal-plan.md`** — append a "Phase 2A — designer-painted outdoor overrides" section that says: "Phase 2A landed in iteration 5-13. Two Terrain3D paint slots (14 = block, 15 = walkable) flow to a canonical `nav_mask.r8` consumed by `GridNavQuery::from_heightmap`. POI obstacles layer in via `apply_obstacles` at attach time. Offline tier uses a sparse `WaypointGraph` built alongside the grid. See [`sim-iteration-5-13-plan.md`](sim-iteration-5-13-plan.md) and [`../walkthroughs/terrain3d-nav-paint.md`](../walkthroughs/terrain3d-nav-paint.md)." Update `Last updated` line.
- **`docs/book/src/architecture/crate-guide.md`** — `simn-terrain` section gets a paragraph for `nav_mask.r8` + `nav_mask_format_version` + `nav_override_at`. `simn-sim` nav section gets paragraphs for the painter override in `GridNavQuery::from_heightmap`, `apply_obstacles`, and `WaypointGraph` in `NavQueries`.
- **`docs/book/src/planning/README.md`** — add a line under "Contents - architecture & systems" linking the new iteration plan.
- **`docs/book/src/SUMMARY.md`** — link the new iteration plan in the planning list (alphabetical within iteration plans) and link the walkthrough.

## Verification

End-to-end checks to run before declaring an iteration phase done.

1. **Per-phase tests** as listed under each phase. All `cargo test -p simn-sim` + `cargo test -p simn-terrain` invocations green.
2. **Full sim suite + ignored long-running**: `cargo test -p simn-sim -- --include-ignored` green (catches offline-tier regressions).
3. **Determinism**: `cargo test -p simn-sim --test determinism` green.
4. **Clippy + fmt**: `cargo clippy --workspace -- -D warnings` + `cargo fmt --all -- --check` clean before every commit.
5. **mdbook**: `mdbook build docs/book` clean after every doc commit.
6. **Headless Godot parse**: `godot --headless --quit --path godot 2>&1 | grep -i error | grep -v "test_map_2"` empty after the exporter / loader changes. (The `test_map_2` filter accounts for known unrelated warnings; adjust if those clear.)
7. **In-engine smoke** (manual, requires a Terrain3D-equipped map — `cascade_locks` is the current candidate; if task #16 hasn't landed, the smoke uses whatever map carries Terrain3D today). Open the map, paint a corridor block in slot 14, drop a NavObstacleMarker over a POI footprint, restart the sim, watch online NPC tracers (from Phase 4A v2 of iteration 5-12) reroute around the painted block during faction skirmishes.

## Out of scope (deferred to follow-ups)

- **Live rebuild on paint.** Today `GridNavQuery` rebuilds only on `attach_region_terrain`. Re-attaching from the dev panel after a paint pass is sufficient for v1; eventual live invalidation belongs with the broader cover-system invalidation work (`cover-system-plan.md`).
- **Cost-shift / cover overlays** as additional channels (swamps slow you, brush gives concealment). Would use the `road_density.A` channel currently reserved. Add later if playtest demands.
- **Debug-viz coloring** that distinguishes default-walkable from force-walkable in the existing `Sim::nav_traversability` debug overlay. The merged result already reflects in the existing API; coloring split is polish.
- **Cross-region pathfinding through portals.** Offline NPCs stay within a region per `npc-traversal-plan.md` §8.
- **Snapshot of `WaypointGraph`.** Same persistence contract as the existing `GridNavQuery`: content, not state. Rebuilt on every `attach_region_terrain`.
- **Building / `NavigationRegion3D` indoor nav.** The original Phase 2 of `npc-traversal-plan.md`. This iteration ships the *outdoor* designer overlay; the indoor-building authoring path stays planning-only.

## Open questions

A fresh implementer should resolve these (or ask) before starting the corresponding phase:

1. **Which existing map carries Terrain3D today?** Task #16 (wire Terrain3D into test_map_1..4) is pending. If `test_map_1` doesn't have Terrain3D yet, the in-engine smoke (verification step 7) needs `cascade_locks` (or whichever production map has Terrain3D already). Confirm before authoring the walkthrough.
2. **Slot rename mechanics.** Phase A2 renames slots 14 and 15 to `nav_block` / `nav_walkable` in the project's Terrain3D asset list. Is the asset list a `.tres` resource the script can rewrite, or does it require manual editor click-through? Check `godot/scripts/terrain/` and the existing slot naming code path before committing.
3. **Region containment for `nav_obstacle_marker`.** Phase B2's Godot-side enumeration filters markers by region. Two options: (a) compute containment from the region's `Area3D` bounds (matches existing `loot_container_marker` filtering), or (b) require an explicit `@export var region: String` on the marker. Recommend (a) for designer ergonomics; confirm `Area3D` lookup is available on the map load path before locking it in.
4. **Bake-binary fixture map.** Phase A2 + A3 want a fixture map for the integration test. If `tools/bakes/` already has one suitable for round-trip, use it; otherwise the test inlines a 32×32 fixture. Check before writing the test.
