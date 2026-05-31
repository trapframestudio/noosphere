# Cover System — Planning Doc

**Status:** stub — design intent captured, no implementation yet
**Last updated:** 2026-05-05
**Scope:** geometry abstraction for "where can NPCs hide from line of sight." Pre-baked cover-point graph derived from navmesh + heightmap + static obstacles. Queries by tactical AI to position behind cover during firefights. The F.E.A.R. enabler — without this, "cover" is just a word.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 3), [`combat-los-plan.md`](combat-los-plan.md) (LOS query primitive cover relies on), [`npc-traversal-plan.md`](npc-traversal-plan.md) (navmesh that cover points anchor to), [`destruction-plan.md`](destruction-plan.md) (destructibles invalidate cover bakes), [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md) (the consumer that makes cover load-bearing).

This is a living design doc.

---

## 1. Why this exists

F.E.A.R.-class tactical AI requires NPCs to position behind cover, peek-shoot, suppress, flank, retreat. Naively this requires runtime queries against arbitrary geometry. F.E.A.R.'s actual trick was **pre-bake**: hand-annotate cover points along map edges, label them with what direction they cover from, and treat the position-selection problem as a graph query.

We're not hand-annotating — our maps are too big and partly procedural. So the bake step has to be automatic: walk the navmesh, raycast against static geometry from candidate edge points, classify which directions are exposed vs covered. This is a one-time bake per map (with re-bake on destructible flips), and the runtime is just spatial queries against the resulting graph.

## 2. What this system does / does not do

**Does:**

- Define a `CoverPoint` data structure (position + exposed directions + height class).
- Define the bake pipeline: input = navmesh + static obstacle bake + heightmap; output = per-region `CoverGraph`.
- Provide runtime queries: `nearest_cover(pos, exposed_dirs_to_avoid, max_distance, faction_filter) -> Option<CoverPointId>`, `cover_offers_protection(point, from_dir) -> bool`.
- Per-region `CoverGraph` resource loaded with the map; LFS-tracked alongside navmesh.
- `CoverOccupancy` tracking — prevent two NPCs claiming the same cover slot.

**Does not:**

- Cover destructibles dynamically per-frame. Destructible cover invalidates the static graph; [`destruction-plan.md`](destruction-plan.md) issues invalidation events that mark cover points as "stale" until a re-bake. No live geometry queries.
- Cover positioning *strategy* (when to flank, when to suppress). That's the tactical AI planner. Cover system is a query primitive.
- Hand-authored cover for special encounters. If we want hand-placed tactical setups, those go through [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md) overrides, not the bake.

## 3. Data model

```rust
#[derive(Clone, Debug)]
pub struct CoverPoint {
    pub id: CoverPointId,
    pub position: Vec3,
    pub region: RegionId,
    pub height: CoverHeight,           // Low (crouch) | High (stand)
    pub covered_dirs: BitSet8,          // 8-octant bitmap; 1 = direction is covered
    pub exposed_dirs: BitSet8,          // inverse — quick "exposed to fire from where?"
    pub slot_count: u8,                 // how many NPCs can use simultaneously (mostly 1)
    pub adjacent_navmesh_node: NavNodeId, // entry point on the path graph
}

pub enum CoverHeight {
    Low,    // useful prone/crouch; head-exposed when standing
    High,   // useful standing
}

#[derive(Resource, Default)]
pub struct CoverGraphs {
    by_region: HashMap<RegionId, CoverGraph>,
}

pub struct CoverGraph {
    points: Vec<CoverPoint>,
    spatial_index: SpatialGrid,        // cell_size_m similar to NPC spatial hash
    occupancy: HashMap<CoverPointId, NpcId>,
}
```

The `BitSet8` octant model (N, NE, E, SE, S, SW, W, NW) is approximate but cheap. Tactical queries don't need finer angular resolution; raycasts during the bake produce per-octant majority votes.

## 4. Bake pipeline

Runs offline (host-side; not in the gameplay loop), per map, output committed to LFS alongside navmesh:

