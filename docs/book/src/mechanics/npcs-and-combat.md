# NPCs & Combat

This chapter is the player-facing contract for what NPCs do, how they
interact with you and with each other, and how combat currently
resolves. Everything here is **placeholder AI** - the "real" tactical
brain, persona system, and scripted-quest layer are designed in
`../walkthroughs/tactical-ai.md`, `sim-brain.md`,
`ai-generation.md`, and `scripted-quests.md` respectively, and will
replace most of what's described here when they land. This is the
foundation layer they build on.

## What NPCs do

An NPC is a living entity on a body-part HP model (per
[Damage & Healing](damage-and-healing.md); Step 2 limits this to
aggregate HP for NPCs for now), with a faction, a sometimes-squad
(`Group`), a position, a goal, and a lifespan. Every tick, for every
region (not just the one you're in), NPCs:

- **Spawn** into under-populated regions. `spawn_npcs` tops up each
  region toward its `PopulationTargets` by minting squads of 4–5 NPCs
  (sometimes solos for Wanderers / Looters / Compact contractors)
  anchored near same-faction bases.
- **Follow a squad objective.** Every ~10 in-game seconds, the squad
  planner rolls a fresh `SquadObjective` per squad from the faction's
  archetype weights: `Patrol` between owned bases, `Guard` a specific
  post, `Rest` at a campsite or safehouse, `Explore` a neighbor
  region via a portal, `Investigate` a remote point (or a nearby
  hostile-faction base — see "Base capture" below), `Relieve` a
  held post, `Wander`, or `Regroup` (forced when any member drifts
  >80m from the squad centroid).
- **Move toward the objective's target** at ~3 m/s, in a formation
  offset from the squad centroid so they read as a cohesive group
  rather than perfectly overlapping.
- **Age.** Every NPC has a lifespan; when it elapses they die
  `NaturalCauses` and the chronicle records it. A steady-state
  region's population is constant - old NPCs die, `spawn_npcs` tops
  back up, different individuals each pass.
- **Migrate across regions.** `Explore` objectives walk squads to a
  region transition portal; the `npc_portal_cross` system relocates
  them to the reciprocal portal in the neighbor region and they
  pick a fresh objective there.

## Factions and hostility

There are 10 factions (the design overview`). Relations are a const
symmetric lookup - five levels from `Hostile` through `Neutral`:

| Relation | Effect |
|---|---|
| `Hostile` | Acquires aggro on sight; fires at each other. |
| `Cold` | Tolerates in shared regions; no aggro. |
| `Detente` | Similar to Cold; trade-peace flavor. |
| `Warm` | Allied (e.g. Pwa + Linemen); never acquire aggro on each other. |
| `Neutral` | No opinion (Wanderers to most others). |

Worth knowing:

- **Linemen** are a Pwa subfaction - they inherit Pwa's external
  relations but are specifically `Hostile` to most hostile-to-Pwa
  factions on top of that.
- **Merged** are hostile to everyone - endgame antagonists, never
  seeded in random world content.
- **Wanderers** are neutral to everyone - they drift through regions
  without drawing fire (unless they pick up a faction, which they
  won't for a long while).
- Faction-vs-faction relations do **not change at runtime yet**.
  Player reputation, post-mission shifts, faction betrayals - all
  deferred to the persona + brain layers.

## Perception

An NPC acquires aggro on another NPC when three conditions are all
true:

1. **Distance** - target within `sight_radius_m` (default 80m).
2. **FOV** - target inside the spotter's forward cone
   (`fov_deg` = 110°, so ±55° of facing).
3. **LOS** - `exposure` (0..1) from spotter's eye to target
   ≥ `exposure_required` (default 0.33). Default provider is
   `AlwaysVisible`-1.0; `simn-godot` installs a raycast provider for
   the active region that multi-samples feet / torso / head against
   solid + concealment collision layers.

Once acquired:

- **Squad-share.** All squadmates in the same `Group.id` adopt the
  spotter's target (but only if they don't already have their own
  aggro - so a roving engagement doesn't thrash members' targets).
- **Aggro decay.** Target lost from sight for ~10 in-game seconds
  (`AGGRO_DECAY_TICKS = 200`) and the aggro component clears.
- **No memory.** Aggro is strictly line-of-sight; NPCs don't hold
  grudges between encounters. Persona-driven grudge memory lands
  with the brain layer.

## Combat (placeholder)

Every ~2.5 in-game seconds (`FIRE_INTERVAL_TICKS = 50`), NPCs with
`Aggro` roll a shot at their target:

| Distance | Hit chance |
|---|---|
| < 15m | 70% |
| 15..40m | 50% |
| 40..80m | 25% |
| ≥ 80m | 0% (out of sight radius) |

On hit: 15–30 HP damage (rolled uniform), scaled by the shooter's
`Aggression` (faction-flavored: Merged ~0.95, Linemen ~0.85, PWA
~0.60, Wanderers ~0.30). Target's `LastDamager` is stamped; if the
target reaches 0 HP, `npc_death_check` credits the kill to the
shooter's faction and the chronicle records
`DeathCause::Combat { killer_faction }`.

Combat is explicitly not tactical AI: **no pathfinding, no cover
use, no LOS check on the firing path itself, no weapon variation,
no ammo, no reload**. The hit roll is just a distance bucket + RNG.
Real tactical AI per `../walkthroughs/tactical-ai.md` (GOAP + squad
coordination + cover + tactical-map annotations) replaces it.

## Base capture (placeholder)

Bases can change hands. The mechanic is intentionally minimal -
just enough to make faction borders mean something while the full
contestation design in
[`../planning/contestation-plan.md`](../planning/contestation-plan.md)
is still parked.

**How a base flips:**

1. A squad on `Investigate` looks for a hostile-faction base in
   its current region. If one exists, the squad walks to it
   (favoring the nearest few with random jitter so multiple
   squads don't dogpile the same outpost).
2. The squad engages the defenders via the normal aggro + combat
   path. No special "siege" behavior - it's the same firefight
   as any other contact.
3. Once the defenders are gone and at least **2 attackers** from
   the same hostile faction remain within **40 m** of the base,
   the base's owner flips to the attacker faction. Toast appears
   in the PDA feed ("Linemen captured a Federal Outpost in
   Western Line").

**What flips and what doesn't:**

- **Outposts, safehouses, checkpoints, supply caches** flip.
- **`Headquarters`** bases never flip - they're narrative
  anchors. A squad on `Investigate` will skip them when picking a
  target.
- **`CampSite`** (neutral) bases don't flip either - they're open
  to any faction at any time, so there's nothing to take.

**What you'll see as a player:**

- The base's authored faction colour / label / NPC garrison
  changes to the new owner the next time the region is active.
  Population top-ups (`spawn_npcs`) now seed the *new* owner's
  squads near the base.
- A PDA toast naming the new owner, old owner, and region.
- Faction borders shift over time as squads from neighbouring
  hostile factions push into each other's territory. Steady-
  state is not a given - one region can change hands repeatedly
  over a single play session.

**Limitations of the placeholder:**

- No per-base "contest tier" - any non-HQ, non-CampSite base
  is equally flippable.
- No attack cooldown - if you (or another squad) clear the new
  garrison fast enough, the base can flip back immediately.
- No persistent ownership history beyond what survives in the
  snapshot. Full ledger-backed contestation lands with
  `contestation-plan.md`.
- The offline tier still uses its own placeholder dominance
  heuristic (Phase 1F, 2026-05-12) for regions you're not in -
  same idea, different code path. Both supersede when full
  contestation ships.

## Offline simulation - what happens in regions you're not in

**Everything.** This is the part that took the spatial-hash refactor
to make practical. NPCs in a region you can't see:

- Spawn and die (chronicle records it either way).
- Follow squad objectives - patrol, guard, rest, explore neighbors.
- Acquire aggro on hostile squads they encounter.
- Fire at each other; casualties land in the chronicle with
  `DeathCause::Combat`.
- Migrate across region portals.

When you enter a region, you see the current simulated state - a
squad mid-patrol between two bases, a firefight between a Pwa
checkpoint guard and a Looter raid, a Wanderer drifting toward the
neighbor region. Not a spawn-anchor pile and not a rewound snapshot.

### How fast NPCs die off vs. spawn back

`spawn_npcs` tops each region's per-faction population back toward
`PopulationTargets` every 50 sim ticks (~2.5 in-game seconds). The
chronicle's `total_ever_spawned` keeps climbing as old NPCs die and
new ones replace them; the `currently_alive` count stays roughly
steady at the target. The debug overlay's `chronicle: ever=N
alive=N` line shows both.

## NPC scope and limits

**Current reality:**

- Population targets are static per region. No dynamic "Pwa is
  winning the Western Line" swings yet.
- Combat is the placeholder model above. Weapons, ammo, cover,
  armor, penetration - all deferred to the weapons/combat plan.
- Solo NPCs (no `Group`) still use the original per-NPC FSM
  (Idle/MoveTo/RestAt), not the squad-objective system. Grouped
  NPCs use squad objectives as described.
- No day/night or weather-driven behavior shifts. NPCs patrol
  through a thunderstorm exactly the same as through clear sky.
- No inter-squad communication. An aggroed squad doesn't call for
  help from the squad two cells over.
- NPCs now carry the same per-part `BodyParts` (head / torso /
  limbs) as players and take differentiated damage from weapon
  raycasts via `SimHost.damage_npc_part`. Above-threshold hits spawn
  Bleed wounds that drain the part over time - same pipeline as
  players. NPC-vs-NPC combat also spawns (ephemeral, non-journaled)
  Bleeds on torso hits. The full treatment API is mirrored for NPCs
  (`SimHost.apply_bandage_npc` / `apply_tourniquet_npc` /
  `apply_stitch_npc` / `apply_wound_pack_npc` /
  `apply_disinfectant_npc` / `remove_tourniquet_npc` /
  `apply_antibiotics_npc`), though no caller wires it up yet. Pain
  and survival meters remain player-only.

**What the player can observe:**

- **Humanoid dummies.** One `humanoid_dummy.tscn` per live NPC within
  ~300m of the local player. Segmented body (head / torso / arms /
  legs), each with its own collider on the `NPC_HITBOX` layer so
  weapon raycasts can resolve which body part was hit. Color-tinted
  by faction (via the shared palette in `scripts/faction_colors.gd`).
- **`Tab`** toggles Label3D billboards above each dummy showing the
  NPC's current state (patrol / guard / rest / explore / aggro).
- **Debug overlay chronicle line** - `chronicle: ever=N alive=N`
  tracks total population history vs. current alive count. Watch it
  move as you wait in a region.
- **Behavior log (`F9`)** - emits a structured tracing summary every
  100 ticks (~5s): `spawns=N deaths=N migrations=N aggro=N
  objectives=[kind:n,...]`. The headless `watch` example streams the
  same log without Godot.
- **Weapon (LMB click-to-fire)** - once the mouse is captured,
  left-click fires the weapon in the active equipment slot. Weapons
  + magazines + ammo + armor all live in `crates/simn-sim/data/items.toml`;
  Phase 2 ships three weapons (pistol / rifle / shotgun), 9 ammo
  variants (HP / FMJ / AP per caliber, plus slug/flechette/buckshot
  for 12ga), and 5 armor tiers (soft vest → class-IV exo, plus a
  helmet). Player equips weapon to `primary` / `secondary` /
  `sidearm` and cycles slots with `Q` / `E`. `R` reloads with the
  best-loaded matching-caliber magazine; load_rounds tops that mag
  up from pocket ammo stacks.
  The fire path is **host-authoritative**: the client sends
  `SimHost.fire_weapon(sid, slot, aim_yaw, aim_pitch)`; the sim
  spawns a `Projectile` entity at the muzzle, ticks it with
  gravity + drag, sweeps a ray against humanoid body-part hitboxes
  in-region each frame, and on hit runs the penetration-vs-armor
  formula (`round.penetration_class - armor.protection_class` →
  full soft damage or scaled blunt) before routing through
  `apply_damage_to_npc_part`. Hitscan is gone; range falloff and
  ballistic drop are live. Empty mag / no-ammo-variant = dry
  click. Tracer + impact FX are client-side, driven by
  `SimHost.projectile_spawned` / `projectile_impacted` signals -
  see `docs/book/src/mechanics/weapons.md` for the damage
  matrix and the load_rounds flow.
- **NPC wound debug label** - while `Tab` labels are on, damaged NPCs
  show a second line with per-part HP (`H90 T67 LA100 RA85 LL100
  RL100`). NPCs with wounds show a third line summarizing count plus
  untreated-bleed / infected / tourniqueted counts
  (`W:3 B:1 I:1 T:1`). Undamaged unharmed NPCs still render only
  the single first line.

## Loadouts & corpse loot

Every NPC spawns with a **faction-keyed loadout** rolled from
[`crates/simn-sim/data/npc_loadouts.toml`][loadouts_toml]. Each
faction's entry is a list of independent rolls of the form
`{ id, count, chance }`. Guaranteed rolls (`chance = 1.0`) always
grant; lower chances are rolled once per spawn against the squad RNG,
so the same seed + tick produces the same gear. The roll feeds a
4×4 `GridInventory` placed via the standard pickup engine - items
that don't fit are silently dropped, identical to player-pickup
overflow behaviour.

[loadouts_toml]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/data/npc_loadouts.toml

Current baseline shape (subject to balance passes):

| Faction | Guaranteed | Notable chance rolls |
|---|---|---|
| PWA / RevereGuard / Federal | bandage ×2, ration ×1 | scrap, painkiller, antibiotics |
| Linemen | bandage ×2, field ration ×1 | wire bundle, basic gunsmith kit (rare) |
| Gulf Compact | energy bar ×2, clean water ×1 | stim cocktail |
| Aegis Pacific | field ration ×1 | anti-rad, advanced toolkit, basic drug-making kit (rare) |
| The Attuned | dirty water ×1 | contaminated food, morphine |
| Looters | (nothing guaranteed) | bandage, vodka, rusty pipe, broken radio, cloth scrap |
| Wanderers | (nothing guaranteed) | dirty water, frayed boots |
| Merged | anti-rad ×2 | morphine - never seeded randomly |

When an NPC dies - combat, lifespan expiry, or the `kill_npc_for_test`
helper - their pockets convert into a **private**
[`WorldContainer`](inventory.md#dropping--ground-containers) at their
position. The corpse:

- Is **private** (`is_public = false`), so it doesn't satisfy crafting
  kit requirements via the kit-pool. You loot the toolkit and walk it
  to the bench yourself.
- Carries the dead NPC's grid as its initial state. Item placement,
  rotation, and any nested `inner_grid` (loaded backpack contents,
  PR-2 territory) all travel with it.
- Is **skipped entirely if the inventory is empty** - Wanderers and
  Looters who rolled no chance items leave no body pile, so the
  ground doesn't litter with empty containers.
- Persists across save/load like any other `WorldContainer`. There's
  no TTL; dropped corpses stick around until the cleanup pass that
  ships alongside ground-pile rendering.

The looting UI - `F` to interact, side-by-side pockets ↔ corpse
grid - is the PR-4c panel; see
[Inventory & Items - Looting](inventory.md#looting-pr-4c) for the
full interaction contract.

## What's deferred

- **Dynamic faction territory swings** (capture/loss of bases over
  time, driven by offline combat outcomes). Noted in `TODO.md`.
- **Inter-squad communication.** Aggroed squad calls for backup.
- **Tactical AI** (GOAP, cover, pathfinding, weapon-aware LOS on
  firing path, persona-weighted goal priority) - `tactical-ai.md`.
- **Sim brain** (deterministic faction/region rule reactions) -
  `sim-brain.md`.
- **AI-generation** (personas, memory, LLM narration) -
  `ai-generation.md`.
- **Scripted quest layer** (authored canon arcs, claim/release
  contract with brain + tactical) - `scripted-quests.md`.
- **Pain + survival stats (hunger / thirst / fatigue) for NPCs** -
  still player-only per the survival-and-crafting plan. Body-part
  wounds and the full treatment API already extend to NPCs - see
  the NPC scope section above.
- **NPC equipment slots** - corpses currently carry pockets only.
  The paper-doll `Equipment` component is player-only; once NPCs
  equip armor / weapons (weapons-plan slice), corpses will need a
  larger grid sized for the loadout + flatten the equipped items in.
- **Per-NPC loot variance from rank / role** - current loadouts key on
  faction only. A "Lineman captain" with a guaranteed advanced kit is
  the named-encounter slice's job, not loadouts.toml's.

## See also

- [Damage & Healing](damage-and-healing.md) - the shared HP + wound
  + treatment pipeline. Players and NPCs ride the same systems;
  the "NPC scope" section covers the NPC-specific bits.
- [Drugs & Effects](drugs-and-effects.md) - NPCs don't use drugs
  yet.
- `../walkthroughs/sim.md` - implementation-side: the ECS data
  model, the tick schedule, and the spatial hash that made offline
  combat practical.
- `../walkthroughs/tactical-ai.md` (parked) - the real AI design
  that eventually replaces most of this chapter.
