# Crafting

Every craftable thing in Noosphere comes from a **TOML recipe** that
names its inputs, outputs, the time it takes, the crafting station it
needs (campfire / basic / advanced / expert bench), and - the new
GAMMA-style dimension - the **toolkit or specialty kit** the crafter
must have on hand.

This chapter is the player-facing contract: what tiers mean, what
kits cover what, how the queue works, and how coop kit-sharing works.
Inventory mechanics (slots, weight, salvage, consume) are in
[Inventory & Items](./inventory.md); the raw item / recipe schema
lives in `crates/simn-sim/src/items.rs`.

## Stations vs. kits vs. tools

Three independent axes. A recipe can demand any or all of them.

**Crafting station** - the fixed workspace you stand at. Four kinds:

| Station          | Covers                               |
|------------------|--------------------------------------|
| `campfire`       | Cooking, water purification          |
| `basic_bench`    | Bandages, common consumables         |
| `advanced_bench` | Weapon parts, ammo reloading prep    |
| `expert_bench`   | Shard containment, rare crafts    |

Benches are **cumulative**: standing at an Advanced bench satisfies a
recipe that needs `basic_bench`. Campfire is separate - benches don't
substitute for a campfire, and vice versa.

**Tool tier** - GAMMA-style progression, **cumulative**:

| Tier       |
|------------|
| `basic`    |
| `advanced` |
| `expert`   |

An Expert-tier kit satisfies any Basic- or Advanced-tier requirement
within the same specialty.

**Specialty** - which axis of crafting the kit lets you do. Matches
GAMMA's specialty-kit ladder 1:1:

| Specialty       | Covers                                        |
|-----------------|-----------------------------------------------|
| `general`       | Bandages, basic repairs, *crafting* specialty kits |
| `gunsmith`      | Weapon modding, part fitting, ammo crafting   |
| `armor_repair`  | Armor condition restoration                   |
| `weapon_repair` | Weapon condition restoration (condition, not parts) |
| `drug_making`   | Antibiotics, stims, anti-rad / anti-tox       |
| `shards`     | Shard combination / upgrade (Artefact Melter) |

### Class-to-tier mapping

For the two repair ladders, the tier gates which **class** of gear
the kit can service. GAMMA's class system (TYPE A/B/C/D weapons,
light/medium/heavy/exo armor) maps onto our cumulative tiers:

| Kit tier   | Armor class covered       | Weapon class covered |
|------------|---------------------------|----------------------|
| `basic`    | light                     | TYPE A, B            |
| `advanced` | light, medium             | TYPE A, B, C         |
| `expert`   | light, medium, heavy, exo | TYPE A, B, C, D      |

A recipe that repairs a heavy armor piece just names
`required_kit = { specialty = "armor_repair", min_tier = "expert" }`
- no separate "heavy armor repair" enum needed. Higher tier covers
everything below within the same specialty.

A recipe might demand any combination:

```toml
required_kit    = { specialty = "gunsmith", min_tier = "advanced" }
required_context = "advanced_bench"
time_ticks = 12000              # 10 real-world minutes
```

## Coop kit-sharing

