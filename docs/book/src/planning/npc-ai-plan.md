# NPC AI — Umbrella Plan

**Status:** umbrella plan; sequences existing plans + identifies gaps. Stage 1 foundations are now substantially landed (pathfinding, terrain Y, determinism, LOS cache, squad blackboard, world event bus, NPC body-part substrate); Stage 2 has begun with state-driven squad objectives, multi-target threat board, goal arbitration, and per-NPC identity (stats / personality / rank / names / lived-experience).
**Last updated:** 2026-05-09
**Scope:** an ordered roadmap from today's NPC simulation in `crates/simn-sim/` to S.T.A.L.K.E.R. + F.E.A.R.-class behavior, plus multiplayer-aware extensions. This doc indexes the existing plans, identifies what still needs a plan, and stages the work so dependencies are explicit.

This is a living design doc. Concrete designs live in their own plans; this doc's job is **sequencing and gap discovery**, not duplicating their content.

Companions:
- Plans: [`npc-traversal-plan.md`](npc-traversal-plan.md), [`tier-transition-plan.md`](tier-transition-plan.md), [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md), [`contestation-plan.md`](contestation-plan.md), [`loot-and-economy-plan.md`](loot-and-economy-plan.md), [`world-ledger-plan.md`](world-ledger-plan.md), internal design notes, [`sim-hardening-plan.md`](sim-hardening-plan.md), [`weapons-plan.md`](weapons-plan.md), [`destruction-plan.md`](destruction-plan.md), [`dismemberment-plan.md`](dismemberment-plan.md).
- Walkthroughs (design-detailed but not shipped): [`tactical-ai.md`](../walkthroughs/tactical-ai.md), [`sim-brain.md`](../walkthroughs/sim-brain.md), [`ai-generation.md`](../walkthroughs/ai-generation.md), [`scripted-quests.md`](../walkthroughs/scripted-quests.md).

---

## 1. Where we are today (2026-05-09)

The NPC system is substantially more capable than the 2026-05-05 baseline. Stage 1 foundations are mostly landed and the Stage 2 first slice is on main. Inventory of what works:

