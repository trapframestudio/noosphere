# Damage & Healing

This chapter is the player-facing contract for how a character takes,
carries, and heals damage. It covers the mechanics that ship in
**survival/crafting plan §1 (stats foundation)** and **§2 (wounds +
bleed)**. Tuning numbers below are calibrated for "feel" today and
expected to drift with playtest.

## The health systems

A character's wellbeing is tracked across these parallel systems -
nine entries today, more as the survival/crafting plan rolls out.
Every one is server-authoritative, persisted, and survives reload.

| System | Range | Source of truth | Restored via |
|---|---|---|---|
| Body-part HP | 0..100 per part, 6 parts | `BodyParts` | `heal_part` / wound healing |
| Aggregate HP (death gate) | 0..100 | mirrored from `min(head, torso)` | derived |
| Survival meters | 0..100 (hunger, thirst, fatigue) | `SurvivalStats` | `consume`, `eat`, `drink` |
| Wounds | list of discrete instances | `Wounds` Vec | bandage / wound-pack / tourniquet / stitch + time |
| Pain | 0..100 (derived) | `Pain` | painkiller / morphine; clears as wounds heal |
| Radiation | 0..100 | `Contamination.radiation` | passive decay + anti-rad |
| Toxicity | 0..100 | `Contamination.toxicity` | passive decay + anti-tox |
| Active effects | list | `ActiveEffects` | timed; effects retire automatically |
| Drug tolerance | per-drug 0..100 | `DrugTolerance` | passive decay (~25/in-world hour) |

The four are **decoupled**: bandaging a wound stops bleeding but
doesn't restore the HP you've already lost. Healing an HP pool doesn't
clear an open wound. Eating a ration restores hunger but doesn't heal
the leg you just got shot in. Players have to handle each layer.

## Body parts (Step 1)

Six body parts, each with an independent 0–100 HP pool:

```
head, torso, left_arm, right_arm, left_leg, right_leg
```

- **Head or torso at 0 → death.** Aggregate `Health.current` mirrors
  `min(head, torso)` so the death gate behaves like any other HP pool
  for callers that don't care about the breakdown.
- **Limb at 0 → disabled.** `BodyParts::limb_disabled(part)` returns
  true. The movement and aim systems will read this in a later step;
  for now the flag is exposed but no system consumes it.
- **Per-limb `LimbState`.** Sibling component `LimbStates` tracks
  `Intact / Wounded / Severed` per body part alongside the numeric
  HP. The wound pipeline flips a part to `Wounded` on wound spawn and
  back to `Intact` once the last open wound resolves; `Severed` is
  permanent. State and HP answer different questions: HP is "how much
  is left in the pool", state is "is the limb structurally there at
  all". Severed parts disable that limb regardless of HP. Production
  sever (caliber-driven `WoundKind::Sever`) lands with the projectile
  + weapons work; the current path is `Sim::sever_limb_for_test`.
- **No "max HP buffer" yet.** All parts share `DEFAULT_MAX = 100`.
  Per-part max scaling (head fragile, torso sturdy) is a tuning lever
  for later.

`apply_damage_to_part(steam_id, part, amount)` is the canonical entry
point. The legacy `apply_damage(steam_id, amount)` routes to the torso
for back-compat with non-located damage (falls, environmental).

## Survival meters (Step 1)

Three meters in `[0, 100]` where 100 is full and 0 is depleted.

| Meter | Drain rate (per in-world second) | Time to empty (in-game) |
|---|---|---|
| Hunger | 100 / 2400 ≈ 0.0417 | ~8 hours |
| Thirst | 100 / 1800 ≈ 0.0556 | ~6 hours |
| Fatigue | 100 / 4800 ≈ 0.0208 | ~12 hours (passive) |

Drain is uniform per tick. Sprinting / combat / heat will add bursts on
top once those layers exist.

### Degraded function thresholds

Per spec §3.3: stats below the line **degrade function**, not insta-kill.

| Trigger | Effect |
|---|---|
| Hunger < 30 | Stamina regen halved |
| Thirst < 50 | Stamina regen halved |
| Hunger < 10 | Slow torso HP drain (0.25 hp/in-world-sec) |
| Thirst < 20 | Slow torso HP drain (0.25 hp/in-world-sec) |