**Your crewmate's toolkit counts as yours at the same bench.** If
you and your team are within ~6m of each other in the same region,
every kit and tool in any accessible grid - pockets plus every
equipped container's inner grid (rig, backpack, nested
containers inside those) - is checked when you craft. See
[Inventory & Items - Paper doll](./inventory.md#paper-doll--equipment-slots)
for the full accessible-grid rules. One player can carry the Expert
Gunsmith Kit for the whole squad, tucked in their backpack.

**Public world containers extend the pool too.** Any nearby
[`WorldContainer`](./inventory.md#dropping--ground-containers) with
`is_public = true` (bench parts bins, shared crew crates) gets walked
the same way - drop the squad gunsmith kit in the parts bin chained
to the workbench and it counts for everyone, no inventory shuffling
required. **Private** containers (player stashes, ground drops, NPC
corpses) are deliberately excluded so a stash doesn't silently
satisfy a recipe just because it's nearby.

Material inputs are still consumed from **your** inventory (pockets
grid specifically, for now) - you pay for what you craft. Only the
kit/tool check is pooled.

(Once real workbench entities land, the 6m radius anchor moves from
your position to the bench; until then it's a reasonable proxy for
"standing at the same bench.")

## The crafting queue

Recipes have a `time_ticks` cost (20 ticks per second). At Step 5
recipes run through a per-player **queue**:

1. You call `queue_craft(recipe_id, count)`. The sim validates
   preconditions, **consumes all inputs × count immediately**, mints
   a job id, and pushes the job onto your queue.
2. The head job ticks down one unit at a time. When a unit's
   `ticks_remaining` hits zero, the recipe's outputs are minted into
   your inventory (stamped with the current tick, so perishables
   start aging from completion).
3. The job's `count_remaining` decrements. If more units remain, the
   timer resets to the recipe's `time_ticks` and the next unit
   begins. If the count's exhausted, the job pops and the next
   queued job (if any) takes over.
4. You can `cancel_craft(job_id)` at any time. Remaining-unit
   materials are **refunded**. The in-progress unit is **forfeit** -
   whatever materials went into it are lost.

Materials lock up front (step 1) so you can't dupe by cancelling
mid-craft and re-queueing elsewhere. The in-progress forfeit is the
quick-and-clean version of partial-refund logic; the spec's
partial-material return for failed recipes lands with the weapons
crafting layer.

### Queue replication is deterministic

Per-unit completions **don't** emit network deltas. The queue state
lives in a replicated component; every sim (host, solo, coop mirror)
ticks it forward identically from the shared snapshot, same pattern
as perishable expiry. Only the discrete lifecycle events -
`CraftJobQueued` and `CraftJobCancelled` - travel over the wire.
That keeps the delta volume proportional to player actions, not tick
rate.

## Weight cap

Step 5 activates the weight cap that Step 4 scaffolded. Default:
**50kg**. You can still pick up one more item when you're full - the
cap is soft - but **stamina regen is multiplied by `0.5` while
overweight**. Same shape as the low-hunger and high-pain penalties
that already gate regen.

Both numbers are tunable via `InventoryConfig` (a world resource, not
a snapshot field - retuning ships with a code change, not a save
migration).

The spec's per-character skill-driven weight cap lands with the
progression system; for now every player has the same cap.

## TOML reference

The example catalog stocks one item per cell of the
**specialty × tier** matrix (15 kits total, plus the generic `basic
/ advanced / expert` toolkit ladder):

```toml
# Gunsmith ladder
[[items]]
id = "gunsmith_kit_basic"
tool = { specialty = "gunsmith", tier = "basic" }

[[items]]
id = "gunsmith_kit_advanced"
tool = { specialty = "gunsmith", tier = "advanced" }

[[items]]
id = "gunsmith_kit_expert"
tool = { specialty = "gunsmith", tier = "expert" }
```

Example recipes exercise the system end-to-end:

- `craft_bandage` (general toolkit, basic bench).
- `craft_antibiotics` (drug-making kit, basic bench).
- `craft_armor_repair_kit_advanced` - mirrors GAMMA's
  "Advanced Tools → Heavy Armor Repair Kit" chain. The crafter needs
  an Advanced general toolkit at an advanced bench to produce the
  specialty kit item itself.
- `craft_armor_repair_kit_expert` - Expert tools, expert bench, pulls
  in an optical lens.

Real per-tier catalogs for weapons, armor, drugs, and meds fill in
as those systems ship.

## In-game UI (Slice B)

Press **`I`** to open the inventory + crafting panel. Two tabs:

- **Inventory** - category filter chips (food / drink / medical /
  drug / junk / component / tool), slot grid, weight bar (turns red
  + shows "OVER (regen ÷2)" when over the cap).
- **Crafting** - specialty filter chips, "craftable now" toggle,
  recipe list (each row green when ready, red when blocked, with a
  "Requires:" line driven by `can_craft`), per-recipe detail with
  inputs / outputs / time / kit / station, and a `queue × N` spinner.
  The bottom strip shows live jobs with progress bars and Cancel
  buttons.

The panel polls `SimHost.tick_completed` for refresh - ~20Hz on
host / solo, fine for the queue widget.

Press **`R`** to cycle the debug `NearWorkbench` flag through
`none → basic → advanced → expert → none`. Mirrors the **`F3`**
campfire toggle (rebound from `F` in PR-4c so `F` could become
the looting `interact` action). Until scene-placed workbench
entities + a real proximity system land, this is how you set up
a bench-context for testing.

## What's deferred

- **Workbench entity placement in scenes** - the `NearWorkbench`
  component, gdext setter, and debug `R`-key cycle are live; the
  scene-side proximity system and the actual placed bench entities
  land with worldbuilding work later in the slice.
- **Failure chance + partial-material returns.** All current recipes
  succeed; the spec's partial-refund path lands with weapons crafting.
- **Blueprint / recipe discovery.** Every recipe is known from start
  today. Blueprint pickups + "unknown → silhouette" land later.
- **Per-character weight cap from progression.** Global today.
- **Shared material inputs across coop inventories.** Only tools /
  kits pool at the bench; inputs still come from the crafter.
- **Queue-shared-at-workbench for coop.** Each player has their own
  queue today. Shared-bench queues land alongside workbench entity
  placement.
