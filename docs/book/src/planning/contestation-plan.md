# Contestation — Planning Doc

**Status:** planning only for the full system; a **minimal
placeholder capture mechanic landed 2026-05-25** as a side effect
of the squad-planner Investigate upgrade. The placeholder is:
(a) `squad_planner::build_investigate` targets a nearby hostile-
faction non-HQ, non-CampSite base as the Investigate destination
when one exists in-region; (b) `base_capture_check` (in
`crates/simn-sim/src/systems/base_capture.rs`, scheduled in
`build_schedule_npc_lifecycle` after `spawn_npcs`, gated to every
60 sim ticks / 3 s) flips `InFaction` on any non-HQ base in an
active region when defenders = 0 and ≥ 2 same-faction hostile
attackers stand within 40 m. Emits `WorldEventKind::BaseFlip` +
`PdaEvent::BaseFlip`. Headquarters bases are flip-immune. No
contest-tier weighting, no attack cooldown, no garrison
repopulation, no ledger persistence — that's still this doc's
scope. The full system supersedes the placeholder when it ships.
The placeholder gives faction borders something to move along
in the meantime; player-facing contract at
[`../mechanics/npcs-and-combat.md`](../mechanics/npcs-and-combat.md)
"Base capture (placeholder)".
**Last updated:** 2026-05-25
**Scope:** how `BASE_*` POIs marked `contested = true` rotate ownership through faction attacks, hold periods, and capture events. Where the tick lives in `simn-sim`, what state it persists, how it composes with the rest of the faction layer.

Companions: `world-ledger-plan.md` (where rotated-ownership state persists), `tier-transition-plan.md` (offline → online materialization of garrison NPCs), `npc-traversal-plan.md` (the offline graph the contestation system queries), `loot-and-economy-plan.md` (capture-reward loot drops).

Living design doc — captures decisions and open questions, not a spec.

---

## 1. What This System Does / Does Not Do

**Does:**

- Run a slow tick that scans `poi_markers` group, filters `contested = true` BASE_* nodes, maintains a `ContestedBase { current_owner, last_flip_tick, attack_cadence }` component per node.
- Schedule attack cycles based on `contest_tier` (1–4): tier 1 = rare attacks, tier 4 = constant pressure.
- Resolve attacks against the defending faction's garrison + base inherent defense modifier; on attacker win, swap `current_owner` and refresh garrison.
- Persist current ownership + last flip tick to `simn-world` ledger so contestation state survives session restart and re-seed.
- Emit events the engine layer renders (capture cinematic hooks, faction territorial-control updates, NPC re-population).

**Does not:**

- Author bases. That's `PoiMarker3D` + `RegionMarker3D` (per `walkthroughs/poi-authoring.md`). The tick reads existing markers, doesn't create them.
- Drive single-attack combat. Attack resolution is a *roll* between attacker and defender forces; the actual battle is offline-tier abstract (forces + tier modifiers) until a player gets close, at which point `tier-transition-plan.md` materializes the ongoing combat as live NPCs.
- Replace static base ownership. `BASE_*` markers with `contested = false` are stable and never rotate; the tick ignores them.
- Reset to authored state on world-seed. The seed sets `current_owner = poi_marker.faction` for new ledger rows, but on save load the ledger is authoritative.

---

## 2. Tick Architecture

A single `contestation_tick` system in `simn-sim`, registered alongside the other slow systems (faction relations, region presence, etc.). Runs once per game-minute or so; cheap because attack rolls are statistical, not simulated.

```rust
fn contestation_tick(
    mut q_contested: Query<&mut ContestedBase>,
    factions: Res<FactionRelations>,
    region_graph: Res<RegionGraph>,
    rng: Res<RngStream>,
    ledger: ResMut<WorldLedger>,
    time: Res<SimTime>,
)
```

Per tick:

1. For each `ContestedBase` whose `last_flip_tick + cooldown(tier) ≤ now`, roll for an attack event.
2. Attack probability scales by `contest_tier` × strategic-pressure modifier (more pressure when neighboring regions are hostile).
3. On attack: select an aggressor faction from `relation(current_owner) ∈ Hostile` set, weighted by their territorial proximity + force level.
4. Resolve as a single roll: attacker_force vs defender_garrison × defense_mod, with a stochastic component proportional to RNG seed + base difficulty.
5. On attacker win: swap `current_owner`, refresh garrison from the new owner, schedule next eligible attack window via `tier`-driven cooldown, write to ledger.
6. On defender win: increment defender hold streak (cosmetic + leaderboard hook), schedule next attack window.

