# NPC Tier Transition - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-24
**Scope:** the handoff between `simn-sim`'s online tier (full-fidelity simulation for entities near a player) and offline tier (abstract graph-level simulation for entities elsewhere). Covers what state crosses the boundary, when the handoff fires, how projection works, and how the same mechanism doubles as the core of multiplayer replication.

This is a living design doc. It captures decisions and open questions; it is not a spec.

Companions: `physics-tiering-plan.md` (a separate, orthogonal axis - see §2), `sim-hardening-plan.md` (pre-netcode work that unblocks parts of this plan), and `../walkthroughs/sim.md` (the current simulation).

---

## 1. Current State (2026-04-24)

The tier *filter* now gates simulation behavior; the tier
*handoff/projection* is still scaffolding-only.

What exists (post 2026-05-11):

- `ActiveRegions { regions: HashSet<RegionId> }` resource (a HashSet
  for O(1) `is_active`; landed 2026-05-09 per sim-hardening-plan §4).
- `Sim::set_active_region(region)` clears + inserts one region.
  Multi-region multiplayer expands later.
- `ActiveRegions::is_active(region)` is **hot**: read every tick by
  `npc_aggro` (Pass 2 region filter), `npc_combat` (per-shooter +
  early return), `tick_npc_goals` (per-NPC freeze in offline
  regions), `goal_arbitration` (per-NPC skip), `squad_planner` (per-
  NPC + per-group skip), `sweep_threats` (per-NPC skip), and
  `broadcast_npc_positions` (per-NPC filter + early return). The
  hot-systems "tier filter" landed alongside the NPC AI Stage 2
  optimization pass — see `crate-guide.md` §"Active-region tier
  filter (2026-05-11)".

What still does *not* exist:

- No projection function. There's no code that collapses online-tier
  component state into an offline-tier representation or vice versa.
  Today the filter is "skip the work for offline regions"; there's
  no separate offline schema running in parallel.
- No handoff trigger. `set_active_region` is called from `SimHost`
  when the player changes region; the new tier filter immediately
  flips that region's NPCs from "frozen" to "simulating" with no
  projection-stage intermediate.
- No offline-tier data model. Same components exist on every NPC; the
  filter just skips reading/writing them in offline regions. When
  the offline tier lands, it'll add a parallel schema (2D
  waypoint-graph state) and the projection function will translate
  between the two.

The filter is the cheap structural win that buys us time before the
full handoff pipeline lands. Maintenance systems (`age_npcs`,
`spawn_npcs`, `advance_world_time`, `tick_perishables`, etc.) still
run globally — population dynamics and time keep moving in offline
regions, the visible-NPC pipeline does not.

---

## 2. Two Tiering Axes - Don't Conflate Them

Two different tier systems live in the codebase. Keep them straight:

- **NPC fidelity tier** (this doc) - per-entity, server-side: does this NPC run the full combat / AI / wound / survival pipeline, or an abstracted graph-level version? Controls *CPU cost*.
- **Physics replication tier** (`physics-tiering-plan.md`) - per-body, per-peer: how much network bandwidth does this rigid body consume for a given client? Controls *network cost*.

They compose, they don't replace each other. An online-tier NPC with full wound pipeline can still be replicated at a reduced physics tier to a peer two regions away. An offline-tier NPC barely has physics state to replicate at all.

---

## 3. Guiding Principle

**When a player can witness an entity, the online tier is the authoritative source of truth. When no player can, the offline tier is.** State flows in one direction at a time: online → offline when the last observer leaves; offline → online when the first observer arrives.

Corollary: there is no window where both tiers simulate the same entity simultaneously and reconcile results. Overlapping state during a handoff window is fine for *interpolation* (to avoid visual pops) but one side is always the writer.

Corollary: offline-tier state is a strict subset / projection of online-tier state. The online tier can always reconstruct a valid offline-tier snapshot from its own components; the offline tier cannot reconstruct full online-tier state without extra data (equipment details, exact wound positions, pathfinding context). What the offline tier loses and what it preserves is the central design decision - §5.

---

## 4. When the Handoff Fires

Several plausible trigger definitions. Each has different pop / latency / cost tradeoffs.

