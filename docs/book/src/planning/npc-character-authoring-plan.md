# NPC Character Authoring — Planning Doc

**Status:** steps 1–3 landed.
- **Step 1 (substrate, 2026-05-08, PR #147):** `CharacterId` + `NpcStats` (8-stat block).
- **Step 2 (stat integrations, 2026-05-08, PR #148):** `perception` → `npc_aggro` sight scaling; `endurance` → bleed-rate damping; `leadership` → squad cohesion leash; `accuracy` → `npc_combat` hit-chance multiplier.
- **Step 3 (identity + lived experience, 2026-05-08, PR #149):** `PersonalityTraits` 10-bool bitmap + per-faction `PersonalityArchetype` (TOML-driven), goal-arbitration personality bias, four new `GoalKind` variants (`Hunt` / `Socialize` / `Loot` / `Bloodsport`) introduced via personality, universal `NpcRank` ladder (Rookie / Experienced / Veteran / Master / Legend) keyed on `combat_competence`, `NameRegistry` with 8 nationality buckets + per-faction `nationality_weights` overrides, `LivedExperience` rank promotion via `record_kill` (kill counter buffs effective competence by 3 per kill, capped at 500). Surfaced on `NpcView` (name / nationality / rank).

Still ahead: backstory templates + `Templated` / `AIGenerated` / `Scripted` authoring tiers; persistent `kills` counter across snapshot reload (currently re-derives from base stats; chronicle work will fix); remaining stat integrations (`marksmanship` ballistic compensation, `stealth` audible-radius reduction, `strength` melee, `endurance` healing rate); executors for the four personality-introduced goal kinds (today they fall through to wander).
**Last updated:** 2026-05-09
**Scope:** procedural per-NPC identity generation. Every NPC spawned gets a name, short backstory, rank, personality traits, and stat block — all seeded from `NpcId` + faction context for determinism. Identity persists across squad joins, region transitions, online↔offline tier transitions, and into the chronicle. The substrate that makes "every drifter has a story" possible.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 2 personality, Stage 4 narrative integration), [`world-ledger-plan.md`](world-ledger-plan.md) (chronicle as identity backbone), [`goal-arbitration-plan.md`](goal-arbitration-plan.md) (personality drives goal candidates), [`offline-tier-plan.md`](offline-tier-plan.md) (personality preserved across tier transitions), [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md) (per-NPC tactical memory), [`../walkthroughs/sim-brain.md`](../walkthroughs/sim-brain.md), [`../walkthroughs/ai-generation.md`](../walkthroughs/ai-generation.md) (the generative narrative layer that may consume + extend this).

This is a living design doc.

---

## 1. Why this exists

Today, NPCs have `NpcId` + `Aggression(f32)` jitter and that's the entire identity. They're indistinguishable squad members with random aggro values. The user vision is the opposite: every NPC is *somebody* — has a name, a faction history, a rank, a personality archetype, distinct stats. When a squad takes a casualty, it's a specific person dying. When a player encounters the same wandering hunter twice in different regions, they remember.

Two design forcing functions:

1. **Per-NPC history persists across squad joins.** When NPC X leaves squad A and joins squad B, X's chronicle entries about prior firefights, prior squadmates, prior decisions all stay attached to X. Squad membership is a current fact about X, not the only fact. (Per user direction: "if that individual has a past, it shouldn't be lost because he joins another group.")

2. **Personality drives goal candidates, not just re-ranks them.** Per [`goal-arbitration-plan.md`](goal-arbitration-plan.md) §6, personality is allowed to *introduce* new goal candidates a generic NPC wouldn't have ("this person always investigates first"). Without per-NPC distinct personalities, this lever is meaningless.

Together, these elevate per-NPC identity from "Stage 4 nice-to-have" to "Stage 1-2 foundation."

## 2. What this system does / does not do

**Does:**

- Generate a complete `NpcCharacter` data block at NPC spawn time, deterministically from `(world_seed, npc_id, faction, region, spawn_tick)`.
- Provide name, short backstory, rank, personality traits, stat block.
- Persist character data alongside `NpcId` for the entity's lifetime; include in chronicle on death.
- Survive tier transitions (online↔offline carry the same `NpcCharacter`).
- Survive squad joins (character is keyed on entity, not group).
- Expose authoring tables for backstory templates, name banks, rank progressions per faction.
- Feed personality traits into [`goal-arbitration-plan.md`](goal-arbitration-plan.md) bias system (re-rank + introduce candidates).
- Feed stat block into [`physical-combat-plan.md`](physical-combat-plan.md) accuracy / aim cone / movement speed.
- Optional generative extension via the AI-gen layer ([`../walkthroughs/ai-generation.md`](../walkthroughs/ai-generation.md)) — backstories can be filled in by Gemma at world-init for noteworthy NPCs (named officers, faction figureheads), templated for the rest.

**Does not:**

- Drive long-term faction politics (faction-strategic decisions live in [`../walkthroughs/sim-brain.md`](../walkthroughs/sim-brain.md), not per-NPC personality).
- Author quest content. Scripted quests own their own characters via the claims system; procedural NPCs may be promoted into scripted casts but the inverse doesn't happen.
- Replace player character (player has full character data via different system; this plan is NPC-only).
- Drive dialog content directly (dialog is a runner per [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md); personality + stats may inform dialog choices but dialog tables are separate).

## 3. Data model

```rust
#[derive(Component, Clone, Debug)]
pub struct NpcCharacter {
    pub character_id: CharacterId,       // distinct from NpcId; survives respawn / re-instantiation
    pub name: String,                    // procedurally generated (faction name banks)
    pub backstory: BackstoryTemplate,    // template ref + filled-in slots
    pub rank: Rank,                      // faction-specific ladder
    pub personality: Personality,
    pub stats: NpcStats,
    pub authored_tier: AuthoringTier,    // Generic | Templated | AIGenerated | Scripted
}

#[derive(Clone, Debug)]
pub struct Personality {
    pub traits: PersonalityTraits,       // bitmap of trait flags
    pub bias_weights: HashMap<GoalKind, f32>,  // per-goal-kind nudges (0.5 to 2.0)
    pub introduces_goals: SmallVec<[GoalKind; 4]>,  // NEW candidates this personality contributes
    // ^ Landed 2026-05-27 as `introduces_drives() -> SmallVec<PersonalityDrive>`
    //   on `PersonalityTraits` directly (no separate `Personality` struct yet).
    //   `goal_arbitration` resolves each `PersonalityDrive` into a fully-
    //   targeted `GoalKind` using sim context (CorpseIndex / activity points /
    //   group centroid). See goal-arbitration-plan.md status block.
}

#[derive(Clone, Debug)]
pub struct PersonalityTraits {
    pub aggressive: bool,
    pub cautious: bool,
    pub curious: bool,
    pub greedy: bool,
    pub loyal: bool,
    pub bloodthirsty: bool,
    pub social: bool,
    pub solitary: bool,
    pub disciplined: bool,
    pub reckless: bool,
    // … extend as needed; rolled at spawn from faction-weighted distribution
}

#[derive(Clone, Debug)]
pub struct NpcStats {
    pub accuracy: u8,                    // 0-100; aim cone tightness
    pub perception: u8,                  // FOV / sight radius modifier
    pub stealth: u8,                     // sound propagation reduction
    pub strength: u8,                    // melee damage, carry capacity
    pub endurance: u8,                   // stamina regen, wound resistance
    pub marksmanship: u8,                // ballistic compensation skill
    pub leadership: u8,                  // squad cohesion bonus when leader
    pub luck: u8,                        // dice-roll modifier (offline tier visible)
}

#[derive(Clone, Debug)]
pub struct BackstoryTemplate {
    pub template_id: BackstoryTemplateId,  // reference into authoring tables
    pub origin_region: Option<RegionId>,
    pub years_in_zone: u8,
    pub former_factions: Vec<Faction>,
    pub notable_event: Option<String>,    // "lost squadmate to fault", "betrayed by previous faction"
    pub generated_text: Option<String>,   // AI-gen layer's filled-in narrative
}

#[derive(Clone, Debug)]
pub enum Rank {
    Recruit,
    Member,
    Veteran,
    Specialist(Specialization),
    Sergeant,
    Lieutenant,
    Captain,
    Commander,
    // faction-specific variants extend this; not every faction uses every rank
}

#[derive(Clone, Debug)]
pub enum AuthoringTier {
    Generic,         // template-rolled, low investment
    Templated,       // hand-templated backstory class with filled-in slots
    AIGenerated,     // Gemma-authored backstory at world-init
    Scripted,        // hand-authored for a specific quest role
}
```

## 4. Authoring pipeline

**At NPC spawn** (`npc_spawn` system):

1. `character_id = hash(world_seed, npc_id)` — stable identity.
2. Roll faction-weighted personality traits: each trait flag has a per-faction probability table.
3. Roll stats: faction archetype baseline (Wanderers low across the board, PWA high discipline + leadership, Looters high greed + low loyalty), modified by personality traits and a small per-NPC variance.
4. Pick name from faction name bank (deterministic by `character_id`).
5. Pick rank by faction ladder + roll weighted by stats (high leadership rolls into officer ranks).
6. Pick backstory template by personality + faction + roll a few notable events.
7. Compute `bias_weights` and `introduces_goals` from personality traits + faction archetype.
8. `authored_tier = Generic` for typical squadmates. NPCs spawned into scripted quest claims get `Scripted` and skip generation.

**At world init (optional, async):**

- AI-gen layer ([`../walkthroughs/ai-generation.md`](../walkthroughs/ai-generation.md)) walks the spawned NPC list, picks ~5% (named officers, faction figureheads, NPCs with rare trait combos) for `AIGenerated` backstory expansion. Generated text fills `BackstoryTemplate::generated_text`. Validator gate per ai-generation contract.

**At chronicle event time:**

- Each NPC chronicle entry references `character_id`, not just `npc_id`. Chronicle survives entity death; later-spawned characters never collide because `character_id` is unique.

## 5. Personality → goal arbitration

The integration with [`goal-arbitration-plan.md`](goal-arbitration-plan.md):

- **Re-rank existing candidates.** `bias_weights` multiplies the priority of each candidate goal at arbitration time. A Curious personality has `bias_weights[Investigate] = 1.5`; that goal scores 50% higher when arbitration ranks. A Cautious personality has `bias_weights[Engage] = 0.7` and `bias_weights[Flee] = 1.4`.
- **Introduce new candidates.** `introduces_drives` (renamed 2026-05-27 from `introduces_goals`) lists `PersonalityDrive` flags that `goal_arbitration` resolves into fully-targeted `GoalKind`s using sim context. A Curious personality might always nominate `Investigate(nearest_fault)`. A Greedy personality nominates `Loot(nearest hostile-faction corpse)` via `CorpseIndex`. As landed: `Loot` / `Hunt` ride at `PRIO_PERSONALITY_BIAS + 5..+10` (65–70, below squad objectives so they fire when nothing more urgent is happening), `Socialize` rides at `PRIO_SQUAD_OBJECTIVE + 5` (85, gated to Rest-arrived squads so chatter actually breaks formation visibly).

Goal vocabulary expansion (per user direction "more goals and activities — hunting, partying, bloodsport"):

- `GoalKind::Hunt(species_or_target)` — drives NPC to hunt fauna or specific NPCs.
- `GoalKind::Socialize(group_or_individual)` — drives NPC to engage in chatter, sit at campfire.
- `GoalKind::Bloodsport(arena_or_target)` — drives NPC to fight for fun (faction-cultural, e.g., Wanderers specifically).
- `GoalKind::Loot(target)` — drives NPC to rifle through corpses, stashes.

Personality-introduced candidates are how these goals *enter* the world; without personality bias, no system would nominate them.

## 6. Stats → physical combat + behavior

Direct integrations:

- `accuracy` → aim cone width in [`physical-combat-plan.md`](physical-combat-plan.md) §6.
- `marksmanship` → ballistic compensation threshold (NPCs below threshold fire flat, miss long shots).
- `perception` → FOV cone size + sight radius in `npc_aggro`.
- `stealth` → sound propagation reduction in [`world-event-bus-plan.md`](world-event-bus-plan.md).
- `endurance` → stamina regen rate, wound healing rate, infection resistance.
- `leadership` → squad cohesion bonus (max member-distance threshold scales with leader's leadership stat).
- `luck` → small modifier to all dice rolls; visible in offline tier (lucky NPCs survive longer in dice combat).

## 6.5. Landed in step 1 (2026-05-08)

The substrate is on main; downstream integrations and the richer authoring tiers above are still ahead.

- **`CharacterId(u64)`** in `simn-sim/src/components.rs` — stable per-NPC identity derived from `(npc_id, faction_id)` via a simple multiplicative-hash function (`NpcCharacter::derive_id`). World-seed mixing folds in once `Sim` carries one as a resource.
- **`NpcStats`** — eight `u8` fields (`accuracy`, `perception`, `stealth`, `strength`, `endurance`, `marksmanship`, `leadership`, `luck`), all rolled into `30..=80` with a faction-aggression nudge (+0..=20) on the combat-flavored stats (`accuracy` + `marksmanship`). `NpcStats::roll(rng, base_aggression)` is the canonical entry point.
- **`NpcCharacter` component** — `{ character_id, stats }`. Spawned for every NPC at every spawn site (`npc_spawn`, `world::debug::spawn_npc_for_test`, snapshot reload, `WorldDelta::SpawnNpc` replay). Re-rolled deterministically from `(npc_id, faction_id)` on snapshot load — no inline persistence required while the shape stays a function of identity alone. Inline storage + a `FORMAT_VERSION` bump come when an identity field needs to evolve independently of the spawn contract (e.g., personality drift, rank progression).
- **Test scaffolding:** `Sim::npc_character_for_test(id)` returns the live component for integration tests.

**Not yet landed:**

- Personality traits (`PersonalityTraits` bitmap, `bias_weights`, `introduces_goals`). Lands with the goal-arbitration personality-bias slice — those two need to ship together to be useful.
- Procedural names. The plan calls for ~200 first + ~200 last per faction; that's a content-authoring task. Substrate-only PR keeps faction names off the critical path.
- Backstory templates + the `Templated` / `AIGenerated` / `Scripted` authoring tiers.
- Rank ladders (per-faction enums; needs faction-specific authoring).
- Remaining behavior integrations: `accuracy` → npc_combat aim cone (waits on physical-combat projectile path), `stealth` → world-event-bus audible-radius reduction, `endurance` → wound-healing rate, `marksmanship` → ballistic-compensation threshold, `leadership` → squad cohesion bonus. Each ships independently as the matching plan-step lands.

**First behavior integration (2026-05-08): `perception` → `npc_aggro` sight radius.** `sight_radius_for_perception(perception, base)` scales the per-NPC sight range linearly across `[0.6, 1.4]` (perception `0..=100`, 1.0× at 50). `npc_aggro` now does asymmetric distance gating — A's range governs whether A sees B, B's range governs whether B sees A — which lets stat 90 snipers spot stat 30 grunts at distances the inverse pair can't reach. The pre-cull uses the larger of the two so we don't drop pairs where one direction is reachable. Five tests in `tests/perception_sight.rs`.

**Second behavior integration (2026-05-08): `endurance` → bleed-rate damping.** `bleed_rate_multiplier(endurance)` scales the per-NPC HP-drain rate from open wounds inversely across `[1.3, 0.7]` (endurance `0..=100`, 1.0× at 50). Frail conscripts bleed 30% faster than baseline; tough veterans 30% slower. Players collapse to the baseline since they don't carry `NpcCharacter`, so the existing wound tuning is unchanged. Four tests in `tests/endurance_bleed.rs`.

**Third behavior integration (2026-05-08): `leadership` → squad cohesion leash.** `cohesion_multiplier_for_leadership(mean_leadership)` scales each squad's cohesion-break threshold linearly in `[0.7, 1.3]` over the squad's mean leadership stat. Default 80 m leash collapses to ~56 m for unled grunts and stretches to ~104 m for leader-rich veterans. Squads with no `NpcCharacter` carriers fall back to the flat 80 m. Five tests in `tests/leadership_cohesion.rs`.

**Fourth behavior integration (2026-05-08): `accuracy` → npc_combat hit-chance multiplier.** `accuracy_hit_multiplier(accuracy)` scales the per-shooter chance-of-hit linearly in `[0.7, 1.3]` over accuracy `0..=100`. The multiplier composes with the existing distance-bucket and aggression factors. Three tests in `tests/accuracy_combat.rs` (math endpoints + monotonicity + a wiring smoke test). A behavioral A/B comparison waits for a controlled-fire test harness (or projectile ballistics, where accuracy will scale aim-cone width instead of hit-chance).

## 6.6. Personality traits substrate (2026-05-08)

Step 2 of this plan. Adds `PersonalityTraits` (10-bool bitmap) to `NpcCharacter` and the goal-arbitration consumer.

- **`PersonalityTraits`** in `simn-sim/src/components.rs` — `aggressive / cautious / curious / greedy / loyal / bloodthirsty / social / solitary / disciplined / reckless`. Mutually-coexisting; rolled independently per trait against the archetype's probability vector.
- **`PersonalityArchetype`** — `Disciplined / Aggressive / Greedy / Curious / Reverent / Default`. `from_faction_name(&str)` table maps registry-keyed faction names to archetypes; per-archetype `trait_probabilities()` returns a 10-element probability vector that drives `roll_traits(&mut rng)`.
- **`NpcCharacter::roll(npc_id, faction_id, archetype, base_aggression)`** now also rolls personality. Re-derives deterministically from the same inputs on snapshot reload.
- **Goal arbitration personality bias.** `personality_bias_for_objective(traits, objective)` returns a multiplier in roughly `[~0.3, 2.5]` (amplified 2026-05-27 from the original `[0.6, 1.6]` so personality is visible in playtest) applied to the squad-following NPC's `SquadObjective` candidate priority (only — combat / survival / scripted lanes are NOT modulated). The biased priority is clamped to `≤ PRIO_INDIVIDUAL_AGGRO - 1` so a personality-boosted squad objective can never preempt aggro pursuit. `pick_objective` also injects a personality-floor weight of 2 on matching objectives even when the faction archetype zeros them, so a Curious NPC in a faction that never picks Explore still occasionally explores. Per-objective trait nudges (multipliers are 3× the values shown below since 2026-05-27):
  - `Patrol`: disciplined +20%, curious +10%, solitary -20%.
  - `Guard`: disciplined +30%, loyal +20%, curious -30%.
  - `Rest`: cautious +20%, aggressive -30%.
  - `Investigate`: curious +50%, cautious -10%, aggressive -20%.
  - `Explore` / `Wander`: curious +40%, solitary +20%, disciplined -10%.
  - `Relieve` / `Regroup`: loyal +20%, solitary -20%.

**Eight tests** in `tests/personality_traits.rs` cover trait substrate, deterministic re-roll, faction-name → archetype mapping, archetype population skew, per-objective bias direction, blank-traits baseline, and the no-preempt-aggro invariant.

**Universal `NpcRank`** (also 2026-05-08, same branch). S.T.A.L.K.E.R.-style five-tier threat ladder (`Rookie / Experienced / Veteran / Master / Legend`) shared across every faction so the player can read enemy threat at a glance regardless of who they're fighting. Today the rank is a pure function of `NpcStats::combat_competence(self) -> u32` (sum of `accuracy + perception + marksmanship + endurance + luck` — utility stats `strength / leadership / stealth` are intentionally excluded). Threshold floors: 0 / 280 / 350 / 410 / 460. Refreshed on `roll`. **Lived-experience promotion** (kills accumulated, firefights survived → effective stat buffs that promote the NPC over their lifetime) lands when chronicle-driven experience tracking arrives. 6 tests in `tests/npc_rank.rs`.

**Not yet landed** (deferred to follow-up slices):

- `bias_weights: HashMap<GoalKind, f32>` per the §3 data model — the per-NPC custom-multiplier table is still parked. Current personality bias uses the fixed `personality_bias_for_objective` rules above. Drives landed 2026-05-27 as `PersonalityTraits::introduces_drives() -> SmallVec<PersonalityDrive>`; `Hunt` / `Socialize` / `Loot` now have full executors in `tick_npc_goals` and arbiter resolution in `goal_arbitration`. `Bloodsport` is still deferred (needs an arena/sparring concept).
- Backstory templates / `Templated` / `AIGenerated` / `Scripted` authoring tiers — content authoring layer.
- Lived-experience promotion of rank (chronicle-driven kills + firefights survived buffing effective stats).

## 6.7. Names + nationality (2026-05-08)

Multicultural name pool shipped on the same branch. Every faction draws from the same global distribution; the rolled bucket implies the NPC's ethnic background, which downstream drives character-mesh selection.

- **`NationalityBucket`** enum with 8 variants: `American`, `LatinAmerican`, `Slavic`, `EastAsian`, `SouthAsian`, `WestAfrican`, `WesternEuropean`, `MiddleEastern`. Default uniform weights; per-faction overrides reserved for later if any faction needs a distinct demographic mix.
- **`NameRegistry`** resource loads 8 buckets × `~50–60 first` + `~50–60 last` text files at startup (`crates/simn-sim/data/names/{first,last}/{bucket}.txt`, one name per line, `#` comments allowed). Source: hand-curated samples from widely-known public names. Format-compatible with `smashew/NameDatabases` (MIT) for future expansion — drop additional names into the files, no schema change.
- **`NpcCharacter` gains `name: String` and `nationality: NationalityBucket`** fields. The struct loses `Copy` (string field) but keeps `Clone`; one-line `.copied()` → `.cloned()` change in `npc_character_for_test`. Inline-stored on the component (unlike stats / personality which re-derive); names are deterministic from `(npc_id, faction_id, archetype)` so the round-trip across snapshot reload is identical, and this lets code mutate names later (renaming under quest scripts, etc.) without re-rolling everything.
- **`Sim::new_with_seed` registers `NameRegistry::load()`** alongside the other registries. `npc_spawn`, `world::debug::spawn_npc_for_test`, and the snapshot/replay paths read `Res<NameRegistry>` and pass it to `NpcCharacter::roll`.

**Surfaced on `NpcView`** (gdext bridge): `name: String`, `nationality: Option<NationalityBucket>`, `rank: Option<NpcRank>`. Conversions in `simn-godot::sim::conversions` add three keys to `npcs_in_region` dict entries: `name`, `nationality` (snake_case bucket tag), `rank` (label string). Empty strings for legacy NPCs without `NpcCharacter`.

7 tests in `tests/npc_names.rs` cover registry loading, per-bucket non-empty + duplicate-free invariants, `roll` format + determinism + bucket coverage, the spawn-path name+nationality surface, and identity-determinism.

## 6.8. Faction-weighted name distribution (2026-05-08)

Optional per-faction `nationality_weights` map in `factions.toml`. Empty (default) → uniform global multicultural draw. Populated → weighted draw, e.g.:

```toml
[[faction]]
name = "cartel"
# … other fields …
[faction.nationality_weights]
latin_american = 7
american = 2
western_european = 1
slavic = 1
east_asian = 1
south_asian = 1
west_african = 1
middle_eastern = 1
```

- `FactionDef` gains `nationality_weights: HashMap<String, u32>` (string-keyed to keep TOML round-trippable; `NationalityBucket::from_name` parses internally).
- `NameRegistry::roll_for_faction(rng, &weights)` parses the map, drops unrecognized keys silently, falls back to uniform if nothing recognizable remains.
- `NpcCharacter::roll` takes a `&HashMap<String, u32>` (the faction's weights) and threads through to `roll_for_faction`. All four spawn paths (npc_spawn live, debug spawn, snapshot reload, WorldDelta::SpawnNpc replay) read `registry.def(faction_id).nationality_weights` and pass it.
- 3 new tests cover skew direction, empty-map fallback, and typo tolerance.

Two factions ship with skews as examples: `linemen` (US-mainland heavy), `cartel` (Latin-American heavy). The other 14 factions stay uniform; tune later if any need a distinct demographic mix.

## 6.9. Lived-experience rank promotion (2026-05-08)

`NpcCharacter::kills: u16` accumulates over the NPC's lifetime; `effective_competence(self) = combat_competence + kills × 3, capped at 500` buffs the threshold input to `NpcRank::from_competence`. So a 25-kill veteran reliably promotes one tier, a 50-kill veteran lands `Master`, etc.

- `NpcStats::combat_competence` unchanged (still the base 5-stat sum).
- `NpcRank::from_competence(u32)` is the new generic entry point; `from_stats(&NpcStats)` becomes a thin wrapper for the fresh-roll case.
- `NpcCharacter::record_kill(&mut self)` increments `kills` (saturating) and re-derives `rank` from the new effective competence. Idempotent for the rank result; pure on `(stats, kills)`.
- **`PendingKillCredits` resource** + **`apply_kill_credits` system**: split because npc_combat can't mutate one NPC's `NpcCharacter` while iterating another (bevy query aliasing). `npc_combat` pushes `kill_credits.credit(killer_id)` when its damage application brings `vital_min` to zero; `apply_kill_credits` runs right after in the schedule, drains the resource, and applies the credits via a `Query<(&Npc, &mut NpcCharacter)>`.

Lived-experience kills aren't yet persisted across snapshot reload — the kill counter resets to zero on re-roll. Persistence lands when chronicle-driven identity tracking arrives. For now, ranks effectively re-derive from base stats on reload, which is a known limitation the chronicle work will address.

5 tests in `tests/lived_experience.rs` cover the increment + rank-promotion path, the cap, the purity invariant, and starting-state assumptions.

## 6.10. GoalKind expansion + personality-introduced goals (2026-05-08)

Four new `GoalKind` variants — `Hunt`, `Socialize`, `Loot`, `Bloodsport` — that the personality bias system contributes as **weak candidates** in goal arbitration. Per `npc-character-authoring-plan.md` §5: personality nominates these even when no other source does, so an NPC's "default" behavior reflects who they are when no urgent task is in front of them.

- `PersonalityTraits::introduces_goals(&self) -> Vec<GoalKind>` — trait → goal mapping:
  - `curious` → `Hunt`
  - `greedy` → `Loot`
  - `bloodthirsty` → `Bloodsport`
  - `social` → `Socialize`
- `goal_arbitration` consumes the introduced list, pushing each as a `GoalSource::PersonalityBias` candidate at `PRIO_PERSONALITY_BIAS = 60`. Below squad objective (80) and combat (150+), above idle (0). `PRIO_PERSONALITY_BIAS` was already declared as `#[allow(dead_code)]` and is now wired.
- **Executor placeholders.** `tick_npc_goals` falls each new variant through to the `SoloIdleFsm` branch (wander). The variants are substrate for the arbiter today; when the targeting infra lands (ecosystem fauna for Hunt, campfire graph for Socialize, corpse containers for Loot, arena concept for Bloodsport), each variant gets its own executor branch. Variant payloads (target ids, container ids) extend the enum in those follow-up PRs.

6 new tests in `tests/personality_traits.rs` cover the trait → goal mapping, the empty-traits case, and the multi-trait expansion.

**Update 2026-05-27 (NPC realism overhaul):** The trait→goal mapping was promoted to `introduces_drives(&self) -> SmallVec<PersonalityDrive>` returning a `PersonalityDrive` enum (`Hunt | Socialize | Loot | Bloodsport`). `goal_arbitration` resolves each drive into a fully-targeted `GoalKind` using sim context:
- `Hunt` → nearest unowned `Stash` / `Lookout` / `Workbench` activity point.
- `Loot` → nearest hostile-faction corpse container via the new `CorpseIndex` resource (Warm/Friendly factions are skipped — taboo, not greed).
- `Socialize` → group centroid (gated to Rest-arrived squads), at `PRIO_SQUAD_OBJECTIVE + 5` (85) so social NPCs visibly break formation into a face-inward ring.
- `Bloodsport` → still deferred; needs an arena/sparring concept that doesn't exist yet.

`GoalKind::Hunt` / `Loot` / `Socialize` / `SeekMedical` gained payloads (`target_pos` + optional context id). Real executors in `tick_npc_goals` move the NPC toward the target with `Bushwhacker` style. The `introduces_goals` tests in `personality_traits.rs` were renamed to `introduces_drives` tests.

## 6.11. Per-faction archetype in TOML + debug-label name/rank (2026-05-08)

Refactor: `PersonalityArchetype` is now declared per-faction in `factions.toml` instead of derived from a hardcoded `from_faction_name` lookup. Each faction adds an `archetype = "disciplined" | "aggressive" | "greedy" | "curious" | "reverent" | "default"` field. Missing/unknown values fall back to the legacy name-derived default so existing TOML keeps working through the migration.

- `PersonalityArchetype` derives `Serialize / Deserialize` with `rename_all = "snake_case"`. `Default` variant is `#[default]`.
- `FactionDef::archetype: PersonalityArchetype` is the new field. The TOML loader pulls it from the entry; missing → `from_faction_name(&name)`.
- All four spawn paths read `registry.def(faction_id).archetype` instead of recomputing from the name.
- All 16 factions in the canonical roster now declare their archetype explicitly. The hardcoded `from_faction_name` fallback survives for mod overlays / future factions that omit the field.

Debug-label surface: `humanoid_dummy.gd` now renders `Name (Rank) · faction · goal · hp/max` instead of `#id faction · goal · hp/max`. Falls back to `#id` when name is empty (legacy NPCs without `NpcCharacter`). The rank parenthetical uses the `NpcRank::label()` string surfaced via `npc_view_to_dict`.

## 7. Dependencies

- **Blocks:** [`goal-arbitration-plan.md`](goal-arbitration-plan.md) personality bias (rerank + introduce), [`physical-combat-plan.md`](physical-combat-plan.md) accuracy / aim cone, all per-NPC narrative content.
- **Blocked by:** nothing structurally — can land in Stage 2 (alongside or just after squad blackboard / event bus). Optional AI-gen integration is Stage 4.

## 8. Open questions

- **Procedural backstory granularity.** How rich is "Generic" tier? A name + faction + rank only, or always at least 1-2 notable events? Lean: always notable events from a small template library; the variety doesn't cost much storage.
- **Name bank scope.** Per-faction name banks (PWA names sound Polish, Wanderers sound mixed-Slavic, Looters more Western). How big? Tentative: 200 first names + 200 last names per faction = ~16 KB total; combinatorial space far exceeds NPC count.
- **Rank progression in offline tier.** Does a squad leader's rank advance over time as they accumulate kills / survive? Stage 4 territory but worth flagging here so chronicle persistence design accommodates it.
- **AI-gen integration cadence.** World-init only? Periodic refresh as new noteworthy NPCs emerge? Tentative: world-init pass for the initial population, then async background passes when new NPCs hit a "noteworthiness" threshold (3+ kills, survived 5+ firefights, became squad leader).
- **Trait extensibility for mods.** Personality traits as `bool` fields are fixed at compile time. Mods that want to add new traits would need a `Custom(String) -> f32` extension. Couples with [`squad-blackboard-plan.md`](squad-blackboard-plan.md) modding API decision.
- **Storage budget.** With 1000+ NPCs across the world, each carrying name + backstory + traits + stats = ~500 bytes per character (assuming generated text capped at 200 chars). 500 KB total. Trivial; non-blocking.

## 9. Out of scope

- Player character data (separate system).
- Faction-level decisions (sim-brain walkthrough).
- Quest authoring (scripted-quests walkthrough).
- Dialog content (encounter-dispatcher dialog runner).
- Visual character variety (modular outfits per [`character-rendering-plan.md`](character-rendering-plan.md) — feeds off this plan's `rank` + `faction` to pick mesh assets).
