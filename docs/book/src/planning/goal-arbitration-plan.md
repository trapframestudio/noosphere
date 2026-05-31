# Goal Arbitration — Planning Doc

**Status:** v1 landed 2026-05-06 (PR #145, Stage 1 sources). Personality bias landed 2026-05-08 (PR #149): `personality_bias_for_objective(traits, objective)` re-ranks `SquadObjective` candidates per-NPC (clamped under aggro priority), and personality-introduced `GoalKind` candidates (`Hunt` / `Socialize` / `Loot` / `Bloodsport`) push as `GoalSource::PersonalityBias` candidates at priority 60. Squad-objective utility scoring landed 2026-05-09 (PR #150). Blackboard-urgency candidates landed 2026-05-11: `BlackboardUrgency` source consuming `DownedAlly` (priority 180, kind `GoalKind::RegroupOnAlly { id, pos }`), `UnderFireAt` (priority 140, kind `GoalKind::InvestigateAt { pos }`), and `HeardGunshot` (priority 40 — dropped below `SquadObjective` baseline so curiosity doesn't preempt working squads; was 100 at landing, retuned same-day after playtest showed regroup/patrol squads scattering on any audible shot). Executor branch in `tick_npc_goals` moves toward `pos` at `Bushwhacker` travel style with per-NPC `formation_offset` (members fan around the urgency point instead of stacking) and settles into `RestAt` on arrival. Determinism: multiple `DownedAlly` entries pick the lowest-id ally so two same-seed sims agree. Multi-target threat resolution landed 2026-05-06 (PR #146) via `apply_threat_priority` / `threat-board-plan.md`. **Realism overhaul 2026-05-27:** personality bias amplifier widened from `[~0.6, 1.6]` to `[~0.3, 2.5]` so personality is visible in playtest; `PersonalityTraits::introduces_goals` renamed to `introduces_drives`, returns a new `PersonalityDrive` enum that `goal_arbitration` resolves into fully-targeted `GoalKind`s via context (`CorpseIndex` for `Loot`, activity-point catalog for `Hunt`, group centroid for `Socialize`). Drive priorities are now per-drive: `Socialize` rides at `PRIO_SQUAD_OBJECTIVE + 5` (85, gated to Rest-arrived squads); `Hunt` / `Loot` ride at `PRIO_PERSONALITY_BIAS + 5..+10` (65–70). `IndividualSurvival` source added: `vital_min() < 25.0` nominates `GoalKind::SeekMedical { target_pos }` at priority 220 targeting the nearest same-faction rest spot. Remaining Stage 2 follow-ups: scripted-claim candidates, flank-bonus rule, real take-cover / suppress-back / revive behaviors (tactical-AI territory); `Bloodsport` drive is parked until an arena/sparring concept exists.
**Last updated:** 2026-05-27
**Scope:** the resolver that picks an NPC's *current* goal from multiple candidate sources — squad objective, individual aggro, blackboard urgency, scripted-quest claim. Today `tick_npc_goals` has hard-coded branching priority (`Aggro > Group > Idle`); the arbitration system formalizes this so new goal sources slot in cleanly.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 2), [`squad-blackboard-plan.md`](squad-blackboard-plan.md) (one of the goal sources), [`world-event-bus-plan.md`](world-event-bus-plan.md) (event-driven goal candidates), [`../walkthroughs/scripted-quests.md`](../walkthroughs/scripted-quests.md) (scripted claim layer), [`../walkthroughs/sim-brain.md`](../walkthroughs/sim-brain.md) (faction-strategic goal source).

This is a living design doc.

---

## 1. Why this exists

`tick_npc_goals` currently encodes priority via `if`-`else`:

```text
if has Aggro and target alive in region:
    pursue
else if has Group and group has objective:
    follow squad
else:
    solo FSM
```

This works today because there are exactly three goal sources. As the umbrella plan stages add more — blackboard urgency (`DownedAlly` → revive), bus-driven reactions (`HeardGunshot` → investigate), scripted claims (`scripted-quests` reserves an NPC for a beat), per-NPC personality biases — the branching tree breaks down. We need a small resolver that lets each source nominate a candidate goal with a priority, and picks the max.

This is the substrate F.E.A.R.'s GOAP planner sits on. GOAP is "what *actions* satisfy the goal." Arbitration is "*which* goal." Both are needed; they live at different layers.

## 2. What this system does / does not do

**Does:**

- Define a typed `GoalSource` enum and a `GoalCandidate` struct that any system can produce.
- Provide a `goal_arbitration` system that runs each tick: collects candidates from all goal-producing systems, picks max by priority + recency tiebreak, writes the result to a per-NPC `ActiveGoal` component.
- Make `tick_npc_goals` (and any future movement / combat / pursuit system) read `ActiveGoal` instead of querying source components directly.
- Give every goal source a stable priority value and a time-to-live so transient urgencies don't override long-running plans forever.

**Does not:**

- Decide *what* actions the NPC takes to satisfy the goal. That's the planner (GOAP, BT, FSM — TBD per [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md)).
- Replace squad objectives. Squad objectives are still produced by `squad_planner`; arbitration just ranks them against other sources.
- Encode squad-cohesion rules ("don't break formation to chase aggro"). Cohesion is a goal-source modifier — a low-priority "stay near centroid" candidate the formation system produces; arbitration with priority handles the rest. See open questions.

## 3. Data model

```rust
#[derive(Component, Clone, Debug)]
pub struct ActiveGoal {
    pub source: GoalSource,
    pub kind: GoalKind,
    pub target: GoalTarget,
    pub priority: u8,          // 0..=255; higher wins
    pub expires_at: Option<u64>,
}

#[derive(Clone, Debug)]
pub enum GoalSource {
    ScriptedClaim { quest_id: QuestId },
    IndividualSurvival,                  // wounded, hungry, fleeing
    SquadAggro { group: u64 },           // squad-shared aggro (bus or planner)
    IndividualAggro,
    BlackboardUrgency { key: BlackboardKey },
    SquadObjective { group: u64 },
    PersonalityBias,                      // per-NPC trait nudges (Stage 4)
    Idle,
}

#[derive(Clone, Debug)]
pub enum GoalKind {
    PursueTarget(NpcId),
    EngageTarget(NpcId),                 // already in range
    MoveTo(Vec3),
    DefendBase(BaseId),
    Investigate(Vec3),
    Revive(NpcId),
    Flee(Vec3),
    Idle,
}

#[derive(Clone, Debug)]
pub enum GoalTarget {
    Position(Vec3),
    Npc(NpcId),
    Base(BaseId),
    None,
}
```

**Default priority table (tentative):**

| Source | Priority |
|---|---|
| `ScriptedClaim` | 240 |
| `IndividualSurvival` (HP < 25%, Wounds bleeding fast) | 220 |
| `BlackboardUrgency::DownedAlly` (squad-driven revive) | 180 |
| `SquadAggro` | 160 |
| `IndividualAggro` | 150 |
| `BlackboardUrgency::HeardGunshot` | 40 |
| `SquadObjective` (Patrol/Guard/etc.) | 80 |
| `PersonalityBias` | 60 |
| `Idle` | 0 |

Numbers are illustrative; real values land via playtest.

## 4. System behavior

`goal_arbitration` runs each tick after `npc_aggro` and after the [`world-event-bus-plan.md`](world-event-bus-plan.md) drain (so blackboards reflect this tick's events). For each NPC:

1. Collect candidates from all sources:
   - `Aggro` component → `IndividualAggro` candidate (+ `SquadAggro` if shared via group).
   - Squad blackboard → urgency candidates (`DownedAlly`, `HeardGunshot`, `UnderFireAt`).
   - `SquadObjectives` for group → `SquadObjective` candidate.
   - Health / Wounds → `IndividualSurvival` if thresholds hit.
   - Scripted-quest claim store → `ScriptedClaim` if active.
2. Pick max-priority. Tiebreak by recency (lower `created_tick` wins) so long-running plans aren't preempted by their own re-derivation.
3. Compare to existing `ActiveGoal`:
   - Same `source` + `kind` + `target` → update `expires_at`.
   - New winner → write fresh `ActiveGoal`.
4. Movement / combat systems read `ActiveGoal` only.

## 5. Dependencies

- **Blocks:** any state-driven NPC behavior in Stage 2, all of Stage 3 (planner sits on top of arbitration).
- **Blocked by:** [`squad-blackboard-plan.md`](squad-blackboard-plan.md), [`world-event-bus-plan.md`](world-event-bus-plan.md) — both must exist before the resolver sees their inputs. `IndividualAggro` and `SquadObjective` already exist as data sources.
- **Adjacent:** [`../walkthroughs/scripted-quests.md`](../walkthroughs/scripted-quests.md) — the scripted-claim contract feeds into here.

## 6. Open questions

- ~~**Squad cohesion vs aggro**~~ **Decided 2026-05-05: squad aggro is priority by default; individual aggro overrides only when (a) the NPC is being flanked or (b) the NPC is being directly attacked by a different enemy than the squad's target.** Encode in arbitration: `IndividualAggro` candidate gets a +50 priority bonus when `LastDamager` was inflicted within the last N ticks AND `LastDamager.id != SquadAggro.target`, OR when the new target's bearing is in the rear/side octants relative to the current SquadAggro target's bearing. Otherwise SquadAggro outranks. This produces the observed behavior: squad coordination is the default, but a flanked NPC turns to face the new threat instead of stubbornly engaging the group target.
- **Hysteresis.** Without dampening, a frequently-flipping aggro / blackboard could cause goal-thrash. Add per-source min-duration before re-evaluation? Tentative: `ActiveGoal.expires_at` is at least N ticks in the future for non-survival sources; new candidate must beat current by ≥ 20 priority points to preempt.
- ~~**Personality bias scope**~~ **Decided 2026-05-05: personality re-ranks AND introduces new candidates** (per user direction "their personalities should drive their story forward"). See [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) §5 for the full mechanism — `bias_weights` re-rank existing candidates, `introduces_drives` (renamed 2026-05-27 from `introduces_goals`; returns `PersonalityDrive` resolved into a fully-targeted `GoalKind` by `goal_arbitration`) contributes new candidates personality-uniquely.
- ~~**Goal vocabulary**~~ **Expanded 2026-05-05** (per user direction "we will need more goals and activities — hunting, partying, bloodsport"): `GoalKind` adds `Hunt(target_or_species)`, `Socialize(group_or_individual)`, `Bloodsport(arena_or_target)`, `Loot(target)` alongside existing kinds. Personality-introduced goals are how these enter the world; without per-NPC personality these would never be nominated.
- **Concurrent claims.** If a scripted quest claims an NPC and the player blows them up, what happens? `ScriptedClaim` candidates check the NPC is alive before yielding; quest fails gracefully via the encounter dispatcher's resolved-with-outcome event.
- **Multi-target aggro for squads.** Open as of 2026-05-06: `Aggro { target: NpcId, last_seen_tick: u64 }` is single-target, so a squad attacked by multiple players ends up with each member's `Aggro` flipping to whoever was last spotted (or whoever last damaged them — the `npc_aggro` squad-share logic does NOT re-flip squadmates that already hold an aggro). Need to extend either `Aggro` to carry a small set of recent threats, or layer a `SquadThreatBoard` on top of the blackboard so arbitration can pick "highest-threat target" per tick (closest? most-damaging? most-recently-seen?). Critical for the 12-player MP target where a squad will routinely face 3-5 simultaneous shooters. Lands as a Stage 2 follow-up; see `multiplayer-alife-plan.md` for the player-density math driving the requirement.

## 7. Landed in v1 (2026-05-06)

- `ActiveGoal` component, `GoalSource` and `GoalKind` enums in `components.rs`.
- `goal_arbitration` system in `systems/goal_arbitration.rs`, scheduled between `squad_planner` and `tick_npc_goals`.
- Sources wired: `IndividualAggro` (priority 150), `SquadAggro` (160), `SquadObjective` (80), `Idle` (0).
- Hysteresis: 20-point delta to preempt; same-source re-derivations refresh `expires_at` instead of replacing.
- `tick_npc_goals` dispatches on `ActiveGoal.kind` rather than branching on source components.
- 6 unit tests cover the resolver math; 3 integration tests prove end-to-end through the schedule.

Stage 2 follow-up surface area: flank bonus, multi-target aggro, blackboard-urgency candidates, individual-survival candidates, scripted-claim candidates.

## 8. Out of scope

- Action planning (GOAP, BT). Once the goal is picked, the planner decomposes it. Different concern.
- Multi-NPC coordination beyond squad ("ambush from two sides"). That's tactical-AI walkthrough territory; arbitration just gives each NPC a goal.
- Persistence. `ActiveGoal` is derived; rebuilds from sources every tick.