| Trigger | Semantics | Pro | Con |
|---|---|---|---|
| **Hard radius** | Entity transitions the moment it crosses R meters from any player | Simple, deterministic, bounded by spatial hash | Teleport-style pops at the boundary if state diverges; oscillation for entities hovering at R |
| **Region boundary** | Entity transitions when it (or the last player) crosses a region edge | Coarse, cheap, aligns with existing `InRegion` | Abrupt when a player crosses into an empty region full of offline NPCs |
| **N-seconds unobserved** | Offline conversion only after no player has had line of sight (or been within R) for N seconds | Smooth, no visible pops during brief glances away | Expensive to track; entities hold online state during idle moments |
| **Observer-hysteresis** | Online threshold < offline threshold, so oscillation is damped | Best-feeling in practice; STALKER-adjacent | Tuning burden; two thresholds to expose |

**Decided (2026-05-05):** **region boundary trigger, no hysteresis.** The simulation runs ambivalent of player presence — when the last player exits a region, the projection function fires immediately and the offline tier takes over. When a player enters, online tier materializes instantly.

- Online → offline: entity goes offline the moment its region's observer count drops to zero. The dice keep rolling.
- Offline → online: entity goes online the instant a player enters its region.

Why no hysteresis: the world should feel alive whether or not anyone's watching. A player who flees a firefight doesn't get to "outrun" the fight - the offline tier resolves it via dice (per [`offline-tier-plan.md`](offline-tier-plan.md) §4). A player who returns 5 seconds later sees the consequences. This is the STALKER A-Life vision, taken seriously.

The cost trade: combat-in-progress at handoff resolves via dice. A squad mid-firefight that loses its observer collapses immediately to offline state, dice continue. Mitigation built into `project_online_to_offline`: in-flight projectiles resolve via weighted hit-roll on collapse (per [`physical-combat-plan.md`](physical-combat-plan.md) §9), so no shot is "lost" - every shot has an outcome.

Revisit if: player-LOS across region borders matters (sniper vantage from region A shooting into region B). That edge case may want a per-region "active vision" flag separate from "active observer," but punted until it bites.

---

## 5. The Projection Function - What Collapses, What Survives

The projection function is the central artifact of this design. The full offline-tier data model + behavior lives in [`offline-tier-plan.md`](offline-tier-plan.md); this section covers the *handoff* shape and the per-component collapse / materialize decisions. Treat the table below as the canonical projection contract; offline-tier-plan describes what offline does with the result.

It's a pure function in `simn-sim`:

```rust
pub fn project_online_to_offline(
    online: &OnlineEntityView,
    context: &ProjectionContext,
) -> OfflineEntityState;

pub fn materialize_offline_to_online(
    offline: &OfflineEntityState,
    context: &MaterializationContext,
    rng: &mut ChaCha8Rng,
) -> OnlineEntitySeed;
```

Both sides are deterministic. The forward direction (`project_online_to_offline`) is lossy. The reverse direction (`materialize_offline_to_online`) recovers a plausible, seed-driven online entity from the offline record - it cannot recover the original byte-for-byte.

### 5.1 Proposed collapse schedule

Per-component decisions. Numbers are placeholders pending first implementation. The intent column is where future-you should check design intent when editing:

