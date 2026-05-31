# Sim Overhaul Plan — Architecture, Authoring, Cover, Offline Tier

**Status:** Phases 1, 2 (except 2H), and 3 landed. Phase 4 (offline tier),
Phase 5 (AI quality), and Phase 6 (performance) still ahead.

## Context

Noosphere's NPC simulation (`simn-sim`) has grown organically through 70+
commits of anti-clump / stuck-state / combat-realism tuning. The audit
against OpenXRay's A-Life system reveals three categories of work:

1. **Structural debt** — `world/mod.rs` is 2,836 lines; aggro and threat
   processing are split across redundant systems; the spatial hash exists
   but isn't used for aggro; offline tier schema exists but nothing calls
   the projection functions.

2. **Missing authoring tools** — OpenXRay's "smart terrain" system (typed
   job slots at named locations, NPC competition for slots, capacity
   limits) directly solves the #1 QA complaint ("squads cluster near
   bases"). We need designer-placeable activity points, guard posts, and
   patrol routes — not just the existing guard-system-plan.md but a
   broader "smart terrain" concept.

3. **Cover/concealment** — the existing `cover-system-plan.md` describes
   an auto-baked cover graph from navmesh geometry. The user wants a
   complementary **authored** system: placeable 3D nodes with material
   types (concrete, wood, metal, etc.) that drive projectile penetration
   calculations. This is the groundwork for F.E.A.R.-class tactical AI.

The plan is organized into 6 phases with explicit dependencies. Each phase
is independently landable as a PR. Phases 1-3 are the priority; 4-6 are
sequenced behind them.

---

## Phase 1 — Structural Cleanup (unblocks everything)

**Goal:** Reduce complexity in the tick loop, eliminate redundant systems,
and make the codebase ready for the authoring and offline-tier work.

### 1A. Split `world/mod.rs` (~2,836 lines → 5 focused modules)

Extract into sibling files under `world/`:

| New file | Extracted concern | ~Lines |
|---|---|---|
| `world/tick.rs` | `Sim::tick()`, schedule construction, system ordering | ~400 |
| `world/player.rs` | Player state queries, player position updates | ~300 |
| `world/npc_view.rs` | NPC view caching, `SimView` construction, `ArcSwap` publish | ~500 |
| `world/population.rs` | Population target management, region attach/detach, spawn coordination | ~400 |
| `world/registration.rs` | `register_authored_base`, `register_guard_point`, `register_interaction_area`, scene-walker APIs | ~300 |

`world/mod.rs` retains `Sim` struct definition, `new()`, `load()`,
`shutdown()`, and re-exports. Target: <600 lines.

**Files:** `crates/simn-sim/src/world/mod.rs` → split into 5 new files.
No public API change — all methods stay on `impl Sim`.

### 1B. Unify `npc_aggro` + `threat_board` into single perception pass

Currently:
- `npc_aggro.rs` (715 lines): spatial-hash pair-scan, aggro acquisition/decay, blackboard writes
- `threat_board.rs` (305 lines): per-NPC threat scoring from `SquadBlackboards`

Both iterate NPC populations and process aggression data. Merge into
`systems/perception.rs` with three sub-passes in one system function:

1. **Decay pass** — refresh/clear existing `Aggro` components (existing Pass 1)
2. **Acquisition pass** — spatial-hash pair-scan, set `Aggro`, propagate to squad (existing Pass 2)
3. **Threat scoring** — aggregate `RecentAttackers` into `ThreatList` blackboard entries (existing `sweep_threats`)

Eliminates the duplicate NPC iteration. `threat_board.rs` becomes dead code.

**Files:** `systems/npc_aggro.rs` + `systems/threat_board.rs` → `systems/perception.rs`.
Update `systems/mod.rs` schedule registration.

### 1C. Pursue-progress timeout (QA: "stuck in Pursue")

Add to `npc_goals.rs` executor for `GoalKind::PursueTarget`:
- Track `pursue_start_pos` and `pursue_start_tick` on `ActiveGoal`
- Every 600 ticks (30s): if NPC hasn't gotten `PURSUE_PROGRESS_M = 10m`
  closer to target, clear `Aggro` and expire the goal
