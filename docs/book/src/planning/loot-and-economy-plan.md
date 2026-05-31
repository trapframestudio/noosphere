# Loot & Economy - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-15
**Scope:** server-authoritative loot, faction-driven restocking, depth-tier risk/reward axis, sim-driven NPC progression, notoriety, and the circulating-inventory feedback loop. Companion to `weapons-plan.md`.

This doc owns the loot economy. `weapons-plan.md` owns what weapons *are* (parts, rounds, attachments, ballistics). Both cross-reference.

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**The sim is the source of truth.** Pool tables describe *initial conditions* (spawn equipment, fresh-cache restocking), not steady state. Steady state emerges from NPC behavior, faction logistics, and player action.

Consequence: NPCs are persistent entities with real inventories and real histories. Loot dropped by an NPC is whatever the NPC actually had, always. No corpse pool tables. The world tells the truth about itself.

---

## 2. Three Loot Surfaces

| Surface | Source of contents | Persistence |
|---|---|---|
| **Containers** (stashes, crates, caches) | Faction × depth × family pool, rolled on approach, stateful once touched | Server-authoritative, deterministic re-roll on restock event |
| **NPC corpses** | NPC's actual inventory at time of death | Transient (corpse despawn timer), contents are whatever the NPC had |
| **Ambient scatter** (casings, dropped magazines, cold campfires) | Rolled from recent squad activity residue in that cell | Stateless, generated on player approach |

These share data infrastructure (pools, tier tables, faction flavors) but differ in trigger and lifetime.

---

## 3. Container Model - Deterministic, Faction & Depth Driven

### 3.1 The seed formula

```
seed = hash(
  container_id,
  world_seed,
  last_restock_faction,
  last_restock_tick,
  zone.depth_tier_at_restock,
  zone.influence_snapshot_at_restock,
)
```

Every input is server-authoritative. Same inputs → same roll. Coop-consistent by construction.

`container_id` and `world_seed` are stable. The rest are **world-state at restock time**, captured and frozen until the next restock event - so the container's contents stay stable as long as no restock occurs, even if the zone changes around it.

### 3.2 Pool selection by faction influence

Each zone has an influence vector across factions that updates as the sim runs:

```
zone.influence = { pwa: 0.5, linemen: 0.1, bandits: 0.15, wanderers: 0.2, attuned: 0.05, ... }
// Factions with pool tables: PWA, Linemen, Federal, RG, Gulf Compact / Aegis Pacific,
// bandits, cartel crews, the Attuned, wanderers. Merged and Experiments don't restock.
```

Container contents mix per-faction pools weighted by influence:

```
effective_pool = mix(
  pwa_pool[tier]       * 0.5,
  linemen_pool[tier]   * 0.1,
  bandit_pool[tier]    * 0.15,
  wanderer_pool[tier]  * 0.2,
  attuned_pool[tier]   * 0.05,
)
```

A stash's flavor follows who operates in that zone. Take a zone from bandits and the stash rerolls PWA/Linemen-flavored on next restock.

### 3.3 Depth tier - the risk/reward axis

Orthogonal to faction flavor. Every zone has a `depth_tier: u8` (hand-set by worldbuilder, not auto-computed from coordinates - a deep-tier pocket can exist inside a shallow region).

Depth tier modifies, per-faction:
- Round variant weights (7N24 / exotic rounds gate to high tiers)
- Weapon condition + part quality distributions
- Attachment roll chance (optics, suppressors, rails become plausible at higher tiers)
- Stack sizes
- Rare item appearance (shards, medical injectors, unique attachments)
- Sub-pool mix weights (weapons/ammo/meds ratio)

Implementation: one pool definition per faction + family, with entries tagged by tier threshold. Tier parameterizes weights and stack sizes rather than swapping entire pool objects. Reduces duplication.

### 3.4 Restock is an in-world event, not a timer

Containers do **not** have `reset_hours`. They restock when a faction actually services them:

- Factions maintain supply routes between home bases and outposts.
- Supply squads traverse these routes in the sim (offline tier: abstract edge-traversal; online tier: real movement if players nearby).
- When a supply squad passes a cache node belonging to that faction, the cache restocks from that faction's pool at that zone's current depth tier.
- When a faction takes a zone, they sweep existing caches (partial depletion) and, over subsequent in-game days, restock with their own flavor.
- **Abandoned decay:** if a zone has no faction activity within a decay window, caches drift toward an `abandoned_pool[tier]` - rusted food, corroded ammo, low-condition weapons, occasional pre-Valley curiosities. Low yield, but available in neglected zones.