| Online component | Offline representation | Intent |
|---|---|---|
| `Position` | `InRegion` + `GraphNode` (coarse waypoint) | Offline is node-graph; exact coords don't matter |
| `Rotation` | dropped | Regenerated from goal on materialize |
| `BodyParts { head, torso, l/r arm, l/r leg }` | `HealthClass::{Healthy, Wounded, Critical}` | Per-part resolution only meaningful under fire; collapse via "any limb < 25% → Wounded, vital part < 25% → Critical" per [`offline-tier-plan.md`](offline-tier-plan.md) §5. Note: NPCs and players share the BodyParts pipeline online (decided 2026-05-05); zeroed limbs disable + bleed without killing. |
| `Wounds` (Vec of discrete wounds) | folded into `HealthClass` (presence of Wounded/Critical implies wound state); chronicle preserves the kill record | Flags only; exact wound list doesn't drive offline behavior. Reconstituted plausibly on materialize via seed + HealthClass. |
| `ActiveEffects` (drugs, statuses) | `EffectFlags` bitset + `EffectExpiry` tick cap | Offline NPCs don't need per-dose timing |
| `SurvivalStats` (hunger/thirst/fatigue) | `Condition { 0.0..=1.0 }` single scalar | Collapse to one liveness number; offline deaths from survival drain are a dice roll against this |
| `Contamination` | dropped | Zones are not a thing offline |
| `Inventory` (GridInventory) | `LoadoutSummary { has_primary, ammo_bracket, meds_bracket }` | Exact grid is expensive and not consulted offline |
| `Equipment` (slots + inner grids) | folded into `LoadoutSummary` | Same |
| `NpcGoal` (FSM) | `CurrentObjective` (squad-level, not per-NPC) | Offline operates at squad granularity |
| `Aggression(f32)` | preserved | Cheap, drives offline interaction rolls |
| `Group` | preserved | Squads persist offline |
| `LastDamager` (transient) | dropped | Recomputed on materialize if relevant |
| `Aggro { target, last_seen_tick }` | preserved as `OfflineNpc::aggro_target` + `aggro_last_seen_tick`, with `combat_state` set to `Engaged { opponent, since_tick }` | Carries firefight state across the tier boundary — an NPC mid-engagement that loses its observer keeps its target on the offline side (drives `offline_combat`'s pair refresh + the `offline_movement` freeze-in-place rule) and gets its `Aggro` component re-inserted on materialize so the fight resumes without a reset. Decays via `OFFLINE_ENGAGE_STALE_TICKS` (200 sim ticks of no proximity refresh → `Idle`). |
| `Lifespan` | preserved | Offline ages NPCs at coarse tick |
| `Projectile` entities | dropped | Offline combat is dice-roll, not ballistic |

### 5.2 What's *not* lossy - the chronicle

`LifeChronicle` entries are written when NPCs are born and when they die, with regions visited in between. It is **not** a projection target - it's a parallel log that both tiers write to directly. Online-tier combat kills write to the chronicle; offline-tier dice-roll kills write to the chronicle. Readers of the chronicle (journal display, future "who lived here last week" queries) don't care which tier wrote it.

### 5.3 Materialize is seed-driven

Going the other direction, `materialize_offline_to_online` takes the offline summary plus a seeded RNG and fills in the online-tier gaps. Example: `LoadoutSummary { has_primary: true, ammo_bracket: Medium, meds_bracket: Low }` + faction + squad role → a concrete `GridInventory` with plausible contents, via the same `NpcLoadoutRegistry::build_inventory` path that spawns fresh NPCs today.

The RNG seed is derived from `(npc_id, tick_of_materialize)`, so re-materialization across a save-reload is deterministic: you reload into the same region, the same offline NPCs wake up with the same gear.

---

## 6. Event-Replay vs. State-Copy

Two implementation models for the handoff itself. These aren't mutually exclusive; one is the fast path and the other is the complete path.

### 6.1 State-copy (fast path)

At handoff, snapshot the projection/materialization function's input and write the output directly. Cheap, deterministic, no history carried.

Sufficient for most entities. If an NPC's offline behavior has been idle (no interactions with other NPCs, no combat, no faction-significant events), a state-copy round trip loses nothing the player would notice.

### 6.2 Event-replay (rich path)

At handoff, hand the offline tier the *event log* from the entity's online session. Offline can then decide which events matter long-term (NPC killed player's dog → faction relationship shifts; NPC looted a corpse → faction wealth tick). Events that don't matter long-term are dropped.

This is where the existing journal / `WorldDelta` stream earns its keep. `drain_tick_deltas` already exposes per-tick output; a handoff-scoped filter (`filter deltas by NpcId == this_entity during online_session_ticks`) gives you the event list for free.

Event-replay is required for faction-level consequences of online actions. An NPC who murders three Aegis soldiers in front of the player and then walks off the edge of the region should, in offline, result in Aegis issuing a bounty or dispatching a retaliation squad - that's an event consequence, not a state consequence.

### 6.3 Proposed composition

- Use state-copy for the entity's own physical/inventory/condition state (cheap, most entities, no consequences).
- Use event-replay for *faction-facing* events emitted during the online session (squad-level consequences, rumor propagation, chronicle entries).

This pairs well with the internal design notes design for rumor propagation: events that survive the online→offline boundary are the same events that would seed belief updates in other NPCs.

---

## 7. Relationship to Multiplayer Replication

The projection function and the replication projection are **almost the same function**. This is not a coincidence and should be leaned into deliberately.

- Offline projection: "this entity is about to not be simulated; collapse its state to the minimum needed to resume simulation later." Consumer: the offline tier.
- Replication projection: "this entity is not in this client's active zone; collapse its state to the minimum needed to render a plausible far-away silhouette and receive delta updates at a low rate." Consumer: a remote client.

