# Simulation - how the data model + persistence works

## Why this exists

Before this slice, the "source of truth" for player positions was a
Godot scene node. That doesn't scale - every feature we'd build next
(inventory, NPCs, A-Life, save games, anticheat) needs an
authoritative data model that isn't tied to the scene graph. This
slice makes `simn-sim` the source of truth: positions, regions, and
eventually everything else live in a `bevy_ecs::World` that ticks
continuously and persists to disk.

This crate is the **NPC foundation layer** in the architecture
defined by `ai-generation.md`, `sim-brain.md`, `tactical-ai.md`,
and `scripted-quests.md` (all siblings in this section). Higher layers - Persona + Memory + LLM
narration (AI-generation), deterministic rule reactions (sim brain),
GOAP + squad coordination + tactical map annotations + chatter
(tactical AI), and authored canon arcs (scripted quests) - all sit
*above* this layer and plug into the same `NpcId`/`Group`/region
graph data shapes. Their implementations are designed in detail and
parked until the base work matures.

What lives in this crate today:

- **Spawn** - population top-up to per-region targets, spawning
  squads (not individuals) anchored near same-faction bases.
- **Squad objectives** - `Patrol / Guard / Rest / Explore /
  Investigate / Relieve / Wander / Regroup`. Planner picks per
  faction archetype; per-member formation offsets (V-column for
  moving objectives, circular spread for rest/guard) keep squads
  from stacking.
- **Posted guards** - `Guard` with a `post_key` is indefinite;
  squads hold until `Relieve` arrives or they die. Guard + Relieve
  are gated on **territorial standing** (primary or contesting
  faction for the region) so nobody sets up shop in a random
  region they just wandered into.
- **Group cohesion** - centroid-based regroup when max member
  spread exceeds ~80m.
- **Portal-based region migration** - `Explore` objective walks
  squads to a region's transition portal; `npc_portal_cross`
  relocates the non-aggroed squad to the reciprocal portal on
  arrival. 2×2 region grid, transitions are sim-authoritative
  (scenes pull portal positions from `SimHost.region_transitions`).
- **Aggro + placeholder combat** - `npc_aggro` with FOV, sight
  radius, and pluggable LOS; `npc_combat` bucketed hit chance.
- **Aging + combat death** - every NPC that ever lived gets a
  permanent `LifeRecord` in the `LifeChronicle`.
- **Time + weather** - `WorldTime` resource (day / seconds_of_day /
  day_length_seconds, default 7200s = ~12× real) with `sun_angle_rad()` and
  `is_daytime()` helpers. `WeatherState` (single global enum, PNW
  palette: Clear / PartlyCloudy / Overcast / MarineLayer / Fog /
  Drizzle / LightRain / HeavyRain / Windstorm / Thunderstorm /
  SmokeHaze) rolls every ~30 in-game minutes via `advance_weather`
  using Markov-ish transitions that favour staying put and stepping
  along the overcast → drizzle → light → heavy → thunder intensity
  ladder; marine layer branches off clear/partly at dawn and burns
  off to clear more often than it thickens; SmokeHaze is a
  dry-season attractor that sticks once set. Both `WorldTime` and
  `WeatherState` snapshot through the save body, so replays are
  deterministic and weather continuity survives load/save. A
  29.53-day lunar cycle derives from `WorldTime.day + day_fraction`
  - `moon_phase()` (0=new, 0.5=full), cosine-smoothed
  `moon_illumination()`, and `moon_angle_rad()` (sweeps opposite
  the sun, offset by phase so a full moon culminates at midnight).
  Godot adds a procedural moonlight `DirectionalLight3D` that fades
  in at dusk and scales with illumination - new-moon nights are
  genuinely dark. Seasonal biasing, per-region fronts, and NPC
  behavior shifts are parked for the per-region-state slice + brain
  layer.
- **Behavior logging** - togglable `BehaviorLog` resource emits
  a batched `tracing` summary every 5s (counts + per-faction
  spawns + per-cause deaths + objective distribution). F9 in
  Godot; `RUST_LOG=npc.behavior=info cargo run --example watch -p
  simn-sim` headless.

### Status

This is a **placeholder behavior layer** - good enough to feel alive
and exercise the architecture, not the final AI. The parked
`tactical-ai.md` / `sim-brain.md` / `ai-generation.md` /
`scripted-quests.md` designs replace most of what's in this crate
once their base dependencies land. Stage 1 foundations are now
mostly landed; Stage 2 has begun. Known gaps to revisit:

- Solo NPCs still use the original per-NPC FSM (not the squad
  objective system).
- `npc_combat` is still distance-bucketed dice (now scaled by the
  NPC's `accuracy` stat, gated by an interim `LosCache` read so the
  shot drops if the shooter has no per-tick exposure entry on the
  target or exposure < 0.33). The shared `Projectile` ECS path is
  live for player firing; NPC migration onto it is the next slice
  ([`physical-combat-plan.md`](../planning/physical-combat-plan.md)).
- World event bus emitters wired: `npc_aggro` → `EnemySighted`
  (2026-05-06), `npc_combat` → `Gunshot` (2026-05-11),
  `npc_death_check` → `AllyDown` (2026-05-11), `offline_combat` →
  placeholder `BaseFlip` (2026-05-12), and `base_capture_check` →
  online-tier `BaseFlip` (2026-05-25). `PortalUsed` (from
  `npc_portal_cross`), `CorpseSpotted` (observer-driven, needs a
  corpse-perception pass over `WorldContainer` corpses), and
  `Chatter` emitters are still TODO.
- Goal arbitration consumes blackboard urgency as first-class
  candidates (`BlackboardUrgency` source, landed 2026-05-11):
  `DownedAlly` (priority 180, `GoalKind::RegroupOnAlly { id, pos }`),
  `UnderFireAt` (priority 140, `GoalKind::InvestigateAt { pos }`),
  `HeardGunshot` (priority 100, `GoalKind::InvestigateAt { pos }`).
  Executor walks toward `pos` at `Bushwhacker` style and settles
  on arrival; real take-cover / suppress-back / revive behaviors
  are tactical-AI follow-ups.