Players influence this directly: ambush a supply squad → downstream caches stay empty → NPCs in that area run low on ammo in subsequent fights. Loot, combat, and territory coupled by the sim, not by special code.

### 3.5 Container storage

```
ContainerState {
  container_id,
  last_restock_faction: Option<FactionId>,
  last_restock_tick: u64,
  depth_tier_at_restock: u8,
  influence_snapshot: CompactInfluenceVec,
  removed_items: Vec<ItemStack>,
}
```

Untouched containers in unchanged zones store zero bytes (derive on demand). State grows only when touched or when restock events fire.

### 3.6 Opt-outs

- **Scripted containers** (quest rewards, hand-placed story caches) declare `fixed_contents` and skip the pool system entirely.
- **Player-built containers** (base stashes) are real inventories, not rolled. Player activity at a player base can count as a "player-faction restock" for any shared cache at that base.

---

## 4. NPC Progression - Why Low-Tier Can Become High-Tier

### 4.1 NPCs are persistent entities, not spawn drops

```
NPC {
  id,
  faction,
  personal_tier: u8,              // earned, drifts over time
  notoriety: f32,                  // earned, decays slowly
  inventory: Inventory,            // real persistent gear
  combat_history: CombatHistory,   // kills, zones survived, shards, etc.
  skill_profile,
  risk_tolerance: f32,             // individual trait, shapes goal selection
}
```

Spawn-time gear comes from `faction_pool[faction_baseline_tier]` at spawn location. After spawn, gear is state - what they acquired, traded, looted.

If a t2 bandit pushes into a t4 zone, survives, loots a Linemen corpse, and walks out with suppressed AK-12 and 7N22 - that is now their gear. Full stop. Next time they engage, their corpse (if they die) drops that exact loadout.

### 4.2 Personal tier vs. faction tier

- **Faction baseline tier:** worldbuilding parameter. What a fresh faction recruit spawns with.
- **Personal tier:** derived per-NPC stat. Weighted function of equipment tier, zones successfully operated in, combat record, notoriety.

Personal tier drifts **slowly**. A single lucky kill doesn't promote you. Sustained survival in higher-tier zones and retained high-tier gear does.

Drifts **up** when: equipment-tier average rises, operations in zones above current tier succeed, high-tier kills accumulate.
Drifts **down** when: gear lost (forced retreat, defeat), persistent downgrade.

### 4.3 Notoriety is the social dimension

Tier is what they carry. Notoriety is what others know.

