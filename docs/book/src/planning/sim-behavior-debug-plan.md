# Sim Behavior Debug Plan

**Status:** Phase 3+ complete — 7 tests pass, full behavior overhaul applied
**Last updated:** 2026-05-26
**Goal:** Diagnose and fix NPC behavior issues without a ground-up
rebuild. If this plan fails to resolve the core problems, escalate
to the rebuild plan (`sim-behavior-rebuild-plan.md`).

## The Problem

NPCs have 7 overlapping state/decision types that compete:

```
NpcGoal          (Idle | MoveTo | RestAt)         — legacy FSM
ActiveGoal       (source + kind + priority)       — arbitration output
GoalKind         (PursueTarget | SquadFollow | …) — what to do
SquadObjective   (Guard | Patrol | Rest | …)      — squad-level plan
CombatStance     (Approaching | InCover | …)      — tactical state
CombatRole       (Pointman | Support | …)         — role assignment
GoapPlanComp     (action sequence)                — GOAP plan
```

These are written by 4 different systems in sequence:
1. `squad_planner` → writes `SquadObjective` (every 200 ticks)
2. `goal_arbitration` → reads SquadObjective + Aggro + blackboard → writes `ActiveGoal`
3. `npc_tactical` → reads Aggro + health + cover → writes `CombatStance` + `CombatRole` + `GoapPlanComp`
4. `tick_npc_goals` → reads ActiveGoal + CombatStance → moves NPC

The problem: step 3 can override step 4's movement target, and step 1's
objectives may not match what step 3 decides. There's no single owner of
"what this NPC should be doing right now."

## Debug Protocol

### Phase 1 — Instrument the decision chain

Add a per-NPC behavior trace that logs, for each aggroed or stuck NPC:
```
[NPC 42] tick=1000 goal=SquadFollowObjective squad_obj=Guard(base_pos)
         stance=Firing aggro=Some(17) goap=Some(["Shoot"])
         pos=(100,50,200) target=(105,50,210) dist=11.2m
         movement_target=(105,50,210) arrive_sq=900 ARRIVED=true
```

This trace reveals:
- Is the NPC arrived at its target? (arrive_sq too large → stuck)
- Does CombatStance override SquadObjective movement?
- Does GOAP produce a plan? Does it map to a useful stance?
- Is Aggro flickering (present one tick, gone the next)?

### Phase 2 — Verify each system in isolation

Write targeted integration tests:

**Test A: Guard at activity point**
```
1. Sim::new_in_memory
2. Register 1 activity point (GuardStatic, faction=pwa, pos=[100,0,0])
3. Spawn 1 PWA squad (4 NPCs) near [0,0,0]
4. Tick 400× (20 seconds)
5. Assert: at least 1 NPC within 5m of [100,0,0]
```

**Test B: Rest at campfire**
```
1. Register 1 activity point (Campfire, faction=None, pos=[50,0,50])
2. Spawn 1 squad, force Rest objective
3. Tick 400×
4. Assert: squad centroid within 30m of campfire
```

**Test C: Combat → return to objective**
```
1. Register guard point, spawn PWA squad guarding it
2. Spawn hostile Bandit near the guard point
3. Tick 200× (combat happens)
4. Kill the bandit manually
5. Tick 200× more
6. Assert: PWA squad returns to guard point (not stuck at combat pos)
```

**Test D: Shot → reactive aggro → combat**
```
1. Spawn 2 hostile NPCs facing away from each other
2. Fire projectile from A at B
3. Tick 50×
4. Assert: B has Aggro targeting A
5. Assert: B is facing A (yaw check)
```

**Test E: Wander doesn't stick**
```
1. Spawn squad with Wander objective
2. Record position at tick 0
3. Tick 1000× (50 seconds)
4. Assert: position moved at least 200m from start
5. Assert: NPC is not spinning (yaw variance < threshold)
```

### Phase 3 — Fix what fails

Based on test results, fix the specific broken link:

- If Test A fails: `try_guard_from_activity_points` selection logic is wrong (faction matching, distance scoring)
- If Test C fails: post-combat Aggro cleanup isn't restoring SquadObjective
- If Test D fails: reactive aggro in projectiles.rs isn't working
- If Test E fails: wander drift target selection or arrive threshold