- Aggro has no cross-region memory (per-NPC chronicle of
  attackers is folded into [`npc-character-authoring-plan.md`](../planning/npc-character-authoring-plan.md);
  `LivedExperience.kills` doesn't yet survive snapshot reload).
- No day/night or weather-driven behavior shifts.
- No mass events (raids, faction swings). Small-scale **base
  capture** does work as of 2026-05-25: squads rolling
  `Investigate` will target a nearby hostile-faction non-HQ
  non-CampSite base when one exists in-region, and
  `base_capture_check` flips ownership when the defenders are
  cleared and ≥ 2 same-faction attackers remain within 40 m.
  Headquarters bases are flip-immune. Full contestation
  (per-base tier, attack cadences, garrison repopulation,
  ledger persistence) still lives in
  [`../planning/contestation-plan.md`](../planning/contestation-plan.md).

The placeholder combat is explicitly *not* tactical AI - `npc_aggro`
acquires by distance → FOV cone → line-of-sight (asymmetric per-NPC
sight via the `perception` stat); squad-share propagates first
contact and the multi-target threat board (`apply_threat_priority`)
re-focuses fire when a new attacker dominates by hysteresis;
`npc_combat` rolls a distance-bucketed hit chance with no LOS check
on the firing path itself. Real GOAP planning, cover use,
tactical-map annotations, and persona-weighted goal priority all
live in the parked tactical AI plan.

**Perception.** `PerceptionConfig` (fov_deg 110, sight_radius 80m,
exposure_required 0.33, concealment_visibility 0.5) drives
acquisition. The sim does the cheap gates (distance, FOV) itself
and then consults a pluggable `LosProvider`:

- Headless runs / tests install `AlwaysVisibleLos` (always returns
  1.0 - no LOS filter).
- The gdext crate installs `GodotLosProvider`, which samples
  multiple heights on the target (feet / torso / head by default)
  via `PhysicsDirectSpaceState3D::intersect_ray`, weights solid hits
  at 0 and concealment-only hits at `concealment_visibility`, and
  averages. This is how partial exposure (e.g. behind a bush) and
  stacked cover (feet behind a crate, torso exposed) start to
  matter. See `crates/simn-godot/src/los.rs` for the collision-layer
  contract (`LAYER_SOLID` = bit 0, `LAYER_CONCEALMENT` = bit 1,
  `LAYER_NPC_HITBOX` = bit 2).

Squads have a **per-group objective layer** between spawn and
movement: every ~10s the `squad_planner` system rolls a new
objective for each squad based on a per-faction archetype table
(`Patrol` between same-faction bases, `Guard` a nearby base, `Rest`
at a nearby `CampSite` or same-faction Safehouse/Outpost, `Explore`
to a neighbor-region portal, `Investigate` a remote point, `Wander`,
`Regroup` for cohesion). Guard and Rest prefer the nearest-3 bases
to the squad centroid so squads visibly camp instead of trekking
across the map. **Guard is posted indefinitely** - a squad holding
a registered post stays there until another squad arrives to
`Relieve` them or the holder dies. When a squad rolls Guard but
every local base is already posted, it rolls `Relieve` instead,
marching to an existing post and swapping ownership on arrival
(the old holder re-rolls a fresh objective). `Explore` walks members to a transition portal;
when any member arrives, `npc_portal_cross` relocates the whole
non-aggroed squad to the neighbor's reciprocal portal and the
planner picks a fresh objective. Squads cap at 4–5 members
at spawn - larger objectives will co-ordinate multiple squads once
the brain layer lands, rather than growing one oversized squad.
Neutral `CampSite` bases (seeded 4–7 per region) are non-contestable
and open to any faction at any time. Members pull
their per-tick movement target from the squad's objective rather
than each rolling their own destination. If a member drifts more
than ~80m from the squad centroid, the planner overrides to
`Regroup` until cohesion is restored. `Patrol` keeps a small
recently-visited list to bias toward unvisited bases. Aggro
preempts the objective system entirely. Solo NPCs (no `Group`)
keep the original per-NPC FSM. This is still placeholder for the
parked tactical AI's brain-driven strategic objectives.

The sim exposes a togglable `BehaviorLog` resource
(`Sim::set_behavior_log`, or F9 in-game, or
`cargo run --example watch -p simn-sim`) that emits structured
`tracing` events under target `npc.behavior` for spawn, death,
migration, objective change, and aggro acquisitions. See
`dev-controls.md` for the event format and headless
watcher usage.

**Sim tick rate.** Fixed 20Hz regardless of render rate. `SimHost`
drives the sim with a wall-clock accumulator so a 144Hz display
doesn't cause 7× over-ticking. Cap of 4 ticks/frame prevents the
spiral-of-death when a frame stalls (GC, disk, scene load).

**Server-authoritative behavior runs everywhere, always.** The sim
ticks every NPC every tick regardless of whether a player is in the
NPC's region. NPCs in regions you can't see still spawn, wander,
fight, migrate, and die - the chronicle reflects all of it. Godot's
NPC dummies are a dumb view layer over `SimHost.npcs_in_region(local
player's region)`; the sim is the source of truth, the renderer is
just a window onto whichever slice of state the local player can see
right now.

**Spatial hash for aggro.** The one piece of per-NPC work that
really did cost - the `npc_aggro` pair scan - is now keyed on
[`NpcSpatialHash`], rebuilt every tick by `rebuild_spatial_hash`
(runs between `index_npc_positions` and `npc_aggro`). The hash is
per-region; each grid uses 100m cells (`SPATIAL_CELL_SIZE_M`,
chosen to exceed the 80m default sight radius so within-cell + 4
directional-neighbor lookups cover every possible sight pair). Pass
2 of `npc_aggro` iterates cells rather than all-pairs, dropping the
comparison count from `O(Σ n_r²)` to near-linear in practice. Pass 1
(decay/refresh existing aggro) and `npc_combat` stay iteration-based
on the NPC snapshot and are cheap in shooter-count. This unlock is
what made running aggro + combat in offline regions practical; NPCs
in regions with no player fire at each other, die, and the chronicle
records it all without tanking tick time.

## Three layers

```
bevy_ecs::World  →  Sim (simn-sim)  →  SimHost (simn-godot)  →  GDScript
```

Data model lives in the ECS world. `Sim` wraps it and is the only
thing that mutates state or writes to disk. `SimHost` is a thin
`Node`-flavored shell around `Sim` that pumps the tick and exposes
`#[func]` methods to GDScript. GDScript drives it from
`game_session.gd`.

## The data model

Components are plain Rust structs deriving `bevy_ecs::Component`,
`serde::Serialize`, `serde::Deserialize`:

- **`Position([f32; 3])`** - world-space position in meters. Matches
  Godot's `Vector3` layout.
- **`Rotation(f32)`** - yaw in radians. Pitch/roll are rendered
  engine-side only, not authoritative yet.
- **`InRegion(RegionId)`** - which region the entity is in. The
  region graph defines valid values.
- **`Actor { kind: ActorKind }`** - `Player` or `Npc`.
- **`PlayerOwned { steam_id: u64 }`** - maps this entity to a specific
  Steam user. Unique per entity; lookup by Steam ID is
  `query::<(Entity, &PlayerOwned)>()` + find.
- **`Health { current, max }`** - aggregate hit points for any
  actor. For players this is a *mirror* of `min(BodyParts.head,
  BodyParts.torso)` maintained by every body-part mutation path; the
  death gate (HP=0 ⇒ dead) keeps working for callers that don't care
  about per-part state. For NPCs it's still the source of truth.
- **`BodyParts { head, torso, left_arm, right_arm, left_leg, right_leg }`**
  - per-body-part HP carried by players and NPCs. Six independent
  f32 pools, each clamped to `[0, 100]`. Head/torso at 0 ⇒ death;
  limbs at 0 ⇒ disabled (`limb_disabled(part)`). Players route
  damage via `Sim::apply_damage_to_part`; NPCs through
  `Sim::apply_damage_to_npc_part`. The legacy `Sim::apply_damage`
  routes to torso. Both paths above-threshold spawn a Bleed wound
  alongside the HP change.
- **`SurvivalStats { hunger, thirst, fatigue }`** - three player
  meters in `[0, 100]` (100 = full). Drained by `drain_survival_stats`
  at per-in-world-second rates tuned to a ~8-in-game-hour full-bar
  (hunger), ~6-hour (thirst), and ~12-hour (fatigue) cycle. Below
  threshold (hunger<30 / thirst<50) `regen_stamina` halves stamina
  regen; below the bottom thresholds (hunger<10 / thirst<20)
  `apply_survival_effects` drains torso HP at 0.25/sec - degraded
  function before death per `survival-and-crafting-plan.md` §3.3,
  never a stat-driven instakill.
- **`Stamina { current, max, regen_per_sec }`** - passive regen
  driven by the `regen_stamina` system at `regen_per_sec` units per
  in-game second. Halved when survival meters drop low (see above).
  Per-tick regen is *not* journaled.
- **`Wounds(Vec<(WoundId, Wound)>)`** - discrete wound instances per
  `../planning/survival-and-crafting-plan.md` §4. Carried by players
  and NPCs both. `WoundKind::Bleed` with severity 1..5; treatment
  progression `Untreated → Disinfected → Bandaged → Stitched →
  Healed` (light) and `Untreated → Tourniquet | WoundPacked →
  Stitched → Healed` (heavy). Each `Untreated` Bleed drains its body
  part's HP at `severity * 0.5 hp/in-world-second` via
  `apply_bleed_damage`; infected wounds add a small extra drain even
  when Bandaged. `tick_infection` flips an Untreated wound to
  `infected` after `MedConfig.infection_trigger_ticks`; antibiotics
  clear it (player `apply_antibiotics` + NPC `apply_antibiotics_npc`
  both spawn the `AntibioticsActive` effect the system consumes).
  `tick_necrosis` drains a tourniqueted limb after
  `MedConfig.necrosis_warning_ticks`. `age_and_heal_wounds` handles
  Bandaged → Healed and Stitched → Healed (faster). Wound ids are
  minted by `WoundIdCounter`. Player-facing numbers and protocols in
  `../mechanics/damage-and-healing.md`.
- **`Pain(f32)`** - derived per-tick from active wounds (severity
  weighted by treatment) reduced by Painkiller / Morphine effect
  intensity. Above `MedConfig.pain_regen_threshold` (default 50),
  `regen_stamina` halves regen. Player-only.
- **`Contamination { radiation, toxicity }`** - both 0..100. Decay
  passively per `tick_contamination`; rise from `Sim::add_radiation` /
  `add_toxicity` (called by `eat`/`drink` profiles, anti-rad's
  trade-off, future fault exposure). Above
  `MedConfig.contamination_hp_threshold` (default 80) → slow torso HP
  drain. Anti-rad / anti-tox drugs reduce these explicitly.
- **`ActiveEffects(Vec<ActiveEffect>)`** - carried by players and
  NPCs. On NPCs currently only the `AntibioticsActive` effect lands
  (via `Sim::apply_antibiotics_npc`); the drug-application API
  stays player-only for now, but the component surface is in place
  so future NPC brain effects reuse it. Each
  `ActiveEffect { id, kind, applied_tick, duration_ticks, intensity }`
  contributes its modifier while `now - applied_tick < duration_ticks`.
  Multi-phase drugs (Stim's active+rebound, Adrenaline's
  active+crash) schedule the crash as a separate effect with
  `applied_tick = active_phase_end_tick`. `tick_active_effects`
  retires expired entries each tick. `EffectKind` covers player
  drugs (Painkiller / Morphine / Adrenaline / StimCocktail / AntiRad
  / AntiTox) plus system-emitted statuses (Withdrawal,
  OverdoseDisorientation, AdrenalineCrash, FatigueRebound,
  AntibioticsActive). EffectIds minted by `EffectIdCounter`.
- **`DrugTolerance(Vec<(DrugKind, f32)>)`** - per-drug counter
  `[0, 100]`. `Sim::apply_drug` adds the drug-specific gain (per
  `default_tolerance_gain` in `systems/meds.rs`); `decay_drug_tolerance`
  drains it at `MedConfig.tolerance_decay_per_in_world_sec`. Used
  by `apply_drug` to gate overdose (`tolerance > overdose_threshold`
  AND another active dose) and by `tick_active_effects` to gate
  withdrawal. Player-facing model in
  `../mechanics/drugs-and-effects.md`.
- **`InFaction(Faction)`** - faction allegiance for any entity (NPCs
  and bases). Players are intentionally faction-agnostic.
- **`Base { kind: BaseKind }`** - marks an entity as a faction base.
  Bases are full ECS entities with sibling `Position` + `InRegion` +
  `InFaction` + `Health` + `Base{kind}`. `BaseKind`: Checkpoint,
  Outpost, Safehouse, Headquarters, ResearchPost.
- **`Npc { id: NpcId }`** - marks an entity as an NPC, with stable
  identity. Sibling components: `InFaction`, `InRegion`, `Position`,
  `Rotation`, `Health`, `NpcGoal`, `Lifespan`, optional `Group`.
  `NpcId` is a `u64` newtype minted by `NpcIdCounter` and is the
  **chronicle key** - stable across save/load, never reused.
- **`NpcGoal`** - `Idle { until_tick }` / `MoveTo { target }` /
  `RestAt { until_tick }`. Driven by the `tick_npc_goals` system.
- **`Group { id: u64 }`** - squad cohesion. NPCs sharing a `Group.id`
  use the same RNG seed in `tick_npc_goals` when picking new patrol
  targets, so they walk to the same place. Squad members also share
  aggro: when one acquires, all members of the same group acquire
  the same target. Solo factions (Wanderers; sometimes Looters/
  Compact contractors) skip this.
- **`Aggro { target: NpcId, last_seen_tick }`** - transient. Set by
  `npc_aggro` when an NPC sights a hostile-faction NPC in same
  region within ~80m; refreshed each tick the target is still in
  sight; cleared after ~10s without re-spotting. Not serialized -
  perception re-acquires after load.
- **`Aggression(f32)`** - `[0.0, 1.0]` per-NPC aggression. Set at
  spawn from `faction_base_aggression(faction)` ± 0.15. Scales hit
  chance in `npc_combat`. Placeholder for the persona-weighted
  goal priority that lands with the Persona system.
- **`LastDamager { faction }`** - transient. Stamped by `npc_combat`
  on a target each time it takes a hit; used by `npc_death_check`
  to credit `DeathCause::Combat { killer_faction }`. Not serialized.
- **`Lifespan { spawned_tick, die_at_tick }`** - when
  `clock.tick >= die_at_tick`, `age_npcs` ends the NPC with
  `DeathCause::NaturalCauses`. Combat deaths from `npc_death_check`
  (HP<=0 driven by `npc_combat`) use
  `DeathCause::Combat { killer_faction }` instead.

Resources (ECS singletons):

- **`SimClock { tick, fixed_dt_ms }`** - monotonic engine-tick
  counter. 50ms default (20Hz), matching the network broadcast rate.
- **`WorldTime { day, seconds_of_day, day_length_seconds }`** -
  in-world clock, independent of `SimClock`. Advanced by
  `advance_world_time` each tick. Defaults to a 7200s real day (120
  real minutes per 24-hour in-world day, ~12× compression - tuned to
  feel like STALKER GAMMA's ~2.4 hr/day, biased a hair tighter).
  Stored in snapshots, not the journal - crash drift is bounded by
  the snapshot interval, which is invisible for day/night purposes.
- **`RegionGraph`** - `HashMap<RegionId, Region>`. Each `Region` has a
  name, a `res://`-qualified map scene path, and neighbor IDs. Seeded
  on a fresh sim from `RegionGraph::default_test_graph()` (two nodes
  matching the existing test scenes).
- **`RegionControl { by_region: HashMap<RegionId, RegionControlState> }`** -
  per-region territorial state. `RegionControlState` carries the
  `primary` faction, a `contested_by` list, and a `tension` float in
  `[0.0, 1.0]`. Read by future encounter-spawn / NPC AI systems.
  Stored in snapshots, not the journal - nothing mutates it at
  runtime yet.
- **`PopulationTargets`** - `HashMap<RegionId, HashMap<Faction, u32>>`,
  the desired live NPC count per region per faction. Seeded from
  `RegionControl` (primary → 120, each contesting → 60 as of
  2026-05-23 — tuned for playable framerate at the current
  online-tier cost; bigger pop comes back once distance-tier
  projection lands). The `spawn_npcs` system tops up populations
  toward target every 50 ticks.
- **`NpcIdCounter`** - monotonic source of `NpcId`s, persisted so
  ids are stable across saves and never reused.
- **`LifeChronicle`** - `BTreeMap<NpcId, LifeRecord>`. The
  permanent record of every NPC the world has ever produced -
  birth/death ticks, regions visited, cause of death - kept in the
  chronicle *after* the entity itself despawns. Records are
  inserted by `spawn_npcs`, mutated on migration and death, and
  never pruned automatically. ~150 bytes/record; plenty of headroom
  in the snapshot for a long playthrough.
- **`PendingDeltas`** - buffer that ECS systems push `WorldDelta`s
  into during a tick. `Sim::tick` drains it after `schedule.run` and
  appends each entry to the journal. Keeps systems decoupled from
  the journal and makes the "pure vs journaled" split (see below)
  enforceable at the boundary.
- **`SavePaths { snapshot, journal }`** - on-disk file paths. Not
  serialized; resolved from the save directory at startup.

## Factions

`Faction` is a `Copy` enum with 10 variants matching the design overview
exactly: `Pwa`, `Linemen`, `RevereGuard`, `Federal`, `GulfCompact`,
`Merged`, `NoosphereWorshippers`, `Looters`, `CorporateResearch`,
`Wanderers`. The naming rule from §5.3 is hard - these names are
canonical, no STALKER archetype substitutions.

Faction-vs-faction relations are a const symmetric lookup:
`relation(a, b) -> Relation` where `Relation` is `Hostile | Cold |
Detente | Warm | Neutral`. The matrix mirrors the design overview's
external table (PWA↔RG Hostile, PWA↔Compact Detente, …) plus
reasonable in-Valley defaults (Merged Hostile to all, Wanderers
Neutral to all). Self-relation is always Warm.

Relations don't change at runtime in this slice. Player reputation,
post-mission shifts, faction betrayals - all later.

## Random world content

`world_seed::seed_random_world_content(world, graph, seed)` runs
once in `Sim::new` (with a fixed default seed of 1) or
`Sim::new_with_seed` (caller-supplied). It's deterministic: same
seed → identical world on every platform, courtesy of
`rand_chacha::ChaCha8Rng`.

Per region:

- Pick `primary` from a weighted distribution that favors PWA and
  Wanderers (frontier authority + ambient population). The Merged are
  excluded - they're endgame antagonists at one specific site, never
  randomly seeded.
- 30% chance to pick 1–2 contesting factions; tension scales with
  how outnumbered the primary is.
- Spawn 25–40 `Base` entities per region using **stratified placement**:
  a 7×7 grid of ~660m cells across a ±2300m square, with at most one
  base per cell. Inside its cell each base is jittered to a random
  position with a 10% inset off the cell edges. The grid prevents the
  visible clumping that pure-uniform sampling causes on sparse maps.
  Base kind is biased by owner faction - Linemen → Checkpoint,
  Federal → ResearchPost, Looters → Outpost, etc. Test maps are 5km ×
  5km, so the placement square sits 200m off each edge.

This is scaffolding. When authored region content lands (PWA-must-
hold-the-Western-Line, Linemen-guard-the-grid, Worshippers-around-Maryhill),
the seeder is replaced wholesale; the data shapes (`RegionControl`,
`Base`-as-entity) don't change.

## `Sim` public API

```rust
Sim::new(save_paths, graph)         // fresh sim; writes tick-0 snapshot
Sim::load(save_paths)               // resume: snapshot + journal replay
Sim::load_or_new(save_paths, graph) // the one the engine calls
Sim::new_in_memory(graph)           // tests: full schedule, no journal/snapshot, no NPCs
Sim::new_in_memory_with_seed(graph, seed) // tests: same with explicit seed

sim.tick()                          // advance one tick, journal, maybe snapshot
sim.shutdown()                      // final snapshot + fsync

sim.upsert_player(steam_id, region, pos, yaw)   // seeds Health + Stamina + BodyParts + SurvivalStats full
sim.move_player(steam_id, pos, yaw)
sim.change_player_region(steam_id, region)
sim.remove_player(steam_id)
sim.apply_damage(steam_id, amount)              // legacy; routes to torso
sim.heal(steam_id, amount)                      // legacy; routes to torso
sim.apply_damage_to_part(sid, BodyPart, amount) // per-part; updates Health mirror
sim.heal_part(sid, BodyPart, amount)
sim.set_stamina(steam_id, value)                // clamps to [0, max]
sim.set_survival_stat(sid, SurvivalStat, value) // clamps to [0, 100]
sim.consume(sid, hunger_d, thirst_d, fatigue_d) // raw meter restore
sim.eat(sid, FoodKind)                          // consume food by category
sim.drink(sid, WaterKind)                       // consume water/beverage
sim.apply_disinfectant(sid, BodyPart)           // Untreated → Disinfected
sim.apply_bandage(sid, BodyPart)                // light bleeds; errors on heavy
sim.apply_wound_pack(sid, BodyPart)             // alt to tourniquet for heavy bleed
sim.apply_tourniquet(sid, BodyPart)             // any severity; starts necrosis timer
sim.remove_tourniquet(sid, BodyPart)            // wound resumes bleeding
sim.apply_stitch(sid, BodyPart)                 // Bandaged/Tourniquet/WoundPacked → Stitched
sim.apply_antibiotics(sid)                      // clears infection over time
sim.apply_drug(sid, DrugKind) -> DrugOutcome    // Effect or Overdose
sim.set_radiation(sid, value) / set_toxicity(sid, value)
sim.add_radiation(sid, delta) / add_toxicity(sid, delta)
sim.wounds_on_player(sid) -> Vec<(WoundId, Wound)>
sim.player_view(steam_id) -> Option<PlayerView> // includes pain + contamination + effects + tolerance
sim.each_player(|view| …)
sim.regions() -> &RegionGraph
sim.world_time() -> WorldTime
sim.current_tick() -> u64

sim.region_control(region_id) -> Option<&RegionControlState>
sim.region_control_by_name("map_a") -> Option<&RegionControlState>
sim.bases_in_region(region_id) -> Vec<BaseView>
sim.each_base(|view| …)
sim.faction_relation(a, b) -> Relation

// --- Items + inventory (Step 4 + grid rewrite) ---
sim.item_def(&ItemId) -> Option<&ItemDef>
sim.items() -> impl Iterator<Item = &ItemDef>
sim.recipe(id: &str) -> Option<&Recipe>
sim.recipes() -> impl Iterator<Item = &Recipe>
sim.inventory_view(sid) -> Vec<ItemInstance>       // back-compat (drops position)
sim.inventory_view_grid(sid) -> GridInventory      // includes (x, y, rotation) per stack
sim.inventory_weight(sid) -> f32
sim.near_campfire(sid) -> bool
sim.near_workbench(sid) -> Option<ToolTier>
sim.grant_item(sid, &ItemId, count)        // alias: sim.pickup(...)
sim.drop_item(sid, slot_idx)               // stack vanishes; ground items later
sim.move_between_slots(sid, from, to)
sim.consume_from_slot(sid, slot_idx, Option<BodyPart>)
sim.salvage(sid, slot_idx) -> Vec<ItemStack>
sim.craft(sid, recipe_id)
sim.queue_craft(sid, recipe_id, count) -> Result<u32>   // Step 5 queue
sim.cancel_craft(sid, job_id)
sim.crafting_queue(sid) -> Vec<CraftJob>
sim.can_craft(sid, recipe_id) -> CraftabilityReport
sim.set_player_near_campfire(sid, bool)    // debug context flag
sim.set_player_near_workbench(sid, Option<ToolTier>)

// Paper doll + hotbar (equipment PR-2). Source-grid strings are
// "pockets" for the player's Inventory, or "equipped:<slot_id>" for a
// nested grid inside an equipped container.
sim.equipment_slots() -> &EquipmentSlotRegistry          // paper-doll catalog
sim.equipment_view(sid) -> HashMap<SlotId, EquippedItem>
sim.equip(sid, &SlotId, source_grid: &str, source_idx)
sim.unequip(sid, &SlotId, dest_grid: &str)
sim.consume_from_hotbar(sid, hotbar_idx, Option<BodyPart>)
```

The grid placement engine lives at [`crate::inventory_grid`][placement]
- pure functions on `GridInventory` (`grant_or_merge`,
`consume_from_grid`, `place_at`, `place_at_with_inner`, `move_within`,
`find_first_fit_any_rotation`, `count_of`). The Sim API methods above
route mutations through it; the legacy `merge_item_stack` /
`consume_from_stacks` free helpers in `world::inventory` are now thin
adapters over the engine so `apply_delta` and the crafting tick
system can keep their old call shape. Crafting kit-pooling
(`collect_shared_inventories`) recursively walks pockets + every
equipped container's `inner_grid` + any nested container's grid, so
a gunsmith kit in your backpack satisfies a recipe's `KitRequirement`
without having to move it to pockets.

[placement]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/src/inventory_grid.rs

Every mutating method does two things in lockstep: mutates the ECS
`World` and appends a `WorldDelta` to the journal. That's the
invariant - you never have ECS state without a journal record, and
vice versa. When a system later wants to mutate state from inside the
tick (say, an NPC moves itself), it'll emit deltas via a
`bevy_ecs::Events` resource that a journal-flushing system drains;
the invariant holds because it's enforced at the boundary, not
inside each mutation path.

## The tick loop

`Sim::tick` does:

1. Run the `bevy_ecs::Schedule` - `advance_clock`,
   `advance_world_time`, `regen_stamina` chained in that order.
   These are *pure* per-tick systems: deterministic from current
   resource/component values + elapsed ticks, so they don't journal.
   The split between "pure system" and "event-driven mutation"
   (which does journal) is what keeps journal volume bounded as more
   systems land.
2. Append a `WorldDelta::Tick { tick }` marker to the journal.
3. `journal.maybe_fsync()` - flush the buffered writes, fsync if it's
   been ≥1s since the last fsync.
4. If `tick % snapshot_interval == 0` and `tick > 0`: roll a snapshot.

Snapshot interval defaults to 600 ticks (~30s at 20Hz). A test hook
(`set_snapshot_interval_for_test`) overrides it for unit tests.

### Pure vs journaled mutations

Two flavors of state change live in the sim:

- **Pure per-tick systems** (`advance_world_time`, `regen_stamina`)
  - outputs are a function of inputs already in the world. On load,
  the snapshot restores the inputs and the next `tick()` re-derives
  the outputs. No journal records are needed. The price: up to one
  snapshot interval (~30s) of drift on crash - unnoticeable for time-
  of-day or stamina regen.
- **Event-driven mutations** (`upsert_player`, `move_player`,
  `apply_damage`, …) - discrete state changes that aren't predictable
  from current state. Each one writes a `WorldDelta` to the journal
  in lockstep with the ECS mutation, so journal replay reconstructs
  the exact post-mutation state.

Adding a new system means deciding which side of this line it sits
on. Most "behavior" systems are pure; most "external command" or
"discrete event" mutations are journaled.

## Persistence - journal-then-snapshot

The design goal: crash recovery with ≤50ms granularity, without
rewriting the whole world every tick.

### Snapshot

`world.save`. Full, self-contained dump. Atomic: write to
`world.save.tmp`, fsync, rename over.

```
[8]   magic: b"NSPHSAVE"
[4]   version: u32 LE
[8]   snapshot tick: u64 LE
[4]   body_len: u32 LE
[N]   body: bincode(SnapshotBody)
[32]  blake3(body)
```

`SnapshotBody` contains the clock, region graph, and a `Vec<SerializedEntity>`.
Each `SerializedEntity` is every persistable component on one entity,
each stored as an `Option<T>` (so the "which components does this
entity have" information is implicit in what's `Some`). The snapshot
doesn't preserve `bevy_ecs::Entity` identities - entities get fresh
IDs on load. That's fine because we use `PlayerOwned.steam_id` for
identity rather than ECS `Entity`.

blake3 over the body catches truncation and bit flips. Mismatch → hard
error on load (not a torn tail - snapshots are atomic).

### Journal

`world.journal`. Append-only log of deltas. Header pairs the journal
to a specific snapshot tick; a journal from a different snapshot gets
discarded on load rather than replayed against the wrong base state.

```
[8]   magic: b"NSPHJRNL"
[4]   version: u32 LE
[8]   snapshot_tick: u64 LE
record*

record:
  [4]   payload_len: u32 LE
  [N]   payload: bincode(WorldDelta)
  [4]   crc32(payload)
```

**fsync policy:** buffered `write()` every tick (cheap), `sync_data`
every ~1s (enough to rate-limit SSD wear). `flush_and_sync()` is
called on graceful shutdown.

**Crash tolerance:** the read path stops at the first torn record -
short length prefix, truncated payload, missing CRC, CRC mismatch,
bincode decode error. Everything before that point is kept.
Everything after is silently dropped. This is exactly what you want
when a crash happened mid-write: the last partial record is garbage,
but the thousand clean records before it are fine.

### Rotation

After writing a snapshot at tick N, the journal is truncated and its
header rewritten with `snapshot_tick = N`. So at any point on disk
there's a snapshot at some tick `S` and a journal of deltas strictly
after `S`. Load is: deserialize snapshot, replay journal tail.

## GDScript integration

`SimHost` is a `GodotClass(base=Node)`. Lives as a child of
`GameSession` in `scenes/session_root.tscn` (the autoload). In
`_ready`:

```gdscript
var save_dir := OS.get_user_data_dir() + "/saves"
DirAccess.make_dir_recursive_absolute(save_dir)
_sim.start(save_dir)
```

`OS.get_user_data_dir()` resolves per-platform:
- Linux: `~/.local/share/godot/app_userdata/Noosphere/saves/`
- Windows: `%APPDATA%\Godot\app_userdata\Noosphere\saves\`

`SimHost::process` (runs every Godot frame) calls `sim.tick()`. If it
errors, the `sim_error` signal fires and GDScript pushes an error.

`SimHost`'s GDScript-facing surface (in addition to
`upsert_local_player` / `move_local_player` / `change_region` /
`region_map_scene` / `shutdown`):

- `damage_player(steam_id, amount)` / `heal_player(steam_id, amount)` -
  thin wrappers around `Sim::apply_damage` / `Sim::heal`; route to
  torso under the hood now that body parts exist. Clamped.
- `damage_part(steam_id, part_name, amount)` /
  `heal_part(steam_id, part_name, amount)` - per-body-part damage.
  `part_name` is `"head" | "torso" | "left_arm" | "right_arm" |
  "left_leg" | "right_leg"`; unknowns are logged and ignored.
- `set_player_stamina(steam_id, value)` - clamped sets, journaled.
- `set_survival_stat(steam_id, stat_name, value)` /
  `consume_food(steam_id, hunger_d, thirst_d, fatigue_d)` - set or
  add to a survival meter; clamped to `[0, 100]`. `stat_name` is
  `"hunger" | "thirst" | "fatigue"`.
- `apply_bandage(steam_id, part_name)` /
  `apply_tourniquet(steam_id, part_name)` /
  `remove_tourniquet(steam_id, part_name)` /
  `apply_disinfectant(steam_id, part_name)` /
  `apply_stitch(steam_id, part_name)` /
  `apply_wound_pack(steam_id, part_name)` /
  `apply_antibiotics(steam_id)` - wound treatment. Errors (e.g. "no
  light bleed to bandage", "bandage cannot treat heavy bleed") are
  logged via `godot_error!`; the calls don't panic into Godot.
- `apply_drug(steam_id, drug_name) -> bool` - apply a drug.
  `drug_name` ∈ `painkiller | morphine | adrenaline | stim_cocktail |
  anti_rad | anti_tox`. Returns `true` on normal application,
  `false` on overdose (the disorientation effect spawns instead but
  the call doesn't fail).
- `eat(steam_id, food_name)` / `drink(steam_id, water_name)` -
  consume by category (see `../mechanics/food-and-water.md`
  for names + profiles).
- `set_radiation(steam_id, value)` / `set_toxicity(steam_id, value)`
  - debug hooks for direct contamination control.
- `player_state(steam_id)` - Dictionary includes `health`,
  `max_health`, `stamina`, `max_stamina`, `body_parts` (nested dict
  keyed by part name), `hunger` / `thirst` / `fatigue`, `wounds`
  (Array of dicts with `id`/`body_part`/`kind`/`severity`/`treatment`/
  `spawned_tick`/`infected`), `pain` / `radiation` / `toxicity`,
  `active_effects` (Array of dicts with `id`/`kind`/`applied_tick`/
  `duration_ticks`/`intensity`), `drug_tolerance` (dict of
  drug-name → counter), alongside `region`/`pos`/`yaw`. HUD reads
  from this.
- `world_time()` - Dictionary `{ day, seconds_of_day,
  day_length_seconds }`. Day/night rendering will read this once it's
  wired.
- `region_control(region_name)` - Dictionary
  `{ primary, contested_by, tension }`. HUD / map overlays read this.
- `bases_in_region(region_name)` - Array of base dictionaries
  `{ kind, faction, pos, health, max_health }`. Used to render
  faction icons on the world map and spawn base props in scenes.
- `faction_relation(a, b)` - String like `"hostile"` / `"warm"`.
  GDScript can use this to color faction icons on the HUD.
- `npcs_in_region(region_name)` - Array of NPC view dictionaries
  `{ id, faction, pos, yaw, health, max_health, body_parts }`.
  `GameSession` polls this every physics tick and spawns/updates
  `humanoid_dummy.tscn` instances keyed by `id`.
- `chronicle_summary()` - Dictionary
  `{ total_ever_spawned, currently_alive, by_faction: { … } }`.
  The debug overlay shows the headline as `chronicle: ever=N alive=N`.
- `recent_deaths(limit)` - Array of dicts with id / faction /
  birth/death ticks / region names / cause string. For the future
  in-game journal UI; debug-only for now.
- `grant_item(steam_id, item_id, count) -> bool` /
  `drop_slot(steam_id, slot_idx)` /
  `move_slot(steam_id, from, to)` /
  `consume_slot(steam_id, slot_idx, body_part_or_empty)` /
  `salvage_slot(steam_id, slot_idx)` /
  `craft_recipe(steam_id, recipe_id)` /
  `set_near_campfire(steam_id, bool)` - inventory surface. Errors are
  logged and returned as `false`; no panics. `body_part_or_empty` is
  `""` for food/drink/drugs/antibiotics, a limb name for treatments.
- `item_catalog()` - Array of every item with
  `{ id, name, category, weight, stack_size, perishable_ticks }`.
  Drives future recipe browser / inventory UI.
- `player_state` additionally includes `inventory` (Array of
  `{ id, name, category, count, spawned_tick, x, y, w, h, rotation }`
  per placed stack), `inventory_width` / `inventory_height` (cell
  dimensions of the player's pockets grid), `inventory_weight` (total
  kg), `near_campfire` (bool), `near_workbench` (string tier tag), and
  `crafting_queue` (Array of in-flight craft jobs).

`game_session.gd`'s `_physics_process` does the sim ↔ render handshake:

```gdscript
var pos := _local_player.global_position
var yaw := _local_player.rotation.y
_sim.move_local_player(sid, pos, yaw)        # write to sim
var view: Dictionary = _sim.player_state(sid) # read back authoritative
if not view.is_empty():
    _network.publish_state(view["region"], view["pos"], view["yaw"])
```

The network layer now ships what the sim says, not what the Godot
node says. In this slice those values are equal (no correction is
happening), but the pipe is right-side-up for when sim-side
clamping/validation lands.

On quit, `GameSession._notification(NOTIFICATION_WM_CLOSE_REQUEST)`
calls `_sim.shutdown()` before exiting - that final snapshot is what
makes "launch again and resume" work.

## Region transitions

Transition cubes call `GameSession.request_map_change("map_b")`. The
flow:

1. `_enter_region("map_b", try_saved_state=false)` runs.
2. `_sim.region_map_scene("map_b")` resolves to
   `res://scenes/test/test_map_2.tscn`.
3. Old scene is freed, new one instantiated.
4. Local player spawned at the new map's `PlayerSpawn` marker.
5. `_sim.upsert_local_player(sid, "map_b", spawn_pos, 0.0)` records
   the new region + position in the sim authoritatively. The journal
   gets a `SpawnPlayer` delta for it.

On host() the same function runs with `try_saved_state=true`, which
asks the sim "do you already have state for this player?" If yes and
the saved region matches the region we're entering, we use the saved
position. If not, we fall back to `PlayerSpawn`. That's how
"walk around, quit, relaunch, click Host, appear where you were"
works.

## Tests

`crates/simn-sim/tests/persistence.rs`, using `tempfile::TempDir`:

- `save_load_roundtrip` - 3 players in 2 regions, tick 10x, shutdown,
  reload, all state matches.
- `journal_replay_after_crash` - tick 50 moves without shutdown,
  reload replays the journal, final state matches tick-50.
- `torn_journal_tail_is_skipped` - append random bytes to the journal,
  reload, last intact record's state is what's recovered.
- `region_navigation_persists` - `change_player_region` round-trips.
- `unknown_region_rejected` - `upsert_player` to a region not in the
  graph returns `Err`.
- `snapshot_compaction` - with a 5-tick interval, tick 5x, verify the
  journal header now carries `snapshot_tick = 5`.
- `apply_damage_routes_to_torso` - legacy `apply_damage` updates
  torso + aggregate health mirror; head untouched.
- `body_parts_roundtrip` - damage all six parts to distinct values,
  shutdown, reload, every part HP preserved; aggregate `health`
  mirrors `min(head, torso)`.
- `head_damage_kills` / `limb_damage_disables_not_kills` - head=0 ⇒
  `is_alive() == false` and `health.current == 0`; limb=0 ⇒ `limb_disabled(part)`,
  player still alive, aggregate health unchanged.
- `survival_stats_drain` - 200 ticks drains hunger/thirst/fatigue,
  thirst faster than hunger per spec §3.3.
- `survival_persists_across_reload` - set non-default values on all
  three meters, save, load, preserved.
- `consume_clamps_to_full` - `consume(.., 200, ..)` over 50 hunger
  caps at 100.
- `low_hunger_halves_regen` - hunger=25 + stamina=0 + 20 ticks ⇒
  regen ≈ half of normal rate.
- `starvation_drains_hp_slowly` - hunger=thirst=0 + 100 ticks loses
  HP but well under 10 hp (degraded function, not insta-death).

`crates/simn-sim/tests/wounds.rs` (Step 2):

- `small_damage_no_wound` / `light_damage_creates_light_bleed` /
  `heavy_damage_creates_heavy_bleed` - confirm the threshold table
  (<10 = no wound, 10..25 = light sev 1–3, ≥25 = heavy sev 4–5).
- `bleed_drains_part_hp_over_time` - sev-4 bleed loses ~2 hp from the
  affected part across one in-world second.
- `bandage_stops_light_bleed` / `bandage_on_heavy_bleed_errors` /
  `bandage_with_no_wound_errors` - eligibility, error messages.
- `tourniquet_stops_any_bleed` / `remove_tourniquet_resumes_bleed` -
  treatment toggling.
- `bandaged_wound_heals_and_despawns` - uses
  `set_heal_ticks_for_test(20)` to avoid ticking the default
  6000-tick timer.
- `wounds_persist_roundtrip` - three wounds in three treatment states
  survive save+load with stable WoundIds.
- `wound_id_counter_persists` - new wound after reload gets a fresh id
  greater than any pre-reload id (no reuse).
- Step 3 additions: `untreated_wound_becomes_infected`,
  `disinfect_prevents_infection`, `antibiotics_clear_infection`,
  `stitch_heals_faster_than_bandage`,
  `tourniquet_necrosis_starts_after_warning`,
  `wound_pack_stops_heavy_bleed`. All use
  `set_med_timings_for_test(40)` and `set_heal_ticks_for_test(N)`
  so they don't need the default 6000+ tick windows.

`crates/simn-sim/tests/effects.rs` (Step 3):

- `first_dose_is_safe` - no drug overdoses on a single use.
- `painkiller_reduces_pain` / `morphine_reduces_pain_more_than_painkiller`.
- `stim_boosts_regen` - confirms the `regen_stamina` multiplier path.
- `adrenaline_revives_at_low_hp` - vital_min < 10 → restore to 30%.
- `tolerance_increments_per_use` / `tolerance_decays_over_time`
  (uses 6000 ticks = 1 in-world hour, expects ~25 unit drop).
- `third_morphine_overdoses_when_tolerance_high` /
  `overdose_disorients_player`.
- `anti_rad_reduces_radiation_with_tox_cost` - confirms the spec §4.4
  trade-off.
- `anti_tox_reduces_toxicity` / `high_contamination_drains_hp`.
- `effects_persist_roundtrip` - apply painkiller + stim, save, load,
  effect count and kinds preserved.

`crates/simn-sim/tests/food.rs` (Step 3):

- One test per `FoodKind` / `WaterKind` profile that matters: hunger/
  thirst restore, raw meat tox, contaminated rad+tox, dirty water
  rad+tox, clean water safe, energy drink grants Stim.

`crates/simn-sim/tests/inventory.rs` (Step 4, 16 tests):

- `items_toml_loads` - registries come up at `Sim::new` and hold the
  expected catalog entries + cook_meat recipe.
- `pickup_stacks_same_id` / `pickup_splits_over_stack_size` - stack
  merge + stack-size overflow behavior.
- `drop_removes_slot` / `move_between_slots_swap` - slot-level
  mutations.
- `consume_food_routes_to_eat` - consuming a cooked-meat stack calls
  `eat` and decrements the slot; hunger rises.
- `consume_drug_routes_to_apply_drug` - painkiller consume spawns the
  Painkiller effect; slot empties.
- `consume_bandage_errors_without_wound` / `consume_bandage_routes_to_treatment`
  - underlying API error leaves the stack untouched; success
  decrements + treats the wound.
- `salvage_without_tool_errors` / `salvage_with_tool_produces_outputs` -
  toolkit requirement + output materialization (components end up in
  inventory, junk is consumed).
- `craft_cook_meat_requires_cookware` / `craft_cook_meat_requires_campfire`
  / `craft_cook_meat_success` - tool + context gates, then the happy
  path.
- `perishables_expire` - `set_perishable_ticks_for_test` + a few
  ticks removes the expired stack.
- `inventory_persists_roundtrip` - grant a mix, shutdown, reload,
  every stack + the near-campfire flag survive.

## Mirror mode + action dispatch (slice-1 net)

The sim now has two operating modes:

- **Authoritative** (solo / host) - runs the full schedule, writes
  journal + snapshots, drain `last_tick_deltas` for network broadcast.
  Mutations go through `record_delta` which appends to disk and
  buffers for broadcast in one shot.
- **Mirror** (coop client) - `Sim::new_mirror(graph)` builds a sim
  with `journal: None` and `save_paths: None`. The schedule is
  reduced (no NPC-mutating systems - `Entity::to_bits()` in their RNG
  seeds isn't stable across instances). Host state flows in via
  `apply_external_snapshot(body, tick)` on join and
  `apply_external_delta(delta)` per tick thereafter;
  `set_tick_for_mirror(host_tick)` anchors the mirror's clock.

A new `broadcast_npc_positions` system on the authoritative schedule
emits one `WorldDelta::NpcPositionBatch` per tick carrying every NPC's
transform - the mirror applies those to keep NPC dummies in sync
without running the NPC behavior systems.

**Action dispatch.** `Sim::apply_action(steam_id, ActionKind)` routes
a client-originated mutation variant to the matching existing method.
`ActionKind` covers everything a client can trigger: Move, ChangeRegion,
ApplyBandage / Tourniquet / Disinfect / Stitch / WoundPack / Antibiotics,
ApplyDrug, Eat, Drink, ConsumeSlot, DropSlot, MoveSlot, SalvageSlot,
CraftRecipe, QueueCraft, CancelCraft, SetNearCampfire, SetNearWorkbench,
Equip, Unequip, HotbarConsume, GrantItem. `encode_action` /
`decode_action` are the wire-format helpers that `simn-net` stays
ignorant of.

## Per-run save directories

`SavePaths::in_run_dir(user_data_dir, run_id)` resolves to
`<user_data_dir>/saves/<run_id>/world.{save,journal}`. The GDScript
shell's `RunsStore` (`godot/scripts/ui/runs_store.gd`) owns
`save_dir_for(id)` and `remove(id)` (which recursively deletes the
save directory along with the metadata entry). `GameSession.solo(run_id)`
and `host(run_id)` thread the id through to `SimHost.start(save_dir)`;
`join(lobby_id)` calls `start_mirror()` instead and never touches
disk.

## What's next on top of this

- **`bevy_reflect` for generic serialization.** Replace the
  hand-rolled `SerializedEntity` with reflection-based snapshots so
  adding a new component doesn't require editing the persistence
  layer. Do this when component count grows past ~10.
- **Client-side prediction + reconciliation.** Slice 2 - local-echo
  prediction with host-correction rollback for the local player's
  transform, so coop feels as snappy as solo.
- **Per-region delta subscription.** Slice 2 - filter
  `NpcPositionBatch` and player-move deltas by the recipient's
  region to cut client bandwidth at 12-player scale.
- **Dedicated server binary.** Since `simn-sim` is engine-agnostic,
  it can run in a headless `main.rs` without Godot at all. Same
  save format; just a different entry point.
