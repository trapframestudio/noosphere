# Offline Tier — Planning Doc

**Status:** stub — design intent captured, no implementation yet
**Last updated:** 2026-05-05
**Scope:** the abstract simulation that runs in regions with no player observers. 2D projection of the world, waypoint-graph movement, dice-roll combat, no body-part wound state, no item instances. The "STALKER A-Life" tier — believable world activity at near-zero CPU cost. Pairs tightly with [`tier-transition-plan.md`](tier-transition-plan.md), which owns the projection function between online and offline state.

Companions: [`tier-transition-plan.md`](tier-transition-plan.md) (the boundary), [`npc-traversal-plan.md`](npc-traversal-plan.md) (waypoint-graph movement source), [`physical-combat-plan.md`](physical-combat-plan.md) (dice combat replaces online physical-projectile resolution), [`world-ledger-plan.md`](world-ledger-plan.md) (chronicle persists across tier transitions), [`world-event-bus-plan.md`](world-event-bus-plan.md) (cross-tier event propagation).

This is a living design doc.

---

## 1. Why this exists

The 12-player MP target sets a hard ceiling: 12 simultaneously online regions at full fidelity (physical projectiles, body-part wound pipeline, GOAP, navmesh A*) is the design budget. But factions live across 30+ regions on a typical map. The offline tier is what lets the world stay alive in the other ~20 regions without paying full sim cost.

**Design stance: the world simulates ambivalent of player presence.** If a player flees a firefight and exits the region, the dice keep rolling. Squads can win battles, take casualties, take territory, get wiped — entirely offscreen. When a player returns, they see the consequences, not a paused world.

The offline tier is conceptually a different game running on the same world entities — a top-down strategic sim with dice resolution. The online tier is a tactical 3D sim. Both run continuously on the server; the projection function ([`tier-transition-plan.md`](tier-transition-plan.md)) translates between them.

## 2. What this system does / does not do

**Does:**