- Preserves squad blackboard `LastKnownEnemyPos` so nearby squads can
  still investigate

**Files:** `systems/npc_goals.rs`, `components.rs` (add fields to `ActiveGoal`).

### 1D. Commitment window + smoother Wander (QA: "abrupt goal changes")

- **Commitment window:** New field `committed_until_tick: u64` on
  `ActiveGoal`. When a `SquadObjective`-sourced goal is set,
  `committed_until_tick = now + COMMITMENT_TICKS (600, 30s)`.
  `goal_arbitration` skips non-combat candidates during the window.
- **Smoother Wander drift:** Bias new drift angle toward previous heading
  within ±90° unless outward-bias overrides. Add `last_drift_heading: f32`
  to `SquadObjectiveState`.

**Files:** `components.rs`, `systems/goal_arbitration.rs`,
`systems/squad_planner.rs`.

---

## Phase 2 — Smart Terrain + Content Authoring

**Goal:** Replace the single-base gravity-well model with a rich set of
designer-placeable activity points that give NPCs diverse goals across the
map. Directly addresses the #1 QA complaint.

This subsumes and extends `guard-system-plan.md` Phases A-F into a broader
"activity point" system inspired by OpenXRay's smart terrain.

### 2A. `ActivityPointMarker3D` — the universal authoring node

New `godot/scripts/world/activity_point_marker.gd` (`@tool`, extends
`Marker3D`). Replaces the narrower `GuardPointMarker3D` from the guard
plan with a general-purpose activity node.

**Exports:**
```gdscript
enum ActivityKind { GUARD_STATIC, GUARD_PERIMETER, PATROL_WAYPOINT,
                    REST_SPOT, LOOKOUT, CAMPFIRE, WORKBENCH, STASH,
                    SNIPER_NEST, AMBUSH_POINT }
@export var kind: ActivityKind = ActivityKind.GUARD_STATIC
@export var loop_id: String = ""          # perimeter/patrol waypoints sharing a route
@export var facing_yaw_deg: float = 0.0   # static post hint
@export var faction: Faction = Faction.NONE  # NONE = any faction
@export var radius_m: float = 2.0         # arrival tolerance
@export var capacity: int = 1             # how many NPCs can use simultaneously
@export var priority: int = 0             # higher = more desirable (for NPC selection)
```

**Inspector gizmo:** Small icon mesh per `ActivityKind` (flag for guard,
campfire for rest, crosshair for sniper, etc.) + radius ring, color-tinted
by faction. Group under `&"activity_points"`.

**Files:** `godot/scripts/world/activity_point_marker.gd` (new),
`godot/scenes/markers/ActivityPointMarker.tscn` (new).

### 2B. `PatrolRouteMarker3D` — connected waypoint chains

New `godot/scripts/world/patrol_route_marker.gd` (`@tool`, extends
`Path3D`). Designer draws a path in 3D; each `Curve3D` control point
becomes a patrol waypoint. NPCs walk the curve.

**Exports:**
```gdscript
@export var route_id: String = ""         # unique route identifier
@export var faction: Faction = Faction.NONE
@export var loop: bool = true             # closed loop vs out-and-back
@export var priority: int = 0
```

**Inspector:** Path3D curve visualization (already built into Godot).
Faction-colored line.

**Files:** `godot/scripts/world/patrol_route_marker.gd` (new),
`godot/scenes/markers/PatrolRouteMarker.tscn` (new).

### 2C. Sim-side `ActivityPoints` resource

```rust
pub enum ActivityKind {
    GuardStatic, GuardPerimeter, PatrolWaypoint,
    RestSpot, Lookout, Campfire, Workbench, Stash,
    SniperNest, AmbushPoint,
}

pub struct ActivityPoint {
    pub id: u64,                        // auto-assigned
    pub kind: ActivityKind,
    pub pos: [f32; 3],
    pub facing_yaw: f32,
    pub faction: Option<FactionId>,
    pub radius_m: f32,
    pub capacity: u8,
    pub priority: i8,
    pub loop_id: Option<String>,
    // Live state
    pub occupants: Vec<NpcId>,
    pub claimed_by_groups: Vec<u64>,
}

pub struct PatrolRoute {
    pub id: String,
    pub waypoints: Vec<[f32; 3]>,
    pub faction: Option<FactionId>,
    pub is_loop: bool,
    pub priority: i8,
}

#[derive(Resource, Default)]
pub struct ActivityPoints {
    pub by_region: HashMap<RegionId, Vec<ActivityPoint>>,
    pub routes_by_region: HashMap<RegionId, Vec<PatrolRoute>>,
}
```