Differences:

| | Offline projection | Replication projection |
|---|---|---|
| Consumer | Server-side offline tier | Remote client's mirror sim |
| Delivered over | Memory | Network |
| Persistent? | Yes (journaled) | No (reconstituted from server each session) |
| Includes behavior state? | Yes (goals, squad objective) | Usually no (client doesn't simulate) |
| Rate | One-shot on handoff | Periodic (delta stream) at reduced frequency |

Implementation consequence: design the `project_online_to_offline` signature so the same `OfflineEntityState` shape can be serialized and sent to a client as a reduced-fidelity replication payload. Don't build two projection pipelines - build one, and parameterize its output detail level.

This also means the hardening items in `sim-hardening-plan.md` (determinism harness, format versioning) are prerequisites here too: if projection is non-deterministic, offline NPCs drift across save-reloads; if the projection output format isn't versioned, a client on an older schema can't deserialize what a newer server sends.

---

## 8. The Five Concrete Code Artifacts This Plan Demands

1. `OfflineEntityState` struct in `simn-sim` - the projected schema (§5). Serializable, snapshotted. `FORMAT_VERSION` byte per `sim-hardening-plan.md`.
2. `project_online_to_offline` / `materialize_offline_to_online` functions - pure, deterministic, in `crates/simn-sim/src/tier/mod.rs` (new module).
3. Handoff system `tier_transition` - `bevy_ecs` system that observes region-active transitions and runs projection/materialization. Emits `WorldDelta::NpcWentOffline { npc_id }` / `NpcWokeOnline { npc_id, seed }` so clients can stop/start rendering and mirrors replay the same transition.
4. Offline-tick systems - the coarse equivalents of `tick_npc_goals` / `npc_aggro` / `npc_combat` that operate on `OfflineEntityState` at much lower frequency (e.g. every 30 ticks, once per in-game minute). Probably one combined system that rolls squad-level outcomes from objective + condition.
5. Determinism test (`sim-hardening-plan.md` §2) extended to exercise projection round-trips: project → materialize → project → assert equal. Catches any drift introduced by a future change to the projection schedule.

---

## 9. Open Questions

- **Regions with zero NPCs.** Offline tick cost should approach zero when a region's offline population is zero. Ensure the offline-tick system is a `run_if`-gated query, not a per-region scan.
- **Player-owned NPCs (future).** If co-op players hire NPCs (the design overview mentions this in the economy tier), those NPCs must remain online regardless of region, because their owner cares about their exact state. Special-case via a `PlayerOwned` exemption or fold into the broader "online-regardless" flag.
- **Cross-region visibility.** A player in region A with a sniper looking into region B should perceive region B's NPCs moving. Today "offline region" would mean they're not simulated at all; that's a visible bug. Mitigation: `materialize_offline_to_online` triggers on spectator-LOS, not just region-entry. Open question: cost of this check vs. frequency.
- **Journal replay boundaries.** When loading a save, `apply_external_delta` sees a stream of deltas that includes `NpcWentOffline` / `NpcWokeOnline` pairs. Replay must run projection/materialization deterministically from the saved seed - verify via the extended determinism harness.
- **LLM narration and personas (parked).** The AI-generation plan (`../walkthroughs/ai-generation.md`) treats persona as first-class sim state. Offline projection must preserve enough persona state for LLM prompts to remain coherent across handoffs. Revisit once the persona system has a concrete schema.

---

## 10. What's Blocked On This Plan

Once the projection function and offline-tick system exist, several parked designs become buildable:

- **Tactical AI** (`../walkthroughs/tactical-ai.md`) - the F.E.A.R.-class GOAP + squad layer runs online only, because it needs LOS and pathfinding. Its existence makes the online/offline fidelity gap larger, which makes a clean handoff more important, not less.
- **Belief sim** (internal design notes) - rumor propagation between NPCs runs primarily at offline tier because it's graph-level. Event-replay projection (§6.2) is the source of rumors.
- **Multiplayer replication** - per §7, the same projection shape is what goes over the network. Without this, `simn-net` can't carry per-entity replication beyond the slice-1 snapshot/delta firehose.

Not blocked: single-player gameplay, content work, UI, the current combat / inventory / crafting pipelines. All of that continues to function at today's "everything is online-tier everywhere" posture.
