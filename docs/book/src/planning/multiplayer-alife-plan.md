# Multiplayer-Aware A-Life — Planning Doc

**Status:** stub — design intent captured, no implementation yet
**Last updated:** 2026-05-05
**Scope:** co-op-aware extension of [`tier-transition-plan.md`](tier-transition-plan.md). Multiple players = multiple "online windows" into the world simultaneously, on different regions or overlapping ones. Tier transitions, witness-sync of NPC events, server-authoritative chronicle replication, and "follow squad across regions" all need explicit handling that single-player STALKER never had to face.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 4), [`tier-transition-plan.md`](tier-transition-plan.md) (single-player tier model this extends), [`world-event-bus-plan.md`](world-event-bus-plan.md) (event propagation across observation scopes), [`world-ledger-plan.md`](world-ledger-plan.md) (chronicle persistence layer).

This is a living design doc.

---

## 1. Why this exists

`tier-transition-plan.md` describes the online↔offline handoff for a single observer (player). With co-op, the rules generalize but the constraints multiply:

- **Multiple online windows.** Up to N=4 players spread across the map; each is an independent observer. A region is "online" if ≥1 player observes; "offline" only when 0 do. Per-region tier becomes per-region observer-count.
- **Witness consistency.** When player A's NPC squad fires at a player-B-witnessed enemy, both clients must agree on the result. Server-authoritative + replicated journal deltas already gives us this for shipped events; the corner is in-flight combat that journals only at death.
- **Cross-region events.** A faction takes a base in region X (witnessed by player A); player B (in region Y) needs to see that ownership flip in their world. Bus events propagate within their region; cross-region propagation needs explicit replication.
- **Tier-transition simultaneity.** All players cross a region boundary near-simultaneously — no observer left in old region. Server runs the offline-projection; if any player crosses back within hysteresis window, the offline state has to coherently re-online for all observers.

This plan is the multiplayer-specific layer on top of the single-player tier model. The single-player model (`tier-transition-plan.md`) must come first; this composes on top.

## 2. What this system does / does not do

**Does:**

- Replace `ActiveRegions { regions: Vec<RegionId> }` with `RegionObservers { by_region: HashMap<RegionId, SmallVec<[PlayerId; 4]>> }`. Per-region observer set.
- Define multi-observer tier rules: online while observer-count > 0; offline + hysteresis when count = 0.
- Replicate chronicle events to all clients, not just the witnessing client. Server publishes; clients apply to their local copy.
- Handle cross-region event propagation (base flips, faction-strategic events). The world event bus runs server-side; bus deliveries that affect distant regions get bundled into per-tick replication.
- Address the "follow squad across regions" UX — when a squad migrates via portal and a player chases, the squad is recoverable on the destination side.
- Define per-tick observer-set update protocol: client reports player position → server computes which regions become online/offline → server sends tier-transition deltas to affected clients.

**Does not:**

- Replace the underlying `tier-transition-plan.md` design. This *extends* it.
- Cover replication transport. That's `simn-net` territory (Steam P2P session, UDP framing).
- Cover prediction or rollback for player input. That's a separate netcode concern in `simn-net`.
- Drive co-op-specific *gameplay* (PvP, friendly fire rules, drop-in/drop-out). Those are gameplay decisions, not A-Life decisions.

## 3. Data model changes

```rust
// Replaces ActiveRegions
#[derive(Resource, Default)]
pub struct RegionObservers {
    by_region: HashMap<RegionId, ObserverSet>,
    last_observed_tick: HashMap<RegionId, u64>,  // for hysteresis
}

pub struct ObserverSet {
    /// Sorted, deduplicated. SmallVec to avoid allocs in the common 0-4 case.
    pub players: SmallVec<[PlayerId; 4]>,
}

impl RegionObservers {
    pub fn is_online(&self, region: RegionId) -> bool {
        self.by_region.get(&region).map_or(false, |set| !set.players.is_empty())
    }
    pub fn observer_count(&self, region: RegionId) -> usize { … }
    pub fn add_observer(&mut self, region: RegionId, player: PlayerId);
    pub fn remove_observer(&mut self, region: RegionId, player: PlayerId);
}
```

