# NPC Traversal - Planning Doc

**Status:** phase 1 landed 2026-05-05/06 (PR #145). Rust-side pathfinding lives in `crates/simn-sim/src/nav.rs`: `NavQuery` trait, `GridNavQuery` (uniform-grid A* with deterministic NW-to-SE tie-breaking + style-aware LOS simplification), `TravelStyle` enum (`RoadHugger` / `Mixed` / `Bushwhacker`), `NavQueries` resource keyed by `RegionId`, lazily built inside `Sim::attach_region_terrain` from each region's `Heightmap`. Public API: `Sim::path_in_region(region, from, to, style)`, `Sim::is_traversable`, `Sim::nav_grid_dims`, `Sim::nav_traversability`. `Path` component on NPCs caches waypoints, recomputed on goal change or target drift > 8 m; `tick_npc_goals` consumes it (aggro pursuit uses `Bushwhacker`; squad objectives pick a style via `style_for(faction, objective)`; solo FSM uses `Mixed`). Falls back to straight-line `move_toward` on path failure. Bridged into Godot via `SimHost::path_in_region` / `is_traversable` / `nav_grid_dims` / `nav_traversability`. Terrain Y-clamping (`clamp_npc_terrain_y`) is also live.

**Phase 2 split.** Phase 2's static-obstacle scope is splitting into two complementary halves: **Phase 2A — designer-painted outdoor overrides** (this work, scoped under [`sim-iteration-5-13-plan.md`](sim-iteration-5-13-plan.md) — designer paints two Terrain3D slots, exporter writes a canonical `nav_mask.r8`, sim consumes it in `GridNavQuery::from_heightmap`, POI obstacles layer in via `apply_obstacles` at attach time, offline tier paths a sparse `WaypointGraph`); and **Phase 2B — indoor `NavigationRegion3D` + `Area3D` authoring** (still planning-only, described in §3–§7 below as originally drafted). The two compose at runtime: outdoor paint and POI stamps live on the heightmap-derived grid; indoor nav lands as a separate region graph the sim queries via the same `NavQuery` trait.

**Last updated:** 2026-05-21 (Phase 2A split landed in this doc; implementation tracked in `sim-iteration-5-13-plan.md`)
**Scope:** how online-tier NPCs path through play areas, buildings, and POIs in `simn-sim`'s own pathfinding system, and how offline-tier NPCs use a coarser waypoint graph (per [`offline-tier-plan.md`](offline-tier-plan.md)) that survives tier transitions without spawning entities inside walls.

This is a living design doc. It captures decisions and open questions; it is not a spec.

Companions: [`tier-transition-plan.md`](tier-transition-plan.md) (the materialization step depends on this plan's spawn-point guarantee - see §7), [`offline-tier-plan.md`](offline-tier-plan.md) (the offline waypoint graph), [`worldgen-osm-plan.md`](worldgen-osm-plan.md) (OSM-derived buildings are a primary obstacle source - see §9), [`physics-tiering-plan.md`](physics-tiering-plan.md) (orthogonal axis), and `../architecture/crate-guide.md` (the engine-agnostic boundary this plan respects).

---

## 1. Guiding Principle (revised 2026-05-05)

**Sim owns navigation. Godot is the renderer.** Online-tier NPCs path-find via a Rust implementation in `simn-sim` (or a sibling `simn-nav` crate if it grows); paths are returned as `Vec<Vec3>` waypoints. Godot never participates in path computation - it just displays the result.

**Why the reversal from the earlier "Godot owns geometry" framing:**

- **Determinism.** Once journal+snapshot replay is the foundation (per [`sim-hardening-plan.md`](sim-hardening-plan.md)), pathfinding *must* be deterministic across game versions and machines. Godot's `NavigationServer3D` is a black box with implementation drift between engine versions - replay breaks the moment Godot 4.7 ships with different navmesh tessellation. Rust-side pathfinding owns its own seed-and-implementation contract; replay survives.
- **Headless server.** Per [`physics-backend-plan.md`](physics-backend-plan.md), the dedicated server runs without Godot at all. Pathfinding has to work in that mode, which forces the implementation into `simn-sim`.
- **Latency.** Path queries inside the simulation are immediate; round-tripping to Godot's server adds frame delay. Critical at the 12-player online-region target ([`multiplayer-alife-plan.md`](multiplayer-alife-plan.md)).
- **Shared representation across tiers.** The offline-tier waypoint graph is already Rust-side by necessity. Sharing the navmesh data structure between tiers cuts duplicate code.
- **Architectural alignment.** The "client as headless view" stance - sim is authoritative, Godot is the renderer - extends beyond pathfinding. This decision lives in that broader frame.

Consequence: one source of truth for "where can a humanoid stand?" - the baked Rust navmesh + obstacle data. The sim consumes it directly. The bake step (§6) produces this data from heightmap + obstacle scenes; the editor can visualize it but doesn't author it.

**Tech-choice notes for implementation:**

- Start with **uniform-grid A*** against heightmap + static-obstacle bake (smallest surface area, most deterministic, easiest to test). Existing crates: `pathfinding` for the A* core, custom data structures for the grid.
- Navmesh polygon meshes are an upgrade path, not a starting point. Recast/Detour Rust ports exist but add complexity.
- Both tiers share the same path return type (`Vec<Vec3>`); offline tier's waypoint graph is a sparser representation queryable through the same trait.
- Player input (click-to-move, companion AI, vehicle pathing) uses the same Rust-side path-finding - no separate path system for player vs NPC.

---

## 2. What This System Does / Does Not Do

**Does:**

- Provide a Rust-side path API in `simn-sim` (or a sibling `simn-nav` crate). Both online (uniform-grid A* on heightmap + obstacle bake) and offline (waypoint-graph traversal) consumers query through the same `NavQuery` trait, returning `Vec<Vec3>` waypoints. Engine-agnostic - works in both listen-server (Godot present) and dedicated-server (no Godot) deployments.
- Define a designer authoring contract: where to place region markers, doorways, navigation seeds in scenes (Godot is the *source* for obstacle and region authoring even though it's not the path-runtime).
- Bake - as an explicit, designer-triggered step - a versioned navmesh + obstacle artifact + waypoint graph, consumable by `simn-sim`. Produces both online-tier grid data and offline-tier sparse graph from the same source.
- Provide a guaranteed-valid spawn point inside any region for tier materialization (§7) - query Rust navmesh for a random navigable point, biased toward marker anchors.
- Validate at bake time: orphan markers, unreachable regions, regions with no navmesh coverage, markers outside any region.

**Does not:**

- Use Godot's `NavigationServer3D` at runtime. Godot may visualize the bake in the editor for designer feedback, but path queries during gameplay run entirely in Rust. (Reverses 2026-04-25 framing; see §1 for rationale.)
- Bake on save. Bake is a manual step (binary in `simn-godot` or sibling `simn-bake-nav` crate), not a save hook. See §6.
- Dynamically alter the navmesh at runtime in the general case. Door open/close and destructible flips invalidate cover bakes ([`cover-system-plan.md`](cover-system-plan.md)) and may re-bake nav similarly; live navmesh edits are out of scope here.
- Generate navmeshes from scratch by hand. Designers author in Godot scenes (obstacles, regions, markers); the bake step extracts the data into Rust-readable form.

---

## 3. The Two-Layer Split

> **Diagram needs revision per §1's reversal.** The `simn-godot → NavigationServer3D` arrow is gone — both online and offline tier consume Rust-side data directly. The bake step still extracts from Godot scenes (designer authoring lives there) but produces Rust-readable artifacts (navmesh grid + waypoint graph + obstacle data). Godot's runtime nav system is unused.

```
                                  ┌──────────────────────────────────┐
       ┌──── online ────┐         │  Godot scene (authoring)         │
       │                │         │  ├─ obstacle meshes              │
   simn-sim ─path query─┘         │  ├─ region markers               │
   NPC AI  ◀────────────┐         │  └─ navigation seeds             │
       │                │         └──────────────────────────────────┘
       │                │                          │
       │                │                          │  bake (manual binary)
       │                ▼                          ▼
       │          ┌──────────────────┐    ┌──────────────────┐
       │          │ nav-grid.bin     │◀───│ bake artifact    │
       │          │ waypoint-graph.bin│    │ extraction       │
       │          └──────────────────┘    └──────────────────┘
       │                ▲
       └──── offline ───┘
```

**Online tier.** NPC AI in `simn-sim` produces a navigation intent (`Move from current_pos to target_pos`). A `NavQuery` trait answers `path(from, to) -> Option<Vec<Vec3>>` using the loaded `nav-grid.bin` (uniform A* over heightmap + obstacles). Implementation lives in `simn-sim` directly (or `simn-nav` if it grows). Tests use the same code path with a smaller fixture grid; no engine stub needed.

**Offline tier.** NPC AI operates on `RegionId` and `WaypointGraph::neighbors(node) -> &[WaypointId]`. The graph is loaded from the baked artifact at sim startup. Node positions are real coordinates (not abstract); offline-tier movement just hops between waypoints with dice for transit time per [`offline-tier-plan.md`](offline-tier-plan.md). Both tiers share the `Vec<Vec3>` path return type - offline just produces shorter paths over a sparser graph.

The two layers meet at tier transitions (§7). They do not meet anywhere else.

---

## 4. Designer Authoring Contract

What a designer places in a scene to make a region navigable and named:

| Node | Purpose | Required? |
|---|---|---|
| `NavigationRegion3D` with baked `NavigationMesh` | Defines navigable surface. Standard Godot. | Yes - no nav coverage means no online pathing and no offline region. |
| `Area3D` named `region:<id>` containing the navigable area | Names the region for the offline graph. Tags via metadata (`region_kind = interior`, `poi = aegis_outpost_3`). | Yes for any area the sim should reason about. Unnamed nav coverage still works for online pathing but produces a single anonymous region in the graph. |
| `Marker3D` with metadata `nav_anchor = "spawn" \| "patrol" \| "sleep" \| ...` | Hints for materialization spawn-point selection (prefer a `spawn` anchor over a random navmesh point, when present). | No - bake falls back to navmesh-random if absent. |
| `NavigationLink3D` between regions | Explicit cross-region edges (ladder, ziplines, hatches). | Only when implicit adjacency (touching `NavigationRegion3D`s) doesn't capture the link. |

Authoring rules baked into the validator:

- Every `region:<id>` `Area3D` must contain at least one navmesh polygon centroid. Empty regions are an error.
- Region IDs must be unique within a scene. Cross-scene uniqueness is the bake tool's responsibility (it namespaces by scene path).
- Tags are free-form strings but the bake tool emits a manifest of all observed tags so we can grep for typos (`paroll` vs `patrol`).

---

## 5. The Region Graph Artifact

The bake tool emits one versioned binary file per world (or per scene, with a top-level manifest - open question §10). Schema sketch:

```rust
pub struct RegionGraph {
    pub format_version: u16,        // per sim-hardening-plan.md §3
    pub world_id: WorldId,
    pub regions: Vec<RegionRecord>,
    pub edges: Vec<EdgeRecord>,
}

pub struct RegionRecord {
    pub id: RegionId,
    pub scene_path: String,          // "res://scenes/maps/the_dalles.tscn"
    pub nav_region_node_path: NodePath, // for runtime lookup of the live RID
    pub centroid: Vec3,
    pub bounds: Aabb,
    pub area_m2: f32,
    pub tags: BTreeMap<String, String>,
    pub anchors: Vec<AnchorRecord>,  // spawn / patrol / sleep / …
}

pub struct EdgeRecord {
    pub a: RegionId,
    pub b: RegionId,
    pub link_kind: LinkKind,         // Implicit | NavigationLink3D | …
    pub portal_point: Vec3,          // for handoff path-stitching
    pub cost_hint: f32,
}
```

`simn-sim` loads only `regions` (id, tags, anchor *kinds* - not coordinates) and `edges`. Coordinates are kept in the artifact for `simn-godot` and the materialization shim, not for sim logic.

---

## 6. The Bake Tool

### 6.1 Where it lives

A small binary in `simn-godot` (or a sibling crate `simn-bake-nav` if it grows) that runs Godot in headless mode, opens the scene(s), iterates `NavigationRegion3D` nodes, queries `NavigationServer3D` for polygon data, walks the marker tree, and emits the artifact. Headless Godot already supports `NavigationServer3D` - verify in §10.

### 6.2 What it does

1. Open scene → wait for navmesh bake to settle (NavigationRegion3D bakes are async; tool waits on the signal).
2. For each `region:<id>` `Area3D`: collect contained navmesh polygon centroids → cluster into a single `RegionRecord`.
3. Detect implicit edges: regions whose navmesh polygons are within ε of each other across an `Area3D` boundary.
4. Detect explicit edges: `NavigationLink3D` nodes connecting two regions.
5. Validate (§4 rules + §6.4).
6. Serialize artifact, write to `godot/baked/region-graph.bin` (or per-scene equivalent).

### 6.3 Why bake is manual, not on-save

Decided 2026-04-25: bake runs only when a designer explicitly invokes it. Iteration speed during level work matters more than always-fresh graphs. A running session's offline graph can be stale relative to the in-editor scene; the consequence is at most a re-bake before commit. We get our coffee, the artifact updates, we commit.

This trades one specific risk: a designer edits a scene, forgets to rebake, and ships a region graph that disagrees with the navmesh. Mitigated by:

- A pre-commit check (likely in `docs-keeper` or a new sibling `level-keeper` agent) that diffs `*.tscn` mtime vs. `region-graph.bin` mtime and warns on staleness.
- The validator (§6.4) running again on bake - so any drift surfaces as a hard error before the artifact is overwritten.

### 6.4 Validation pass

Hard errors (bake fails):

- Marker outside any `NavigationRegion3D` coverage.
- `region:<id>` `Area3D` containing zero navmesh polygons.
- Duplicate `RegionId` within a scene.
- `NavigationLink3D` whose endpoints don't sit in any region.

Warnings (bake succeeds, prints):

- Region with no anchors (will fall back to random navmesh-point on spawn).
- Tag value not seen in any other region in the world (likely typo).
- Region with area below threshold (probably a leftover authoring artifact).

---

## 7. Materialization Spawn - The Stuck-NPC Problem

This is the core reason the plan exists in this shape.

When `tier-transition-plan.md`'s `materialize_offline_to_online` fires, an offline NPC needs a concrete `Position` in the world. The naive "spawn at the region's centroid" breaks the moment a designer edits geometry - the centroid drifts off the navmesh, and the NPC spawns embedded in a wall or floating two meters above ground.

The plan's contract:

```rust
// in simn-godot bridge
fn region_spawn_point(region: RegionId, prefer: Option<AnchorKind>, rng_seed: u64) -> Vec3;
```

Implementation: ask `NavigationServer3D` for a random navigable point inside the region's `NavigationRegion3D`, biased toward markers of the requested anchor kind when present. The returned point is on the navmesh by definition. **The geometry can shift between bakes and the spawn is still valid**, because the live navmesh - not the baked graph - is the source of the spawn point. The graph is only used to identify *which* region; the navmesh is used to find a point *in* it.

Order of preference for the returned point:

1. A `Marker3D` with `nav_anchor = prefer.to_str()` inside the region, if any.
2. Any `Marker3D` with a sensible `nav_anchor` ("spawn" by default) inside the region.
3. A random navmesh point inside the region's `Area3D` bounds.
4. (Failure mode) Region has no live navmesh - log error, return centroid, surface as a runtime warning. This case should be impossible if the bake validator passed; we surface it loudly anyway because asset reloads can reorder things.

`materialize_offline_to_online` calls this function and uses its return as the entity's `Position`. No other code path in the sim places NPCs.

---

## 8. Cross-Region Pathing and Stitching

Online-tier paths inside a single `NavigationRegion3D` come back in one query. Across regions, two cases:

- **Implicit adjacency** (regions sharing a `NavigationLink3D`-less boundary, e.g. a building threshold open to the outside): `NavigationServer3D` already path-stitches across linked maps when both `NavigationRegion3D`s are on the same `RID` map. Authoring rule: regions in the same scene share the default map.
- **Explicit links** (ladders, ziplines, scripted jumps): `NavigationLink3D` carries the link metadata. The sim's online-tier API still gets back a single `Vec<Vec3>`; the link is invisible in the result. Animation / scripted traversal at the link is a separate concern handled in `simn-godot`'s NPC driver, not here.

Cross-*scene* pathing (an NPC walking from one map to another) is not in scope for this plan. Maps are streamed as discrete units; an NPC leaving the active map enters offline tier and re-materializes in the next map's region graph when a player gets close. That handoff is `tier-transition-plan.md`.

---

## 9. Interaction with Worldgen and Hand-Authored Buildings

OSM-derived buildings (`worldgen-osm-plan.md`) are spawned as scene nodes at runtime. For the navmesh layer, this means:

- Each spawned building must include or attach a `NavigationRegion3D` covering its interior + entry threshold, baked at scene-build time (offline, in the same pipeline that emits the OSM artifact).
- Each building's `NavigationRegion3D` gets a `region:<osm_id>` `Area3D` so the offline graph references it by stable OSM id.
- The bake tool runs *after* worldgen, so the region graph reflects both hand-authored landmarks (story buildings, POIs) and procedural OSM buildings.

Hand-authored landmarks override OSM regions of the same id. The bake tool warns when this happens to make the override visible.

---

## 10. Open Questions

- **Headless `NavigationServer3D`.** The bake tool runs Godot headless and queries nav data. Verify that `NavigationServer3D` is fully functional in `--headless --quit` mode (likely yes, but not yet tried). If it isn't, fall back to reading `NavigationMesh` resources directly off disk and clustering polygons ourselves.
- **One artifact per world or per scene.** Per-scene is cheaper to rebake (only edited scenes change), but a top-level manifest then has to enumerate scenes and merge graphs at sim load. Per-world is simpler at load time but rebakes the whole world on any single-scene edit. Lean per-scene with a tiny manifest, decide at impl time.
- **Dedicated server with no Godot scene tree.** A dedicated server (per `physics-backend-plan.md`) will run `simn-net` + `simn-sim` without rendering. It still needs path queries for online-tier NPCs. Options: (a) link `simn-godot` headlessly on the server too; (b) ship the navmesh polygons as a sim-loadable artifact and run a Rust pathfinder (e.g. `pathfinding` crate) on them. (a) keeps a single source of truth; (b) decouples the server from Godot. Open until the dedicated-server crate exists.
- **Dynamic obstacles and the offline graph.** A locked door or destroyed wall changes online-tier paths via `NavigationObstacle3D`, but the offline graph is static (baked). If a region becomes unreachable mid-session, offline NPCs in that region don't know. Acceptable for the slice; revisit when destruction lands (`destruction-plan.md`).
- **Region granularity for very large outdoor areas.** A single 4 km² wilderness map shouldn't be one giant region - squad-level offline behavior wants finer granularity. Probably `region:<id>` `Area3D`s subdivide outdoor terrain manually; a future iteration could auto-subdivide by distance from POIs. Out of scope for v1.
- **Multi-floor buildings.** Godot navmesh handles vertical layers; `region:<id>` markers will need to be per-floor in interiors. Mostly an authoring discipline issue; the bake tool treats each floor's `Area3D` as a separate region with explicit `NavigationLink3D` for stairs.

---

## 11. The Concrete Code Artifacts This Plan Demands

1. **`NavQuery` trait in `simn-sim`** - `path(from: Vec3, to: Vec3) -> Option<Vec<Vec3>>`. Inserted as a resource. Production impl in `simn-godot`, stub in tests.
2. **`RegionGraph` struct + loader in `simn-sim`** - versioned, deserialized from the baked artifact at sim startup. Exposes `neighbors`, `tags`, `anchor_kinds`. No coordinates.
3. **`region_spawn_point` bridge function in `simn-godot`** - the only entry point that places offline NPCs into the world. `materialize_offline_to_online` calls it.
4. **Bake binary** (`simn-bake-nav` or equivalent) - runs Godot headless, walks scenes, emits `region-graph.bin` + per-scene manifests, runs validator. Wired into a Cargo task or `xtask`.
5. **Validator** - shared between the bake binary (hard fail) and a pre-commit / `level-keeper` check (warn on staleness). One implementation, two callers.
6. **Designer-facing docs** - a short authoring guide under `docs/book/src/architecture/` (or `walkthroughs/` once it ships) covering the marker contract from §4. Must exist before non-Claude designers touch the system.

---

## 12. What's Blocked On This Plan

- **Online-tier NPC behavior past the prototype.** Today's NPC scaffolding has no real pathing. Any non-trivial AI work (patrols, flanking, retreat-to-cover) is blocked on the path API in §3.
- **`tier-transition-plan.md` materialization.** That plan punts on "where exactly does the NPC spawn?" - §7 here is the answer. Without it, materialization can't ship without spawning NPCs in walls.
- **Faction occupation of POIs.** Squad-level offline objectives like "Aegis holds Outpost 3" need the region graph to express *what* is being held. Without named regions, faction state has nowhere to attach.
- **`tactical-ai.md` (F.E.A.R.-class GOAP).** Tactical AI is path-bound by definition (cover selection, flanking arcs). Online-only, but online-only still requires §3.

Not blocked: terrain, weather, current combat / inventory / crafting, single-player at slice fidelity, hand-authored cinematic encounters that don't rely on procedural pathing.