Registration API: `Sim::register_activity_point(region, point)`,
`Sim::register_patrol_route(region, route)`,
`Sim::clear_activity_points_for_region(region)`.

Transient (not serialized) — re-enumerated from scene on region attach.

**Files:** `crates/simn-sim/src/resources.rs` (new types),
`crates/simn-sim/src/world/registration.rs` (registration API),
`crates/simn-godot/src/sim/mod.rs` (bridge `#[func]`s).

### 2D. `activity_point_spawner.gd` — scene walker

Same pattern as `base_spawner.gd`. Walks `&"activity_points"` group,
maps GDScript enums to Rust, calls `sim.register_activity_point(...)`.

Hooked into map load alongside existing `base_spawner` /
`interaction_area` calls.

**Files:** `godot/scripts/world/activity_point_spawner.gd` (new),
`godot/scripts/test_map.gd` (new call).

### 2E. POI baker auto-generates default activity points

Extend `godot/scripts/tools/poi_baker.gd`: when it creates a `BASE_*`
PoiMarker, auto-generate a cluster of `ActivityPointMarker3D` children:

| BaseKind | Generated points |
|---|---|
| CHECKPOINT | 2 GuardStatic flanking, 1 RestSpot |
| OUTPOST | 4 GuardStatic (15m radius), 1 Campfire, 1 perimeter loop (4 waypoints) |
| SAFEHOUSE | 1 GuardStatic (entrance), 4 GuardPerimeter (25m loop), 2 RestSpot, 1 Workbench |
| HEADQUARTERS | 6 GuardStatic (two rings), 6 GuardPerimeter (40m loop), 3 RestSpot, 2 Lookout, 1 SniperNest |
| RESEARCH_POST | 3 GuardStatic, 1 Workbench, 1 Stash |
| CAMP_SITE | 2 RestSpot, 1 Campfire (no guards — non-faction) |

Y-snap via TerrainNode. Inherit parent base's faction.

**Files:** `godot/scripts/tools/poi_baker.gd`.

### 2F. Squad planner consumes `ActivityPoints`

Refactor `squad_planner.rs` to use `ActivityPoints` for objective
selection:

- **Guard** → claim a `GuardStatic` or `GuardPerimeter` activity point.
  Each squad member targets a different slot (round-robin). Legacy
  `GuardPosts` resource deprecated.
- **Patrol** → claim a `PatrolRoute` or walk between `PatrolWaypoint`
  activity points sharing a `loop_id`.
- **Rest** → claim a `RestSpot` or `Campfire`.
- **Investigate** → prefer `Lookout` or `AmbushPoint` near the
  investigation target.
- **Objective selection** → NPC suitability scoring (like OpenXRay's
  `suitable()`): distance, faction match, priority, personality fit,
  capacity remaining. Closest unclaimed point with best score wins.

New `SquadObjective` variants:
```rust
ActivityPost { point_ids: Vec<u64>, expires_at: u64 }
PatrolRoute { route_id: String, leg_index: usize, expires_at: u64 }
```

Death/despawn releases occupancy. 15-min tenure rotation (existing
`GUARD_TENURE_TICKS`) applies to guard-type activity points.

**Files:** `systems/squad_planner.rs` (major refactor),
`systems/npc_goals.rs` (executor for new variants), `resources.rs`
(new `SquadObjective` variants).

### 2G. `SpawnPointMarker3D` — authored spawn locations

Currently NPCs spawn procedurally at faction bases via `PopulationTargets`
(per-region, per-faction desired count). The user wants designer-placeable
spawn points with explicit control over what spawns, where, and how often.

New `godot/scripts/world/spawn_point_marker.gd` (`@tool`, extends
`Marker3D`).

