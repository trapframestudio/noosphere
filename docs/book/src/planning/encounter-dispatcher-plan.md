# Encounter Dispatcher — Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-05-04
**Scope:** how `EncounterTrigger3D`'s `encounter_triggered(id, kind, body)` signal gets routed to the right gameplay system (combat / ambush / scripted event / dialog / cutscene), where encounter data lives, how authored `tags` graduate into typed exports.

Companions: `walkthroughs/poi-authoring.md` (the trigger-side authoring contract), `npc-traversal-plan.md` (encounters often involve NPCs spawning at anchors, materialized through the same path), `tier-transition-plan.md` (encounters can fire across tier transitions).

Living design doc — captures decisions, not a spec.

---

## 1. What This System Does / Does Not Do

**Does:**

- Provide a single `EncounterDispatcher` autoload in Godot that connects to every `encounter_triggered` signal in the active scene.
- Route by `EncounterKind` enum to specialized subsystems:
  - `COMBAT` → `CombatEncounterRunner` (spawns hostiles, manages engagement state)
  - `AMBUSH` → `AmbushRunner` (specialized combat: pre-positioned hostiles with surprise modifier, breaks player stealth state)
  - `SCRIPTED_EVENT` → `ScriptedEventRunner` (one-shot world events — explosions, vehicle arrivals, NPC group movements)
  - `DIALOG` → `DialogRunner` (NPC interaction, branching conversation)
  - `CUTSCENE` → `CutsceneRunner` (camera takeover, scripted animation playback, optional skip)
- Look up encounter content (combat tables, dialog trees, etc.) by `encounter_id` against per-kind data registries.
- Persist fired-once state to `simn-world` ledger so reloading a save doesn't replay scripted moments.
- Emit `encounter_resolved(id, outcome)` events the rest of the game (quest hooks, world ledger) can subscribe to.

**Does not:**

- Generate encounters procedurally. Encounters are hand-authored — the dispatcher routes existing triggers, doesn't create them.
- Run the encounter mechanics themselves. Combat / dialog / cutscene logic lives in the per-kind runners; the dispatcher is wiring + lookup.
- Replace the existing combat / dialog systems. It's a routing layer that calls into them.
- Drive contested-base attacks. That's `contestation-plan.md` — orthogonal system that may *use* an encounter trigger to schedule a player-witnessed attack, but the contestation tick doesn't go through the dispatcher.

---

## 2. Architecture

```
       EncounterTrigger3D ── encounter_triggered ──┐
       (dropped in scenes)                         │
                                                   ▼
                                         EncounterDispatcher
                                         (Godot autoload)
                                                   │
                                          route by kind
                ┌──────┬──────┬──────────┬─────────┴─────────┐
                ▼      ▼      ▼          ▼                   ▼
            Combat  Ambush  Scripted  Dialog            Cutscene
            Runner  Runner  Event     Runner            Runner
                                  Runner
```

Each runner pulls its content from a per-kind data registry. The dispatcher's only state is `fired_once` tracking and the encounter-id → kind index (built at scene-load by walking `encounter_triggers` group).

---

## 3. Data Registries

Per encounter kind, a `Resource`-typed registry that authored content references via `encounter_id`:

| Kind | Registry | Stores |
|---|---|---|
| `COMBAT` | `CombatEncounterTable` | hostiles list (faction + loadout), spawn anchors (NPC nav-anchor `poi_id`s in the same scene), engagement geometry hints |
| `AMBUSH` | `AmbushTable` | combat data + pre-positioning (NPCs already at firing positions, optional dialogue hook on player detection) |
| `SCRIPTED_EVENT` | `ScriptedEventTable` | event sequence (timed audio/anim/spawn beats), preconditions, outcome flags |
| `DIALOG` | `DialogTable` | dialog tree root id, speaker NPC reference, branching conditions on player faction-rep + inventory |
| `CUTSCENE` | `CutsceneTable` | timeline resource, camera path, audio cues, skippable flag |

Each registry lives at `res://resources/encounters/<kind>.tres` initially; if a registry grows past ~20 entries we shard per-map (`<kind>_<map_id>.tres`).

---

## 4. Tag-to-Typed Graduation Path

`EncounterTrigger3D` carries `tags: Dictionary` for early authoring. The current contract says e.g.:
- `combat_table=pwa_outpost_west`
- `ambush_squad=looter_3`
- `scripted_event=dalles_intro`
- `dialog_id=trader_intro`
- `cutscene_id=squall_intro`

Phase-1 dispatcher reads these tag keys, resolves them against the appropriate registry. Authoring works without typed schema.

Phase 2 (when content stabilizes): per-kind exports replace the tag pattern.

```gdscript
# Phase 2 EncounterTrigger3D — typed exports per kind
@export_subgroup("Combat")
@export var combat_table: CombatEncounterEntry
@export_subgroup("Dialog")
@export var dialog_root: DialogEntry
# ...
```

Inspector hides irrelevant subgroups based on `encounter_kind`. Tags stay supported for backward compat + free-form metadata that doesn't fit the schema. Migration script converts existing tag-driven encounters to typed exports.

