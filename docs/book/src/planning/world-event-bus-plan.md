# World Event Bus — Planning Doc

**Status:** v1 landed 2026-05-06 (PR #145) — `WorldEventQueue` resource, the full `WorldEventKind` enum (`Gunshot { caliber_class }`, `Explosion`, `AllyDown`, `EnemySighted`, `CorpseSpotted`, `BaseFlip`, `PlayerSighted`, `PortalUsed`, `Chatter`, `ModExtension`), per-kind `Audience` filter (`Anyone` / `SameFaction` / `HostileTo` / `GlobalFaction`), linear distance falloff, and the `drain_world_events` system that delivers events to listening squad blackboards at tick start. Public API: `Sim::push_world_event(kind, position, region, ttl)`, `Sim::world_event_queue_len()`. Emitters wired: `npc_aggro` pushes `EnemySighted` on new aggro acquisition (PR #145); `npc_combat` pushes `Gunshot { caliber_class }` on every shot (2026-05-11; caliber_class derived from the shooter's round `ammo_config` since iter 5-12 Phase 4B v1 — pistols/intermediates/full-power audibly diverge); `npc_death_check` pushes `AllyDown { id, faction }` on every NPC death (2026-05-11); `offline_combat` pushes placeholder `BaseFlip` on dominance heuristic (2026-05-12, see [`../mechanics/npcs-and-combat.md`](../mechanics/npcs-and-combat.md)); `base_capture_check` pushes online-tier `BaseFlip` when defenders are cleared and attackers hold a base for ≥ 2 NPCs at 40 m (2026-05-25, see [`contestation-plan.md`](contestation-plan.md) placeholder note). Remaining emitters: full contestation (`BaseFlip` from a real attack-cooldown system, supersedes the two placeholders), `npc_portal_cross` (`PortalUsed`), a corpse-perception pass for `CorpseSpotted` (observer-driven, not death-driven), and a Godot bridge for player-originated events.
**Last updated:** 2026-05-25
**Scope:** AI-strategic event broadcaster. When an NPC fires a gun, a corpse is created, a base flips ownership, or a player is sighted — that fact propagates to nearby AI agents with spatial decay. Squad objectives become reactive instead of weighted-random.

This is the **AI propagation cousin** of [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md) — the dispatcher routes hand-authored encounter triggers to gameplay systems; this bus routes simulated events between AI agents. Different scope, different consumers, but a similar shape.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 1 foundation), [`squad-blackboard-plan.md`](squad-blackboard-plan.md) (the per-squad write target), [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md) (orthogonal authored-trigger system), internal design notes (belief axes consume bus events), [`tier-transition-plan.md`](tier-transition-plan.md) (offline-tier consumption is a different story).

This is a living design doc.

---

## 1. Why this exists

Today the squad objective planner rolls weighted random. `Investigate` picks a random point in 2200 m. `Guard` doesn't track threats. `Patrol` doesn't re-route when a base goes hot. The world feels flat because there's no signal flowing between events and AI decisions.

The fix is a small priority-queued event bus with **spatial decay**: events are queued with a position; nearby AI agents read them; relevance falls off with distance. Squad blackboards consume bus events to populate per-group facts. Belief sim consumes bus events to update faction-wide axes. The encounter dispatcher does *not* consume bus events — its triggers are authored, not emergent.

## 2. What this system does / does not do

**Does:**

- Provide a `WorldEventQueue` resource that systems push events onto.
- A consumption pass each tick: walk events, deliver to relevant subscribers based on event kind + position + faction.
- Spatial decay: an event N meters away is K relevance, falling off (linear or 1/r²); below a threshold, no delivery.
- Bounded retention: events live for a small TTL (1 tick to a few seconds depending on kind). Bus is *not* a journal — long-term record is the chronicle.
- Categorize events by kind: gunshot, explosion, vehicle, corpse-spotted, base-flip, player-sighted, ally-down, etc.
- Provide a subscription API for AI consumers — squad blackboards, belief sim, ambient NPCs.

**Does not:**

