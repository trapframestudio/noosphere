# Food & Water

Consumables are how the player refills hunger/thirst/fatigue meters,
and how they trip rad/tox contamination. This chapter documents the
profile of every food and water kind. Cooking (raw → cooked) and
perishables (items that spoil) are live as of the [inventory
pass](inventory.md).

The profile tables below still describe behavior **by kind** -
`FoodKind::CookedMeat` always gives the same nutrients regardless of
which stack it came from. Food and water items in `items.toml`
reference these kinds by their `consume_action`; `Sim::consume_from_slot`
reads the action and calls the matching `eat` / `drink` method.

## Food

| Kind | hunger | thirst | rad | tox | notes |
|---|---|---|---|---|---|
| `PreservedRation` | +30 | −5 | 0 | 0 | salty; raises thirst slightly |
| `FreshFood` | +35 | 0 | 0 | 0 | safe; 12 in-world hour shelf life |
| `RawMeat` | +20 | 0 | 0 | +20 | **mild food poisoning**; cook it first |
| `CookedMeat` | +40 | 0 | 0 | 0 | safe; the reward for cooking |
| `ContaminatedFood` | +30 | 0 | +30 | +20 | looks normal, reads as radiation-hot; rare |
| `FieldRation` | +50 | −5 | 0 | 0 | high quality; valuable trade good later |
| `EnergyBar` | +15 | 0 | 0 | 0 | snack; good for a top-off |

A few player-facing implications:

- **Cook raw meat.** +20 toxicity per raw-meat meal will stack
  uncomfortably with any other tox source. Cooked is clean.
- **Preserved rations and field rations make you thirsty.** Plan a
  drink nearby.
- **Contaminated food is rare but dangerous.** Spec §5.1 envisions
  source-readable hints (you found it in a hot zone). Today it's
  rare in the world seed; narrative lore around how to recognise
  contaminated food arrives with authored content.

## Water

| Kind | hunger | thirst | rad | tox | grants |
|---|---|---|---|---|---|
| `DirtyWater` | 0 | +50 | +15 | +10 | - |
| `CleanWater` | 0 | +60 | 0 | 0 | - |
| `EnergyDrink` | 0 | +40 | 0 | 0 | short StimCocktail effect |
| `Vodka` | 0 | +20 | −5 | +5 | mild morale (deferred) |

Player-facing implications:

- **Dirty water keeps you alive but costs rad and tox.** In a pinch,
  better than dying of thirst - but plan to apply anti-rad / anti-tox
  within the in-world day. Purification tablets will convert dirty →
  clean when that recipe lands (Step 5 craft tree).
- **Energy drink chains into the Stim pipeline.** This means the same
  tolerance counter as taking Stim Cocktail directly. You can't spam
  energy drinks in a combat loop without eventually triggering the
  fatigue rebound from stacked Stims.
- **Vodka reduces radiation slightly.** Spec §5.2 foreshadows the
  classic STALKER mechanic (alcohol dulls radiation absorption).
  Morale / drunk debuffs are deferred until the morale stat exists.

## What's deliberately not in this PR

- **Purification tablets.** Listed in the survival plan; lands with
  the Step 5 recipe tree.
- **Morale stat and vodka's morale payoff.** Morale is a spec §3.1
  stat that doesn't exist yet. Vodka's rad reduction is the only
  current mechanical effect.
- **Quantity / per-meal vs per-bottle metering.** Each
  `consume_from_slot` consumes one unit of the stack and applies the
  full profile. A multi-serving bottle is a future item-state
  refinement.

## Dev usage

The inventory layer wraps these APIs. You grant an item and consume
a slot, rather than calling `eat`/`drink` directly:

```gdscript
sim.grant_item(sid, "cooked_meat", 1)
sim.consume_slot(sid, 0, "")             # body_part unused for food
sim.grant_item(sid, "energy_drink", 1)
sim.consume_slot(sid, 0, "")             # also spawns a short Stim
```

`Sim::eat(FoodKind)` / `Sim::drink(WaterKind)` are still public for
scripting - the inventory wrapper calls them under the hood.

## See also

- [Inventory & Items](inventory.md) - where stacks live, cooking,
  perishables.
- [Damage & Healing](damage-and-healing.md) - body-part HP, survival
  meters, infection.
- [Drugs & Effects](drugs-and-effects.md) - why EnergyDrink's Stim
  grant isn't a free lunch.
- `../planning/survival-and-crafting-plan.md` §5 - design source.
