# Squad Blackboard — Planning Doc

**Status:** v1 landed 2026-05-06 (PR #145) — `SquadBlackboards` resource, typed `BlackboardKey` enum (engine facts + `Custom { mod_id, name }` mod-extension variant), per-tick `sweep_squad_blackboards` system, and `Sim::squad_blackboard(group_id)` accessor. Writers wired so far: `npc_aggro` (`LastKnownEnemyId` + `LastKnownEnemyPos`), `world_event_bus::drain_world_events` (`HeardGunshot` / `EnemySighted` / etc.), `threat_board::sweep_threats` (`ThreatList`). Readers wired: `squad_planner` (`BlackboardSignals` consumed by utility scoring), `goal_arbitration` + `apply_threat_priority`. Stage-2 follow-up: `npc_combat` / `npc_death_check` writers (`UnderFireAt`, `DownedAlly`).
**Last updated:** 2026-05-09
**Scope:** per-`Group` shared state with TTLs. Squadmates currently share exactly two things — `Group.id` membership and inherited `Aggro` target. The blackboard is the substrate that lets squadmates share *facts* — gunshot heard at X, ally down, position last seen, taking suppressing fire from direction Y.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 1 foundations), [`world-event-bus-plan.md`](world-event-bus-plan.md) (the bus that *writes* to blackboards), [`goal-arbitration-plan.md`](goal-arbitration-plan.md) (the resolver that *reads* blackboards), [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md) (the F.E.A.R.-class AI on top).

This is a living design doc.

---

## 1. Why this exists

Without a shared squad state, every NPC's world model is its own. Squadmate A spots a player, gets aggro, fires; squadmate B (no LOS) keeps patrolling because nothing told them. Today aggro has a special-case squad-share inside `npc_aggro` — that's the only fact that propagates. The blackboard generalizes the pattern: any squadmate can write a fact, any squadmate can read it.

This is the input layer for [`world-event-bus-plan.md`](world-event-bus-plan.md) (events broadcast → relevant squad blackboards updated) and the read layer for [`goal-arbitration-plan.md`](goal-arbitration-plan.md) (NPC chooses goal partly from blackboard contents). It's a small data model with big downstream leverage.

## 2. What this system does / does not do

**Does:**

- Per-`Group` typed key/value store with TTLs. Stored as a `Resource`, not per-component, so reads are O(1) by group id without iterating squadmates.
- Sweep stale entries each tick.
- Write-API for systems: `bb.set(group, key, value, ttl_ticks)`, `bb.clear(group, key)`.
- Read-API: `bb.peek(group, key) -> Option<&BlackboardValue>`, `bb.iter(group)` for AI scanning.
- Lifecycle: blackboard for a group is created when the group is created, dropped when the group dissolves (last member dies / leaves).

**Does not:**

- Replace per-NPC state. Individual `Aggro`, `NpcGoal`, `Wounds` etc. stay where they are. Blackboard is *shared* facts only.
- Persist across saves directly. Blackboard contents are derived from world state + recent events; they rebuild from journal replay. (Opinionated decision; see open questions.)
- Cross squads. There is no global blackboard. Cross-squad signaling happens via [`world-event-bus-plan.md`](world-event-bus-plan.md), which propagates spatially.

## 3. Data model

```rust
// crates/simn-sim/src/resources.rs
#[derive(Resource, Default)]
pub struct SquadBlackboards {
    by_group: HashMap<u64, GroupBlackboard>,
}

pub struct GroupBlackboard {
    entries: HashMap<BlackboardKey, BlackboardValue>,
}

#[derive(Hash, Eq, PartialEq, Clone, Debug)]
pub enum BlackboardKey {
    LastKnownEnemyPos,
    LastKnownEnemyId,
    DownedAlly { id: NpcId },
    HeardGunshot,
    Suppressed { from_dir: u8 },        // octant
    UnderFireAt,
    LeaderId,
    RallyPoint,
    Reinforcing { target_group: u64 },
}

pub enum BlackboardValue {
    Position(Vec3),
    NpcRef(NpcId),
    GroupRef(u64),
    Tick(u64),
    Float(f32),
    Bool(bool),
}

#[derive(Clone)]
pub struct BlackboardEntry {
    pub value: BlackboardValue,
    pub written_tick: u64,
    pub ttl_ticks: u32,
}
```