- **Spawning** — faction-aware via `PopulationTargets`, squad sizes faction-flavored (Wanderers 65/25/10 solo/pair/trio, PWA/Linemen 4–5, Looters 3–5). Squads spawn pre-grouped at faction-base anchors with ±6 m spread; lifespans staggered (30k–80k ticks). Each NPC carries `NpcCharacter { character_id, name, nationality, stats, personality, rank, kills }` derived deterministically from `(npc_id, faction_id, archetype)`.
- **Squad cohesion** — every-tick centroid check; cohesion-break threshold scales per-squad by `cohesion_multiplier_for_leadership(mean_leadership)` (≈56 m for unled grunts, ≈104 m for leader-rich squads, 80 m baseline).
- **Squad objectives** — utility-based selection every 200 ticks. Each candidate's score is `base_weight × personality_fractions × blackboard_signals`; `SquadPersonality` aggregates trait fractions per group, `BlackboardSignals` reads `HeardGunshot` / `LastKnownEnemyPos` / `UnderFireAt`. Goal-arbitration personality bias re-ranks candidates per-NPC. Trait nudges (Disciplined → Patrol/Guard, Curious → Investigate/Explore, Aggressive → no-Rest, Solitary → Wander, Loyal → Guard) compose multiplicatively.
- **Movement** — Rust-side A* pathfinding (`nav.rs`) with `TravelStyle::{RoadHugger, Mixed, Bushwhacker}` per NPC role. `Path` component caches waypoints; `tick_npc_goals` consumes them in all three branches with straight-line fallback on path failure.
- **Terrain** — `clamp_npc_terrain_y` snaps every NPC's Y to the heightmap each tick when their region has attached terrain.
- **Perception** — per-tick spatial hash + position index. Aggro gates on faction relation, FOV cone, distance (per-NPC, scaled by `sight_radius_for_perception(perception, base)` linear in `[0.6, 1.4]` over perception 0..=100), and `LosProvider::exposure` (cached per-tick in `LosCache`).
- **Body-part wounds for NPCs** — `BodyParts` + `Wounds` + `LimbStates` + `ActiveEffects` are now NPC-too (used to be player-only). Same bleed / treatment / infection / necrosis pipeline runs for every entity. Endurance scales the bleed-rate multiplier per NPC.
- **Squad blackboards** — typed `BlackboardKey` enum per `Group`. Writers: `npc_aggro` (`LastKnownEnemyId/Pos`), event-bus drain (`HeardGunshot` / `EnemySighted` / etc.), `sweep_threats` (`ThreatList`). Readers: `squad_planner` (`BlackboardSignals`), `goal_arbitration`, `apply_threat_priority`. Modding extension via `Custom { mod_id, name }`.
- **World event bus** — `WorldEventQueue` resource with `WorldEventKind::{Gunshot{caliber_class}, Explosion, AllyDown, EnemySighted, CorpseSpotted, BaseFlip, PlayerSighted, PortalUsed, Chatter, ModExtension}`. `drain_world_events` runs at tick start with per-kind audible-radius + `Audience` filter. Emitters wired: `npc_aggro` → `EnemySighted`, `npc_combat` → `Gunshot` (2026-05-11), `npc_death_check` → `AllyDown` (2026-05-11).
- **Multi-target threat board** — `RecentAttackers` per-NPC + per-squad `BlackboardKey::ThreatList`. `sweep_threats` aggregates damage × recency × proximity; `apply_threat_priority` switches `Aggro.target` to the squad's top threat with hysteresis (1.5× or +2.0).
- **Goal arbitration** — typed `GoalSource` / `GoalKind`, priority-based winner-picks-all with a 20-point hysteresis. Stage 1 sources wired (`IndividualAggro` 150, `SquadAggro` 160, `SquadObjective` 80, `Idle` 0); personality bias adds the four personality-introduced kinds (`Hunt` / `Socialize` / `Loot` / `Bloodsport`) at priority 60. Blackboard-urgency consumer landed 2026-05-11: `BlackboardUrgency` source nominates `RegroupOnAlly { id, pos }` from `DownedAlly` (180), `InvestigateAt { pos }` from `UnderFireAt` (140), and `InvestigateAt { pos }` from `HeardGunshot` (40 — dropped below `SquadObjective` baseline so curiosity doesn't pull working squads off-task; idle / personality-biased NPCs still react); executor moves toward `pos` at `Bushwhacker` style until member-arrival radius, with per-NPC `formation_offset` so squad members fan around the urgency point instead of stacking.
- **Per-NPC stat integrations** — `perception` scales sight, `endurance` damps bleed, `leadership` stretches squad cohesion, `accuracy` scales `npc_combat` hit-chance.
- **Universal NpcRank** — Rookie / Experienced / Veteran / Master / Legend ladder shared across factions, derived from `combat_competence` (sum of accuracy + perception + marksmanship + endurance + luck). `LivedExperience::record_kill` bumps `kills` (saturating u16) and re-derives rank via `+3 effective competence` per kill.
- **Squad-shared aggro propagation via the threat board** — when any squadmate gets hit, the squad's `ThreatList` aggregates and arbitrates target switches.
- **Squad-shared aggro on first contact** — when one member acquires a hostile, unaggroed squadmates inherit the same target.
- **Region crossings** — Explore squads teleport through portals on arrival.
- **Persistence + determinism** — `LifeChronicle` + journal + snapshot. Determinism harness (`tests/determinism.rs`) proves byte-identical snapshots tick-for-tick on this platform.

What doesn't work yet:

- **Pathfinding has no static obstacles.** Phase-1 grid is heightmap-traversability only (slope > ~35° + Water/Cliff features = impassable). OSM buildings + hand-placed obstacles are phase 2 of [`npc-traversal-plan.md`](npc-traversal-plan.md).
- **NPC combat is still placeholder.** `npc_combat` rolls a distance-bucketed hit chance scaled by aggression + accuracy stat, gated by an interim `LosCache` read (no entry or exposure < 0.33 → no shot). No projectile collision (player-side projectile pipeline exists but NPCs don't use it yet), no cover, flanking, suppression, reload, retreat, callouts. The shared `Projectile` ECS path is the next slice ([`physical-combat-plan.md`](physical-combat-plan.md)).
- **World event bus has remaining emitters to wire.** `EnemySighted` (npc_aggro), `Gunshot` (npc_combat), `AllyDown` (npc_death_check), and `BaseFlip` (placeholder via `offline_combat` 2026-05-12 + online-tier `base_capture_check` 2026-05-25 — see [`contestation-plan.md`](contestation-plan.md)) are live. `PortalUsed` (from npc_portal_cross), `CorpseSpotted` (observer-side, needs a corpse-perception pass over `WorldContainer`s), and `Chatter` (from squad coordination) are still TODO; the full contestation system also still owes a real `BaseFlip` source that supersedes both placeholders.
- **Blackboard-urgency executor is the move-toward stub.** `goal_arbitration` now nominates `RegroupOnAlly` / `InvestigateAt` candidates from the blackboard; `tick_npc_goals` walks toward the position at `Bushwhacker` style. Real take-cover / suppress-back / revive behaviors are tactical-AI work that lands on top of the cover system.
- **No tier transitions.** Spatial hash + per-tick caching layer made every-region-online affordable; the offline-tier abstract sim still does not exist ([`offline-tier-plan.md`](offline-tier-plan.md), [`tier-transition-plan.md`](tier-transition-plan.md)).
- **NPC identity is partial.** Names, nationality, personality traits, rank, lived-experience kill counter are landed. Backstory templates, `Templated` / `AIGenerated` / `Scripted` authoring tiers, persistent kill counter across snapshot reload, and the personality-introduced goal executors are still ahead.
- **Cross-squad signaling beyond the bus is shallow.** Adjacent friendly squads notice each other through `EnemySighted` propagation, but there's no faction-strategic layer that re-routes patrols when a base goes hot or a squad takes heavy losses.

---

## 2. Stages

### Stage 1 — Foundations (blockers)

These unblock everything else. Without them, even excellent strategic + tactical AI has nowhere to put its decisions.

| Piece | Plan | Status |
|---|---|---|
| Pathfinding — Rust-side, online navmesh + offline waypoint graph | [`npc-traversal-plan.md`](npc-traversal-plan.md) | ✅ phase 1 landed 2026-05-05/06 (PR #145); phase 2 (OSM/hand-placed obstacles) pending |
| Terrain Y integration (`clamp_npc_terrain_y`) | [`npc-traversal-plan.md`](npc-traversal-plan.md) §spawn safety | ✅ landed |
| Determinism / replay harness | [`sim-hardening-plan.md`](sim-hardening-plan.md) | ✅ landed 2026-05-06 (PR #145) |
| Combat LOS query primitive | [`combat-los-plan.md`](combat-los-plan.md) | ✅ landed 2026-05-06 (PR #145) |
| Squad blackboard data model | [`squad-blackboard-plan.md`](squad-blackboard-plan.md) | ✅ landed 2026-05-06 (PR #145) |
| World event bus (priority queue + spatial decay + chatter) | [`world-event-bus-plan.md`](world-event-bus-plan.md) | ✅ landed 2026-05-06 (PR #145); only one emitter wired so far |
| NPC body-part unification + limb zeroing | [`dismemberment-plan.md`](dismemberment-plan.md) | ✅ step 1 landed 2026-05-07 (PR #147) |

Notes:
- Combat LOS reuses the exposure sampler `npc_aggro` already calls; the gap is connecting it to `npc_combat`, plus a small per-tick caching layer.
- Squad blackboard is a small per-`Group` `HashMap<Key, Value>` with TTLs; the data layout isn't the hard part, the contract for what goes in it is.
- World event bus is the AI-propagation cousin of [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md) — different scope (emergent events vs authored triggers) and different consumers (squad blackboards / belief sim, not gameplay runners). Promoted from "section in dispatcher" to its own plan after reading the dispatcher plan's stated scope-not exclusions.

### Stage 2 — Strategic / A-Life

What turns the world from "things wandering" into "things that have reasons." Most pieces have plans.

| Piece | Plan | Status |
|---|---|---|
| State-driven objectives (utility-based selection) | [`goal-arbitration-plan.md`](goal-arbitration-plan.md) + [`world-event-bus-plan.md`](world-event-bus-plan.md) | ✅ utility scoring landed 2026-05-09 (PR #150); blackboard-urgency goal candidates still pending |
| Multi-target threat board | [`threat-board-plan.md`](threat-board-plan.md) | ✅ v1 landed 2026-05-06 (PR #146) |
| Goal arbitration (resolving conflicting goals on a single NPC) | [`goal-arbitration-plan.md`](goal-arbitration-plan.md) | ✅ v1 + personality bias landed 2026-05-06/08 (PR #145, #149); blackboard-urgency + survival sources pending |
| NPC character authoring (procedural identity) | [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) | ✅ steps 1–3 landed 2026-05-08 (PR #147–#149); backstory templates + persistent kill-count still ahead |
| Faction registry migration (TOML-driven, drift journaling, debug colors) | [`faction-registry-plan.md`](faction-registry-plan.md) | ✅ all 7 steps landed 2026-05-06 |
| Offline tier (2D + waypoint + dice abstraction) | [`offline-tier-plan.md`](offline-tier-plan.md) | Stub |
| Tier transitions (online↔offline handoff) | [`tier-transition-plan.md`](tier-transition-plan.md) | Detailed draft (no-hysteresis decision locked 2026-05-05) |
| Faction territory dynamics | [`contestation-plan.md`](contestation-plan.md) | Draft |
| Faction economy + equipment circulation | [`loot-and-economy-plan.md`](loot-and-economy-plan.md) | Draft |
| Persistent world ledger (chronicle / corpses / containers) | [`world-ledger-plan.md`](world-ledger-plan.md) | Draft |
| Cross-map tactical memory (per-NPC, region-spanning, decay) | partial — chronicle persistence in [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md); deeper "tactical memory of the player" deferred to future `tactical-ai-plan.md` | Partial |

Tier transitions are the load-bearing piece for anything past current entity counts. Stage 2 ships a few systems' worth of state-driven behavior in active regions before tier transitions are strictly required, but the work should land before NPC populations grow much.

### Stage 3 — Tactical (F.E.A.R.-class)

The moment-to-moment combat behavior. The walkthrough is detailed; sub-pieces need impl plans.

| Piece | Plan | Status |
|---|---|---|
| Physical combat — online projectile sim + offline dice | [`physical-combat-plan.md`](physical-combat-plan.md) | Stub (new 2026-05-05) |
| GOAP + squad coordination (the spine) | [`tactical-ai.md`](../walkthroughs/tactical-ai.md) | Walkthrough only |
| Cover system (geometry abstraction + queries) | [`cover-system-plan.md`](cover-system-plan.md) | Stub (server-authoritative + full re-bake decided 2026-05-05) |
| Combat-state component (`InCombat::{Approaching, Engaging, Suppressing, Flanking, Retreating}`) | **DEFERRED** — section in future `tactical-ai-plan.md` | Not planned |
| Squad fire discipline + dialog callouts (chatter event already in bus) | [`tactical-ai.md`](../walkthroughs/tactical-ai.md) + [`world-event-bus-plan.md`](world-event-bus-plan.md) §3 (Chatter event kind) | Walkthrough + stub |
| Reload / weapon-state behavior | [`weapons-plan.md`](weapons-plan.md) (ballistics) + [`physical-combat-plan.md`](physical-combat-plan.md) (per-NPC fire decisions) | Composes |
| Wound / IK reactions in combat | [`dismemberment-plan.md`](dismemberment-plan.md) | Draft |

Stage 3 depends on Stage 1's pathfinding (NPCs need to *go* to cover) and combat LOS (cover only matters when sightlines actually gate damage).

### Stage 4 — Beyond STALKER

The differentiating layer. Most of this is design-locked and parked; what's missing is integration plans.

| Piece | Plan | Status |
|---|---|---|
| Three-layer narrative (scripted → brain → AI-gen) | [`scripted-quests.md`](../walkthroughs/scripted-quests.md), [`sim-brain.md`](../walkthroughs/sim-brain.md), [`ai-generation.md`](../walkthroughs/ai-generation.md), internal design notes | Design-locked 2026-04-15 |
| NPC personality + procedural identity | [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) | Stub (new 2026-05-05; promoted from "deferred Stage 4" since per-NPC identity is now first-class) |
| Multiplayer-aware A-Life (12-player target) | [`multiplayer-alife-plan.md`](multiplayer-alife-plan.md) | Stub (12-player + no-hysteresis decided 2026-05-05) |
| Replay-driven tuning (journal as story-extraction tool) | Journal exists; no consumer | Gap, lower priority |
| Hybrid GOAP + neural priors | Mentioned in `tactical-ai.md`; not specced | Gap, exploratory |

---

## 3. Dependency graph

```
Stage 1 — Foundations
  pathfinding ──┬──> Stage 2 movement-dependent objectives
                └──> Stage 3 cover positioning
  terrain Y ────────> all visible NPC behavior
  determinism ───────> tier transitions, netcode
  combat LOS ───────> Stage 3 combat resolution
  squad blackboard ──> Stage 3 squad coordination
  world event bus ───> Stage 2 state-driven objectives

Stage 2 — A-Life
  state-driven objectives ←── event bus
  contestation ───────────────> Stage 4 multiplayer A-Life (territory replicates)
  loot & economy ─────────────> chronicle, world ledger
  tier transitions ───────────> Stage 4 multiplayer A-Life (offline tier is multiplayer-safe by construction)
  world ledger ───────────────> persistent identity, cross-map memory

Stage 3 — Tactical
  GOAP ────── needs squad blackboard, pathfinding, cover, LOS
  combat states ──── needs all of Stage 1
  fire discipline ── on top of GOAP

Stage 4 — Beyond
  3-layer narrative ──── needs Stage 2 (event bus, persistent identity)
  personality system ── extends GOAP/blackboard with per-NPC weights
  multiplayer A-Life ── built on tier transitions
```

---

## 4. Suggested implementation sequence

The dependency graph forces most of the order. A reasonable concrete sequence:

1. ✅ **Pathfinding + terrain Y** ([`npc-traversal-plan.md`](npc-traversal-plan.md)) — phase 1 landed 2026-05-05/06 (PR #145). Rust-side uniform-grid A* with `TravelStyle` cost mults, `Path` component on NPCs, `clamp_npc_terrain_y` system. Phase 2 (static-obstacle bake from OSM / hand-placed obstacles) still pending.
2. ✅ **Determinism harness** ([`sim-hardening-plan.md`](sim-hardening-plan.md)) — landed 2026-05-06 (PR #145). Tick-200 byte-identical assertion plus stable entity-sort + `det_serde::sorted_map` adapters.
3. ✅ **Combat LOS query primitive** ([`combat-los-plan.md`](combat-los-plan.md)) — landed 2026-05-06 (PR #145). `LosCache` resource, asymmetric per-direction entries, `Sim::los_exposure` accessor, gdext bridge.
4. ✅ **Squad blackboard** ([`squad-blackboard-plan.md`](squad-blackboard-plan.md)) — landed 2026-05-06 (PR #145). Typed `BlackboardKey` enum, per-tick sweep, modding extension via `Custom { mod_id, name }`.
5. ✅ **World event bus** ([`world-event-bus-plan.md`](world-event-bus-plan.md)) — landed 2026-05-06 (PR #145). Full event-kind enum, per-kind audience filter, `drain_world_events` at tick start. Emitters wired: `npc_aggro` → `EnemySighted` (PR #145), `npc_combat` → `Gunshot` (2026-05-11), `npc_death_check` → `AllyDown` (2026-05-11), `offline_combat` → placeholder `BaseFlip` (2026-05-12), `base_capture_check` → online-tier `BaseFlip` (2026-05-25; see [`contestation-plan.md`](contestation-plan.md) placeholder note). Remaining emitters: `PortalUsed`, `CorpseSpotted`, `Chatter`, plus a real contestation source that supersedes both `BaseFlip` placeholders.
6. ✅ **NPC body-part unification + limb zeroing** ([`dismemberment-plan.md`](dismemberment-plan.md)) — step 1 landed 2026-05-07 (PR #147). NPCs carry `BodyParts` + `Wounds` + `LimbStates` + `ActiveEffects`. Caliber-driven `WoundKind::Sever` + reactive IK still planning.
7. **Physical combat — online projectile sim** ([`physical-combat-plan.md`](physical-combat-plan.md)) — extend the player projectile pipeline to NPC weapons. Per-tick projectile budget. Aim cone driven by NPC accuracy stat. **Player projectile path is live; NPC migration still pending.**
8. ✅ **NPC character authoring** ([`npc-character-authoring-plan.md`](npc-character-authoring-plan.md)) — steps 1–3 landed 2026-05-08 (PR #147–#149). `NpcCharacter` with stats, personality traits, names + nationality buckets, universal rank ladder, lived-experience kill counter. Backstory templates + persistent kill-counter across reload still pending.
9. ✅ **Goal arbitration** ([`goal-arbitration-plan.md`](goal-arbitration-plan.md)) — v1 landed 2026-05-06 (PR #145), personality bias landed 2026-05-08 (PR #149), blackboard-urgency consumer landed 2026-05-11 (`DownedAlly` / `UnderFireAt` / `HeardGunshot` nominated as `BlackboardUrgency`-source candidates with new `GoalKind::RegroupOnAlly` / `InvestigateAt` variants). Individual-survival + scripted-claim candidates and the flank-bonus rule still pending.
10. ✅ **State-driven squad objectives** — landed 2026-05-09 (PR #150): per-objective utility = `base_weight × personality_fractions × blackboard_signals` with deterministic max-utility pick. `SquadPersonality` aggregates trait fractions per group; `BlackboardSignals` reads `HeardGunshot` / `LastKnownEnemyPos` / `UnderFireAt`. Trait nudges (Disciplined → Patrol/Guard, Curious → Investigate/Explore, Aggressive → no-Rest, Solitary → Wander, Loyal → Guard) compose multiplicatively. `objective_utility` exposed for unit tests.
10a. ✅ **Multi-target threat board** ([`threat-board-plan.md`](threat-board-plan.md)) — landed 2026-05-06 (PR #146). Inserted between (9) and (10) once 12-player MP analysis surfaced the gap.
11. **Offline tier** ([`offline-tier-plan.md`](offline-tier-plan.md)) — 2D + dice abstraction. Required before tier transitions are useful. **Pending.**
12. **Tier transitions** ([`tier-transition-plan.md`](tier-transition-plan.md)) — projection function between online and offline tiers. **Pending.**
13. **Cover system** ([`cover-system-plan.md`](cover-system-plan.md)) — pre-bake pipeline + runtime queries; first F.E.A.R.-shaped tactical work. Needs #1 (pathfinding) and #3 (LOS), both of which are now landed. **Pending.**
14. **Tactical-ai impl plan** — graduates the walkthrough into a real impl plan; folds in combat-state machine, GOAP planner, cross-map tactical memory of the player. **Pending.**
15. **Three-layer narrative** — the parked primary-priority initiative; unblocks once event bus + persistent identity are settled. Event bus is landed; persistent identity is partial. **Pending.**
16. **Multiplayer-aware A-Life** ([`multiplayer-alife-plan.md`](multiplayer-alife-plan.md)) — last; composes on top of tier transitions, world ledger, and the netcode work. 12-player target validates the architecture. **Pending.**

---

## 5. New plan docs

The umbrella identified eight gap topics in its first pass. The decisions-locked-in pass (2026-05-05) added three more new plans on top of the original six, and resolved the deferred items via [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) (which subsumes most of the "future tactical-ai-plan" content for personality + per-NPC history).

| Gap | Resolution |
|---|---|
| Combat LOS query primitive | [`combat-los-plan.md`](combat-los-plan.md) (now scoped down — see [`physical-combat-plan.md`](physical-combat-plan.md) for combat resolution) |
| Squad blackboard data model | [`squad-blackboard-plan.md`](squad-blackboard-plan.md) |
| World event bus | [`world-event-bus-plan.md`](world-event-bus-plan.md) |
| Cover system | [`cover-system-plan.md`](cover-system-plan.md) |
| Goal arbitration | [`goal-arbitration-plan.md`](goal-arbitration-plan.md) |
| Multiplayer-aware A-Life | [`multiplayer-alife-plan.md`](multiplayer-alife-plan.md) |
| Offline tier (2D + dice) | [`offline-tier-plan.md`](offline-tier-plan.md) **(new 2026-05-05)** — replaces the vague "abstract simulation" framing with a concrete 2D + waypoint + dice model |
| Physical combat (online) + dice fallback (offline) | [`physical-combat-plan.md`](physical-combat-plan.md) **(new 2026-05-05)** — server-authoritative projectile sim for online tier, dice for offline; replaces the earlier "extend hitscan dice" framing |
| NPC character authoring (personality + identity) | [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) **(new 2026-05-05)** — procedural per-NPC name / backstory / rank / personality / stats; subsumes the previously-deferred "personality data model" gap |
| Cross-map tactical memory | partially absorbed by [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) (per-NPC chronicle survives across squad joins, regions, tier transitions); deeper "tactical memory of the player" extension still defers to a future `tactical-ai-plan.md` |
| Combat-state component (`InCombat::{Approaching, Engaging, …}`) | DEFERRED — still belongs in future `tactical-ai-plan.md`; [`physical-combat-plan.md`](physical-combat-plan.md) addresses the firing side, not the higher-level combat state machine |

---

## 6. Open questions

### Decided 2026-05-05

- ~~**Pathfinding granularity**~~ → **Rust-side**, deterministic, navmesh data shared between online + offline tiers. Reasoning: replay determinism (Godot's `NavigationServer3D` drifts across engine versions), dedicated-server posture (server runs without Godot), latency. See [`npc-traversal-plan.md`](npc-traversal-plan.md) §1.
- ~~**Personality authoring path**~~ → **seeded procedural** ([`npc-character-authoring-plan.md`](npc-character-authoring-plan.md)). Optional AI-gen layer fills noteworthy NPCs at world-init.
- ~~**Multiplayer A-Life latency budget**~~ → **12-player target.** Server must handle up to 12 simultaneously online regions. Cost relief from offline tier ([`offline-tier-plan.md`](offline-tier-plan.md)).
- ~~**Combat resolution model**~~ → **physical projectiles online, dice offline** ([`physical-combat-plan.md`](physical-combat-plan.md)). Player + NPC weapons share the existing `Projectile` ECS path online.
- ~~**NPC damage pipeline**~~ → **NPCs use the same body-part wound system as players** ([`dismemberment-plan.md`](dismemberment-plan.md) §2). Limb zeroing disables + bleeds but doesn't kill.
- ~~**Tier transition handoff**~~ → **no hysteresis, ambivalent simulation** ([`tier-transition-plan.md`](tier-transition-plan.md) §4). Region online when ≥1 player present; offline immediately when last player leaves. Combat-in-progress collapses via dice resolution.
- ~~**Per-NPC identity persistence**~~ → **chronicle survives squad joins, region transitions, tier transitions.** A character is keyed on `CharacterId`, not on which group they're currently in.

### Still open

- **Tactical-ai walkthrough → plan transition.** [`tactical-ai.md`](../walkthroughs/tactical-ai.md) is design-detailed but lives in `walkthroughs/`. Either move/copy it to `planning/tactical-ai-plan.md` with the walkthrough kept as aspirational, or write a separate impl plan that references the walkthrough. Personality + per-NPC chronicle (originally deferred to this future plan) are now covered by [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md); residual scope is the GOAP planner + combat-state machine + cross-map tactical memory of the player. Decision still open.
- **Cover invalidation in-memory delta layer.** Full re-bake on destructible flip is decided ([`cover-system-plan.md`](cover-system-plan.md) §7); the in-memory delta layer that bridges between bake invalidation and re-bake completion is TBD. Concrete protocol lands when destruction integration starts.
- **Vertical cover (windows / peek-shoot).** Defer to tactical-ai impl phase.
- **12-region stress-test methodology.** Need a benchmark harness in [`sim-hardening-plan.md`](sim-hardening-plan.md). What's "max NPC population per region"? Tentative: 50 (600 simultaneous online entities). Validate.
- **Per-tick projectile budget tuning** ([`physical-combat-plan.md`](physical-combat-plan.md) §9). 500 in-flight is a guess; real number lands via 12-player stress test.

---

## 7. What this plan is NOT

- **Not an implementation plan.** Each piece has its own; this is the umbrella.
- **Not a vertical-slice scope decision.** Whether the first shipping NPC AI cut prioritizes combat, base-defense, or co-op coordination needs gameplay scope input and isn't this doc's call.
- **Not the player-AI plan.** Player companions, summoned mobs, and player-side decision aids are separate concerns.
- **Not a faction-design doc.** Faction archetypes (PWA, Federal, Looters, Wanderers, NoosphereWorshippers) live in `lore/factions/`. This plan only references factions where their identity drives AI behavior.
