# Inventory & Items

What you carry. Step 4 turns every food / drug / bandage / tool /
junk / component into a **TOML-defined item**. You pick them up (for
now: via the `G` debug cheat), consume them, salvage junk into
components, cook raw meat at a campfire, and watch perishables rot.

The inventory is **Tarkov/STALKER-hybrid grid-based** as of the
inventory-grid PR. Each item occupies an `(x, y)` cell with an `(w, h)`
footprint from its [`items.toml`][items_toml] `size = { w, h }` row,
and may rotate 90° if `rotatable = true`. Rigs and backpacks (with
their own nested grids) ship this PR; world containers + corpse loot
come with PR-4.

[items_toml]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/data/items.toml

## Grid + slots + stacks

The default player **pockets** grid is **4×4** (16 cells). Pickups
follow a merge-then-place rule:

1. **Merge into existing matching stacks first.** Two picks of the
   same item id merge into one slot up to its `stack_size` (e.g.
   `bandage` caps at 20; `pickup × 25 bandage` fills the existing
   slot to 20, then places a new 5-stack in the next free spot).
2. **Place a new stack in the first free spot.** Top-left scan; tries
   `Deg0` first, then `Deg90` if the item is rotatable.
3. **Drop the overflow if there's no room.** Pickup never errors on
   "out of room" - it logs a warning and drops the leftover. The
   leftover lands in a ground container at the player's feet (see
   "Dropping & ground containers" below).

Perishable items **never merge across ages**. If you pick up `raw_meat`
at tick 0 and more `raw_meat` at tick 1000, you get two stacks - the
older one expires first, the newer one keeps its full shelf life.

Item footprints in the current catalog are all `1×1` except the
two containers (basic_backpack and basic_rig at `2×2`); larger items
(rifles, body armor, weapon cases) land with the weapons / armor
catalogs.

## Paper doll + equipment slots

Every drifter has a paper-doll loadout of equipment slots, defined
in `crates/simn-sim/data/equipment_slots.toml` (**modularity
contract** - adding a new slot is a TOML row, zero engine code):

| Slot | Accepts | Notes |
|---|---|---|
| `head` | head_gear | Helmets, hats. |
| `eyes` | eyes | Goggles, masks. |
| `armor_vest` | armor_vest | Body armor. |
| `rig` | chest_rig | Exposes its nested grid - load-bearing rig. |
| `backpack` | backpack | Biggest nested grid. |
| `primary` / `secondary` | weapon_primary / weapon_secondary | Two long-gun slots, STALKER-style. |
| `sidearm` | sidearm | Pistol. |
| `melee` | melee | Knife / bat. |
| `belt_1..4` | medical / drug / food / drink | Hotbar slots, bound to keys 1-4. |
| `pockets` | *virtual* | Always-present 4×4 grid (the `Inventory` component). |
| `secure_pocket` | (empty - items opt in via `equip_slots`) | Tiny always-with-you slot. Not death-insurance; the world is "go get your stuff". |