Both HP-drain triggers stack additively. Even with both at zero, you
have **minutes** to find food/water - the survival layer never kills in
under a minute on its own.

### Restoring meters

`consume(steam_id, hunger_delta, thirst_delta, fatigue_delta)` adds and
clamps to `[0, 100]`. Items (food, water, rest) will hook here in
Step 3. Today the only consumer is dev tooling.

## Wounds and bleeding (Step 2)

Damage above a threshold doesn't just lower a part's HP - it also
**spawns a persistent wound** that bleeds over time. The wound is a
discrete object that persists across saves, has its own treatment
state, and despawns only after appropriate care.

### Wound spawning

`apply_damage_to_part` evaluates the damage amount and may spawn a
`Bleed` wound on the same part:

| Damage amount | Result |
|---|---|
| < 10 | HP loss only (a bruise) |
| 10..25 | HP loss + light Bleed (severity 1–3, scales with damage) |
| ≥ 25 | HP loss + heavy Bleed (severity 4–5, scales with damage) |

Multiple wounds per body part are allowed - repeated hits stack.

### Bleed rate

Each `Untreated` Bleed wound drains its body part's HP at:

```
rate = severity × 0.5 hp / in-world second
```

A sev-1 wound bleeds at 0.5 hp/sec; a sev-5 wound at 2.5 hp/sec. Sums
across all active untreated bleeds. `Bandaged`, `Tourniquet`, and
`Healed` wounds contribute zero.

**NPC endurance damps the rate.** NPCs scale their bleed rate by
`bleed_rate_multiplier(endurance)` — linear inverse in `[1.3, 0.7]`
over the endurance stat `0..=100`, 1.0× at 50. A frail conscript at
endurance 0 bleeds 30% faster than the listed rates; a tough veteran
at endurance 100 bleeds 30% slower. Players don't carry `NpcCharacter`,
so the player numbers above stay literal.

### Treatment items + protocol

The Step 3 wound-treatment tree implements GAMMA-feel sequencing while
keeping it readable for intermediate players.

| Tool | Source state | Result | Notes |
|---|---|---|---|
| Antiseptic | Untreated | Disinfected | Sterilises; prevents infection. Always-safe step. |
| Bandage | Untreated **or** Disinfected (light bleed only, sev ≤ 3) | Bandaged | Skipping disinfect leaves the wound at infection risk. |
| Wound pack | Untreated/Disinfected (heavy bleed, sev ≥ 4) | WoundPacked | No-cost alternative to tourniquet; no necrosis timer. |
| Tourniquet | Untreated/Disinfected (any severity) | Tourniquet | Stops bleed immediately, **starts the necrosis timer**. |
| Stitch (suture kit) | Bandaged / WoundPacked / Tourniquet | Stitched | Halves the heal time; closes a tourniqueted wound. |
| Antibiotics | Any infected wound | clears `infected` flag | Takes ~10 in-world min of effect to fully clear. |

**Bandage on heavy bleed errors.** A basic bandage isn't enough for
arterial-grade bleeding. Use a tourniquet (emergency, with cost) or a
wound pack (no cost, but requires the item).

**Tourniquet starts the necrosis timer.** Bleed stops immediately, but:

- After **1 in-world hour** (5 real min), the tourniqueted limb begins
  losing HP at 0.05 hp/in-world-second.
- After **2 in-world hours**, the rate quadruples to 0.2 hp/sec.
- Removing the tourniquet (without stitching) stops necrosis but
  resumes bleeding.
- Stitching the tourniqueted wound closes both: necrosis stops AND the
  wound is on the heal track. This is the canonical heavy-bleed
  resolution.

**Wound pack** is the gentler alternative for heavy bleed - same
"stops bleed" effect without the necrosis cost, but the item itself
will be a craftable that's harder to find than a basic bandage (Step 4
inventory will reflect this).

### Infection

Untreated wounds left alone for **2 in-world hours** (~10 real min)
become **infected**. Infection drains 0.05 hp/in-world-second on the
wound's body part - slow, recoverable, but persistent. The wound's
heal timer pauses while infected: bandaging an infected wound stops
the bleed but the wound won't transition to Healed until the infection
is cleared.