**Exports:**
```gdscript
@export var faction: Faction = Faction.NONE     # which faction spawns here
@export var spawn_rate: float = 1.0             # squads per minute (0 = one-shot on map load)
@export var max_concurrent: int = 3             # max alive squads from this spawner
@export var squad_size_min: int = 3             # min NPCs per squad
@export var squad_size_max: int = 5             # max NPCs per squad
@export var spread_radius_m: float = 15.0       # spawn jitter around marker
@export var enabled: bool = true                # toggle without deleting
@export var initial_delay_s: float = 0.0        # delay before first spawn
@export var loadout_tier: int = 0               # 0 = faction default, 1-5 = specific tier
```

**Inspector gizmo:** Faction-colored ring at `spread_radius_m` with
upward arrow icon. Shows `faction` label + `spawn_rate` text.

Group under `&"spawn_points"`.

**Sim-side resource:**
```rust
pub struct AuthoredSpawnPoint {
    pub id: u64,
    pub region: RegionId,
    pub pos: [f32; 3],
    pub faction: FactionId,
    pub spawn_rate_per_min: f32,       // 0 = one-shot
    pub max_concurrent: u8,
    pub squad_size: (u8, u8),          // (min, max)
    pub spread_radius_m: f32,
    pub loadout_tier: u8,              // 0 = default
    pub enabled: bool,
    // Live state
    pub active_squads: Vec<u64>,       // group_ids spawned from here
    pub last_spawn_tick: u64,
    pub initial_delay_ticks: u64,
}

#[derive(Resource, Default)]
pub struct AuthoredSpawnPoints {
    pub by_region: HashMap<RegionId, Vec<AuthoredSpawnPoint>>,
}
```

**Integration with `npc_spawn.rs`:**
- Current `npc_spawn` fills `PopulationTargets` deficits by spawning at
  random same-faction bases. With authored spawn points, the system
  checks `AuthoredSpawnPoints` FIRST:
  - For each spawn point where `active_squads.len() < max_concurrent`
    and enough time has elapsed since `last_spawn_tick`:
    - Spawn a squad at that point's position ± `spread_radius_m`
    - Record the group_id in `active_squads`
    - When a squad dies or leaves the region, remove from `active_squads`
  - `PopulationTargets` still fills the remainder (procedural background pop)
- **One-shot spawners** (`spawn_rate = 0`): spawn once on region attach,
  then never again until region detaches and reattaches. Good for
  scripted encounter setups.
- **Rate-limited spawners**: `spawn_rate_per_min` converted to tick
  interval. Respects the existing per-tick budget (8 squads/tick max).

**Spawner walker:** `godot/scripts/world/spawn_point_spawner.gd` walks
`&"spawn_points"` group, registers into sim.

**Files:** `godot/scripts/world/spawn_point_marker.gd` (new),
`godot/scenes/markers/SpawnPointMarker.tscn` (new),
`godot/scripts/world/spawn_point_spawner.gd` (new),
`crates/simn-sim/src/resources.rs` (new types),
`crates/simn-sim/src/systems/npc_spawn.rs` (consume authored points),
`crates/simn-sim/src/world/registration.rs` (registration API),
`crates/simn-godot/src/sim/mod.rs` (bridge).

### 2H. Capture transfer for activity points

When `base_capture_check` flips a base, walk nearby `ActivityPoints`
and update faction + clear occupancy, same pattern as Phase F of the
guard plan.

**Files:** `systems/base_capture.rs`.

---

## Phase 3 — Cover/Concealment Authoring System

**Goal:** Provide designers a 3D node for placing cover volumes with
material properties that drive projectile penetration calculations.
This is the authored complement to the auto-baked cover graph in
`cover-system-plan.md`.

### 3A. `CoverVolumeMarker3D` — the authoring node

New `godot/scripts/world/cover_volume_marker.gd` (`@tool`, extends
`Node3D`).

