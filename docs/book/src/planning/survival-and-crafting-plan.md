# Survival, Medical, Food, Junk & Crafting - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-15
**Scope:** GAMMA/Anomaly-depth survival and crafting systems with deliberate UX improvements. Owns medical, food/water, fatigue, body-part health, junk/salvage, recipes, and workbenches. Cross-references `weapons-plan.md` (parts, ammo crafting) and `loot-and-economy-plan.md` (items in circulation).

This is a living design doc. Captures decisions and open questions; not a spec.

---

## 1. Guiding Principles

- **GAMMA depth, not GAMMA friction.** We want the same richness of medical protocols, food economy, junk salvage, and crafting trees. We do not want the inventory tetris, opaque recipes, or deep-menu stat-reading that drives non-modders away.
- **Legibility is a feature, not a hint.** If something will kill the player, tell them clearly. If a recipe needs X, show X and where to get X. No coy tooltips.
- **Meaningful choice, not micromanagement.** Hunger/thirst/fatigue matter, but players shouldn't be eating every five minutes. Slow tick rates, degraded function before death, generous mid-tier options.
- **Every mechanic is data-driven.** Wound types, drugs, recipes, food entries, junk categories - all TOML. Modders extend without touching Rust.
- **Coop-aware.** All state is server-authoritative. Revive mechanics, shared crafting queues, and shared consumption all need to work for up to 12 concurrent players without weird edge cases.

---

## 2. Crate Boundaries

| Concern | Crate |
|---|---|
| Stats (health, hunger, thirst, fatigue, radiation, toxicity) | `simn-sim` |
| Wound instances on body parts | `simn-sim` |
| Drug/effect state machine (duration, stacks, withdrawal) | `simn-sim` |
| Item definitions, recipes, workbench tiers | `simn-sim` |
| Crafting queues + outcomes | `simn-sim` |
| Medical wheel, inventory UI, crafting browser | `godot/scripts` (GDScript) |
| Hit-location resolution from projectile impact | `simn-sim` (math) + `simn-godot` (raycast bridge) |

Hard rule: `simn-sim` stays engine-agnostic.

---

## 3. Survival Stats Model

### 3.1 Top-level stats (per character)

- **Body-part HP:** head, torso, left_arm, right_arm, left_leg, right_leg. Each tracked independently. Head/torso at 0 → death; limbs at 0 → disabled (can't aim, can't sprint).
- **Overall vitality:** derived from body parts + hydration + nutrition + fatigue. Drives stamina cap and regen.
- **Hunger, Thirst, Fatigue:** 0–100 bars, tick down over in-game time at tunable rates.
- **Radiation, Toxicity:** 0–100 bars, tick up on exposure, tick down via treatment. High values cause escalating damage over time.
- **Bleeding rate:** summed from active bleed wounds across body parts; HP drain per second.
- **Pain:** derived from active wounds; affects aim steadiness and screen effects.
- **Morale:** soft stat influencing stamina recovery and companion NPC behavior. Low morale from hunger/cold/recent deaths; restored by rest/food/alcohol.

### 3.2 Tick rates (illustrative, for feel - tune in playtest)

- Hunger/thirst drain a full bar over ~8 in-game hours of active play.
- Fatigue drains faster when sprinting, sleeps heal it.
- Radiation decays on its own slowly; drugs/shards accelerate.

### 3.3 Degraded function, not instant death

All stats below 100% impose curves, not cliffs:
- Hunger < 30: stamina regen halved. Hunger < 10: slow HP drain. Hunger 0: faster drain, still minutes to die.
- Thirst: sharper curves than hunger (water matters more, faster).
- Fatigue < 20: aim shake, slower reload. Fatigue 0: you still function, but badly.

Nothing should ever kill the player in under a minute from a survival stat alone. Combat and wounds are different.

---

## 4. Medical System

### 4.1 Wound instances

A wound is a discrete object attached to a body part:

```
Wound {
  body_part: TorsoFront | LeftArm | ...
  kind: Bleed(severity) | Fracture | Burn(severity) | Puncture | Laceration
  severity: 1..5
  age_ticks: u64          // for infection escalation
  infected: bool
  treatment_state: Untreated | StoppedBleeding | Disinfected | Bandaged | Stitched | Healing
}
```