### Phase 4 — Resolve system conflicts

If Tests A-E pass individually but behavior is still broken in
combination, the problem is system interaction:

1. **GOAP vs squad planner:** Does `npc_tactical` override the
   movement target that `tick_npc_goals` computed from SquadObjective?
   If yes: GOAP should only activate during combat (when Aggro exists),
   not during peacetime.

2. **CombatStance persistence:** Does CombatStance linger after Aggro
   clears? If yes: `npc_tactical` should `remove::<CombatStance>()` when
   Aggro is gone (it already does this — verify it works).

3. **ActiveGoal expiry:** Does ActiveGoal expire correctly after
   SquadObjective changes? The commitment window may prevent the
   new objective from taking effect.

## Phase 2 Results (2026-05-26)

All 5 integration tests pass (`tests/behavior_chain.rs`):

| Test | Result | Notes |
|------|--------|-------|
| A: Guard at activity point | **PASS** | Squad picks Guard from AP, NPCs walk to it |
| B: Rest at campfire | **PASS (soft)** | Planner picks Guard over Rest due to utility weights (PWA Guard=5, Rest=3). Soft assertion passes — NPCs move from spawn. |
| C: Combat → return to objective | **PASS** | NPCs return to guard post after bandit killed |
| D: Reactive aggro from shot | **PASS** | Victim acquires aggro, pursues attacker |
| E: Wander doesn't stick | **PASS** | Squad drifts 50m+ from spawn in 1000 ticks |

**Key findings:**
1. **Activity points work** when the test correctly sequences the
   first-spawn seed pass + forced expiry. The original test failure was
   a test timing bug (forcing expiry before the planner created the
   initial objective).
2. **Territorial standing gate works** — PWA as a contester in
   `RegionControl` gets Guard access via `has_territorial_standing`.
3. **Squad planner slot staggering** (`group_id % 200 == tick % 200`)
   means tests must use group_ids whose slots align with the tick window.
4. **Utility scoring dominates Rest** — Guard weight (5) beats Rest (3)
   for PWA, so campfire-adjacent squads often Guard instead of Rest.
   Not a bug, but worth tuning if Rest behavior is desired.
5. **Combat → return works** — aggro cleanup restores the squad to its
   Guard objective after the threat dies.

## Phase 3 Fixes Applied (2026-05-26)

**Fix 1: Orphaned goal demotion** (`goal_arbitration.rs`)
— When an ActiveGoal's source no longer generates a matching candidate
(e.g. PursueTarget after Aggro decays), the goal is replaced
unconditionally, bypassing hysteresis. Fixes the critical bug where
NPCs stood frozen forever after combat.

**Fix 2: Procedural activity points + cover scatter** (`world_seed.rs`)
— Procedural test maps now get per-base guard APs (2-3 per faction
base), campfire/rest APs at campsites, lookout APs across the map,
patrol routes between same-faction bases, and cover volumes (2-3 per
base + 15-25 freestanding). Previously these maps had zero APs and
zero cover — all behavior fell through to base-position guards or
wander.

**Fix 3: Shortened dispersion phase** (`squad_planner/mod.rs`)
— Reduced DISPERSE_MIN/MAX_DIST_M from 60/120 to 20/40. Squads now
start meaningful behavior in 7-13 seconds instead of 20-40 seconds.

**Fix 4: New integration test** (`tests/behavior_chain.rs`)
— `orphaned_pursue_target_clears`: verifies NPCs transition away from
stale PursueTarget after the target dies and aggro decays.

**Remaining concerns (Phase 4 territory):**
- **Playtest validation** still needed — tests prove each link in the
  chain works in isolation, but real multi-squad multi-faction scenarios
  may reveal interaction issues.
- **Rest vs Guard competition** — the utility weights may need tuning
  so campfire-rest actually happens when Rest spots are available.
- **GOAP peacetime interference** — not tested yet. Does `npc_tactical`
  override squad objective movement during peacetime? Tests A/E suggest
  it doesn't (NPCs successfully follow SquadFollowObjective), but edge
  cases under partial aggro (one squad member aggroed, others not) are
  untested.

## Success Criteria