**Exports:**
```gdscript
enum CoverMaterial {
    CONCRETE,     # 300mm RHA-equivalent, stops all small arms
    BRICK,        # 200mm, stops pistol/SMG, degrades vs rifle
    STEEL_THICK,  # 12mm plate, stops all small arms
    STEEL_THIN,   # 3mm sheet metal, stops pistol only
    WOOD_THICK,   # 150mm timber, marginal vs rifle
    WOOD_THIN,    # 20mm plywood, concealment only vs rifle
    SANDBAG,      # 450mm, stops all small arms when fresh
    EARTH,        # 300mm, stops all small arms
    GLASS,        # concealment only, shatters on first hit
    VEGETATION,   # concealment only, no ballistic protection
    VEHICLE_BODY, # mixed steel+glass, directional
}

enum CoverHeight {
    LOW,          # crouch/prone only (~0.9m)
    HIGH,         # standing (~1.5m)
    FULL,         # full body when standing (~1.8m+)
}

enum ShapeSource {
    PRIMITIVE,    # use child CollisionShape3D
    MESH,         # inherit from referenced MeshInstance3D
}

@export var material: CoverMaterial = CoverMaterial.CONCRETE
@export var height: CoverHeight = CoverHeight.HIGH
@export var shape_source: ShapeSource = ShapeSource.PRIMITIVE
@export var mesh_source_path: NodePath = NodePath("")  # path to MeshInstance3D when MESH
@export var thickness_mm: float = 300.0   # material thickness for penetration calc
@export var destructible: bool = false     # can this cover be destroyed?
@export var health: float = 100.0          # HP if destructible
```

**Shape handling:**
- `PRIMITIVE`: Designer adds a child `CollisionShape3D` with a
  `BoxShape3D`, `CylinderShape3D`, or `CapsuleShape3D`. The marker
  reads the shape for registration. Standard Godot workflow.
- `MESH`: Marker reads the `mesh_source_path` MeshInstance3D's AABB
  and generates a simplified convex hull or oriented bounding box for
  the cover volume. The visual mesh itself drives the cover geometry —
  place a sandbag mesh, point the marker at it, and the cover volume
  matches the mesh.

**Inspector gizmo:** Semi-transparent tinted box/hull matching the
cover shape. Color by material (gray = concrete, brown = wood,
green = vegetation, blue = steel). Height indicator line.

Group under `&"cover_volumes"`.

**Files:** `godot/scripts/world/cover_volume_marker.gd` (new),
`godot/scenes/markers/CoverVolumeMarker.tscn` (new).

### 3B. Material penetration table (sim-side)

```rust
pub struct CoverMaterial {
    pub id: CoverMaterialId,
    pub name: &'static str,
    pub rha_equivalent_mm: f32,  // rolled homogeneous armor equivalent
    pub provides_cover: bool,     // true = stops projectiles (not just concealment)
    pub provides_concealment: bool,
    pub ricochet_chance: f32,     // 0.0-1.0
    pub spall_factor: f32,        // fragment damage multiplier on penetration
    pub durability: f32,          // HP per mm thickness (for destructible)
}

pub fn can_penetrate(
    projectile_penetration_mm: f32,  // from CaliberClass
    material: &CoverMaterial,
    thickness_mm: f32,
    angle_of_incidence: f32,  // 0 = head-on, PI/2 = parallel
) -> PenetrationResult {
    // Effective thickness = thickness / cos(angle)
    // Compare projectile_penetration vs material.rha_equivalent * effective_thickness
    // Returns: FullPenetration { residual_energy }, PartialPenetration { spall_damage }, Stopped
}
```

The `CaliberClass` system (already in `items.rs` / `ammo.toml`) already
has per-caliber `penetration_mm` values. This connects them to cover
materials.

Penetration table loaded from `data/cover_materials.toml`:
```toml
[[material]]
name = "concrete"
rha_equivalent_mm = 1.2   # 1mm concrete ≈ 1.2mm RHA
provides_cover = true
provides_concealment = true
ricochet_chance = 0.15
spall_factor = 0.3
durability = 8.0

[[material]]
name = "glass"
rha_equivalent_mm = 0.01
provides_cover = false
provides_concealment = true
ricochet_chance = 0.0
spall_factor = 0.0
durability = 0.5
```

**Files:** `crates/simn-sim/src/cover.rs` (new module),
`crates/simn-sim/data/cover_materials.toml` (new).