Multiple wounds can coexist on the same body part. Each contributes bleeding, pain, and reduced HP until treated and healed.

### 4.2 Treatment as a protocol, not a one-tap heal

Anomaly/GAMMA's depth comes from *sequencing* - you don't just press bandage and win. Each wound type has a treatment sequence:

**Heavy bleed (arterial, limb):**
1. **Tourniquet** (emergency, stops bleeding, but limb function -80%, must be removed within N minutes or necrosis)
2. **Stop bleeding** (wound pack or pressure) - removes the tourniquet need
3. **Disinfect** (antiseptic) - prevents infection
4. **Bandage** (bandage item) - wound is stable
5. **Stitch/surgical** (field surgery kit, workbench preferred) - wound begins healing
6. Over time, wound heals naturally, or faster with antibiotics if infected

**Fracture:**
1. **Splint** - restores limb function partially; requires clean splint + bandage
2. **Immobilization** - rest to heal, or medical bay for faster

**Burn:**
1. **Cool + clean** (water + disinfectant)
2. **Burn salve** (specialized med)
3. **Bandage**

**Puncture/laceration:**
Simpler: disinfect → bandage → natural heal.

Not every wound needs every step. UI surfaces the *next required step* per wound explicitly. No guessing.

### 4.3 Medical items (starter list)

- **Bandage** (basic consumable, resolves light bleed + wraps wound)
- **Combat tourniquet** (emergency bleed stop, imposes limb penalty)
- **Wound pack / pressure dressing** (stops heavy bleed without tourniquet cost)
- **Antiseptic swab** (disinfect step)
- **Suture kit / field surgery kit** (stitch step, reduces heal time)
- **Splint** (fracture treatment)
- **Burn salve**
- **Antibiotics** (treats infection over time)
- **Painkillers** (reduces pain; overuse → dependency)
- **Morphine / strong painkiller** (combat-grade, heavy pain reduction; strong addiction risk)
- **Adrenaline / stimpack** (emergency revive-from-bleeding-out window; severe crash after)
- **Anti-rad drug** (reduces radiation over time)
- **Anti-tox drug** (reduces toxicity)
- **Stim cocktail** (boosts stamina/endurance temporarily)

### 4.4 Drug effects: buffs with real costs

Every drug with a "positive" effect has a cost downstream. This is the GAMMA feel:

- **Painkillers:** reduces pain (improves aim) → dependency counter; withdrawal if discontinued → reverse effect for a window
- **Stim cocktail:** +stamina cap, +regen → fatigue rebound after duration; heart strain if stacked
- **Morphine:** huge pain relief → slow heart rate, slow reaction, addiction
- **Adrenaline:** brings you back from bleed-out once → crash: weakness, nausea, reduced HP cap briefly
- **Anti-rad:** reduces rad → minor toxicity increase (trade one poison for another at high doses)

### 4.5 Dependency & overdose

- Each drug has a `tolerance` counter that rises with use, decays with time.
- At high tolerance: effect reduced, withdrawal triggers on abstention.
- Exceeding drug-specific thresholds in a short window → overdose effects (damage, temporary stat floors).

Keeps the "combat cocktail" loop honest. You *can* stack mid-fight; you pay for it afterward.

### 4.6 Revive in coop

Downed player has a bleed-out timer. Teammate can:
- **Field revive:** adrenaline + bandage sequence, ~8 seconds, vulnerable to interrupt. Restores to ~30% HP with pain + weakness.
- **Full stabilize:** field surgery kit, ~30 seconds, better post-state.

Revive is gated by items the reviver has, not a generic "press F." Gives medical items coop weight.

---

## 5. Food, Water, Sleep

### 5.1 Food

Categories:
- **Preserved** (canned, tushonka-style): long shelf life, mid nutrition, no rad/tox unless near fault
- **Fresh** (bread, cheese, chocolate bar): faster spoil, better morale
- **Raw mutant meat:** inedible raw (food poisoning + rad); edible after cooking
- **Cooked mutant meat:** good nutrition, mutant-type-specific rad/tox profile (some mutants are poisonous even cooked)
- **Contaminated food:** Valley-exposed items, look normal but tick rad/tox on consumption - reading the source (where you found it) is a real skill
- **Field rations** (military, high quality): valuable trade goods