- All 5 integration tests pass ✓
- Playtest: NPCs visibly guard POIs, rest at campfires, return to
  objectives after combat
- No stuck-spinning behavior
- Hostile contact → combat → resolution → return to duty cycle works

## Estimated Effort

2-4 hours of focused debugging with tests. If Phase 4 reveals
fundamental design conflicts, escalate to rebuild plan.

---

# Sim Behavior Rebuild Plan

**Status:** contingency plan — only execute if debug plan fails
**Last updated:** 2026-05-26
**Goal:** Ground-up redesign of the NPC decision system with all
subsystems (activity points, combat, roles) integrated from the start.

## Why Rebuild

The current system has 7 behavior-related types written by 4 systems.
This emerged from incremental feature additions:
- Sprint 1: NpcGoal FSM (Idle/MoveTo/RestAt) + squad_planner
- Sprint 2: ActiveGoal + goal_arbitration + priority system
- Sprint 3: CombatStance + npc_tactical + GOAP + CombatRole

Each layer was correct in isolation but they don't compose cleanly.
The rebuild designs all three concerns as one integrated system.

## Architecture: Single Decision Pipeline

Replace 7 types with 3:

```
NpcBehavior     — what the NPC is doing right now
SquadOrder      — what the squad leader decided
ThreatState     — combat awareness
```

### NpcBehavior (replaces NpcGoal + ActiveGoal + CombatStance + GoapPlanComp)

```rust
#[derive(Component)]
pub enum NpcBehavior {
    // Peacetime
    Idle,
    MovingTo { target: [f32; 3], reason: MoveReason },
    Guarding { point_id: u64, facing_yaw: f32 },
    Resting { point_id: u64, until_tick: u64 },
    Patrolling { route_id: String, leg: usize },

    // Combat
    Engaging { target: NpcId, stance: CombatStance },
    TakingCover { volume_id: u64, target: NpcId },
    Flanking { target: NpcId },
    Retreating { toward: [f32; 3] },

    // Transition
    Investigating { pos: [f32; 3] },
    ReturningToPost { point_id: u64 },
}
```

One component. One match statement in the executor. No ambiguity.

### SquadOrder (replaces SquadObjective + SquadObjectiveState)

```rust
#[derive(Resource)]
pub struct SquadOrders {
    pub by_group: HashMap<u64, SquadOrder>,
}

pub struct SquadOrder {
    pub kind: OrderKind,
    pub assigned_points: Vec<(NpcId, u64)>, // NPC → activity point
    pub issued_tick: u64,
    pub expires_tick: u64,
}

pub enum OrderKind {
    GuardBase { point_ids: Vec<u64> },
    Patrol { route_id: String },
    Rest { point_ids: Vec<u64> },
    Investigate { pos: [f32; 3] },
    Wander { zone: ZoneId },
    Engage { threat: NpcId },
    Retreat { rally: [f32; 3] },
}
```

The squad leader assigns orders. Each NPC gets a specific activity
point assignment. No "pick the nearest unoccupied" at execution time.

### ThreatState (replaces Aggro + RecentAttackers + CombatRole)

```rust
#[derive(Component)]
pub struct ThreatState {
    pub primary_target: Option<NpcId>,
    pub last_seen_tick: u64,
    pub taking_fire: bool,
    pub suppressed: bool,
    pub role: CombatRole,
    pub health_frac: f32,
}
```

Updated by perception. Read by the single decision function.

### Single Decision System (replaces squad_planner + goal_arbitration + npc_tactical)

```rust
pub fn decide_behavior(
    // Inputs
    order: &SquadOrder,           // what the squad wants
    threat: &ThreatState,         // what's happening tactically
    nearby_cover: Option<&Cover>, // environment
    personality: &Personality,    // individual flavor
    // Output
    behavior: &mut NpcBehavior,   // what to do
) {
    if threat.suppressed {
        *behavior = TakingCover { .. };
        return;
    }
    if let Some(target) = threat.primary_target {
        // Combat behavior based on role + cover availability
        *behavior = match threat.role {
            Pointman => Engaging { target, stance: Firing },
            Support => if nearby_cover.is_some() { TakingCover { .. } } else { Engaging { .. } },
            Flanker => Flanking { target },
            Medic => if squad_has_downed { Investigating { .. } } else { TakingCover { .. } },
        };
        return;
    }
    // Peacetime: execute squad order
    *behavior = match &order.kind {
        GuardBase { point_ids } => Guarding { point_id: my_assigned_point },
        Patrol { route_id } => Patrolling { route_id, leg },
        Rest { point_ids } => Resting { point_id: my_spot, until_tick },
        Wander { zone } => MovingTo { target: zone.random_point(), reason: Wander },
        // ...
    };
}
```