- Simulate every NPC in regions with zero observers, at greatly reduced fidelity.
- Movement: waypoint-to-waypoint on the per-region waypoint graph (same graph used by [`npc-traversal-plan.md`](npc-traversal-plan.md) for offline pathfinding); transit time via dice roll weighted by distance + NPC speed stat.
- Combat: dice rolls weighted by NPC accuracy / cover / weapon-class advantage / personality stats; outcomes shift `HealthClass` not numeric HP.
- Squad behavior: the same objective system as online (Patrol, Guard, Investigate, Rest, Explore, Relieve, Wander) but resolved by waypoint hops and dice rather than continuous movement.
- Event consumption + emission: cross-tier event bus delivery (a faction taking a base in offline tier produces a `BaseFlip` event observable from online regions; a gunshot in online tier's edge can inform an offline squad just inside an adjacent region).
- Chronicle continuity: NPC identity, personal history, faction membership, equipment class, and personality persist unchanged across tier transitions.

**Does not:**

- Run the body-part wound pipeline (no per-limb tracking; HealthClass enum only).
- Track item instances (LoadoutClass enum substitutes; specific weapons + ammo + condition rematerialize on online projection).
- Run physical projectiles (in-flight bullets resolve immediately on tier transition; ongoing offline combat is dice ticks).
- Run pathfinding navmesh queries (waypoint graph only).
- Run the GOAP planner (objectives are still selected via [`goal-arbitration-plan.md`](goal-arbitration-plan.md), but action execution is implicit — "moving to base X" just runs waypoint hops + transit dice).
- Render or replicate to clients on a per-tick basis (offline state replicates only at tier-transition events + chronicle deltas).

## 3. Data model

```rust
// crates/simn-sim/src/offline_tier.rs
#[derive(Component, Clone, Debug)]
pub struct OfflineNpc {
    pub id: NpcId,
    pub region: RegionId,
    pub position_2d: Vec2,             // projected from heightmap; world XZ in meters
    pub waypoint: Option<WaypointId>,  // current movement target
    pub waypoint_eta_tick: Option<u64>,// when arrival roll resolves
    pub faction: Faction,
    pub group: Option<u64>,
    pub health_class: HealthClass,
    pub loadout_class: LoadoutClass,
    pub personality_seed: u64,         // deterministic reconstitution
    pub stats: NpcStats,               // accuracy, perception, etc. (same as online)
    pub combat_state: OfflineCombatState,
    pub aggro_target: Option<NpcId>,    // preserved across tier transition
    pub aggro_last_seen_tick: u64,      // mirrors online Aggro::last_seen_tick
}

#[derive(Clone, Debug)]
pub enum HealthClass {
    Healthy,                            // all body parts > 75%
    Wounded,                            // one or more limbs 25-75%; bleed possible
    Critical,                           // multi-part damage or vital part < 25%; active bleed
}

#[derive(Clone, Debug)]
pub enum LoadoutClass {
    Standard { faction: Faction, tier: GearTier },
    Elite { faction: Faction },
    Improvised,                         // wanderers, looters with mixed kit
}

#[derive(Clone, Debug)]
pub enum OfflineCombatState {
    Idle,
    Engaged { opponent: NpcId, since_tick: u64 },
    Routed { until_tick: u64 },         // fleeing
}
```

Note: chronicle (`NpcChronicle`) lives on the *entity*, shared across tier transitions — it's not duplicated between online and offline state. Same for `Personality` and `NpcStats`.

## 4. System behavior

The offline tier runs a smaller, slower schedule alongside the online schedule:

**Tick cadence:** offline tier ticks every 10 server ticks (2 Hz vs online's 20 Hz) by default. Tunable. The slower cadence is a conscious cost cut and matches the abstract grain of the simulation.

**Per-tick offline systems:**

1. `offline_movement` — for each `OfflineNpc` with `waypoint` set, check `waypoint_eta_tick`; if reached, snap `position_2d` to the waypoint, pick next waypoint via objective. Otherwise interpolate position estimate.
2. `offline_combat` — for each pair of opposing-faction `OfflineNpc`s in the same region within engagement radius, roll combat dice. Outcomes shift `HealthClass`; `Critical` + bleed roll → death + chronicle entry.
3. `offline_squad_planner` — same `squad_planner` as online but with offline-tier objective resolution (Patrol = visit 3 waypoint bases in sequence, Guard = stay near base waypoint, etc.).
4. `offline_event_emit` — produce coarse-grain events (BaseFlip, FactionCasualty) into the event bus; cross-tier delivery handles propagation.

**No** physical-projectile, body-part-tick, infection, necrosis, navmesh-A*, GOAP, or formation-offset systems run for offline NPCs. They simply don't exist at this layer.

## 5. Projection function (handoff with online tier)

Detailed in [`tier-transition-plan.md`](tier-transition-plan.md). Summary of what crosses:

**Offline → online (player enters region):**
- Spawn online entity at `(waypoint_position.xz, terrain_y)` + procedural offset from `personality_seed`.
- Materialize body parts: HealthClass → distribution (Healthy → 100% all; Wounded → roll one limb 30-60% + bleed; Critical → multi-part 10-50% + multiple bleeds).
- Materialize loadout: LoadoutClass → specific weapon + ammo + condition from faction inventory tables.
- Squad members re-formed around centroid via formation slots.
- `OfflineCombatState::Engaged` materializes as `Aggro { target, last_seen_tick }` pointing at the (also materializing) opponent.

**Online → offline (last player leaves):**
- Snap position to nearest waypoint.
- BodyParts → HealthClass: any limb < 25% → Wounded; any vital part < 25% → Critical.
- Inventory → LoadoutClass.
- In-flight projectiles resolve immediately via dice (hit-roll weighted by remaining flight time).
- Active aggro becomes `OfflineCombatState::Engaged`.

## 6. Cross-tier event propagation

The world event bus ([`world-event-bus-plan.md`](world-event-bus-plan.md)) has both online and offline subscribers. A few cross-tier cases:

- **Online event observed offline:** a gunshot in online region X at the boundary with offline region Y can wake an offline squad inside Y (HeardGunshot → flee or investigate roll). Limited radius — only events within ~100 m of the boundary cross.
- **Offline event observed online:** offline-tier `BaseFlip` events are global within the faction; online squads receive them and may switch objectives.
- **Offline event observed offline:** standard event delivery within the offline tier; no online involvement.

Cross-tier deliveries are bounded — the event bus has explicit per-kind cross-tier filters.

## 7. Dependencies

- **Blocks:** [`multiplayer-alife-plan.md`](multiplayer-alife-plan.md) (the offline tier IS the cost-relief that makes 12-player target tractable), faction-strategic AI (sim-brain operates primarily on offline state since most factions live offline most of the time).
- **Blocked by:** [`tier-transition-plan.md`](tier-transition-plan.md) (the projection function), [`npc-traversal-plan.md`](npc-traversal-plan.md) (waypoint graph), [`world-ledger-plan.md`](world-ledger-plan.md) (chronicle persistence).

## 8. Open questions

- **Engagement radius offline.** What distance triggers offline combat between opposing-faction NPCs in the same region? Online has 80 m sight radius; offline could use a coarser ~150 m to compensate for slower tick rate.
- **Stat-to-dice mapping.** Concrete formulas: how does NPC `accuracy` stat translate to attack-roll bonus? How does `Healthy` HealthClass translate to defender's hit-soak? Needs a draft formula doc, then playtest tuning.
- **Faction-strategic outcomes.** When an offline squad wins decisively, do they advance a `contestation` state (faction takes the base)? Coupling between offline combat results and the contestation system needs spec.
- **Player-witnessed transitions.** When a player enters a region mid-offline-fight, the projection function materializes both squads in their offline positions with `Aggro` set. Are the *consequences* of the dice rolls already in (e.g., Squad A has 2 casualties), or does the online tier "redo" the fight? Strong opinion: consequences are already baked in (HealthClass, member count); online resumes from there. The fight doesn't restart; it continues with full fidelity.
- **Dice cadence within offline combat.** 1 combat roll per 10-tick offline tick? Per N seconds? Fast resolution risks "fights that were 30 minutes long online resolve in 3 seconds offline." Slow resolution risks fights running for in-game days. Tentative: rolls scale with weapon RPM but capped — full firefight resolves in ~30 s offline regardless of online equivalent length.
- **Memory ceiling.** With ~30 regions × ~50 offline NPCs per region = 1500 offline entities. At ~200 bytes per `OfflineNpc`, that's 300 KB. Trivial. Online ceiling matters more.

## 9. Out of scope

- The projection function detail (lives in [`tier-transition-plan.md`](tier-transition-plan.md)).
- Physical projectile combat (lives in [`physical-combat-plan.md`](physical-combat-plan.md); offline tier explicitly does not use it).
- Per-NPC personality + character authoring (lives in [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md); offline tier consumes the same `Personality` data).
- Player-side rendering of "offline state" (clients never see offline state directly — they only see the online-tier projection at tier transition time).