The tick never blocks on player presence. Online-tier proximity just means the materialization layer (separate plan) renders the rotation for the player to witness.

---

## 3. ContestedBase Component

```rust
pub struct ContestedBase {
    /// PoiMarker3D's `poi_id` the base anchors at.
    pub poi_id: String,
    /// Authored canonical owner (from PoiMarker3D.faction at world seed).
    pub canonical_owner: Faction,
    /// Live current owner (rotates with attacks). Same as canonical
    /// at world seed; ledger-persisted across saves.
    pub current_owner: Faction,
    /// Tier 1–4, copied from PoiMarker3D.contest_tier.
    pub tier: u8,
    /// Last sim-tick at which ownership flipped, OR last attack
    /// resolved. Used as cooldown anchor.
    pub last_flip_tick: u64,
    /// Attacks this owner has held against. Cosmetic; resets on flip.
    pub hold_streak: u32,
    /// Cached attack cadence in sim-ticks. Recomputed on tier change.
    pub attack_cadence: u64,
}
```

`canonical_owner` survives flips so a future "world reset" / "campaign restart" feature can revert to authored state without re-loading the scene tree.

---

## 4. Tier-Driven Tunables

Numbers illustrative; tune at impl time.

| Tier | Reading | Attack cadence (sim-ticks) | Garrison size | Defense mod | Capture reward |
|---|---|---|---|---|---|
| 1 | Minor checkpoint / camp | 1800 (~30 game-min) | 2–3 NPCs | 0.8× | small loot drop, +1 territorial-influence |
| 2 | Standard outpost | 900 (~15 game-min) | 4–6 NPCs | 1.0× | normal loot, +2 influence |
| 3 | Important outpost / hub | 450 (~7 game-min) | 8–12 NPCs | 1.3× | premium loot, +5 influence, audible Valley-wide on capture |
| 4 | Major faction asset | 240 (~4 game-min) | 16+ NPCs | 1.5× | rare-tier loot, +10 influence, faction-wide reaction |

Cadence is cooldown-based: after an attack resolves, the next eligible attack window opens `attack_cadence` ticks later. Doesn't preclude a quick-flip-back if the new owner's defenders are weak.

---

## 5. Garrison Population

When a base's owner changes:

1. Despawn existing garrison NPCs (offline-tier — just delete records).
2. Pull the new owner's loadout-table for this base kind + tier.
3. Spawn `garrison_size` NPCs as offline-tier records, marked `InRegion(region_id_for_base)` and `InFaction(new_owner)`.
4. If a player is online-tier-close to the base, materialize the new garrison via `region_spawn_point` (per `npc-traversal-plan.md` §7) at `ANCHOR_SPAWN` markers in the base's region.

Open question: do already-online NPCs at the base flip their loyalty to the new owner, or get overwritten? Probably overwritten — feels more like a real attack outcome than a coup. Revisit if it reads strangely in playtest.

---

## 6. Attack Resolution Math

Single-roll for offline tier. Online-tier in-progress attacks (player witnessing) are out of scope here — that's a future "live attack resolution" plan that promotes the abstract roll into a real battle.

Roll form:

```
attacker_score = attacker_force × tier_pressure(attacker.tier_at_origin)
                  × proximity_bonus(distance_to_attacker_home)
defender_score = defender_garrison × tier_modifier × hold_streak_bonus
roll = (attacker_score - defender_score) / max(attacker_score, defender_score)
       + rng_jitter(±0.15)

if roll > 0.0:
    attacker wins
else:
    defender wins (hold_streak += 1)
```