Each food has:
- hunger_restore
- thirst_effect (salty food can raise thirst)
- rad_contamination (if any)
- tox_contamination (if any)
- morale_bonus
- time_to_eat
- perishable_ticks (0 = non-perishable)

### 5.2 Water

- **Dirty water:** free from any water source → tox/rad hit unless purified
- **Clean water:** purified or bottled, safe
- **Purification tablets:** craftable; convert dirty → clean
- **Energy drinks / alcohol:** specific effects (caffeine → fatigue relief, alcohol → morale + reduces rad absorption briefly, classic vodka mechanic; excess alcohol → debuffs, dependency)

### 5.3 Cooking

- **Field cookable** at any campfire with the right cookware (pot, skewer).
- Raw → cooked is a recipe, requires fuel (wood, fuel canister).
- Cooking in the open is visible/audible to nearby NPCs; signal risk.

### 5.4 Sleep/rest

- Safe locations (bed, bedroll in secure area) allow **sleep**: advances in-game time, restores fatigue and some HP, gives optional dream/lore events.
- Sleeping in unsafe locations = risk (ambush interrupt, partial rest).
- Over-sleeping past need → diminishing returns; no exploit by sleeping 20 hours straight.

---

## 6. Junk & Salvage

### 6.1 Everything decomposes

Every breakable item declares its salvage output:

```
Item: radio_broken
  weight: 1.2
  volume: 0.004
  salvage:
    tool_required: field_toolkit
    time: 15s
    output:
      - { item: wire_bundle, count: 2..4 }
      - { item: capacitor, count: 0..2 }
      - { item: metal_scrap, count: 1..3 }
      - { item: plastic_scrap, count: 1..2 }
```

### 6.2 Component categories

Keep a flat but broad component vocabulary so recipes compose cleanly:
- **Metals:** scrap, steel plate, aluminum, precision parts, springs, screws
- **Electronics:** wire, capacitor, circuit fragment, battery cell, optical lens
- **Textiles:** cloth scrap, canvas, leather, cordage
- **Chemicals:** solvent, adhesive, gunpowder, primer compound, alcohol
- **Medical:** clean bandage stock, surgical thread, chemical reagents
- **Gun-specific:** ammo brass, ammo lead, barrel stock, spring stock
- **Shard-related** (late game): reagent dust, fault crystal, contained flux

### 6.3 Salvage vs. trade

Junk has two exits:
- **Salvage for components.** Good if you need the parts.
- **Sell to specific trader.** Each trader values specific junk categories differently (scavenger buys metals; tech trader buys electronics; medic buys medical junk).

UI must show both values at-a-glance so players can decide in context.

---

## 7. Crafting

### 7.1 Stations, tool tiers, specialty kits

Three orthogonal axes. A recipe may demand any or all.

**Crafting station** - the fixed workspace in the world.

- **`campfire`** - cooking, purification.
- **`basic_bench`** - bandages, common consumables, light repair.
- **`advanced_bench`** - weapon part *machining*, ammo reloading prep,
  mid-tier drugs, attachment crafting.
- **`expert_bench`** - shard containment crafting, high-end repair,
  rare outputs.

Benches are **cumulative**: an Advanced bench satisfies a recipe that
wants `basic_bench`; Expert satisfies both. Campfire is separate -
benches don't substitute for a campfire and vice versa.

**Tool tier** - GAMMA-style ladder, **cumulative** within specialty.

- `basic` → `advanced` → `expert`. Higher tier covers every
  lower-tier requirement.

**Specialty** - which axis of crafting the kit unlocks.

- **`general`** - universal toolkit path (Basic/Advanced/Expert
  Toolkit). Bandages, basic repairs, generic recipes.
- **`gunsmith`** - weapon modding / part fitting / overhauls (Basic
  /Advanced/Expert Gunsmith Kit).
- **`armor_repair`** - armor condition restoration (Basic/Advanced
  /Expert Armor Repair Kit).
- **`weapon_repair`** - weapon condition restoration (Basic/Advanced
  /Expert Weapon Repair Kit). Distinct from Gunsmith (condition
  restore vs. part swap / modding).
- **`drug_making`** - antibiotics, stims, anti-rad, anti-tox
  (Basic/Advanced/Expert Drug Making Kit).