**Avoiding infection:**

- Disinfect early. The `Disinfected` state never trips the trigger.
- Apply a bandage or tourniquet within the 2-hour window. Only `Untreated`
  wounds infect.
- Apply antibiotics if you missed the window (or if the field hospital
  was the wound's first stop anyway).

**Antibiotics** are an active effect (like a drug - see
[Drugs & Effects](drugs-and-effects.md)). One dose clears infection on
*every* infected wound after 10 in-world minutes of being active. The
wound returns to its prior treatment state, and the heal timer
resumes from now.

### Pain

`Pain` is a derived 0–100 stat computed each tick:

```
pain = sum_of (severity × 5 × treatment_weight) − painkiller_relief
```

Treatment weights: Untreated/Disinfected = 1.0, Bandaged = 0.5,
Stitched/Tourniquet/WoundPacked = 0.25, Healed = 0.

A single sev-5 untreated wound = 25 pain. Three of them = 75 pain.

**Pain ≥ 50 halves stamina regen.** That's the practical "ouch" gate;
above it, sprinting and recovery feel sluggish. Painkillers (-25) and
morphine (-75) suppress this directly - see drugs.

### Healing timeline (current)

```
hit (≥ 10 damage)
   │
   ├─ HP loss applied
   │
   └─ wound spawned (Untreated) ──── bleeds @ severity × 0.5 hp/sec
                                      │
                       ┌──────────────┴────────────────────┐
              [light: bandage]                       [heavy: tourniquet OR wound pack]
                       │                                    │
                  Bandaged ◀─────[disinfect first]      Tourniquet (starts necrosis timer)
                       │                          │       OR WoundPacked (no necrosis)
                       │ [optional: stitch]       │       │
                       ▼                          │       │ [stitch within ~1hr]
                   Stitched ◀────────────────────┴───────┘
                       │
                  [time: ~5 real min bandaged, ~2.5 stitched]
                       │
                    Healed
                       │
                  despawned

  ANY untreated > 2hr → infected → HP drain + heal paused
                                   ──[antibiotics × 10min]──> cleared
```

## What this isn't (yet)

These belong to later plan steps and are **deliberately absent** from
the model right now:

- **Wound kinds beyond Bleed** - Fracture / Burn / Puncture / Laceration
  arrive in a later focused step. The broader wound classification
  (`WoundSmall` / `WoundLarge` / `SlugHole` / `BuckshotScatter` /
  `Sever` / `HeadGib`), caliber-driven resolution, and limb severing
  are designed in `../planning/dismemberment-plan.md` and extend - rather than
  replace - this pipeline.
- **Limb severing / dismemberment** - `BodyParts` is planned to extend
  from `f32` per part to `LimbHp { current, max, state: LimbState }`,
  where `LimbState ∈ { Intact, Wounded, Severed }`. Severed limbs
  can't be healed and are gone for good; visual dismemberment (shader
  mesh discard, severed-limb prop spawn, stump cap, blood FX) drives
  off gameplay-critical `DismemberEvent` replication. See
  `../planning/dismemberment-plan.md`.
- **Reactive hit reactions** - planned client-side `SkeletonModifier3D`
  stack for transient IK goals on gunshot / explosion hits. Cosmetic,
  caliber-energy-driven, no authoring cost per hit type. See
  `../planning/dismemberment-plan.md`.
- **Aim shake / screen effects from pain** - visual only; the data is
  exposed via `view.pain`, but no aim system reads it yet.
- **Tourniquet limb-function penalty (-80%)** - the spec calls for it
  but movement/aim systems that would consume the flag don't exist
  yet. Necrosis cost is implemented; functional cost lands when those
  layers do.