Open: the math should respect `FactionRelations` (allies don't attack each other, even-strength can still flip if hatred is high). Encode hatred as a +pressure modifier on attacker side.

---

## 7. Persistence & Determinism

Rotation state lives in `simn-world` ledger:

```sql
CREATE TABLE contested_bases (
    poi_id TEXT PRIMARY KEY,
    current_owner INTEGER NOT NULL,    -- Faction discriminant
    last_flip_tick INTEGER NOT NULL,
    hold_streak INTEGER NOT NULL DEFAULT 0
);
```

Loading flow:
1. Sim loads world. Walks `poi_markers` group via the scene-tree → ECS bridge.
2. For each `BASE_*` with `contested = true`, look up `poi_id` in `contested_bases`.
3. If row exists: hydrate `ContestedBase` from the ledger.
4. If row missing: insert with `current_owner = canonical_owner`, `last_flip_tick = now`, `hold_streak = 0`.

This means **deleting the ledger row** for a base resets it to canonical — useful for testing and for a future "this faction quit" event that hands a base back to its original owner.

Determinism: the tick reads `RngStream` keyed on `poi_id + sim_tick` so a re-played save produces identical rotations. (Per `sim-hardening-plan.md` standards.)

---

## 8. Player-Facing Hooks

What the player sees:

- **Map UI flag color** matches `current_owner`. Flips when ownership flips.
- **Audio cue** on rotation if player is in the same region (territorial-pressure hum, per the existing soundscape system).
- **NPC dialog** at faction hubs references recent flips ("Did you hear? Looters took the Cascade Locks checkpoint last night.").
- **Quest hooks** (per `PoiMarker3D.QUEST_HOOK`) can predicate on `current_owner` for retake / hold missions.

What the player doesn't see directly: the actual attack roll. They see the *outcome* in the world, plus optional radio chatter "Compact forces engaging at White Salmon outpost" mid-resolution.

---

## 9. Open Questions

- **Offline-tier player participation.** Can a player help an attack from offline tier (joining an attack while in a different region)? Probably yes, as a "support attack" action that adds a fixed score boost. Defer until we have any real online↔offline player action.
- **Multiple attackers per cycle.** Do two different hostile factions ever attack the same base simultaneously? If yes, it's a 3-way roll. If no, the tick picks the highest-pressure attacker only. Lean **picks one** for simplicity in v1; revisit if it feels artificially clean.
- **Player capture eligibility.** Can the player faction-claim a base? Probably only via story progression (per the no-extraction-loop rule from the design overview). The mechanic is *territorial control between NPC factions*, not "build your empire."
- **Cascading capture.** If Aegis takes Cascade Locks, do nearby Aegis-held bases get a hold-streak bonus from territorial cohesion? Yes, eventually — encoded as `proximity_bonus` lookup against neighboring same-faction bases.
- **Tier override at runtime.** Should an authored `tier = 1` base ever escalate to `tier = 2` due to gameplay events (a major story beat)? Probably — handled via a separate "story escalation" system that mutates the ledger row directly. Not in v1.

---

## 10. Concrete Code Artifacts This Plan Demands

1. **`ContestedBase` component in `simn-sim`** — see §3.
2. **`contestation_tick` system in `simn-sim`** — see §2.
3. **Ledger schema + read/write in `simn-world`** — `contested_bases` table per §7.
4. **Scene → ECS bridge in `simn-godot`** — walks `poi_markers` group on map load, emits one `RegisterContestedBase` event per qualifying node, fed into the sim by the existing `simn-godot::sim::SimSession` bridge.
5. **Attack roll math + tier tunables** — §4 + §6 land as constants in the sim crate; tune via integration tests.
6. **Player-facing hooks** — Godot-side: map flag color update on `ContestedBaseFlipped` event; audio cue; dialog string substitution.

---

## 11. What's Blocked On This Plan

- **Faction territorial control beyond canonical seed.** Today the world seed assigns base ownership from `PoiMarker3D.faction` and that's it. Without contestation, faction territories are static.
- **Capture-driven loot rewards** (per `loot-and-economy-plan.md`) — the "you took this base, here's the loot" mechanic needs the contestation tick to fire the capture event.
- **NPC squad-level offline objectives** ("Aegis is attacking Compact at the_dalles") — needs contestation to actually be the attack scheduler.
- **Quest predicates on ownership.** "Take back the checkpoint" / "Hold the outpost for X minutes" missions are gated on this system.

Not blocked: PoiMarker3D authoring, RegionMarker3D placement, the scene-tree → group lookup pattern, encounter triggers (orthogonal — encounters can fire inside a contested base regardless of who owns it).