### 3C. Sim-side `CoverVolumes` resource

```rust
pub struct CoverVolume {
    pub id: u64,
    pub region: RegionId,
    pub pos: [f32; 3],
    pub half_extents: [f32; 3],    // AABB half-size
    pub rotation: [f32; 4],         // quaternion
    pub material_id: CoverMaterialId,
    pub height: CoverHeight,
    pub thickness_mm: f32,
    pub destructible: bool,
    pub health: f32,
    pub max_health: f32,
}

#[derive(Resource, Default)]
pub struct CoverVolumes {
    pub by_region: HashMap<RegionId, Vec<CoverVolume>>,
    pub spatial_index: HashMap<RegionId, SpatialGrid<usize>>,
}
```

Queries:
- `nearest_cover(pos, threat_dir, max_dist, height_pref) -> Option<&CoverVolume>`
- `check_cover_between(shooter_pos, target_pos) -> Vec<CoverHit>` —
  ray-AABB intersection test against all volumes in the region, returns
  material + thickness for penetration calculation
- `damage_cover(id, damage) -> bool` — reduce health, return true if
  destroyed

Registration: `Sim::register_cover_volume(region, volume)`,
`Sim::clear_cover_volumes_for_region(region)`.

**Files:** `crates/simn-sim/src/cover.rs`, `resources.rs`,
`world/registration.rs`, `crates/simn-godot/src/sim/mod.rs` (bridge).

### 3D. `cover_volume_spawner.gd` — scene walker

Walks `&"cover_volumes"` group, reads shape data (primitive child or
mesh AABB), material, thickness, and registers into sim.

**Files:** `godot/scripts/world/cover_volume_spawner.gd` (new),
`godot/scripts/test_map.gd` (new call).

### 3E. Wire penetration into `npc_combat`

When `npc_combat` resolves a hit:
1. Call `cover_volumes.check_cover_between(shooter_pos, target_pos)`
2. For each cover volume hit along the ray:
   - Call `can_penetrate(caliber.penetration_mm, material, thickness, angle)`
   - If `Stopped`: no damage, log suppression event to blackboard
   - If `PartialPenetration`: apply spall damage (reduced)
   - If `FullPenetration`: reduce `projectile_penetration_mm` by
     material cost, continue to next volume or target
3. If destructible cover: `damage_cover(id, caliber.damage)` on each hit

This connects the existing `CaliberClass` ballistics to the new cover
system without changing the combat flow — it's an additional gate
between "hit resolved" and "damage applied."

**Files:** `systems/npc_combat.rs`.

---

## Phase 4 — Tier Transitions + Offline Sim

**Goal:** Wire up the two-tier system that's been designed but never
activated. This is the critical architectural gap identified in both
the audit and the OpenXRay comparison.

### 4A. Projection scheduling (Phase 1C)

Wire `project_online_to_offline` and `project_offline_to_online` into
the region attach/detach lifecycle:

- When `ActiveRegions` removes a region: run `project_online_to_offline`
  for every NPC in that region. Despawn online entities, spawn
  `OfflineNpc` components.
- When `ActiveRegions` adds a region: run `project_offline_to_online`
  for every `OfflineNpc` in that region. Re-roll inventory, body parts,
  NpcCharacter from (id, faction, archetype). Spawn online entities.

Add hysteresis: NPC within 50m of region boundary stays on current tier
for 200 ticks (10s) to prevent rapid flickering.

Add round-trip tests: spawn online → project offline → verify
OfflineNpc fields → project back → verify equivalence.

**Files:** `offline_tier.rs` (projection functions exist, need
scheduling wrappers), `world/population.rs` (region lifecycle hooks),
new test file `tests/tier_transition.rs`.

### 4B. Offline movement (Phase 1D)

Implement `offline_movement` system:
- Runs on `OfflineTierClock` cadence (every 10 sim ticks, 2 Hz)
- For each `OfflineNpc` with a `waypoint_chain`:
  - Accumulate walked distance from speed × elapsed time
  - When distance exceeds current leg length, advance `waypoint_chain_idx`
  - Update `position_2d` via linear interpolation