The `BlackboardKey` enum is closed and typed (not strings) so the compiler catches typos and the consumer knows the value shape. When new fact-types are needed, add an enum variant.

## 4. System behavior

- **Sweep system** runs every tick early in the schedule: walks each group's entries, drops any with `written_tick + ttl_ticks <= current_tick`. Cheap (linear in active entries; bounded by ~10–20 entries per group in practice).
- **Group lifecycle:** `npc_join_group` writes a fresh `GroupBlackboard` when a new group spawns; `npc_death_check` removes a `GroupBlackboard` when its last member dies.
- **Write sites:**
  - `npc_aggro`: on new aggro acquisition, write `LastKnownEnemyId` + `LastKnownEnemyPos` with TTL ~200 ticks (matches aggro decay).
  - `npc_combat`: on hit taken, write `UnderFireAt` + `Suppressed { from_dir }`.
  - `npc_death_check`: on squadmate death, write `DownedAlly { id }` to the dead NPC's group blackboard with longer TTL (~600 ticks) so the squad reacts.
  - [`world-event-bus-plan.md`](world-event-bus-plan.md) — propagates events from outside the squad: heard gunshot, witnessed corpse, etc.
- **Read sites:**
  - `tick_npc_goals` aggro branch: prefer `LastKnownEnemyPos` over re-scanning if aggro is set.
  - `squad_planner`: blackboard urgency (e.g., `DownedAlly` present, `UnderFireAt` present) overrides random objective rolls.
  - [`goal-arbitration-plan.md`](goal-arbitration-plan.md): blackboard contents are one of the goal sources the resolver considers.

## 5. Dependencies

- **Blocks:** [`world-event-bus-plan.md`](world-event-bus-plan.md) (event bus needs a place to write per-group facts), [`goal-arbitration-plan.md`](goal-arbitration-plan.md) (resolver reads blackboards), most of Stage 3.
- **Blocked by:** nothing major. Could land before [`combat-los-plan.md`](combat-los-plan.md). The two compose: combat LOS gates the cache; blackboard publishes the result.

## 6. Open questions

- ~~**Persistence**~~ **Decided 2026-05-05: rebuild from world state on tier transition.** Blackboards are derived state, cheap to recompute, and STALKER's design works the same way. No journal entries for blackboard contents.
- **Cross-region groups.** A squad migrating across regions (Explore objective) — does the blackboard travel? **Decided: yes** (the group is the keying entity, not the region). Event-bus subscriptions remain spatial, so a relocated squad stops receiving local events from its origin.
- ~~**Reorganized squads.**~~ **Decided 2026-05-05: per-NPC history persists across squad joins** (per user direction "if that individual has a past, it shouldn't be lost because he joins another group"). Implementation: per-NPC chronicle (lives in [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md)) carries personal history. The squad blackboard is reset to clean slate when joining (group-level state isn't inherited), but the NPC's own chronicle is unchanged.
- **Memory bound.** With M groups and ~20 entries each, M=200 groups × 20 = 4000 entries — trivial. No concern.
- ~~**Closed enum vs string keys**~~ **Decided 2026-05-05: typed enum core + string-keyed modding extension API.** Engine-level facts use `BlackboardKey` enum (type-safe, reviewable schema). A `BlackboardKey::ModExtension(ModId, Cow<'static, str>)` variant carries mod-defined keys; modding-friendly write helpers smooth the rough edges. Mods can read/write their own keys without forking the enum. Modding-engineer agent owns the ergonomic API design when it lands.

## 7. Out of scope

- Per-NPC personal blackboard (memories, beliefs about specific entities). That's [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md) "tactical memory" — different scope, NPC-keyed not group-keyed, longer TTLs, possibly journaled.
- Faction-level blackboard (PWA's strategic decisions). That's `sim-brain.md` walkthrough territory.
- Cross-squad signaling. Handled by [`world-event-bus-plan.md`](world-event-bus-plan.md) — events with spatial decay propagate to all relevant squads.