---

## 5. Combat Encounter Detail

Most common kind. Worth specifying further.

```rust
pub struct CombatEncounterEntry {
    pub id: String,
    pub hostiles: Vec<HostileSpawn>,
    /// Anchor poi_ids in the same scene. Materialization picks one
    /// per hostile in declaration order, falling back to a random
    /// navmesh point if anchors run out.
    pub spawn_anchor_ids: Vec<String>,
    /// Encounter ends when this many hostiles remain (default 0:
    /// kill them all). Set higher for "drive them off" encounters.
    pub end_at_hostiles_remaining: u32,
    /// Reward bundle applied on resolution. References a loot
    /// pool by id; the ledger logs the actual roll.
    pub reward_pool: Option<String>,
}

pub struct HostileSpawn {
    pub faction: Faction,
    pub loadout: String,    // LoadoutRoll table id
    pub aggression_override: Option<f32>,
}
```

Resolution flow:
1. Combat runner spawns hostiles via the existing `npc_spawn` path, placed at `spawn_anchor_ids` resolved through `npc-traversal-plan.md` §7's `region_spawn_point`.
2. Tracks engagement state (active hostile count, player wounds, encounter timer).
3. On end condition, fires `encounter_resolved(id, "victory" | "wipe" | "fled")`.
4. Reward pool drops applied via existing loot system.

---

## 6. Persistence

Fired-once state lives in `simn-world` ledger:

```sql
CREATE TABLE encounter_state (
    encounter_id TEXT PRIMARY KEY,
    fired_count INTEGER NOT NULL DEFAULT 0,
    last_outcome TEXT,           -- "victory" | "wipe" | "fled" | NULL for non-combat
    last_fired_tick INTEGER NOT NULL
);
```

On dispatcher load:
- Pull `encounter_state` for the active scene's encounters.
- For each `EncounterTrigger3D` with `fires_once = true` and `fired_count > 0` in the ledger, set `_fired = true` so the trigger doesn't re-fire.
- Recurring encounters (`fires_once = false`) ignore the ledger; they run every time the player crosses the trigger.

---

## 7. Open Questions

- **Cross-tier encounters.** Can an encounter trigger fire while the player is offline-tier-far from it? No — encounter triggers are physical Area3Ds; if the player isn't online-tier-close, the body-overlap check never fires. Offline-tier "encounters" are different abstraction (the contestation tick or scheduled events). Defer cross-tier encounters until we have a concrete need.
- **Multiplayer encounter sync.** When a peer triggers an encounter, do all peers see it? Yes — the dispatcher should be server-authoritative, with `encounter_resolved` events replicated. Defer to multiplayer integration plan.
- **Encounter cancellation.** Can an encounter be ended early (e.g., player runs away from a `COMBAT` encounter)? Yes — the runner exits early on a "player out of range for X seconds" check. Cleanest to implement per-runner.
- **Layered encounters.** Two `EncounterTrigger3D`s overlapping — both fire? Probably yes; runners are independent. If two combats fire at once, the spawn-anchor pool still works since each encounter has its own list. Watch in playtest for "spawn explosions" if two big triggers overlap.
- **Cinematic interrupt.** A `CUTSCENE` mid-`COMBAT` — does the cutscene pause combat? Yes; the `CutsceneRunner` issues `time_scale = 0.0` on the combat runner for its duration. Other runners ignore the interrupt.

---

## 8. Concrete Code Artifacts This Plan Demands

1. **`EncounterDispatcher` autoload in Godot** — group lookup at scene-load, signal connection, kind→runner routing.
2. **Five `*Runner` classes** — Combat, Ambush, ScriptedEvent, Dialog, Cutscene. Each owns its kind's mechanics.
3. **Five `*Table` resources** — `res://resources/encounters/<kind>.tres` per kind. Phase-1 keyed by string id; phase-2 replaces with typed exports.
4. **`encounter_state` ledger schema + read/write in `simn-world`** — persistence for `fires_once`.
5. **`encounter_resolved` signal + subscriber API** — quest hooks, world ledger, dialog system can hook in.
6. **Phase-2 migration tool** — converts tag-driven encounters to typed exports once content has stabilized.

---

## 9. What's Blocked On This Plan

- **Combat encounters past prototype.** Today there's no encounter system; combat starts when an NPC notices the player. Authored "the looters ambush you crossing this bridge" doesn't work without the dispatcher.
- **Dialog placement.** Talking to NPCs at hand-placed positions needs the dispatcher's `DIALOG` route to wire `EncounterTrigger3D` → existing dialog system.
- **Cutscene system.** No cutscene runner exists yet; planned to slot in as a runner under this plan.
- **Quest mechanics that gate on encounter outcomes.** "Defeat the Looters at the_dalles outpost" needs `encounter_resolved("the_dalles_looter_combat", "victory")` to fire.

Not blocked: encounter trigger placement (already works as inert authoring data), basic combat AI (orthogonal — encounters call into existing combat, don't replace it), the contestation system (uses different machinery to schedule attacks).