Equipping a container (backpack, rig) surfaces its **inner grid** -
so a loaded backpack contributes carry capacity on top of pockets.
Unequip and the contents travel with it. Kit / tool checks for
crafting scan **every accessible grid** (pockets + every equipped
container's nested grid), so a gunsmith kit stashed in your backpack
counts for crafting without digging it out.

Hotbar slots (`belt_1..4`) accept small consumable categories by
default; specific items can pin themselves to a specific belt slot
via `equip_slots = ["belt_1"]` in items.toml. Keys `1..4` trigger
`consume_from_hotbar(idx)` - decrements the stack there, empties the
slot when the count hits zero.

Weight is tracked (`sum(count × def.weight)` in kg) with a
**soft cap** as of Step 5: `InventoryConfig::weight_cap_kg` (default
50). You can still pick up one more item when full - the cap doesn't
reject pickup - but your stamina regen is multiplied by
`overweight_regen_mult` (default 0.5) until you drop below. Same
shape as the low-hunger / high-pain penalties. See
[Crafting](./crafting.md) for the full regen-modifier list.

## Dropping & ground containers

`Sim::drop_item(slot)` removes the stack from pockets and drops it on
the ground at the player's feet. Under the hood it routes through
`drop_item_to_ground`, which spawns (or merges into) a
[`WorldContainer`][world_container] - the same entity used for
scene-placed crates and (PR-4b) NPC corpses. So the drop isn't gone:
you can walk back, open the pile, and take it. STALKER's "go get
your stuff" model.

[world_container]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/src/components.rs

Behaviour:

- **First drop spawns a 4×4 private container** at the player's XZ.
  Private = `is_public = false`: it doesn't count toward the crafting
  kit-pool (only public containers do - see [Crafting](./crafting.md)).
- **Subsequent drops within 1.5 m merge into the same pile**, so a
  shift-drop spree doesn't litter the ground with one-stack containers.
  Beyond 1.5 m you get a fresh container.
- **Despawn is manual.** Picking the last stack out doesn't auto-cull
  the pile yet - empty ground containers stick around until the
  scheduled-cleanup pass lands. Negligible visual impact for now since
  there's no ground-pile sprite either.

The container API is symmetric on both sides: `take_from_container`
and `put_in_container` work for ground drops, scene-placed crates,
and corpse loot interchangeably. The in-game looting panel
([Looting, below](#looting-pr-4c)) renders nearby containers via
`Sim::containers_in_range`.

**Public vs. private** is the key distinction:

- **Public** (`is_public = true`) - bench parts bins, shared crew
  crates. Their contents are visible to the crafting kit-pool, so a
  toolkit dropped in a public bin chained to your workbench counts.
  Authored at scene-placement time or via `spawn_world_container(...,
  is_public: true)`.
- **Private** (`is_public = false`) - ground drops, player stashes,
  NPC corpses. Items are still visible / takeable; they just don't
  short-circuit the kit requirement when crafting nearby.

## Looting

Walk within **2.5 m** of any `WorldContainer` — ground drop, NPC
corpse, scene-placed crate — and a "**[F] LOOT**" prompt appears
above the hotbar. Press `F` to open the **unified inventory
panel** with the container's grid prepended to the right-side
stack. Same UI as `I`-toggle inventory; the container just
shows up alongside pockets + equipped containers.

Drag-and-drop, right-click context menus, hover tooltips, and
the filter toolbar all apply to looting too — no separate panel
or interaction model. Containers participate in the looting
flow via the `take_from_container` / `put_in_container` bridge
methods. Container → equipped (rig / backpack / armor inner
grid) isn't direct in v1 — chain via pockets (drag container →
pockets, then pockets → equipped). `Esc` closes the panel.

- **HUD prompt range** = 2.5 m XZ, same region. Multiple nearby
  containers? The prompt always targets the closest one, so walking
  around a pile auto-picks what you're looking at.
- **Cross-grid carry** currently flows only between pockets and the
  open container. Equipped-container-to-container moves (rig →
  crate) aren't wired yet; the shortest path is unequip → loot.
- **Host-authoritative.** Clients emit `TakeFromContainer` /
  `PutInContainer` actions; the host validates fit and journals the
  delta. Click-feedback is optimistic on the host path, deferred on
  the client path until the next snapshot reconciles.

Every real region map spawns a **test crate** near `PlayerSpawn` so
the loop is exercisable without first killing an NPC. The crate is
public (so it doubles as a portable kit-pool bench-bin). It's a
temporary dev aid - authored scene placements replace it when the
region-content pass ships.

## Consuming items

Every consumable in `items.toml` has a `consume_action`. The sim
routes the action to the matching existing method:

| Action | Calls | Body part? |
|---|---|---|
| `eat` | `Sim::eat(food_kind)` | no |
| `drink` | `Sim::drink(water_kind)` | no |
| `apply_drug` | `Sim::apply_drug(drug)` | no |
| `apply_bandage` | `Sim::apply_bandage` | **yes** |
| `apply_tourniquet` | `Sim::apply_tourniquet` | **yes** |
| `apply_disinfectant` | `Sim::apply_disinfectant` | **yes** |
| `apply_stitch` | `Sim::apply_stitch` | **yes** |
| `apply_wound_pack` | `Sim::apply_wound_pack` | **yes** |
| `apply_antibiotics` | `Sim::apply_antibiotics` | no |

`consume_from_slot(steam_id, slot, body_part)` does the lookup and
the routing. If the underlying API errors (e.g. "no wound to bandage
on torso"), the item is **not consumed** - you can retry. That
matches the existing treatment contract.

## Salvage

Junk items carry a `salvage` recipe. Salvage rolls a per-output count
in `[min, max]` and adds the components to your inventory, consuming
one of the junk. The recipe can require a tool - today everything
uses `field_toolkit`; without it in your inventory, salvage errors
and the junk is untouched.

The outputs are written to the journal as the actual rolled list, so
replay is deterministic without re-running the RNG.

## Cooking (single recipe in Step 4)

One recipe ships this cut: `cook_meat` (raw_meat × 1 → cooked_meat ×
1). It requires `cookware` in the inventory and a `campfire` context.

**Campfire context is still a debug flag through Slice B of Step 5.**
Toggle it with the `F3` key (overlay shows `campfire=ON`). Scene-
placed campfire entities + the real proximity system are parked on
the worldbuilding list - the `required_context` field on recipes
survives that transition unchanged.

Workbench tiers follow the same pattern: the `F2` key cycles the
debug `NearWorkbench` tier (none → basic → advanced → expert) and
`SimHost.set_near_workbench` is the canonical setter until scene-
placed bench entities land.

Cooked meat has a longer perishable window (24 in-world hours) than
raw meat (6 in-world hours), so cooking is both a safety upgrade (no
tox) and a pantry upgrade (lasts longer).

## Perishables

Any item with `perishable_ticks` set in `items.toml` spoils once
`sim_tick - spawned_tick ≥ perishable_ticks`. The `tick_perishables`
system runs each tick, scans player inventories, and removes expired
stacks. Nothing is journaled - expiry is deterministic from spawn
tick + current tick, same pattern as drug-effect retirement.

Today's perishables:

| Item | shelf life |
|---|---|
| `fresh_food` | 12 in-world hours |
| `raw_meat` | 6 in-world hours |
| `cooked_meat` | 24 in-world hours |

Preserved rations, field rations, energy bars, all drugs, medicals,
drinks, and junk are all **non-perishable**. You can stockpile them
indefinitely.

## Debug controls (Step 4)

Step 4 ships without a proper inventory panel scene. Everything is
driven off the debug overlay:

- `G` - open the **Debug Spawn** panel. Categorized item picker
  (weapons, mags & ammo, armor & gear, medical, food, tools, misc)
  with a search box and per-row `+1` / `+10` / `+stack` quick-grant
  buttons. Reads the full `items.toml` catalog, so any item the sim
  knows about is grantable. `G` again or `Esc` closes it.
- `H` - consume slot 0. Passes `body_part = "torso"` so bandages /
  tourniquets / stitches / disinfect / wound-pack on slot 0 target
  the torso. Drugs, food, drink, antibiotics ignore the argument.
- `F3` - toggle the near-campfire flag. (`F` was rebound to the
  looting `interact` action in PR-4c.)
- The overlay's `inventory:` section shows every slot, total weight,
  and the campfire state.

There is no `craft` keybind on the debug overlay - call
`_sim.craft_recipe(sid, "cook_meat")` from GDScript if you need to
exercise crafting outside the panel. (Drop now lives on `X` while
carrying an item in the inventory panel; see "In-game panel + hotbar"
below.)

## In-game panel + hotbar

Press **`I`** to open the inventory + crafting panel. Two tabs:

- **Inventory** - paper doll (left) + 2D grid view (right). The grid
  view stacks pockets and each equipped container's inner grid in a
  scrolling column. As of iteration 5-12 phase 2:
    - **Drag-and-drop is the primary interaction.** Press and hold the
      mouse on any item card to pick it up; the drag preview shows the
      card at 70 % opacity tracking the cursor. Drop targets that
      accept the drag border up in cyan; rejects don't highlight.
      - Drag a card from any grid onto another grid cell to **move**
        it (first-fit within the destination grid; nested inner-grid
        contents travel with the container).
      - Drag onto a populated cell of compatible footprint to **swap**.
      - Drag onto an empty doll slot of compatible category to
        **equip**; drag a doll item back onto any grid to **unequip**
        into that grid.
      - Doll-to-doll moves equip-swap when the destination accepts the
        source category.
    - **Right-click any card or doll slot** for a context menu - the
      options depend on category and source grid: Use / Equip /
      Unequip / Drop / Examine. Stackables also get **Split** for
      ammo, rations, bandages, etc.
    - **Hover any card or slot** for a tooltip (~½-second delay)
      showing name, category, per-unit + total stack weight, stack
      max, magazine load state, perishable hint, and rotation
      indicator. Empty doll slots tooltip surfaces the slot's
      accepted-category list.
    - **Filter toolbar** above the grids: chips for `ALL / WPN /
      AMMO / MED / FOOD / ARMOR / PARTS` plus a free-text search
      box on the right (search matches both display name and stable
      id, so `ak_mag_30` works for power users). Cards that fail the
      active filter dim to ~28 % alpha so the matches read at a
      glance without losing their grid positions.
    - **Paper doll** uses a tarkov-style cold-steel palette. Empty
      slots show a faded category watermark (`RIFLE` / `VEST` /
      `HEAD` etc.) so the slot identity is readable at a glance,
      plus a tiny slot-name chip in the corner. Populated slots layer
      the category icon + item name over the watermark with a count
      badge in the bottom-right corner.
    - **`Esc`** closes the panel.
- **Crafting** - unchanged from Slice B: specialty filter chips, a
  "CRAFTABLE NOW" toggle, recipe list with per-row "Requires:"
  status, per-recipe detail + queue×N spinner, live queue strip
  with progress bars + Cancel buttons.

The inventory + crafting tabs both subscribe to `SimHost.view_updated`
(throttled to 4 Hz) so they refresh after any sim mutation - equip,
consume, craft, drop - without polling every frame.

**Hotbar HUD** - belt slots (`belt_1..4`) are always visible
bottom-center when in-game. Number keys **`1..4`** trigger
`consume_hotbar(idx)`. Drag an item onto a belt slot in the panel to
bind it; the slot's `accepts` list gates what can go there
(medical / drug / food / drink by default).

**Debug workbench cycle** lives on **`F2`**.

## What's deferred

- **Cross-grid swap** - within-pockets swap and cross-grid *move* both
  work. True cross-grid *swap* (atomically exchanging two items
  across pockets ↔ equipped-grid) stays deferred - the dest cell may
  not have room for the source item, so the panel falls back to
  first-fit *move* and the user can chain two moves to swap. Stash-
  to-stash moves are PR-4 scope.
- **Cell-precise placement** - the engine places new items at the
  first-fit position via `grant_or_merge`; the UI can't yet hint "put
  it right here" on drop.
- **Sort options** - "sort by name / weight / condition / recency"
  (Phase 2E in [`planning/sim-iteration-5-12-plan.md`][plan]). A 2D
  grid inventory has fixed item positions, so sort doesn't apply the
  way it does to a flat list - it'd need an auto-arrange sim API
  that re-packs pockets, or a separate flat-list view toggle.
- **Rarity tint + condition bars + per-card equipped badge** -
  Phase 2F polish. Rarity needs a new `ItemDef` field; condition bars
  arrive with weapons-plan Step 3 (parts + condition + jams). Empty-
  doll-slot ghosted placeholder shipped in Phase 2C as a faded
  category watermark.
- **Ground container culling** - empty containers persist until a
  cleanup pass; harmless until ground-pile rendering exists.
- **Workbench entity placement** - `NearWorkbench` + debug setter +
  `F2` cycle live; scene-placed bench entities + a proximity system
  land with worldbuilding.
- **NPC inventories**. Arrives with corpse loot.
- **Morale bonuses from food**. Needs the morale stat.
- **Hot-reload of items.toml**. Restart to pick up TOML edits for
  now.

[plan]: ../planning/sim-iteration-5-12-plan.md