- For NPCs without waypoints: assign waypoints from region graph
  toward their current squad objective's target

Adopt time-budgeted processing (OpenXRay pattern):
- Process max N offline NPCs per offline tick
- Round-robin iterator resumes where it left off
- Prevents frame spikes with 3000+ offline NPCs

**Files:** `offline_tier.rs` (new `offline_movement` system),
`systems/mod.rs` (schedule registration).

### 4C. Offline combat (Phase 1E)

Implement `offline_combat` system:
- Runs on `OfflineTierClock` cadence
- Pair-scan offline NPCs by proximity (use coarse grid, not full O(n²))
- For hostile pairs within `OFFLINE_ENGAGEMENT_RADIUS_M`:
  - Dice resolution: `hit_chance = base × health_class_modifier × loadout_class_modifier`
  - On hit: downgrade opponent's `HealthClass` (Healthy→Wounded→Critical→Dead)
  - Dead: remove from world, write to `LifeChronicle`
- Victory probability evaluation for retreat:
  - Compare cumulative combat power of each side
  - If below threshold: set `OfflineCombatState::Routed { until_offline_tick }`
  - Routed NPCs move away from engagement at double speed

**Files:** `offline_tier.rs` (new `offline_combat` system).

---

## Phase 5 — AI Quality Fixes (from QA backlog)

### 5A. Responder spread

Drop `RESPONDER_CAP_PER_TARGET` from 3 to 2. When selecting responders,
prefer squads approaching from different bearings around the target
(pick from distinct 90° quadrants) so they encircle instead of
converge from one side.

**Files:** `systems/goal_arbitration.rs`.

### 5B. Guard tenure tuning

Bump `GUARD_TENURE_TICKS` from 18000 (15 min) to 36000 (30 min) for
multi-member squads. Solo guards keep 15-min rotation. With Phase 2
landed, multiple activity points per base means more visible coverage
even with longer tenure.

**Files:** `systems/squad_planner.rs`.

### 5C. Aggro expiry consolidation

Extract aggro expiry logic into a single pure function
`should_expire_aggro(last_seen_tick, now, pursue_progress) -> bool`
in `components.rs`. Currently scattered across `npc_aggro` (decay),
`npc_goals` (pursue timeout), and implicit in `goal_arbitration`.

**Files:** `components.rs`, `systems/npc_aggro.rs`, `systems/npc_goals.rs`.

---

## Phase 6 — Performance

### 6A. Spatial hash for online aggro

The `NpcSpatialHash` exists and is rebuilt every tick but `npc_aggro`
doesn't use it for the acquisition pair-scan. Wire it in:
- Cell size = 100m vs sight radius = 80m
- For each cell, only scan within-cell + 8 neighbors
- Drops effective comparisons from O(n²) to O(n × k) where k ≈ 9 cells

**Note from code review:** The spatial hash IS already used (see
`npc_aggro.rs` line 9-18 comments). Verify the actual implementation
matches the description before assuming this is a gap. The audit
agent may have missed that the refactor already landed.

**Files:** `systems/npc_aggro.rs` (verify, potentially no-op).

### 6B. Time-budgeted offline updates

For Phase 4B/4C: implement a `BudgetedIterator<T>` that processes
offline NPCs with a microsecond budget per tick. If budget exhausted,
resume from current position next tick. Mirrors OpenXRay's
`CSafeMapIterator` pattern.

```rust
pub struct BudgetedIterator {
    next_index: usize,
    cycle: u64,
    budget_micros: u64,
}
```

**Files:** `crates/simn-sim/src/budgeted_iter.rs` (new utility).

### 6C. Incremental group→faction index

`squad_planner` rebuilds `group_id → faction` map every tick by
iterating all NPCs. Maintain this as a `Resource` updated on NPC
spawn/death/group-change instead.

**Files:** `resources.rs` (new `GroupFactionIndex` resource),
`systems/npc_spawn.rs`, `systems/npc_death_check.rs`,
`systems/npc_join_group.rs`, `systems/squad_planner.rs`.

---

## Dependency Graph

