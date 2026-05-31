# Squad Threat Board — Planning Doc

**Status:** v1 landed 2026-05-06 (PR #146) — data model (`LastDamager` extended, `RecentAttackers` component, `BlackboardKey::ThreatList`), `sweep_threats` aggregation, and `apply_threat_priority` target switching all live. Stage 2+ follow-ons: per-NPC chronicle of attackers (folded into `npc-character-authoring-plan.md`), tactical positioning (`cover-system-plan.md`), combat-state machine (deferred to future tactical-ai impl plan).
**Last updated:** 2026-05-09
**Scope:** extend the single-target `Aggro` component into a multi-target threat model that lets a squad concentrate fire on the right enemy when several are doing damage simultaneously. Direct response to the multi-target aggro gap noted in [`goal-arbitration-plan.md`](goal-arbitration-plan.md) §6 "Multi-target aggro for squads."

Companions: [`squad-blackboard-plan.md`](squad-blackboard-plan.md) (storage substrate), [`world-event-bus-plan.md`](world-event-bus-plan.md) (damage event broadcast), [`goal-arbitration-plan.md`](goal-arbitration-plan.md) (consumes the threat board), [`multiplayer-alife-plan.md`](multiplayer-alife-plan.md) (12-player target driving the requirement).

This is a living design doc.

---

## 1. Why this exists

Today `Aggro { target: NpcId, last_seen_tick: u64 }` is single-target. Three concrete failure modes:

1. **Spotter overwrite.** `npc_aggro` pair-scans, and a single NPC who sees both target B and target C in one tick gets two pending `Aggro` inserts; only the last wins.
2. **Combat tunnel-vision.** `npc_combat` shoots at `Aggro.target` only. A squadmate getting hit by player B keeps shooting at A (their original aggro) because being damaged doesn't update aggro. `LastDamager.faction` is the *only* attacker info we retain — no NpcId, no recency.
3. **Squad-share is sticky on first contact.** `queue_aggro` propagates the spotter's target to squadmates that don't already have aggro, but never re-flips members. So a squad ambushed by two flanking shooters splits attention permanently.

For the 12-player MP target this is a hard blocker. A 5-Lineman patrol facing 3 players from 3 angles has to have a coherent answer.

## 2. What this system does / does not do

**Does:**

- Track *who* shot each NPC, *when*, and *for how much damage* — the substrate for "current threat" reasoning.
- Aggregate squadmates' threat data into a single `BlackboardKey::ThreatList` so the squad sees a unified picture.
- Score threats by `recent damage × recency × proximity` so the squad can pick a top target with momentum-aware behavior.
- Update individual `Aggro.target` from the squad threat board with hysteresis so squads don't thrash.

**Does not:**

- Replace `Aggro` as a component. `Aggro` stays single-target — it's the *current* engagement focus, the result of arbitration, not the input. Multi-target storage lives in `RecentAttackers` (per-NPC) and the threat-board blackboard entry (per-squad).
- Decide *what* the squad does — that's still `goal_arbitration` reading the threat board. This plan supplies the input; arbitration is the consumer.
- Handle player threat ranking specifically. Players are NPCs to the threat board (their projectiles get attributed via the same path). Player-vs-player aggression isn't in scope.
- Implement combat-state machine (Approaching / Suppressing / Flanking / etc.). Threat board picks targets; tactical positioning around those targets is Stage 3.

## 3. Data model

### 3.1 `LastDamager` gains identity + tick

```rust
#[derive(Component, Clone, Copy, Debug, PartialEq, Eq)]
pub struct LastDamager {
    /// Attacker's `NpcId` (or 0 / sentinel for player-attributed
    /// damage until players also have NpcId-equivalent ids).
    pub attacker_id: NpcId,
    /// Faction. Retained so `npc_death_check` keeps producing the
    /// correct kill-credit `DeathCause::Combat { killer_faction }`.
    pub faction: FactionId,
    /// Tick of the damaging hit. Recency gating (flank bonus,
    /// "are we currently under fire") reads this.
    pub tick: u64,
}
```

### 3.2 New `RecentAttackers` component (per NPC)

```rust
/// Recent damage events on this NPC, oldest first. Capped at
/// `MAX_RECENT_ATTACKERS` (~8) entries; older entries get evicted
/// on push and entries past `THREAT_TTL_TICKS` get swept at tick
/// start. Transient — same persistence policy as `Aggro` (rebuilt
/// from combat events after load).
#[derive(Component, Clone, Debug, Default)]
pub struct RecentAttackers {
    pub events: Vec<AttackerHit>,
}

#[derive(Clone, Copy, Debug)]
pub struct AttackerHit {
    pub attacker_id: NpcId,
    pub tick: u64,
    pub damage: f32,
}
```

Constants live in `crates/simn-sim/src/systems/npc_combat.rs`:

```rust
pub const THREAT_TTL_TICKS: u64 = 600; // ~30s at 20 Hz
pub const MAX_RECENT_ATTACKERS: usize = 8;
```

### 3.3 New `BlackboardKey::ThreatList`

Reuses the existing squad-blackboard infrastructure. Values:

```rust
BlackboardKey::ThreatList → BlackboardValue::Threats(Vec<ThreatEntry>)

pub struct ThreatEntry {
    pub target_id: NpcId,
    pub score: f32,            // recency × damage × proximity
    pub last_seen_tick: u64,   // for the per-tick decay sweep
}
```

`BlackboardValue` gains a new variant; the existing `Custom { mod_id, name }` path stays.

## 4. Systems

### 4.1 `npc_combat` writes attribution

When an NPC takes a hit (existing per-tick path AND any future projectile path):

1. Insert/refresh `LastDamager { attacker_id, faction, tick }` on the victim.
2. Push to victim's `RecentAttackers.events`. Cap-evict oldest if over `MAX_RECENT_ATTACKERS`.
3. If victim has a `Group`, look up the squad blackboard's `ThreatList` and update/insert an entry for `attacker_id`. Score = `damage * 1.0` (recency factor is 1 at write time).

### 4.2 New `sweep_threats` system at tick start

For every `RecentAttackers`: drop entries with `tick + THREAT_TTL_TICKS < now`.

For every group's `ThreatList`: drop expired entries; recompute score with the recency falloff (linear from 1.0 at write-tick to 0.0 at write-tick + TTL) plus a proximity factor (1.0 within engage range, drops to 0.5 at sight radius, drops to 0 past).

### 4.3 `goal_arbitration` reads the threat board

For grouped NPCs with `Aggro` already set: if the squad's `ThreatList` has a higher-scored entry than the current target's score in that list, AND the score delta exceeds a hysteresis threshold (`THREAT_SWITCH_DELTA = 1.5×` or absolute `+2.0`), update `Aggro.target` to the top threat.

For grouped NPCs *without* `Aggro` but with a populated squad threat board (e.g., they got the threat list via squadmate radio but haven't seen the attacker themselves): set `Aggro.target` to the top entry. This is the "the rest of the squad turns to face the new shooter" behavior.

### 4.4 `LastDamager` is the legacy edge case

`npc_death_check` still uses `LastDamager.faction` for kill-credit. With the new shape, also expose the attacker NpcId so chronicle entries can name the killer specifically (out of scope for this PR but a follow-up).

## 5. Score model

```text
score(entry) = damage_sum
             × recency_factor(now, last_seen_tick)
             × proximity_factor(victim_pos, attacker_pos)
```

Where:

- `damage_sum` = sum of `event.damage` for all events with this attacker_id within TTL window.
- `recency_factor` = `clamp((TTL - elapsed) / TTL, 0.0, 1.0)` — linear falloff. At write-tick it's 1.0, at TTL it's 0.0.
- `proximity_factor` = piecewise:
  - `1.0` if dist ≤ ENGAGE_RANGE_M (30 m)
  - linear from 1.0 → 0.5 across `ENGAGE_RANGE_M..SIGHT_RADIUS_M`
  - `0.0` past sight

Values are tunable; `npc_combat.rs` owns the constants.

## 6. Hysteresis

Squad target switching has a sticky-by-default policy:

- New target must beat current target's score by ≥ 1.5× OR absolute +2.0.
- Reset only triggers when the squad has a clear high-score outlier; small wobbles between similar-scored targets don't churn the squad.

Same shape as the goal-arbitration hysteresis, just applied one layer down.

## 7. Tests

- `recent_attackers_appends_and_caps` — push more than `MAX_RECENT_ATTACKERS`, verify FIFO eviction.
- `sweep_drops_expired` — push at tick 0, sweep at tick `TTL+1`, verify empty.
- `squad_threat_board_aggregates_member_attackers` — two squadmates each take damage from a different attacker, verify both attackers in the squad threat board.
- `top_threat_picks_highest_score` — score formula spot-check.
- `aggro_switches_when_new_threat_dominates` — single NPC has `Aggro` on A; new attacker B doing 3× damage triggers switch.
- `hysteresis_blocks_minor_score_swap` — A and B within 1.2× score, no switch.

## 8. Landed in v1 (2026-05-06)

- `LastDamager` extended with `attacker_id: Option<NpcId>` + `tick: u64` (`crates/simn-sim/src/components.rs`).
- `RecentAttackers` component with `record(...)` / `sweep(...)` helpers and the `MAX_RECENT_ATTACKERS = 8` cap. Attached at every NPC spawn site (live, debug helper, snapshot reload, journal replay).
- `BlackboardKey::ThreatList` + `BlackboardValue::Threats(Vec<ThreatEntry>)` on the squad blackboard.
- `systems::threat_board::sweep_threats` aggregates members' `RecentAttackers` into the squad threat board each tick. `THREAT_TTL_TICKS = 600`. Score = `damage × recency × proximity` against the closest squadmate.
- `systems::threat_board::apply_threat_priority` switches an individual `Aggro.target` to the squad's top threat with hysteresis (`THREAT_SWITCH_MULTIPLIER = 1.5×` OR `THREAT_SWITCH_ABSOLUTE_DELTA = 2.0`).
- 7 unit tests for scoring + 7 integration tests in `tests/threat_board.rs` covering aggregation, top-score-by-damage, recency decay, target switching on dominant threats, hysteresis hold under marginal deltas, and ungrouped-NPC isolation.

Test-only scaffolding: `Sim::record_npc_hit_for_test(victim, attacker, tick, damage)` and `Sim::set_npc_aggro_for_test(victim, target)` on `world::debug` for staging integration scenarios without driving the full combat pipeline.

## 9. Out of scope

- Player threat management (player rep evolution from being-shot is a separate system, see [`faction-registry-plan.md`](faction-registry-plan.md) §3.4).
- Tactical positioning around threats (cover, flanking, suppression). Stage 3.
- Combat-state component (`InCombat::Approaching`, etc.). Stage 3.
- Cross-region threat memory (NPC remembers being shot at by you in another region). Folded into `npc-character-authoring-plan.md` chronicle persistence.

## 10. Dependencies

**Blocks:**
- Tactical-AI plan (Stage 3) — combat state machine + cover queries assume multi-target threat input.
- 12-player MP A-Life — direct prerequisite per plan §3.

**Blocked by:** nothing in flight. Squad blackboard, world event bus, goal arbitration are all on main. Faction registry migration is complete.