**Gained from:**
- Surviving N ticks operating in zones above current personal tier
- Kills on higher-notoriety targets (climbing the ladder)
- Kills on rival faction within rival territory
- Shard recoveries, fault-cluster survival
- Surviving engagements with players
- Leading squads to successful objectives (squad planner's lead gets the credit)

**Not gained from:**
- Cheap kills in safe zones (anti-grind)
- Non-killing-blow damage only (scaled by damage share to prevent kill-stealing farms)

**Decays** slowly (in-game months) so history matters without inflating forever.

### 4.4 What notoriety does (so it's not just a number)

- **Faction promotion.** Squad lead → section lead → officer. Hooks into existing faction role used by squad planner.
- **Social gravity.** Mid-notoriety NPCs gravitate toward high-notoriety leaders. Squads form around earned reputation.
- **Bounties.** Rival factions post kill contracts on notorious enemies - emergent quest vector.
- **Morale weight.** In combat, low-notoriety NPCs lose morale faster against high-notoriety foes. Feeds F.E.A.R.-class tactical AI.
- **Trade access.** Faction quartermasters unlock better stock for higher-notoriety members.
- **Player-kill scaling.** Killing notorious enemies yields proportional gear (it's on them) + rep + rumor event propagation.

### 4.5 Rumor surfacing - non-optional

Notoriety must **reach the player** or the sim is simulating into a void. Required surfaces:

- Faction radio chatter referencing notable active members
- Trader/barman gossip about recent notorious events
- Named corpses (high-notoriety NPCs have readable names/callsigns on their body)
- Ambient NPC dialog referencing nearby notorious figures
- Post-kill rumor events that propagate: *"A wanderer put down Cy Vandermeer's crew at the Mosier Tunnels."*

This system is the lens that makes the sim visible. Without it, notoriety is dead weight.

### 4.6 Individual goal layer

The "should I push deeper?" decision lives in the individual-goal layer, on top of squad orders. Driven by `risk_tolerance` (individual trait) weighting existing goals:

- `stay_in_comfort_zone` - low risk, low reward, sustainable
- `push_for_advancement` - accept risk, seek high-tier zones, pursue notoriety
- `hunt_specific_target` - quest or faction order
- `flee_home` - wounded, low morale, low circulating gear

Only a minority of NPCs have high `risk_tolerance`. The ones who push and survive become notable naturally. This is emergence, not scripting.

---

## 5. Circulating Inventory - The Feedback Loop

### 5.1 The mechanism

Each faction maintains a **circulating inventory statistic** - a rolling aggregate of gear that members have been looting, trading, and carrying over the last N in-game days (decaying weight).

Supply squads restocking caches draw from this circulating stock as a **weighting modifier** on top of the base faction pool. The base pool sets what's possible; circulating inventory biases what actually shows up.

### 5.2 The loop

1. Notorious bandits push t4, survive, loot Linemen/Federal gear.
2. They return to bandit home territory (I-84 corridor, Stevenson approaches).
3. That gear flows into bandit circulating inventory.
4. Bandit supply squads pulling from the circulating stat occasionally restock caches with it.
5. A t2 bandit cache in home territory can now drop an "above-baseline" item - because the faction really does have that gear circulating.
6. Other factions raiding those caches inherit the upshift.

No special rules. The sim is just telling the truth.

### 5.3 Dampening

Feedback loops can run hot. Required controls:

- Circulating weight **decays** over time (gear gets used, broken, lost).
- Restocking draws from circulating at a **capped fraction** (e.g., 20% of restock roll can come from circulating, rest from base pool) to prevent runaway.
- High-tier items in circulating are more likely to stay *with individual notable NPCs* than be redistributed to generic caches - elite gear concentrates in elite hands.

All tunable. Needs playtesting.

---

## 6. Ambient Scatter - Emergent, Not Placed

Ambient world loot (weapons leaning on a crate, ammo on a table, dropped magazine, cold campfire contents) is **not** hand-placed. It's generated from **squad activity residue** per cell:

- Every squad tick, squads leave a small activity record at their current position (faction, tier, state: camped / fighting / transiting / fleeing).
- Residue decays over time.
- On player approach, ambient scatter rolls from cells' residue history.

Examples:
- Cell saw a firefight 2 hours ago → casings, dropped magazine, possible wounded-NPC blood trail with a medkit.
- Cell saw a quiet patrol pass → nothing.
- Cell abandoned for weeks → pre-Valley detritus only.

Same pool-tier-faction machinery as containers, parameterized by the residue record instead of a container definition.

**Consequence:** following faction movement = following loot. Metagame farming breaks down. Reading the world becomes the skill.

---

## 7. Cold Start

New worlds have no history, no notable NPCs, no circulating inventory, no activity residue. Two combined answers:

### 7.1 Worldbuilding seeds

Lore-established notable figures exist at genesis - maybe 10–20 named across all factions. They start with high notoriety, appropriate gear, active operations. Not scripted quests, just ongoing sim presence.

### 7.2 Pre-sim warmup

Before first player connects, the sim runs in fast-forward mode for simulated in-game weeks (configurable). Factions move, squads engage, notable NPCs emerge, circulating inventory populates. When players arrive, the world has history.

Offline-tier sim is cheap. A few simulated weeks should cost seconds to minutes of wall time.

---

## 8. NPC Lifecycle & Persistence Budget

Not every NPC can be a fully-tracked entity forever. Cost management:

- **Generic mooks:** lightweight while alive, forgotten on death (faction stats update, nothing else).
- **Notable NPCs** (notoriety > threshold, or named seed NPC): upgraded to full tracked state. Survive across sessions in persistence.
- **Post-mortem:** notable NPCs' deaths are recorded in a **historical registry** (who, when, where, by whom, cause). Registry feeds rumor system; live NPC state frees.
- **Registry pruning:** old entries compacted or aged out as they stop being referenced. Avoids unbounded growth.

"Notable" is a dynamic set. Any generic mook who earns enough notoriety gets upgraded mid-run.

---

## 9. Interactions With Other Systems

| System | Interaction |
|---|---|
| `weapons-plan.md` §3 attachments | Containers roll attachment *on weapon* at restock; NPC corpses drop attachments *as actually equipped* |
| `weapons-plan.md` §4 round variants | Round variant rarity gates on depth tier; circulating inventory can surface rare rounds in lower tiers organically |
| `weapons-plan.md` §5 parts/condition | Condition distributions are tier-gated at roll time for containers; NPC-carried weapons carry their *actual* wear history |
| Squad planner | Squad lead NPCs are selected partly on notoriety; squad activity drives ambient residue |
| F.E.A.R.-class tactical AI | Notoriety feeds morale checks; individual-goal layer adds `risk_tolerance` + push/advance goals |
| Faction/territory sim | Zone influence + depth tier + supply routes are core inputs; this doc's economy is downstream |
| `simn-net` (future) | NPC notable-state needs efficient replication; changes slowly, good delta-sync candidate |
| Persistence (`simn-sim` journal/snapshot) | Notable NPCs, container state deltas, circulating inventory, rumor registry all journal |
| `world-ledger-plan.md` (planned `simn-world` crate) | Container contents, open/unopened state, corpse inventories, and settled dropped items live in the SQLite World Ledger alongside journal+snapshot. Table names: `container_state`, `corpse_state`, `settled_object`, `loot_node_state`. |
| `physics-tiering-plan.md` | Dropped items and corpses that come to rest are Tier 3 (persistent loose physics - collider only, transform-only replicated). Players can still pick them up and knock them around; the tier system handles the promotion/demotion mechanics. |
| `destruction-plan.md` | Destroying a container entity can spawn its contents as Tier 3 settled_object rows. Destroyed crates that rolled high-tier loot still yield their contents - the container went away, but the gear it rolled didn't. |

---

## 10. Open Questions

- **Notable-threshold tuning.** What notoriety level promotes a generic NPC to fully-tracked? Too low → state bloat. Too high → sim feels flat (nobody ever becomes a name). Playtest.
- **Rumor fidelity.** How detailed is a propagated rumor? Exact names + locations, or abstracted ("a wanderer killed Cy Vandermeer's crew somewhere near Mosier")? Affects meta-knowledge balance.
- **Cross-faction gear laundering.** When faction A takes a cache from faction B, does the gear's "origin faction" taint matter? Probably no - gear is gear - but interesting if we want factions to reject certain items (the Attuned might not use Aegis Pacific-branded equipment, RG might reject PWA-stamped gear).
- **Player as faction.** Does player activity feed into a player-faction circulating inventory for coop-shared caches? I lean yes; it's the obvious extension.
- **Legibility of depth tier.** No floating labels. Depth should be taught by the journey - NPC density, fault frequency, environmental decay cues. Concrete design work needed to make this land.
- **Worldbuilder tooling.** Zone depth tier is hand-set; needs a map authoring surface to set and preview.

---

## 11. Proposed Rollout Order

Sequenced so each step produces something playable and doesn't block on later work:

1. **Basic containers + faction-flavored pools + depth tiers.** Static influence vectors (hand-set, no live faction sim driving them yet). Pool tables + tier tables. Deterministic seeded rolls.
2. **NPC persistent inventory + corpse-drops-actual-gear.** Decouples corpse loot from pool system entirely.
3. **Ambient scatter from simple activity residue.** Minimum-viable residue layer, parameterized by current squad positions.
4. **Dynamic faction influence + restock-as-event.** Replaces static influence with live sim output. Supply-route squads become real.
5. **Personal tier + notoriety tracking + individual goal layer.** NPC progression becomes real.
6. **Rumor surfacing system.** Notoriety reaches players. Essential for step 5 to matter.
7. **Circulating inventory feedback loop.** Feedback closes.
8. **Cold-start warmup + worldbuilding seeds.** World ships with history.

Steps 1–3 are straightforward infrastructure. Step 4 onward requires the faction sim to be mature enough to drive it. Step 6 is required for step 5 to be worth the cost; don't ship 5 without 6.

---

## 12. What This Doc Is Not

- Not a spec. Weights, thresholds, decay constants here are illustrative.
- Not a schedule.
- Not committed. All sections are rewritable during planning.