```
Phase 1 (Structural Cleanup)
  ├── 1A (split world/mod.rs) ← no deps
  ├── 1B (unify perception)   ← no deps
  ├── 1C (pursue timeout)     ← no deps
  └── 1D (commitment window)  ← no deps

Phase 2 (Smart Terrain + Authoring)
  ├── 2A-2D (activity nodes + sim resource)   ← no deps
  ├── 2E (POI baker)    ← 2A
  ├── 2F (planner)      ← 2C
  ├── 2G (spawn points) ← no deps
  └── 2H (capture)      ← 2C, 2F

Phase 3 (Cover/Concealment)
  ├── 3A-3B (authoring + materials)  ← no deps
  ├── 3C (sim resource)              ← 3B
  ├── 3D (spawner)                   ← 3A, 3C
  └── 3E (combat wire)               ← 3C

Phase 4 (Offline Tier)
  ├── 4A (projection scheduling) ← no deps
  ├── 4B (offline movement)      ← 4A
  └── 4C (offline combat)        ← 4A

Phase 5 (AI Quality) ← Phase 1
Phase 6 (Performance) ← Phase 4
```

Phases 1, 2, 3 can proceed in parallel. Phase 4 can start alongside
Phase 2/3 but 4B/4C depend on 4A. Phase 5 depends on Phase 1 (uses
the unified perception system). Phase 6 depends on Phase 4 (budgeted
iterator is for offline tier).

---

## Verification

### Per-phase testing

| Phase | Verification |
|---|---|
| 1A | `cargo test -p simn-sim` — no behavior change, all existing tests pass |
| 1B | `perception_sight.rs`, `threat_board.rs`, `npcs.rs` — same results from unified system |
| 1C | New test: spawn NPC, Pursue unreachable target, tick 600×, verify Aggro cleared |
| 1D | `npcs.rs` — Wander drift heading continuity, commitment window prevents premature preempt |
| 2A-2D | Open editor, place ActivityPointMarker3D, verify gizmo + registration log |
| 2E | Click Bake POIs, verify activity point children per BaseKind |
| 2F | Launch game, observe NPCs posting at activity points, rotating on tenure |
| 2G | Place SpawnPointMarker3D, set faction + rate, verify squads spawn at marker, respect max_concurrent |
| 3A | Open editor, place CoverVolumeMarker3D with primitive + mesh source, verify gizmo |
| 3B | Unit test: `can_penetrate` for each material × caliber combination |
| 3C | Registration test: register volumes, query nearest_cover, check_cover_between |
| 3E | Combat test: NPC behind concrete cover survives pistol rounds, rifle penetrates wood |
| 4A | New `tier_transition.rs`: online→offline→online round-trip preserves NPC identity |
| 4B | New ignored test: 100 offline NPCs walk waypoint chains for 1000 ticks, verify position progress |
| 4C | New ignored test: two hostile offline factions in same region, verify casualties after N ticks |

### Integration smoke test

1. Build: `cargo clippy --workspace -- -D warnings && cargo test -p simn-sim`
2. Launch Godot, open test_map_1
3. Verify: NPCs post at authored activity points, patrol routes, rest at campfires
4. Place cover volumes around a base, observe NPCs using cover in firefights
5. Walk away from region, verify NPCs transition to offline tier
6. Walk back, verify NPCs reappear with preserved identity

---

## Documentation updates (per Documentation Manifest)

| Change | Doc target |
|---|---|
| New `cover.rs` module | `crate-guide.md` |
| ActivityPoints + CoverVolumes resources | `crate-guide.md` |
| New bridge `#[func]`s | `api/sim-host.md` |
| Activity point authoring workflow | New `walkthroughs/activity-points.md` + SUMMARY.md |
| Spawn point authoring workflow | Include in `walkthroughs/activity-points.md` or separate `walkthroughs/spawn-points.md` |
| Cover volume authoring workflow | New `walkthroughs/cover-volumes.md` + SUMMARY.md |
| Guard system plan graduation | Move `planning/guard-system-plan.md` to walkthrough |
| Cover system plan update | Update `planning/cover-system-plan.md` with authored volumes |
| Offline tier activation | Update `planning/offline-tier-plan.md` status |
| Penetration mechanics | New or update `mechanics/ballistics.md` |