A recipe states its kit requirement as
`required_kit = { specialty = "...", min_tier = "..." }`. Kit items
are **not consumed** on craft - they stay in inventory.

**Coop kit-sharing.** Every kit and tool in any player's inventory
within ~6m of the crafter in the same region counts toward the check.
One crewmate's Expert Gunsmith Kit unlocks the crew's advanced-weapon
recipes at the shared bench. Material inputs still come from the
crafter's own inventory.

Tier gates recipe visibility, not player access - a recipe you can't
yet craft still shows up in the browser with "Requires: Advanced
Gunsmith Kit + advanced_bench."

### 7.2 Recipes

```
Recipe: ak_762_mag_30rd_repair
  workbench_tier: workbench
  skill_required: gunsmithing >= 2     // optional
  time: 60s
  inputs:
    - { item: mag_damaged_762, count: 1 }
    - { item: spring_stock, count: 1 }
    - { item: metal_scrap, count: 2 }
  outputs:
    - { item: ak_762_mag_30rd, quality_roll: [worn, serviceable] }
  failure_chance: 0.1 * max(0, 2 - skill)  // skill reduces failure
  failure_outputs:
    - { item: metal_scrap, count: 1 }     // partial material recovery
```

Key bits:
- Quality of output can roll; higher skill + better workbench + better inputs → better expected roll.
- Failures give **partial recovery**, never zero. GAMMA-style "craft failed, all materials lost" is a legibility failure we are not repeating.
- Skills are optional; can be implemented as a simple progression later.

### 7.3 Recipe discovery

Three acquisition paths:
- **Known from start** (basic consumables, field repair, common cooking).
- **Blueprints / manuals** dropped as loot or bought from traders. One-time use → unlocks recipe permanently for that player.
- **Experimentation** (late optional system): combine components at workbench, successful combinations auto-add to known recipes. Adds discovery, risks if too spammable - may gate this behind skill/resource cost.

### 7.4 Ammo reloading

High-value loop. Component-based:
- **Case** (new or reclaimed from spent brass)
- **Primer**
- **Powder** (grade determines pressure / variant)
- **Bullet** (weight and type determines round variant)

Result: specific round variant. Mispaired components → squib or overpressure round (chamber risk). Risk scales with skill; good reloaders reliably produce serviceable rounds from scavenged brass.

This couples directly to `weapons-plan.md` round variants. Reloading produces instances of those variants.

### 7.5 Crafting queue

Workbenches support a queue: drop in 10 bandage jobs, walk away, come back later. Jobs progress in real time while you play. No babysitting a progress bar.

For coop: queue is shared at shared workbenches; any player can add/cancel jobs they have materials for. Outputs go to a shared pending output bin.

---

## 8. UX / UI Directives

This is where we explicitly improve on GAMMA. Concrete, non-negotiable:

### 8.1 Medical wheel (combat-usable)

- Bound to a single hotkey (hold → radial).
- Segments: Tourniquet, Bandage, Painkiller, Stim, Anti-rad, Anti-tox, Inject-selected, Field Heal (auto-sequence).
- **Auto-sequence:** one button runs the correct treatment on the worst wound using what you have. If you don't have the right item, it tells you *what you're missing*.
- Radial shows wound severity as colored body silhouette.

### 8.2 Triage panel (pause or full-menu)

- Body silhouette with per-part HP and wound list.
- Each wound shows: kind, severity, next required step, item needed for that step, whether you have it.
- Apply-step buttons where applicable.
- No hidden state. If a wound is infected, it says infected.

### 8.3 Inventory UI

- Grid-based but with **auto-sort** and **auto-stack** on by default.
- Filter chips at top: weapons, ammo, meds, food, junk, attachments.
- **Weight + volume** both visible. Over-limit shows what single-item drop fixes it.
- **Value** column from each relevant trader (toggle which trader), so selling choices are obvious.
- **Drag to hotbar** for consumables; hotbar persists across sessions.

### 8.4 Crafting browser

- Global recipe list, always visible (even unknown recipes show silhouette + "find blueprint" hint, or hidden entirely - designer choice per recipe).
- Filters: by workbench tier, by output category, by "craftable now."
- Per recipe: inputs with **have/need** per item, highlight nearest known source (trader X has this, or this drops from junk type Y).
- Queue this recipe × N with a quantity selector.
- No recipe failures without a clear reason printed ("missing: 1× surgical thread"), and every failure returns partial materials.