1. **Sample candidates.** Walk navmesh edges; sample positions every ~1.5 m along edges. Each sample is a candidate cover point.
2. **Probe geometry.** From each candidate at standing eye height (~1.7 m) and crouch eye height (~0.9 m), raycast in 8 octants ~50 m. If ray hits a static obstacle within ~3 m, that octant is *covered* at that height.
3. **Classify height.** A point covered at crouch but exposed at stand is `CoverHeight::Low`. A point covered at stand is `CoverHeight::High`. Points exposed in all 8 octants at both heights are dropped.
4. **Deduplicate.** Cluster candidates within ~2 m that have identical octant maps; keep one representative.
5. **Index spatially.** Build a per-region spatial grid for query.
6. **Serialize.** Write to `godot/assets/terrain/<map>/cover/<region>.bin` (LFS).

Re-bake is triggered by:
- New map authoring.
- Navmesh re-bake.
- Destructible flip (deferred — destruction plan emits invalidation events; partial re-bake ASAP, full re-bake nightly / next session).

## 5. Runtime queries

- **`nearest_cover(pos, exposed_dirs_to_avoid, max_distance, height_pref) -> Option<CoverPointId>`** — squad asks for cover that protects from a specific direction (where the enemy is). Walks the spatial grid, filters by `covered_dirs & exposed_dirs_to_avoid == exposed_dirs_to_avoid` and `slot_count > occupancy`, returns nearest.
- **`cover_offers_protection(id, from_dir) -> bool`** — does this point still protect from this direction? (For mid-engagement re-validation if enemy moves.)
- **`claim_cover(id, npc_id)` / `release_cover(id, npc_id)`** — slot management. Claimed cover paths-to via [`npc-traversal-plan.md`](npc-traversal-plan.md) routing.

Movement integration: arbitration ([`goal-arbitration-plan.md`](goal-arbitration-plan.md)) yields a `GoalKind::MoveTo(cover_position)`; pathfinding routes; arrival triggers `claim_cover`. Tactical AI then drives peek-shoot logic from the cover point.

## 6. Dependencies

- **Blocks:** F.E.A.R.-class tactical behavior (Stage 3), all "use cover" planner actions in [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md).
- **Blocked by:** [`npc-traversal-plan.md`](npc-traversal-plan.md) (need navmesh first; cover anchors to nav nodes), [`combat-los-plan.md`](combat-los-plan.md) (cover queries use LOS), [`destruction-plan.md`](destruction-plan.md) (for invalidation contract).

## 7. Open questions

- ~~**Discrete vs runtime hybrid**~~ **Decided 2026-05-05: discrete graph as hint + runtime LOS validation against the live scene as refiner.** Cover-system is server-authoritative — virtual collision maps live in `simn-sim` data, queried by AI without engine round-trip. Stealth mechanics consume the same primitives (per user direction).
- ~~**Re-bake on destructible flip**~~ **Decided 2026-05-05: full region re-bake.** Spatial-locality partial bakes were a tentative optimization; user opted for the simpler "respawn the cover graph" approach. Cost is bounded (re-bake is offline-style, runs as a background task; in the meantime the runtime LOS validator catches now-invalid cover before AI commits). Optimize later if measured to be needed.
- ~~**Authoring overrides**~~ **Decided 2026-05-05: yes, but server-authoritative.** Hand-placed cover for scripted encounters lives in encounter-dispatcher data; the dispatcher injects override cover-points into the runtime graph at encounter activation. Per user: "the authoring should drive the server ECS system through an API, the ECS system shouldn't bow down to the client. If an event is triggered, it's triggered for everyone."
- **Cover slot count.** Is one NPC per point standard? Some real-world cover (a long log) supports many. Tentative: `slot_count = floor(usable_length_m / 1.5)`. Bake derives it.
- **Vertical cover (windows, peek-shoot).** Still open. Tentative: model windows as cover-points with a special `peek_octant` annotation that the tactical AI can use for a different action (lean-and-fire). Per user "yeah we need to figure this one out" — defer to tactical-ai impl phase.
- **Cover invalidation between baker and runtime.** Destructible flips happen mid-session; cover bake is on disk. Runtime needs an in-memory delta layer that applies "this point is invalidated, awaiting re-bake" on top of the baked state. Concrete protocol TBD when destruction integration lands.

## 8. Out of scope

- Cover-art / visual indicator (UI for "press button to take cover" — that's player-side).
- AI personality (some NPCs avoid cover; aggressive ones charge). That's [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md) personality scope.
- Suppression mechanics (covering fire forces target to stay behind cover). Separate Stage 3 piece.