- **Per-use item consumption for treatment** - Step 4 introduced the
  inventory layer (see [Inventory & Items](inventory.md)), and
  bandages / tourniquets / antibiotics / disinfectant / stitches /
  wound packs all exist as `items.toml` entries. `consume_slot`
  routes them to the treatment APIs and decrements on success. The
  underlying `apply_*` methods are still callable directly (and still
  don't require an item) - a debug convenience. Step 5's inventory UI
  will route every player-facing treatment through slots, making the
  item the only normal path.
- **Coop revive** - single-player adrenaline-revive is in. The full
  §4.6 reviver-with-kit flow is Step 8.

## NPC scope

NPCs carry the same per-part `BodyParts` pools as players (head /
torso / left_arm / right_arm / left_leg / right_leg, each clamped
`[0, 100]`). Shooting an NPC in the head drains the head pool; head
or torso at 0 fires `npc_death_check` on the next tick. Weapon
raycasts from the player side route through `SimHost.damage_npc_part`
and resolve the specific part from collider metadata on the
humanoid dummy; the built-in `npc_combat` probabilistic NPC-vs-NPC
model still lands on torso only. The end-to-end path is walked in
[`../walkthroughs/humanoids.md`](../walkthroughs/humanoids.md).

**Wound spawning and per-tick processing are live on NPCs.** Above-
threshold damage through `SimHost.damage_npc_part` spawns a Bleed
wound and journals a `NpcWoundAdded` delta (mirrors the player path).
NPC-vs-NPC combat (`npc_combat`) also spawns Bleed wounds when the
probabilistic hit model lands an above-threshold torso shot, but
those wounds are **ephemeral** - not journaled, recovered from the
next snapshot (same trade-off as the torso HP drain already on that
path). `apply_bleed_damage`, `tick_infection`, `age_and_heal_wounds`,
and `tick_necrosis` all iterate every humanoid (players + NPCs), so
NPC wounds bleed and can age into infection the same way players'
do.

**Treatment API is live on NPCs.** Seven mirrored entry points -
`apply_bandage_npc` / `apply_tourniquet_npc` / `remove_tourniquet_npc`
/ `apply_disinfectant_npc` / `apply_stitch_npc` / `apply_wound_pack_npc`
/ `apply_antibiotics_npc` - each journal a parallel
`NpcWoundTreatmentChanged` (or `NpcEffectApplied` for antibiotics)
delta. `npc_view_to_dict` surfaces the full wound array on
`npcs_in_region` entries so debug labels and future medic UIs can
inspect NPC wound state directly.

**NPC self-heal + squad-medic is live.** The `npc_treat_wounds`
system (1 Hz, scheduled after `age_and_heal_wounds` and before
`tick_pain`) walks every online NPC with an active untreated
bleed and tries to apply an appropriate medical item:

1. **Self-heal first.** Light bleed (severity ≤ 3) consumes a
   `bandage` from the NPC's own inventory; heavy bleed (≥ 4)
   prefers a `wound_pack` (no necrosis cost) and falls back to
   a `combat_tourniquet` (stops bleed, starts the necrosis
   timer) if no pack is on hand.
2. **Squad-medic fallback.** If the wounded NPC has nothing in
   their own pockets, the system scans same-group teammates
   within **10 m** for one carrying the right item; the mate's
   inventory is debited and the treatment is applied to the
   wounded NPC.

A per-applicator cooldown (3 s) throttles same-tick flurries -
multi-wound NPCs still stabilise within ~10 s, they just don't
all bandage at once. **Limit worth flagging:** the medic side
only fires when a healthy squad-mate is *already* standing
within 10 m. The system doesn't navigate a remote medic in -
that's a planned `goal_arbitration::HealAlly` candidate. Most
squads sit inside that radius via `formation_offset`, so the
common case is covered. Player-to-NPC medical still rides on a
later UI slice. Related deferred work lives under the tactical
AI slice at
[`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md).

## Dev controls (current)

Open the in-game debug overlay (`` ` ``) for the triage view (vitals,
wounds, active effects, drug tolerance):

| Key | Action |
|---|---|
| B | Apply bandage to torso |
| T | Apply tourniquet to torso |
| 1 | Take painkiller |
| 2 | Take morphine |
| 3 | Take adrenaline |
| 4 | Take stim cocktail |

Per-part bindings + a polished triage panel scene + per-drug hotbar
arrive with the workbench/crafting UI in Step 5+. Anti-rad / anti-tox
/ antibiotics / disinfect / stitch / wound-pack are exposed as
`#[func]` calls but lack dedicated keybinds - call them from a script
or future UI.

## API reference

Engine-agnostic (call from `simn-sim` or any consumer):

```rust
// Damage / HP
sim.apply_damage_to_part(steam_id, part: BodyPart, amount: f32) -> Result<()>
sim.heal_part(steam_id, part: BodyPart, amount: f32) -> Result<()>

// Survival meters
sim.set_survival_stat(steam_id, stat: SurvivalStat, value: f32) -> Result<()>
sim.consume(steam_id, hunger_d, thirst_d, fatigue_d) -> Result<()>
sim.eat(steam_id, kind: FoodKind) -> Result<()>
sim.drink(steam_id, kind: WaterKind) -> Result<()>

// Wound treatment
sim.apply_disinfectant(steam_id, part: BodyPart) -> Result<()>
sim.apply_bandage(steam_id, part: BodyPart) -> Result<()>
sim.apply_wound_pack(steam_id, part: BodyPart) -> Result<()>
sim.apply_tourniquet(steam_id, part: BodyPart) -> Result<()>
sim.remove_tourniquet(steam_id, part: BodyPart) -> Result<()>
sim.apply_stitch(steam_id, part: BodyPart) -> Result<()>
sim.apply_antibiotics(steam_id) -> Result<()>
sim.wounds_on_player(steam_id) -> Vec<(WoundId, Wound)>

// Drugs + contamination
sim.apply_drug(steam_id, drug: DrugKind) -> Result<DrugOutcome>
sim.set_radiation(steam_id, value: f32) -> Result<()>
sim.set_toxicity(steam_id, value: f32) -> Result<()>
sim.add_radiation(steam_id, delta: f32) -> Result<()>
sim.add_toxicity(steam_id, delta: f32) -> Result<()>
```

GDScript bridge (call from any scene with a `SimHost` reference):

```gdscript
sim.damage_part(sid, "torso", 30.0)
sim.heal_part(sid, "left_leg", 50.0)
sim.consume_food(sid, 30.0, 0.0, 0.0)

# Preferred: consume items through the inventory wrapper (Step 4+).
# Grants for testing:
sim.grant_item(sid, "bandage", 1)
sim.grant_item(sid, "painkiller", 1)
# Apply: body_part is only read for wound-treatment items.
sim.consume_slot(sid, 0, "torso")
sim.consume_slot(sid, 0, "")             # food / drug / antibiotics

# Direct calls still work (used by inventory under the hood):
sim.eat(sid, "cooked_meat")
sim.drink(sid, "clean_water")
sim.apply_disinfectant(sid, "torso")
sim.apply_bandage(sid, "torso")
sim.apply_wound_pack(sid, "left_arm")
sim.apply_tourniquet(sid, "left_arm")
sim.remove_tourniquet(sid, "left_arm")
sim.apply_stitch(sid, "torso")
sim.apply_antibiotics(sid)
sim.apply_drug(sid, "painkiller")  # → bool, false on overdose
sim.set_radiation(sid, 0.0)
sim.set_toxicity(sid, 0.0)
var view := sim.player_state(sid)
var wounds: Array = view["wounds"]            # each has .infected
var effects: Array = view["active_effects"]   # each has .kind, .applied_tick, .duration_ticks
var pain: float = view["pain"]
var rad: float = view["radiation"]
var tox: float = view["toxicity"]
var tol: Dictionary = view["drug_tolerance"]
```

## See also

- [Drugs & Effects](drugs-and-effects.md) - drug profiles, tolerance,
  overdose, withdrawal, adrenaline revive.
- [Food & Water](food-and-water.md) - consumable profiles and the
  rad/tox cost model.
- [Inventory & Items](inventory.md) - how treatment items get into
  pockets; cooking, salvage, perishables.
- `../planning/survival-and-crafting-plan.md` - design source for §1 + §2 +
  §3 + the parts of §6 pulled forward into Step 3+meds.
- `../walkthroughs/sim.md` - how the data model + persistence are
  wired in `simn-sim`.
- `docs/book/src/architecture/crate-guide.md` - quick API surface for
  `simn-sim`.