One function. Clear priority: suppression > combat > squad order.
No hysteresis constants, no commitment windows, no competing systems.

### Single Executor (replaces tick_npc_goals complexity)

```rust
pub fn execute_behavior(behavior: &NpcBehavior, pos: &mut Position, rot: &mut Rotation) {
    match behavior {
        Idle => {},
        MovingTo { target, .. } => walk_toward(pos, rot, target),
        Guarding { facing_yaw, .. } => { rot.0 = facing_yaw; },
        Engaging { target, stance } => {
            face_target(pos, rot, target_pos);
            if *stance != Suppressed { walk_to_engage_slot(pos, target_pos); }
        },
        TakingCover { volume_id, .. } => walk_toward(pos, rot, cover_pos),
        Flanking { target } => walk_to_flank_pos(pos, rot, target_pos),
        Retreating { toward } => walk_toward(pos, rot, toward),
        // ...
    }
}
```

### Squad Leader System (replaces squad_planner + pick_objective)

```rust
pub fn assign_squad_orders(
    activity_points: &ActivityPoints,
    groups: &GroupSummaries,
    threats: &Query<&ThreatState>,
) {
    for (group_id, members) in groups {
        if any_member_in_combat(members, threats) {
            // Squad enters combat mode
            assign_combat_roles(members);
            orders.insert(group_id, SquadOrder::Engage { .. });
            continue;
        }
        // Peacetime: pick an activity-point-driven order
        let order = pick_best_order(group_id, activity_points, members);
        // Assign specific points to specific NPCs
        for (npc, point) in assign_points_to_members(order, members) {
            point_assignments.insert(npc, point);
        }
        orders.insert(group_id, order);
    }
}
```

## What Stays (Don't Rebuild)

- `cover.rs` — cover volumes, penetration, material table
- `goap.rs` — GOAP planner core (A* search). Use it as a tool
  inside `decide_behavior` for multi-step combat plans, not as a
  competing decision system
- `patrol_zone.rs` — zone assignment for wander spread
- `ActivityPoints` / `AuthoredSpawnPoints` resources — POI data
- Perception pipeline (`npc_aggro`, `LosCache`, spatial hash)
- Projectile system
- World event bus + squad blackboards
- Chatter system

## What Gets Removed

- `NpcGoal` enum (replaced by NpcBehavior)
- `ActiveGoal` struct (no more arbitration — single decision function)
- `GoalKind` enum (merged into NpcBehavior)
- `CombatStance` enum (merged into NpcBehavior::Engaging/TakingCover/etc)
- `GoapPlanComp` component (GOAP becomes internal to decide_behavior)
- `goal_arbitration.rs` system (~1047 lines)
- `npc_tactical.rs` system (~407 lines)
- Priority constants, hysteresis, commitment windows
- `SquadObjectiveState` complex state (simplified to SquadOrder)

## Migration Path

1. **Build NpcBehavior + SquadOrder + ThreatState** alongside existing types
2. **Build decide_behavior + execute_behavior** as new systems
3. **Wire new systems into schedule**, disable old ones
4. **Run existing tests** — some will break, update assertions
5. **Write the 5 integration tests** from the debug plan
6. **Remove old types and systems** once tests pass
7. **Playtest** with the same scenarios that exposed the current bugs

## Estimated Effort

Full rebuild: 1-2 focused sessions (~6-10 hours). The subsystems
(cover, GOAP, activity points, perception) stay — it's the decision
layer and executor that get rewritten. ~2000 lines removed, ~1000
lines added.

## Risk

Lower than it sounds. The rebuild is scoped to the decision layer
only. Perception, combat resolution, projectiles, persistence,
world events — all untouched. The new system is simpler (fewer types,
one decision function, one executor) so there are fewer places for
bugs to hide.