### 8.5 Status HUD

- Minimal always-on badges for dangerous states: bleeding (pulsing red), starving, severe rad, severe fatigue, infected wound.
- Never silently-declining. If a stat will kill you in under five minutes at current rate, it's on screen.

### 8.6 Hotbar

- 8 slots, bound to number keys.
- Consumables, weapons, placeable items (e.g., bandage, painkiller, rifle, pistol, knife, tourniquet, stim, energy drink).
- Quick-consume activates item without opening inventory.

### 8.7 Feedback clarity

- Every drug applies a **floating status** with remaining duration and tradeoff indicator.
- Every wound shows its bleed contribution numerically (e.g., "−1.2 HP/s").
- Recipe preview shows expected output quality range.
- Workbench queue shows ETA per job and total.

---

## 9. Interactions With Other Systems

| System | Interaction |
|---|---|
| `weapons-plan.md` §4 rounds | Ammo reloading recipes produce round variants; round components (brass, primer, powder, bullet) are first-class junk items |
| `weapons-plan.md` §5 parts | Part repair + machining happen at workbench/advanced workbench using scrap + specialized components; `spring_stock`, `barrel_stock`, etc. |
| `weapons-plan.md` §6 damage | Projectile impact resolves into wound instances on body parts; wound severity scales with retained energy |
| `loot-and-economy-plan.md` | Meds, food, junk all flow through the container pools and NPC corpse drops; junk categories tiered by depth |
| Faction/economy | Trader category specialization (medic, scavenger, tech, quartermaster) determines junk buy prices and recipe blueprint availability |
| Persistence | All status effects, wound instances, drug tolerance counters, crafting queues must journal |
| `simn-net` (future) | Crafting queue completion events, revive events, shared workbench state all need sync |

---

## 10. Open Questions

- **Wound localization from projectiles.** How precisely do we map hit location to body part? Hitbox per bone vs. capsule approximation? Godot physics gives us per-collider hits; mapping to our six body parts is straightforward but worth specifying.
- **Skill progression.** Do we have skills at all, and if so how many (gunsmithing, medical, cooking, chemistry)? Or is everything gated by recipes/workbenches and input quality, skill-free? Lean skill-lite or skill-free for v1; add if playtest begs for it.
- **Shard interaction with meds.** Some shards reduce rad, some boost endurance with tox cost. This belongs partly in a shard-system doc (to be written) but hooks here.
- **Perishables in coop.** Shared stash with perishable food: do perishables tick while offline? Probably yes - rot is continuous.
- **"Experimentation" crafting.** Do we build the experimentation loop? Satisfying if done well, punishing if done wrong. Defer to v2 likely.
- **Drug cocktails.** How much interaction between drugs? Minimum: tolerance + overdose per drug. Richer: drug-drug interactions (e.g., morphine + alcohol = respiratory risk). Lean minimum for v1.
- **Hotbar during combat with drugs.** Do we allow quick-consume to force a drug protocol that causes overdose? Yes, but with a threshold warning toast. Player agency wins.

---

## 11. Proposed Rollout Order

1. **Stats foundation.** Body-part HP, hunger/thirst/fatigue ticks, basic damage → HP flow. No wounds yet, HP just ticks from hits.
2. **Wound instances + bleed.** Heavy/light bleed, basic bandage + tourniquet. Minimum viable triage panel.
3. **Food + water + cooking.** Consumables, campfire cooking recipe category, basic purification.
4. **Junk system + basic salvage.** Junk items, salvage recipes, field toolkit.
5. **Workbench + recipe browser + crafting queue.** The core UX win. Medical crafting, consumable crafting.
6. **Full medical depth.** Disinfect/stitch/antibiotics, infection, drug tolerance, overdose, morphine/adrenaline/stims.
7. **Advanced workbench + ammo reloading + part machining.** Late-game crafting loops.
8. **Coop revive + shared workbench polish.**

Steps 1–5 are playable without 6–8. Each step produces incremental value.

---

## 12. What This Doc Is Not

- Not a spec. Numbers and item lists are illustrative.
- Not a schedule.
- Not committed. Reorganize and rewrite freely during planning.