- Replace the journal. Journal is the deterministic durable log; bus is transient AI inputs.
- Drive scripted encounters. Authored encounter triggers stay in [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md).
- Persist across saves. Bus rebuilds from journal replay if needed; don't snapshot the bus itself.
- Cover faction-strategic events (which faction took which base, faction A's truce with faction B). Those are higher-level and belong in `sim-brain.md`.
- Cover narrative events (rumor, story beats). That's the AI-generation layer.

## 3. Data model

```rust
// crates/simn-sim/src/events.rs
#[derive(Clone, Debug)]
pub struct WorldEvent {
    pub id: u64,
    pub kind: WorldEventKind,
    pub position: Vec3,
    pub region: RegionId,
    pub faction_origin: Option<Faction>,
    pub source_entity: Option<Entity>,    // for "ally-down" filtering
    pub created_tick: u64,
    pub ttl_ticks: u32,
}

#[derive(Clone, Debug)]
pub enum WorldEventKind {
    Gunshot { caliber_class: CaliberClass },
    Explosion { magnitude: f32 },
    AllyDown { faction: Faction },
    EnemySighted { target_id: NpcId, target_faction: Faction },
    CorpseSpotted { faction: Faction },
    BaseFlip { kind: BaseKind, new_owner: Faction, old_owner: Option<Faction> },
    PlayerSighted { player_id: u64 },
    PortalUsed { from: RegionId, to: RegionId },
    Chatter { speaker: NpcId, intent: ChatterIntent }, // conversation, callouts, idle dialog — gates stealth detection + flavor
    // …extend with care; closed enum
}

#[derive(Clone, Debug)]
pub enum ChatterIntent {
    IdleConversation,    // patrol banter; useful for player flavor + stealth ("I hear voices")
    Callout,             // "I see one!", "reload!", "flank left!" — squad coordination via voice
    Alarm,               // "Contact!", drives squad alertness
    Mourning,            // post-combat, ally-down chatter
}

#[derive(Resource, Default)]
pub struct WorldEventQueue {
    events: Vec<WorldEvent>,
    next_id: u64,
}
```

A typed enum (not a string-keyed map) so consumers know the value shape and the schema is reviewable. New kinds require a code change — that's a feature, not a bug.

## 4. System behavior

- **Push side.** Systems that emit events: `npc_combat` (gunshot), `npc_death_check` (corpse, ally-down), `contestation` (base-flip), `npc_portal_cross` (portal-used), aggro detection (enemy-sighted), player input layer (player-sighted via per-tier visibility checks).
- **Tick start: drain.** A `drain_world_events` system runs early. For each event:
  1. Find subscribers in range — query [`squad-blackboard-plan.md`](squad-blackboard-plan.md) groups within `audible_radius_for(kind)`. Use the existing `NpcSpatialHash` resource (`crates/simn-sim/src/resources.rs`) for the spatial query.
  2. Compute relevance: `relevance = falloff(distance, audible_radius_for(kind))`. Optionally filter by faction (allies care about ally-down; enemies care about enemy-sighted).
  3. Write to the relevant blackboards. Squadmates that just heard the gunshot get `HeardGunshot { position, relevance }` for ~50 ticks.
- **Tick end: prune.** Drop events past TTL. Bus is empty (or near-empty) at every tick boundary.
- **Spatial decay model.** Per-kind `audible_radius_m` and falloff curve. Gunshot ~250 m linear; explosion ~600 m linear; ally-down ~150 m (only same-faction); base-flip ~world (all groups in faction). Concrete numbers in §6.

## 5. Dependencies

- **Blocks:** state-driven objectives (Stage 2), reactive squad behavior, internal design notes consumers.
- **Blocked by:** [`squad-blackboard-plan.md`](squad-blackboard-plan.md) (the primary write target). Could be developed in parallel; integration is straightforward.

## 6. Open questions

- ~~**Spatial decay curves**~~ **Decided 2026-05-05: linear with per-kind tuning, lean realistic-but-gamey.** Tune via playtest.
- ~~**Event de-duplication**~~ **Decided 2026-05-05: no dedup — let every event be its own.** Per user: "if 5 squadmates fire, 5 squadmates fire. We only dedupe if it's in error. We want the world to feel believable. If 5 npcs dunk on someone, that's cool to watch."
- **Audible radius numbers.** Gunshots are ~1500 m in real life; we want ~250 m for gameplay reasons (squads ~150 m apart shouldn't all converge on every shot). Chatter ~30 m (overhearing patrols, useful for player stealth flavor). Numbers land via playtest, lean realistic-but-gamey per user direction.
- **Faction filtering.** `AllyDown` only goes to same-faction groups. `EnemySighted` only goes to factions hostile to the target. Centralize this with a single `event_audience(event) -> FactionFilter` function.
- **Cross-region propagation.** Most events stay in their region (audible radius < region size in practice). `BaseFlip` is global within the faction. Codify as per-kind metadata. Cross-tier propagation also needed (online → offline regions adjacent at boundary, offline → online regions for global events) — see [`offline-tier-plan.md`](offline-tier-plan.md) §6.

## 7. Out of scope

- Persistence (the journal is the durable log; bus is transient).
- Authored triggers (those go through [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md)).
- Player-side audio mixing — gameplay event ≠ engine sound. The audio layer subscribes to events (probably) but the bus is content-agnostic.
- Cross-tier propagation. When a region goes offline, the bus doesn't bridge events across the tier boundary. Offline-tier handles its own coarser event model.