The chronicle (`LifeChronicle`) gains a replication marker per entry — was this entry replicated to all clients yet? Authoritative server tracks per-client ack; once acked by all, the marker clears.

## 4. System behavior

- **Per-tick observer update.** Each tick, server reads each player's `Position` + `InRegion`, recomputes `RegionObservers`. Compares to last-tick state. For each transition:
  - Region became online (0 → ≥1 observers): if hysteresis window expired, run offline-tier → online-tier projection on all entities. Replicate full state to all observers' clients.
  - Region became offline (≥1 → 0 observers): start hysteresis timer. If no player re-observes within window, run online-tier → offline-tier projection.
- **Witness sync for transient events.** NPC death journals + replicates. NPC took damage but didn't die: should this replicate? Tentative: yes, for combat-state visibility, but at lower priority than death (drop on bandwidth pressure).
- **Cross-region event broadcasts.** `BaseFlip` and `PortalUsed` events — produce bus-event entries server-side; replicate to all clients regardless of observer status. Other event kinds replicate only to clients whose observers can see them.
- **"Follow squad across regions."** When a squad portal-crosses, the journal records the event. Player chasing into the new region triggers the destination's tier-transition; the squad is one of the entities that materializes. Open question on how to handle the chase UX (see §6).

## 5. Dependencies

- **Blocks:** late-stage NPC personality system (per-NPC identity persists across regions, replicates), full faction-strategic AI (`sim-brain.md` outputs propagate cross-client).
- **Blocked by:** [`tier-transition-plan.md`](tier-transition-plan.md) (the single-player model), `simn-net` (replication transport), [`world-ledger-plan.md`](world-ledger-plan.md) (chronicle storage), [`world-event-bus-plan.md`](world-event-bus-plan.md) (cross-region event source).

## 6. Open questions

- ~~**Hysteresis tuning**~~ **Decided 2026-05-05: no hysteresis.** Region transitions instant in both directions per the "ambivalent simulation" principle (per [`tier-transition-plan.md`](tier-transition-plan.md) §4 and user direction). Combat in progress when a region goes offline collapses via dice ([`offline-tier-plan.md`](offline-tier-plan.md)).
- ~~**Player-count target**~~ **Decided 2026-05-05: 12 players, every drifter can be in their own zone.** Sets the architectural ceiling: server must handle up to 12 simultaneously online regions at full fidelity. Spatial-hash sizing, per-region NPC cap, projectile budget all sized against this.
- ~~**Bandwidth budget for chronicle replication**~~ **Decided 2026-05-05: per-event for online zones, batched for unwitnessed.** Witnessed deaths broadcast immediately; unwitnessed (offline tier) deaths batch into periodic summary broadcasts (cadence TBD; tentative: every ~5s server tick).
- ~~**Co-op desync tolerance**~~ **Decided 2026-05-05: prioritize client smoothness, snap back gracefully.** Server-authoritative for hits + state; client-side prediction may show transient divergence; on detection of significant drift, world snaps to truth. Per user: "we don't need razor point accuracy on a desync. The world can snap back to reality as gracefully as it needs to."
- ~~**Drop-in mid-session catch-up**~~ **Decided 2026-05-05: explicit loading screen + sync acceptable.** Late-joining players load the world during a transition / loading screen rather than getting fancy delta replay. Per user "we can let the world load between level transitions, the player will have to deal with it lol."
- **"Follow squad across regions" UX.** When player A enters the destination region of a portal-crossed squad, do they see the full squad arriving (animated), or already-positioned at the destination? Lean: pre-positioned with ±12 m scatter (matches single-player) — the chase isn't tactical, it's narrative. Open until tested.
- **12-region stress-test methodology.** Need a benchmark in [`sim-hardening-plan.md`](sim-hardening-plan.md) that loads 12 regions × max NPC population × full combat tick to verify the architecture meets target. Open: what's "max NPC population" per region? Tentative: 50 NPCs per region (600 simultaneous online entities).

## 7. Out of scope

- Player-vs-player or PvE-with-PvP elements.
- Co-op gameplay rules (friendly fire, shared loot, drop-in/drop-out scope). Those are design decisions, not A-Life.
- Network framing / serialization formats. `simn-net` owns those.
- Single-player A-Life behavior. That's the rest of the plan stack.
