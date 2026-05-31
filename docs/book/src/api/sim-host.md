# SimHost

`class SimHost extends Node`

Owns the `simn_sim::Sim` and ticks it each frame. The main
GDScript-facing surface for everything the simulation does:
players, combat, wounds, drugs, inventory, world state, NPCs,
chronicle, replication.

Typical usage: one `SimHost` child node on the `GameSession`
autoload (`scenes/session_root.tscn`). `GameSession` calls
`start(save_dir)` on session entry and `shutdown()` on exit.

**Source:** `crates/simn-godot/src/sim/mod.rs`

---

## Signals

### `sim_ready()`

Emitted after `start()` or `start_mirror()` succeeds. The sim is
now initialized and safe to query.

### `sim_error(message: String)`

Emitted on fatal sim errors (`tick()` failure, `start()` crash).
`message` contains the underlying `anyhow::Error` chain. The
session should unwind after this - further calls may panic.

### `tick_completed(tick: int, payload: PackedByteArray)`

Host-side only. Emitted after a frame's multi-tick catch-up when
the authoritative sim produced deltas. `payload` is a bincoded
`Vec<WorldDelta>`. `GameSession` forwards to
`NetworkManager.broadcast_delta(tick, payload)`.

### `view_updated(tick: int)`

Phase 2G. Fired whenever a new `SimView` is published (worker
mode) or a tick completes (direct mode) — regardless of host /
solo / client role. Unlike `tick_completed` which only fires when
networked (it carries network delta payloads), this is the
UI-refresh hook every panel subscribes to so player-visible state
changes (equip, drop, consume, drag-drop) reflect immediately.
Without this, solo sessions never saw a refresh signal at all.

### `action_requested(steam_id: int, payload: PackedByteArray)`

Client-side only. Emitted when a mutation `#[func]` runs while
`NetworkManager.role() == "client"`; `payload` is a bincoded
`ActionKind`. `GameSession` forwards to
`NetworkManager.send_action(steam_id, payload)`.

### `snapshot_applied(tick: int)`

Client-side only. Emitted when a mirror sim finishes ingesting a
host-sent snapshot via `apply_network_snapshot`. `GameSession` uses
this to hide the "connecting..." spinner and load the region scene.

### `projectile_spawned(payload: Dictionary)`

Phase 2 FX hook. Fired on both auth sims (from the tick-drain
path) and mirror clients (from `apply_network_delta_batch`) when
a projectile spawns. `scripts/impact_fx.gd` renders a tracer.

**Payload keys:**

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | Stable `ProjectileId`; correlates with the matching `projectile_impacted` payload. |
| `source_steam_id` | `int` | Player shooter's Steam ID. `0` for NPC-fired projectiles. |
| `source_npc_id` | `int` | NPC shooter's `NpcId`. `0` for player-fired projectiles. (Phase 4A v2.) |
| `round_id` | `String` | Ammo item id (e.g. `"round_5_45x39_ap"`). |
| `variant` | `String` | Phase 4B v2: `"fmj"` / `"hp"` / `"ap"` / `"tracer"` / `"overpressure"` — round's `AmmoConfig.variant` family tag. Use for tracer color, casing-eject SFX, impact-FX selection. |
| `origin` | `Vector3` | Muzzle world position. |
| `velocity` | `Vector3` | Initial velocity (m/s). |
| `max_range_m` | `float` | Despawn threshold from the firing weapon. |
| `spawned_tick` | `int` | Sim tick the projectile spawned. |

Exactly one of `source_steam_id` / `source_npc_id` is non-zero
on a real shot. GDScript can branch on which side fired
(tracer color, incoming-vs-outgoing recoil/shake cues).

### `projectile_impacted(payload: Dictionary)`

Phase 2 FX hook. Fired when a projectile's tick resolves (NPC
hit, player hit, or out-of-range). The sim has already applied
damage (if any) via the same path as melee / scripted damage.

**Payload keys:**

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | Matches the `projectile_spawned.id` for this flight. |
| `pos` | `Vector3` | Impact world position. |
| `npc_id` | `int` | `0` if terminal ground / out-of-range / hit a player; else the struck NPC. |
| `hit_player_steam_id` | `int` | Phase 4A v2: `0` if the impact didn't hit a player; else the struck player's Steam ID. |
| `body_part` | `String` | `"head"` / `"torso"` / `"left_arm"` / etc. `""` on null-target impacts. |
| `damage_applied` | `float` | Post-armor HP already applied to the target. |
| `penetrated` | `bool` | `true` if the round breached armor; `false` on blunt-only blocks. |

At most one of `npc_id` / `hit_player_steam_id` is non-zero on
a hit; both are `0` on a miss / despawn. GDScript uses the
distinction to drive local FX (NPC vs player blood splatter,
hit-shake on the local player, etc.).

---

## Lifecycle

### `func set_content_root(path: String) -> void`

Point the sim at a content-pack directory, **overlaid** on the engine's
embedded generic example pack: on-disk files under `path` override the
embedded defaults; anything absent falls back to embedded. Accepts a
`res://` / `user://` / OS path. **Call before `start()`.**

| Arg | Type | Notes |
|---|---|---|
| `path` | `String` | Content root, e.g. `"res://content"`. Resolved to an OS path internally. |

Noosphere wires this in `game_session.gd` (`set_content_root("res://content")`)
to supply its proprietary `factions.toml`, `names/`, and
`chatter_lines.toml` while inheriting mechanics and items from the engine.
If you don't call it, the sim uses the embedded generic example pack. See
the `ContentSource` section in `architecture/crate-guide.md`.

### `func start(save_dir: String) -> void`

Initialize an authoritative sim (solo or coop-host). Loads an
existing save if present, otherwise creates one and writes a tick-0
snapshot.

| Arg | Type | Notes |
|---|---|---|
| `save_dir` | `String` | Absolute path. Typically `OS.get_user_data_dir() + "/saves/" + run_id`. |

Restart-on-reentry: if a sim/worker is already active, `start()`
tears them down (same sequence as `shutdown()` — `Sim::shutdown`
via the worker's inspect channel, then thread join) before
spinning up a fresh sim for `save_dir`. This is what lets the
run-switching flow work — leaving a run and entering a different
one from the menu re-enters `start()` without an explicit
`shutdown()` call from `game_session.gd`. Emits `sim_ready` on
success, `sim_error(message)` on failure.

Authoritative sims always run on a dedicated worker thread
(threaded-sim PR C). The worker owns its own 20 Hz tick clock
and self-drives; `process()` is a no-op for tick driving on
the authoritative path. Mirror sims (`start_mirror`) keep
running in direct-mode because they don't tick autonomously
— they apply external host snapshots / deltas instead.

**Threading model**. Authoritative sims run on a dedicated
`simn-sim` worker thread; the renderer reads state via
lock-free `ArcSwap` cells (a 2-slot snapshot pair for the NPC
lerp + a per-tick `SimView` for HUD reads) and pushes
mutations via typed `SimCommand`s through a bounded
`crossbeam_channel`. `Sim` is the worker thread's exclusive
owner; the bridge never touches it directly on the authoritative
path.

Migration helpers inside `SimHost`:
- `dispatch_player_action(steam_id, kind)` — single dispatcher
  for every `ActionKind`-shaped op. Routes client → emit_action,
  worker → `worker.send(SimCommand::Action)`, mirror →
  `sim.apply_action`.
- `worker_or_direct_mut(|sim| …)` — for non-`ActionKind`
  host-only mutations (debug setters, NPC targeting, terrain
  attach, weather / time / population). Routes to
  `worker.inspect` in worker mode (one-tick worst-case
  latency) or runs inline on the mirror's `sim`.
- `worker.inspect(|sim| …)` — direct use for typed-return
  mutations (`queue_craft`, `load_rounds`, `fire_weapon`,
  `apply_drug`, `spawn_world_container`).

Return-value semantic shift on the `dispatch_player_action`
path: in worker mode `bool` means "command queued cleanly"
rather than "operation succeeded"; the HUD reconciles on the
next `SimView` tick (≤ 50 ms). Typed-return paths keep
synchronous semantics via `inspect` and pay the worker
round-trip cost.

Open follow-up surface (low traffic, not hot path): a handful
of debug-query `#[func]`s with complex Variant returns
(`region_control`, `can_craft`, `nav_traversability`,
`npcs_in_region`, `npcs_near`, `chronicle_recent_deaths`)
still hit `self.sim.as_ref()` and return empty in worker
mode until they're migrated through SimView expansion or
inspect-with-Send-payload. None impact gameplay; they
graduate as needed.

### `func start_mirror() -> void`

Initialize a mirror sim for a coop client. No save directory, no
NPC-mutating systems. Caller follows up with
`apply_network_snapshot` once the host sends its state.

Idempotent. Emits `sim_ready` on success.

### `func attach_network(nm: NetworkManager) -> void`

Wire a sibling `NetworkManager` so `SimHost` can query role +
emit action relays. Called once in `GameSession._ready()`.

### `func detach_network() -> void`

Clear the `NetworkManager` reference. Subsequent behavior: always
authoritative (mutations happen locally).

### `func shutdown() -> void`

Roll a final snapshot, flush the journal, fsync. Call on graceful
exit (`_notification(NOTIFICATION_WM_CLOSE_REQUEST)` in
`GameSession`).

No-op on mirror sims (no disk state).

In worker mode, runs `Sim::shutdown` via the worker's inspect
escape hatch (PR C step 4b-i; step 7 promotes this to a typed
`SimCommand::Shutdown`) then joins the worker thread. Both the
inner shutdown result and the inspect channel are logged, but
the join proceeds either way.

### `func current_tick() -> int`

Current `SimClock.tick`. Monotonic; increments 20× per second on
authoritative sims, slaved to host ticks on mirrors.

---

## Player lifecycle

### `func upsert_local_player(steam_id: int, region_name: String, pos: Vector3, yaw: float) -> void`

Spawn or idempotently move the player entity for `steam_id`.

| Arg | Type | Notes |
|---|---|---|
| `steam_id` | `int` | Steam ID; `0xDEADBEEF` for solo. |
| `region_name` | `String` | Discover via `all_regions()`. Unknown names logged + skipped. |
| `pos` | `Vector3` | World position (m). |
| `yaw` | `float` | Y-rotation (rad). |

**Client behavior:** sends `ChangeRegion` + `Move` actions to host
instead of mutating locally.

### `func move_local_player(steam_id: int, pos: Vector3, yaw: float) -> void`

Update an existing player's transform. Called every physics frame
by `GameSession._physics_process()`.

**Client behavior:** sends `ActionKind::Move` action.

### `func change_region(steam_id: int, region_name: String) -> void`

Teleport a player to a different region. Triggered by transition
cubes (`scripts/transition_cube.gd`). Unknown region → logged +
skipped.

**Client behavior:** sends `ActionKind::ChangeRegion`.

### `func remove_player(steam_id: int) -> void`

Despawn the player entity. Host-only - clients no-op; the host
observes Steam lobby exit and cleans up.

### `func player_state(steam_id: int) -> Dictionary`

Full authoritative player state. Returns an empty dict if the
player isn't known.

**Dictionary keys:**

| Key | Type | Notes |
|---|---|---|
| `region` | `String` | Region name the player is in. |
| `pos` | `Vector3` | World position. |
| `yaw` | `float` | Y-rotation (rad). |
| `health` | `float` | Aggregate HP = `min(head, torso)`. |
| `max_health` | `float` | Max HP (100). |
| `stamina` | `float` | Current stamina [0–100]. |
| `max_stamina` | `float` | Max stamina. |
| `body_parts` | `Dictionary` | Per-limb HP: keys `head`, `torso`, `left_arm`, `right_arm`, `left_leg`, `right_leg`, each `float`. |
| `hunger` | `float` | [0–100]; 0 = starving. |
| `thirst` | `float` | [0–100]. |
| `fatigue` | `float` | [0–100]. |
| `pain` | `float` | [0–100]; derived from wounds. |
| `radiation` | `float` | [0–100]; accumulates from contamination. |
| `toxicity` | `float` | [0–100]. |
| `wounds` | `Array[Dictionary]` | See wound-dict table below. |
| `active_effects` | `Array[Dictionary]` | See effect-dict table below. |
| `drug_tolerance` | `Dictionary` | Keys: drug names (`"painkiller"`, …); values: `float` [0–100]. |
| `inventory` | `Array[Dictionary]` | Placed stacks in the player's pockets grid - see inventory-dict table below. |
| `inventory_width` | `int` | Width (cells) of the player's pockets grid. Default 4. |
| `inventory_height` | `int` | Height (cells) of the player's pockets grid. Default 4. |
| `inventory_weight` | `float` | Sum of `count × def.weight` (kg). Soft-capped per `InventoryConfig::weight_cap_kg`. |
| `near_campfire` | `bool` | Debug flag for crafting context. |

**Wound dict** (element of `wounds`):

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | Stable `WoundId`. |
| `body_part` | `String` | `"head"` / `"torso"` / `"left_arm"` / `"right_arm"` / `"left_leg"` / `"right_leg"`. |
| `kind` | `String` | Always `"bleed"` in slice 1. `Fracture` / `Burn` / `Puncture` / `Laceration` land later. |
| `severity` | `int` | 1–5. Light = 1–3, heavy = 4–5. |
| `treatment` | `String` | `"untreated"` / `"disinfected"` / `"bandaged"` / `"stitched"` / `"tourniquet"` / `"wound_packed"` / `"healed"`. |
| `spawned_tick` | `int` | Tick the wound was spawned. |
| `infected` | `bool` | True after infection trigger elapsed without disinfectant. |

**Effect dict** (element of `active_effects`):

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | Stable `EffectId`. |
| `kind` | `String` | `"painkiller"` / `"morphine"` / `"adrenaline"` / `"stim_cocktail"` / `"anti_rad"` / `"anti_tox"` / `"antibiotics"` / `"withdrawal"` / `"overdose"` / `"adrenaline_crash"` / `"fatigue_rebound"`. |
| `applied_tick` | `int` | Tick the effect started. |
| `duration_ticks` | `int` | Effect duration; retired at `applied_tick + duration_ticks`. |
| `intensity` | `float` | Strength multiplier. |

**Inventory dict** (element of `inventory`):

| Key | Type | Notes |
|---|---|---|
| `id` | `String` | Item id from `items.toml`. |
| `name` | `String` | Display name. |
| `category` | `String` | `"food"` / `"drink"` / `"medical"` / `"drug"` / `"junk"` / `"component"` / `"tool"` / `"misc"`. |
| `count` | `int` | Stack size. |
| `spawned_tick` | `int` | Tick the stack was minted (used by perishable aging). |
| `x` | `int` | Top-left cell column in the pockets grid. |
| `y` | `int` | Top-left cell row in the pockets grid. |
| `w` | `int` | Effective footprint width after rotation. |
| `h` | `int` | Effective footprint height after rotation. |
| `rotation` | `String` | `"0"` (upright) or `"90"` (rotated 90° CCW). |

**Example (GDScript):**
```gdscript
var state := _sim.player_state(steam_id)
if not state.is_empty():
    _hud.set_hp(state["health"], state["max_health"])
    _hud.set_hunger(state["hunger"])
    for wound in state["wounds"]:
        if wound["treatment"] == "untreated":
            _hud.flash_bleed_warning(wound["body_part"])
```

---

## Combat

### `func damage_player(steam_id: int, amount: float) -> void`

Apply non-located damage (legacy path; routes to torso). Errors
logged.

### `func heal_player(steam_id: int, amount: float) -> void`

Heal the torso by `amount`. Clamped to `[0, max]`.

### `func damage_part(steam_id: int, part: String, amount: float) -> void`

Damage a specific body part. May spawn a `Bleed` wound above
threshold (light: 10–25 damage, heavy: ≥25).

| Arg | Type | Notes |
|---|---|---|
| `part` | `String` | One of `"head"`, `"torso"`, `"left_arm"`, `"right_arm"`, `"left_leg"`, `"right_leg"`. |
| `amount` | `float` | Positive HP to subtract. |

### `func heal_part(steam_id: int, part: String, amount: float) -> void`

Restore HP to a specific body part. Clamped.

### `func damage_npc_part(npc_id: int, part: String, amount: float) -> void`

Damage one of an NPC's body parts. Parallel to `damage_part` for
players. NPCs carry `BodyParts` (head / torso / limbs) just like
players; the aggregate `health` mirror is rederived as `min(head, torso)`
and `npc_death_check` fires when head or torso hits 0. Unknown part
names are logged and ignored. NPC wounds (bleed / infection /
treatment) are not spawned yet - that rides on a later slice.

| Arg | Type | Notes |
|---|---|---|
| `npc_id` | `int` | Stable `NpcId` (see `npcs_in_region` element `id` field). |
| `part` | `String` | One of `"head"`, `"torso"`, `"left_arm"`, `"right_arm"`, `"left_leg"`, `"right_leg"`. |
| `amount` | `float` | Positive HP to subtract. |

### `func heal_npc_part(npc_id: int, part: String, amount: float) -> void`

Restore HP to one of an NPC's body parts. Mirror of
`damage_npc_part`. Clamped to `[0, max]`.

### `func set_player_stamina(steam_id: int, value: f32) -> void`

Set stamina directly. Clamped to `[0, max]`.

---

## Wounds & medical

All wound-treatment methods are void-return with errors logged.
See the "Error handling" convention note in [the index](index.md).

### `func apply_bandage(steam_id: int, part: String) -> void`

Bandage a light bleed (sev ≤ 3) on `part`. Fails if the wound is
heavy (use `apply_tourniquet` or `apply_wound_pack` first) or if no
untreated wound exists there.

### `func apply_tourniquet(steam_id: int, part: String) -> void`

Stop bleed on any-severity wound. Starts the necrosis timer:
escalating damage after 1 in-world hour, severe after 2.

### `func remove_tourniquet(steam_id: int, part: String) -> void`

Release a tourniquet. Wound resumes bleeding until closed
(stitch + disinfect or wound_pack).

### `func apply_disinfectant(steam_id: int, part: String) -> void`

Move untreated Bleed wounds on `part` to `Disinfected`. Prevents
the infection trigger from firing.

### `func apply_stitch(steam_id: int, part: String) -> void`

Close bandaged / tourniqueted / wound-packed wounds. Halves the
heal-to-`Healed` timer.

### `func apply_wound_pack(steam_id: int, part: String) -> void`

Stop bleed on heavy wounds without the necrosis cost of a
tourniquet. Requires an item.

### `func apply_antibiotics(steam_id: int) -> void`

Clear infection on every infected wound over ~10 in-world minutes.
Spawns an `AntibioticsActive` effect while clearing.

### NPC treatment twins

Seven `#[func]` mirrors of the player treatment methods above. Each
takes `npc_id: int` (instead of `steam_id: int`) and targets the
NPC with the matching `NpcId` from `npcs_in_region`. Semantics, error
messages, and wound-state preconditions are identical to the player
versions; journals go through parallel `NpcWoundTreatmentChanged` /
`NpcEffectApplied` deltas so replay reproduces the same state.

- `func apply_bandage_npc(npc_id: int, part: String) -> void`
- `func apply_tourniquet_npc(npc_id: int, part: String) -> void`
- `func remove_tourniquet_npc(npc_id: int, part: String) -> void`
- `func apply_disinfectant_npc(npc_id: int, part: String) -> void`
- `func apply_stitch_npc(npc_id: int, part: String) -> void`
- `func apply_wound_pack_npc(npc_id: int, part: String) -> void`
- `func apply_antibiotics_npc(npc_id: int) -> void`

Host-authoritative only - unlike the player versions, these don't
fall back to `emit_action` for clients. NPC treatment flows through
the authoritative sim's direct call path; a future medic action
would use a dedicated `ActionKind` for client round-tripping.

---

## Drugs & consumption

### `func apply_drug(steam_id: int, drug: String) -> bool`

Apply a drug. Bumps tolerance; schedules crash-phase effects for
Stim / Adrenaline.

| Arg | Type | Notes |
|---|---|---|
| `drug` | `String` | One of `"painkiller"`, `"morphine"`, `"adrenaline"`, `"stim_cocktail"` (alias `"stim"`), `"anti_rad"` (alias `"antirad"`), `"anti_tox"` (alias `"antitox"`). |

**Returns:**
- `true` - drug applied normally.
- `false` - overdose. Player still gets the `OverdoseDisorientation`
  effect + tolerance bump; no second active dose of the target drug.

### `func eat(steam_id: int, kind: String) -> void`

Eat a food by kind.

| Arg | Type | Notes |
|---|---|---|
| `kind` | `String` | `"preserved_ration"` / `"fresh_food"` / `"raw_meat"` (tox cost) / `"cooked_meat"` / `"contaminated_food"` (rad+tox cost) / `"field_ration"` / `"energy_bar"`. |

Applies per-kind profile (hunger/thirst/fatigue delta + rad/tox
cost). See [mechanics/food-and-water.md](../mechanics/food-and-water.md).

### `func drink(steam_id: int, kind: String) -> void`

Drink by kind. `"dirty_water"` / `"clean_water"` / `"energy_drink"`
(spawns Stim effect) / `"vodka"` (reduces rad).

### `func consume_food(steam_id: int, hunger_delta: float, thirst_delta: float, fatigue_delta: float) -> void`

Raw meter delta. Adds then clamps to `[0, 100]`. Used by debug tools
and the old pre-inventory pathway.

---

## Survival stats

### `func set_survival_stat(steam_id: int, stat: String, value: float) -> void`

Set a meter directly. Clamped.

| Arg | Type | Notes |
|---|---|---|
| `stat` | `String` | `"hunger"` / `"thirst"` / `"fatigue"`. |

---

## Contamination

### `func set_radiation(steam_id: int, value: float) -> void`

Set radiation (`[0–100]`). Debug hook.

### `func set_toxicity(steam_id: int, value: float) -> void`

Set toxicity (`[0–100]`). Debug hook.

---

## Inventory

### `func grant_item(steam_id: int, item_id: String, count: int) -> bool`

Add `count` of `item_id` to the player's inventory. Merges into
existing stacks up to `def.stack_size`; perishables don't age-mix.

**Returns:** `false` on unknown player / item / non-positive count.

### `func drop_slot(steam_id: int, slot_idx: int) -> bool`

Remove slot `slot_idx` from pockets and drop the stack into a
private [`WorldContainer`](#world-containers--looting) at the
player's feet. If a personal ground container exists within 1.5 m
the stack merges into it; otherwise a new 4×4 pile spawns.

**Returns:** `false` on invalid slot.

### `func move_slot(steam_id: int, from_slot: int, to_slot: int) -> bool`

Swap two slots within the pockets grid.

### `func move_between_grids(steam_id: int, from_grid: String, from_idx: int, to_grid: String) -> bool`

Move the item at `(from_grid, from_idx)` into `to_grid` at the first
free spot. Both grid strings follow the equip convention -
`"pockets"` or `"equipped:<slot_id>"`. The item's `inner_grid`
(loaded backpack, magazine with rounds + variant) travels with it.

| Arg | Type | Notes |
|---|---|---|
| `from_grid` | `String` | `"pockets"` or `"equipped:<slot_id>"`. |
| `from_idx` | `int` | Items-array index inside `from_grid`. |
| `to_grid` | `String` | Same string form. **Must differ from `from_grid`** - use `move_slot` for in-pocket swaps. |

**Returns:** `false` on same-grid call, source out of range, dest
not found, or no first-fit position. On placement failure the item
is restored to its source grid - nothing leaks.

Journals `WorldDelta::ItemMovedBetweenGrids` with the resolved
`to_idx` plus the item state for client mirrors to replay.

### `func consume_slot(steam_id: int, slot_idx: int, body_part: String) -> bool`

Use an item. Routes to `eat` / `drink` / `apply_drug` /
`apply_bandage` / … based on the item's `consume_action`.

| Arg | Type | Notes |
|---|---|---|
| `body_part` | `String` | **Required** for wound-treatment items (bandage/tourniquet/disinfect/stitch/wound_pack). **Empty string `""`** for food/drink/drugs/antibiotics. |

**Returns:** `false` if the underlying action errored (e.g., no
wound to bandage). Item is NOT consumed on error - player can retry.

### `func salvage_slot(steam_id: int, slot_idx: int) -> bool`

Break down a junk item into components. Requires the recipe's
`tool_required` elsewhere in the inventory. Rolls deterministic
outputs via ChaCha8 seeded on `(tick, slot_idx)`.

### `func craft_recipe(steam_id: int, recipe_id: String) -> bool`

Craft a recipe. Consumes inputs FIFO; mints outputs with
`spawned_tick = now`.

| Arg | Type | Notes |
|---|---|---|
| `recipe_id` | `String` | From `recipes.toml`. Slice-1 ships only `"cook_meat"`. |

### `func set_near_campfire(steam_id: int, value: bool) -> bool`

Toggle the debug "near campfire" context flag. Required for
`cook_meat`. The Step 5 UI slice replaces this setter with real
scene-placed campfire entities + a proximity system - the
`required_context` field on recipes survives that transition
unchanged, so this `#[func]` is the long-term API as far as
GDScript is concerned.

### `func item_catalog() -> Array`

Every item the sim knows about. Stable across the session.

**Array element dict:**

| Key | Type | Notes |
|---|---|---|
| `id` | `String` | Item id. |
| `name` | `String` | Display name. |
| `category` | `String` | See `inventory` dict table above. |
| `weight` | `float` | kg. |
| `stack_size` | `int` | Max stack. |
| `perishable_ticks` | `int` | Shelf life in ticks, `0` if non-perishable. |

### `func recipe_catalog() -> Array`

Every recipe the sim knows about, with the metadata a recipe
browser needs to render a row without poking back into the sim
per-recipe. Stable across the session.

**Array element dict:**

| Key | Type | Notes |
|---|---|---|
| `id` | `String` | Recipe id (use with `queue_craft` / `can_craft`). |
| `name` | `String` | Display name. |
| `time_ticks` | `int` | Duration per unit. 20 ticks = 1 real-world second. |
| `required_tool` | `String` | Exact item id, or `""` when none. |
| `required_kit` | `Dictionary` \| `null` | `{ specialty, min_tier }`, or `null` when no kit needed. |
| `required_context` | `String` | Station tag (`"campfire"` / `"basic_bench"` / `"advanced_bench"` / `"expert_bench"`), or `""` when none. |
| `inputs` | `Array[Dictionary]` | Each `{ id: String, count: int }`. |
| `outputs` | `Array[Dictionary]` | Each `{ id: String, count: int }`. |

### `func can_craft(steam_id: int, recipe_id: String) -> Dictionary`

Per-player craftability check. Drives the recipe-browser "Requires:"
line and gates the Queue button. Returns the report's `ok=false`
default for an unknown player or recipe.

| Key | Type | Notes |
|---|---|---|
| `ok` | `bool` | `true` ⇔ every other field is satisfied. |
| `inputs` | `Array[Dictionary]` | One `{ id, need, have }` per recipe input. |
| `missing_tool` | `String` | Exact item id missing, or `""` when satisfied. |
| `missing_kit` | `Dictionary` \| `null` | `{ specialty, min_tier }` of the unmet kit, or `null`. |
| `wrong_station` | `String` | Required station tag if not standing at it, else `""`. |

### `func queue_craft(steam_id: int, recipe_id: String, count: int) -> int`

Queue `count` units of `recipe_id` on the player's crafting queue.
Materials lock up front. Per-unit completions land deterministically
each tick; only `CraftJobQueued` / `CraftJobCancelled` deltas travel
on the wire.

**Returns:** the new job id (positive `int`) on success. **`-1`** on
validation / unknown player / unknown recipe / `count <= 0`. Client
path returns `0` and dispatches a `QueueCraft` action - the host's
canonical job id arrives via the next snapshot / `CraftJobQueued`
delta.

### `func cancel_craft(steam_id: int, job_id: int) -> bool`

Cancel a queued job by id. Refunds materials for unstarted units;
the in-progress unit (if any) is forfeit.

**Returns:** `false` on unknown player / unknown job. Client path
returns `true` and dispatches a `CancelCraft` action; the canonical
refund arrives via the next `CraftJobCancelled` delta.

### `func set_near_workbench(steam_id: int, tier_str: String) -> bool`

Set the workbench-tier proximity flag. Mirrors `set_near_campfire`
for the cumulative bench tiers (basic ⊂ advanced ⊂ expert satisfies
recipe `required_context` checks). Slice B's debug setter - the
production proximity system driven by scene-placed workbench
entities lands later.

| Arg | Type | Notes |
|---|---|---|
| `tier_str` | `String` | `""` / `"none"` (clear), or `"basic"` / `"advanced"` / `"expert"`. |

**Returns:** `false` on unknown tier string or unknown player.

### `player_state` Step-5 additions

The dict returned by `player_state(sid)` carries two new fields as of
Slice B:

| Key | Type | Notes |
|---|---|---|
| `near_workbench` | `String` | Tier tag (`""` / `"basic"` / `"advanced"` / `"expert"`). |
| `crafting_queue` | `Array[Dictionary]` | Active crafting jobs. Empty when not crafting. |

**`crafting_queue` element dict:**

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | Stable job id. Use with `cancel_craft`. |
| `recipe_id` | `String` | Recipe id this job runs. |
| `count_remaining` | `int` | Units left, including the head (in-progress) one. |
| `ticks_remaining` | `int` | Ticks until the next unit lands. Reset to `recipe.time_ticks` after each unit. |
| `started_tick` | `int` | Tick the job was queued. |

### `player_state` equipment additions (PR-3 of the inventory rewrite)

`player_state(sid)` adds one more key:

| Key | Type | Notes |
|---|---|---|
| `equipment` | `Dictionary` | Keyed by slot id (`"head"`, `"rig"`, `"belt_1"`, …). Values are `EquippedItem` dicts (see below). Empty dict when nothing is equipped. |

**`equipment` value dict** (one per equipped slot):

| Key | Type | Notes |
|---|---|---|
| `id` | `String` | Item id. |
| `name` | `String` | Display name. |
| `category` | `String` | Item category (see `inventory` dict). |
| `count` | `int` | Stack size. |
| `spawned_tick` | `int` | Tick the stack was minted. |
| `inner_grid` | `Dictionary \| null` | Nested container grid when the equipped item is a rig / backpack / pouch; `null` otherwise. Shape: `{ width: int, height: int, items: Array[Dictionary] }`. `items` uses the same schema as the top-level `inventory` array. |

### `func equipment_slot_catalog() -> Array`

Paper-doll slot registry. Stable across the session; the UI pulls
this once when opening the panel.

**Array element dict:**

| Key | Type | Notes |
|---|---|---|
| `id` | `String` | Slot id (`"head"`, `"backpack"`, `"belt_1"`, `"pockets"`, …). |
| `label` | `String` | Display name. |
| `accepts` | `Array[String]` | Item-category whitelist (e.g. `["head_gear"]`, `["medical", "drug", "food", "drink"]`). Empty for virtual slots (`pockets`) or whitelist-only slots (`secure_pocket`). |
| `position` | `Vector2i` | Paper-doll grid coordinate for UI layout. |
| `size` | `Vector2i` | Paper-doll cell footprint (`w` × `h`). Default `(1, 1)`; wider for primary weapons (`4×1`) / armor vests (`2×2`) / backpacks (`1×4`). The UI multiplies the doll cell size by this to render each slot panel. |
| `is_hotbar` | `bool` | True for belt slots bound to number keys. |
| `hotbar_index` | `int` | 1-based when `is_hotbar`; `0` otherwise. |

### `func equip(steam_id: int, slot_id: String, source_grid: String, source_idx: int) -> bool`

Move the item at `(source_grid, source_idx)` onto the paper-doll slot.

| Arg | Type | Notes |
|---|---|---|
| `slot_id` | `String` | Must match a row from `equipment_slot_catalog()`. |
| `source_grid` | `String` | `"pockets"` for the player's base grid, or `"equipped:<slot_id>"` for a nested container. |
| `source_idx` | `int` | Index into that grid's items array. |

**Returns:** `false` if the slot is unknown, the slot is already
occupied, the item's category isn't accepted, or the source grid /
index is invalid. Client path dispatches an `Equip` action - the
canonical move lands on the next tick.

### `func unequip(steam_id: int, slot_id: String, dest_grid: String) -> bool`

Pull the item at `slot_id` off the paper doll into `dest_grid`. The
item's inner grid (if it's a container) travels with it.

**Returns:** `false` if the slot is empty or the destination grid
has no free footprint.

### `func consume_hotbar(steam_id: int, hotbar_idx: int, body_part: String) -> bool`

Fire the belt slot bound to `hotbar_idx` (1-based). Routes through
the underlying `consume_action` (eat / drink / apply_drug /
apply_bandage / …).

| Arg | Type | Notes |
|---|---|---|
| `hotbar_idx` | `int` | `1..=N` - see `equipment_slot_catalog()`. |
| `body_part` | `String` | `""` for non-treatment items; limb name for wound treatments. Default torso works for the common case. |

**Returns:** `false` on unknown index, empty slot, or underlying
consume-action error (e.g. "no wound to bandage"). The item is not
consumed on error.

---

## World containers & looting

`WorldContainer` is the unified entity for ground drops, scene-placed
crates, and NPC corpses. Containers are addressed by `int` ids
(stable across save/load, region-scoped queries). The unified
inventory panel (`scenes/menus/inventory.tscn`, opened via
`InventoryPanel.open_for_container(id)` as of Phase 3E) uses these
`#[func]`s for everything the player sees; the standalone
`scenes/menus/loot_panel.tscn` is no longer in the loop and is
slated for removal once any lingering references shake out. See
[mechanics/inventory.md - Dropping & ground containers](../mechanics/inventory.md#dropping--ground-containers)
and [mechanics/npcs-and-combat.md - Loadouts & corpse loot](../mechanics/npcs-and-combat.md#loadouts--corpse-loot)
for the player-facing contract.

### `func containers_in_range(steam_id: int, radius_m: float) -> Array[Dictionary]`

Every world container in the player's region within `radius_m`
(XZ distance). Used by the looting HUD to find the nearest
interactable.

**Returns:** Each entry: `{ id: int, pos: Vector3, is_public: bool }`.
Empty array if the player is unknown or no containers are in range.

### `func container_view(container_id: int) -> Dictionary`

Snapshot a container's grid for rendering. Same shape as
`player_state.inventory` so the same grid renderer covers both.

**Returns:** `{ width: int, height: int, items: Array[Dictionary] }`.
Each `item` carries `id, name, count, category, x, y, w, h, rotation`.
Empty `{ width: 0, height: 0, items: [] }` if the container id is
unknown.

### `func take_from_container(steam_id: int, container_id: int, source_idx: int) -> bool`

Pull the item at `source_idx` out of the container into the
player's pockets. Routes through the action queue on clients
(host validates fit). On client, returns immediately with `true`
once the action is queued.

**Returns:** `false` on unknown container, idx out of range, pockets
full, or unknown player.

### `func put_in_container(steam_id: int, container_id: int, source_grid: String, source_idx: int) -> bool`

Push the item at `(source_grid, source_idx)` from the player into
the container.

| Arg | Type | Notes |
|---|---|---|
| `source_grid` | `String` | `"pockets"` or `"equipped:<slot_id>"` for a nested-container source (rig/backpack inner grid). |

**Returns:** `false` on unknown container, missing source,
container full, or unknown player.

### `func spawn_world_container(region_name: String, pos: Vector3, width: int, height: int, is_public: bool) -> int`

Spawn a container at `pos` in `region_name`. **Host-only** -
clients cannot mint containers; this method returns `-1` if called
from a client (the journal write only happens on the host).

| Arg | Type | Notes |
|---|---|---|
| `is_public` | `bool` | `true` = contents count toward the crafting kit-pool (parts bins, shared bench crates). `false` = ground drops, player stashes, NPC corpses - visible / takeable but never auto-satisfy crafting. |

**Returns:** The new container id, or `-1` on failure (unknown
region, non-positive size, client-only call). Used by region map
scenes to place authored loot crates.

### `func register_authored_container(region_name: String, pos: Vector3, kind_id: String, is_public: bool, container_id_str: String, faction: String, depth_tier: int, interaction_mode: String) -> int`

Phase 3D — register a hand-placed `LootContainerMarker3D`. Resolves
the kind's grid from `LootContainerRegistry`, rolls eager initial
contents from `LootPoolRegistry`, and stamps `interaction_mode` onto
the resulting `WorldContainer`. **Host-only**; returns `-1` on
client calls (the journal write only happens on the host).

| Arg | Type | Notes |
|---|---|---|
| `region_name` | `String` | Map id (`"map_a"`, `"corbett"`, etc.). Resolves to a `RegionId` via the cached region graph. |
| `pos` | `Vector3` | World-space anchor (Y typically snapped to terrain by the GDScript walker before the call). |
| `kind_id` | `String` | `"small_crate"` / `"medium_stash"` / `"large_cache"` — must match an entry in `loot_containers.toml`. |
| `is_public` | `bool` | Kit-pool participation, same semantics as `spawn_world_container`. |
| `container_id_str` | `String` | Marker's stable id. Hashed into the roll RNG so same-marker rolls the same contents across reloads of the same save. Empty string falls back to a non-deterministic `(tick, kind_id)` mix. |
| `faction` | `String` | Owning faction for restock + loot flavor. Empty = `"wanderers"` neutral fallback (still produces plausible scavenger loot via the pool fallback chain). |
| `depth_tier` | `int` | 1 / 2 / 3. Clamped to `1..=255` on the bridge; 1 is the only authored tier today. |
| `interaction_mode` | `String` | `"openable"` (default) or `"breakable"`. Breakable is data-only — the field flows onto the spawned component, but HP / damage routing / destruction → ground pile is a future slice. |

**Returns:** The new container id, or `-1` on failure (unknown
kind id, unknown region, client-only call). Called by
`godot/scripts/world/loot_container_spawner.gd` from each map
scene's `_on_terrain_ready` hook.
---

## Weapons (Phase 1)

All weapon stats (caliber, damage, range, fire rate, spread, magazine
capacity) live in `items.toml` under the `weapon_config` /
`magazine_config` / `ammo_config` blocks. The bridge never supplies
defaults - a weapon without a `weapon_config` block can't fire, a
magazine without a `magazine_config` block can't be loaded.

**Phase 2 upgrade** (landed): fire is now host-authoritative -
`fire_weapon` takes an aim direction, spawns a `Projectile` ECS
entity, and resolves hit + damage sim-side against per-body-part
humanoid hitboxes. Round variants (HP / FMJ / AP per caliber) and
armor items with `protection_class` feed the penetration formula;
see `docs/book/src/mechanics/weapons.md` for the player-facing
damage table. Attachments + weapon parts condition remain
deferred.

### `func reload_weapon(steam_id: int, slot_id: String) -> bool`

Reload the weapon equipped at `slot_id` (expected values:
`"primary"`, `"secondary"`, `"sidearm"`). Finds the best-loaded
matching-caliber magazine in the player's pockets, installs it,
and returns any previously-loaded magazine to pockets with its
`loaded_rounds` preserved.

| Arg | Type | Notes |
|---|---|---|
| `slot_id` | `String` | Equipment slot id. Must hold a weapon. |

**Returns:** `false` on unknown player, empty slot, non-weapon item,
or no matching magazine. Client path emits a `ReloadWeapon` action
and returns `true`; state changes land via the host's
`WeaponReloaded` delta.

### `func eject_magazine(steam_id: int, slot_id: String) -> bool`

Remove the currently-loaded magazine from the weapon at `slot_id`
and place it back in pockets. Preserves `loaded_rounds`. Leaves the
weapon with `loaded_magazine = None` (dry-fire state).

**Returns:** `false` on unknown player or non-weapon slot; no-op on
a weapon with no mag loaded. Client path emits an `EjectMagazine`
action.

### `func fire_weapon(steam_id: int, slot_id: String, aim_yaw: float, aim_pitch: float) -> Dictionary`

Fire the weapon at `slot_id` toward `(aim_yaw, aim_pitch)` (both
radians, Godot convention: `+Z` is forward, `+Y` is up). The sim:

1. Decrements the loaded magazine.
2. Spawns a `Projectile` entity at the muzzle + journals
   `WeaponFired` (for HUD) and `ProjectileSpawned` (for client
   tracer FX).
3. The projectile ticks with gravity + drag each frame and
   eventually lands, emitting `ProjectileImpacted`.

**Returns a dict:**

| Key | Type | Notes |
|---|---|---|
| `ok` | `bool` | `false` on dry-click (no-mag, empty-mag, no-variant) / unknown slot / non-weapon. |
| `error` | `String` | anyhow error text on failure; `""` on success. |
| `remaining_rounds` | `int` | Post-fire magazine count; `0` on failure. |

Phase 1's `weapon_config` return field is **gone** - hit
resolution is sim-side, the client doesn't raycast. Tracer + hit
FX ride the `projectile_spawned` / `projectile_impacted` signals.

Client path emits a `FireWeapon` action (yaw + pitch included)
and returns `ok=true`. Dry-click reasons surface through the
action handler on host, not here.

### `func load_rounds(steam_id: int, slot_id: String, round_id: String) -> int`

Top up the magazine loaded at `slot_id` from pocket ammo stacks
of `round_id`. Returns the number of rounds actually loaded.
`-1` on hard error (caliber mismatch, variant flip rejection,
unknown slot, unknown round).

Rules:
- Ammo's `caliber` must match the mag's `caliber`.
- Partial mag with variant X rejects loading variant Y (real-gun
  model; fire out or eject first).
- Stops at `magazine_config.capacity`; excess rounds stay in
  pockets.

Client path emits a `LoadRoundsIntoMag` action and returns `0`;
the host's `MagazineLoaded` delta rebroadcasts the canonical
result.

### `func load_rounds_into_pocket(steam_id: int, pocket_idx: int, round_id: String) -> int`

Top up a magazine sitting at `pocket_idx` in the player's
pockets grid from matching-caliber pocket ammo stacks. The
inventory panel's per-magazine "▲ LOAD" action calls this -
it's the player-facing entry point for ammo-loading (as opposed
to `load_rounds`, which is the equipped-weapon path).

Same validation rules as `load_rounds` (shared
`validate_mag_load` under the hood). `-1` on out-of-range
`pocket_idx` or hard error; `0` on no-op (mag full or pockets
empty of matching ammo); positive integer = rounds loaded.

Client path emits a `LoadRoundsIntoPocketMag` action and
returns `0`; host's `PocketMagazineLoaded` delta rebroadcasts.

### `player_state.inventory` - magazine state fields

The inventory dict (returned as part of `player_state` and
used by `scripts/menus/inventory_panel.gd`) grows four
magazine-specific fields so the renderer can show `AP 24/30`
overlays and filter the "Load" menu to matching-caliber ammo
without extra bridge calls:

| Key | Type | Notes |
|---|---|---|
| `caliber` | `String` | Magazine's caliber tag; `""` on non-magazines. |
| `magazine_capacity` | `int` | `magazine_config.capacity`; `0` on non-magazines. |
| `loaded_rounds` | `int` | Runtime loaded count; `0` if unset. |
| `loaded_variant` | `String` | Ammo item id currently loaded (`"round_5_45x39_ap"`); `""` if mag is unloaded or item isn't a magazine. |

### `player_state.equipped_weapons`

`player_state(sid)` returns an `equipped_weapons` sub-dict keyed
by weapon slot id (`"primary"` / `"secondary"` / `"sidearm"`).
Each value is either `null` (slot empty or item isn't a weapon)
or:

| Key | Type | Notes |
|---|---|---|
| `item_id` | `String` | TOML id, e.g. `"rifle_aks74"`. |
| `name` | `String` | Display name from `items.toml`. |
| `caliber` | `String` | Weapon caliber tag. |
| `damage` | `float` | Per-round damage. |
| `range_m` | `float` | Max projectile range before despawn. |
| `fire_interval_s` | `float` | Cooldown between shots. |
| `spread_deg` | `float` | Reserved (Phase 3 attachment stat). |
| `loaded_rounds` | `int` | Current magazine count; `0` if no mag loaded. |
| `magazine_capacity` | `int` | Loaded mag's `magazine_config.capacity`; `0` if no mag. |
| `has_magazine` | `bool` | `true` iff a magazine is installed. |
| `loaded_variant` | `String` | Ammo id in the loaded mag (`"round_5_45x39_ap"`); `""` if no mag or no variant set yet. |

HUD readers branch on `has_magazine` and `loaded_variant` to
render `<name>  <VARIANT_TAG> <loaded>/<capacity>` (or
`<name>  -/-` / `[ NO WEAPON IN SLOT ]`).

---

## World state

### `func world_time() -> Dictionary`

In-world clock. Empty dict if sim isn't started.

| Key | Type | Notes |
|---|---|---|
| `day` | `int` | In-world day counter (0-indexed). |
| `seconds_of_day` | `float` | Seconds into current day. |
| `day_length_seconds` | `float` | Default `7200.0` (12× real compression). |
| `sun_angle_rad` | `float` | Sun elevation. Positive = daytime. |
| `is_daytime` | `bool` | Convenience = `sun_angle_rad > 0`. |
| `moon_phase` | `float` | `[0, 1)`; `0` = new, `0.5` = full. |
| `moon_illumination` | `float` | `[0, 1]`; cosine of `moon_phase`. |
| `moon_angle_rad` | `float` | Moon elevation. |
| `moon_phase_name` | `String` | One of `"new"`, `"waxing crescent"`, `"first quarter"`, `"waxing gibbous"`, `"full"`, `"waning gibbous"`, `"last quarter"`, `"waning crescent"`. |

### `func set_time_of_day(hour: int, minute: int) -> void`

Set the in-world clock. `hour` `0-23`, `minute` `0-59`.

### `func advance_time(hours: float) -> void`

Advance in-world clock by `hours` (fractional OK).

### `func weather_state() -> Dictionary`

Current weather + pending transition.

| Key | Type | Notes |
|---|---|---|
| `current` | `String` | Current weather tag. |
| `next` | `String` | Weather after next transition. |
| `transitions_at_tick` | `int` | Tick at which `current` → `next`. |

### `func set_weather(name: String) -> void`

Force the current weather. Unknown names logged + skipped. Use
`all_weather_types()` to enumerate.

### `func cycle_weather() -> String`

Advance to the next weather type (debug). Returns the new weather
name.

### `func all_weather_types() -> Array`

Array of valid weather names in order. See [index](index.md) for
the full list.

### `func all_factions() -> Array`

Array of valid faction names. See [index](index.md).

### `func all_regions() -> Array`

Array of region names in the current sim's `RegionGraph`.

### `func region_control(region_name: String) -> Dictionary`

Per-region faction control state. Empty dict for unknown region.

| Key | Type | Notes |
|---|---|---|
| `primary` | `String` | Primary controlling faction (empty string if uncontested). |
| `contested_by` | `Array[String]` | Factions actively present. |
| `tension` | `float` | `[0, 1]`; `0` stable, `1` open conflict. |

### `func bases_in_region(region_name: String) -> Array`

All bases in a region.

**Element dict:**

| Key | Type | Notes |
|---|---|---|
| `kind` | `String` | `"checkpoint"` / `"outpost"` / `"safehouse"` / `"headquarters"` / `"research_post"` / `"campsite"`. |
| `faction` | `String` | Owning faction. |
| `pos` | `Vector3` | World position. |
| `health` | `float` | Current HP. |
| `max_health` | `float` | Max HP. |

### `func faction_relation(a: String, b: String) -> String`

Relation between two factions.

**Returns:** `"hostile"` / `"cold"` / `"detente"` / `"warm"` /
`"neutral"`; empty string if either faction unknown.

### `func set_population_target(region_name: String, faction_name: String, count: int) -> void`

Override per-(region, faction) target NPC count. Clamped to ≥ 0.

### `func scale_population(factor: float) -> void`

Multiply every population target by `factor` (e.g., `2.0` doubles,
`0.5` halves). Used by the F10 density preset.

---

## NPCs & chronicle

### `func npcs_in_region(region_name: String) -> Array`

Live NPCs currently in a region. See element dict in
[`SimHost`](#example-gdscript-1) below or in
`crates/simn-godot/src/sim/conversions.rs::npc_view_to_dict` for
the canonical schema.

**Performance note.** This call marshals *every* NPC in the region
into a heavy `Dictionary` (~15 keys per NPC, plus nested
`body_parts` + `wounds`). At full population that's tens of
thousands of `Variant` allocations per call — fine for one-off
inspector queries, ruinous on a 20 Hz dummy-sync poll. Use
[`npcs_near`](#func-npcs_nearregion_name-string-player_pos-vector3-max_dist_m-float---array)
for the per-tick renderer path instead.

**Element dict:**

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | Stable `NpcId`. |
| `faction` | `String` | Faction tag. |
| `pos` | `Vector3` | World position. |
| `yaw` | `float` | Y-rotation. |
| `health` | `float` | Current aggregate HP (`min(head, torso)`). |
| `max_health` | `float` | Max HP. |
| `body_parts` | `Dictionary` | Per-part current HP: keys `"head"`, `"torso"`, `"left_arm"`, `"right_arm"`, `"left_leg"`, `"right_leg"`, each `float`. Omitted only for NPCs loaded from pre-migration snapshots that haven't re-spawned. |
| `wounds` | `Array<Dictionary>` | Active wounds on the NPC. Same per-element schema as `player_state["wounds"]` (`id`, `body_part`, `kind`, `severity`, `treatment`, `spawned_tick`, `infected`). Empty array for uninjured NPCs. |
| `goal` | `String` | One of: `"idle"` / `"move"` / `"rest"` / `"pursue"` / `"patrol"` / `"guard"` / `"guard_post"` / `"explore"` / `"relieve"` / `"investigate"` / `"wander"` / `"regroup"` / `"hunt"` / `"socialize"` / `"loot"` / `"bloodsport"` / `"seek_medical"` / `"investigate_at"` / `"regroup_on_ally"`. The first batch are squad-objective / FSM tags; the second batch (`hunt`..`regroup_on_ally`) come from `ActiveGoal.kind` overrides — personality drives, individual survival, blackboard urgency — and take precedence over the squad objective when present. |
| `group_id` | `int` | Squad id; `0` for solo NPCs. |
| `aggro_target` | `int` | Target `NpcId` if in combat; `0` otherwise. |
| `name` | `String` | Procedural display name (`"First Last"`); empty for NPCs loaded from pre-migration snapshots. |
| `nationality` | `String` | snake_case nationality bucket tag (e.g. `"american"`, `"slavic"`); empty for legacy NPCs. |
| `rank` | `String` | Rank tier label (`"Rookie"` / `"Experienced"` / `"Veteran"` / `"Master"` / `"Legend"`); empty for legacy NPCs. |
| `combat_stance` | `String` | Current tactical stance when in combat: `"approaching"` / `"in_cover"` / `"firing"` / `"suppressed"` / `"flanking"` / `"retreating"`. Empty string when not in a combat stance. |
| `combat_role` | `String` | Squad-assigned combat role: `"pointman"` / `"support"` / `"flanker"` / `"medic"`. Empty when not assigned. |
| `dwell_pose` | `String` | Renderer-side animation hint while the NPC is dwelling at a Rest/Guard objective: `"standing"` / `"sitting"` / `"crouching"`. Empty string when the NPC isn't dwelling (movement / idle / combat) so the renderer falls back to default locomotion. |
| `goal_source` | `String` | Tag for the arbiter source that selected the current `ActiveGoal`: `"scripted"` / `"survival"` / `"aggro_squad"` / `"aggro_solo"` / `"blackboard"` / `"squad_obj"` / `"personality"` / `"idle"`. Lets debug HUDs distinguish "this NPC is on-task" from "this NPC is reacting to a distraction." |
| `goal_priority` | `int` | Numeric priority of the current `ActiveGoal` (`0..=255`). Useful for debugging arbitration ties — see `PRIO_*` constants in `goal_arbitration.rs`. |

### `func npcs_near(region_name: String, player_pos: Vector3, max_dist_m: float) -> Array`

NPCs within `max_dist_m` (XZ-plane squared distance) of
`player_pos` in `region_name`. Same per-element dict schema as
[`npcs_in_region`](#func-npcs_in_regionregion_name-string---array)
above. The distance filter runs server-side *before* `NpcView`
construction, so the per-NPC clones (`wounds`, `name`) and the
gdext `Dictionary` marshaling cost are paid only for NPCs the
player can actually see.

Empty array if the region tag is unknown, the sim isn't ready,
or no NPCs are within range. Use this for any 20 Hz polling path
(e.g. dummy sync in `game_session.gd::_sync_npc_dummies`); reserve
`npcs_in_region` for inspector / debug overlays that legitimately
want every NPC.

### `func has_snapshot_pair() -> bool`

Threaded-sim PR A scaffold (2026-05-11). Returns `true` once the
sim has published at least two ticks — the renderer can read the
`(prev, curr)` snapshot pair and start interpolating between
consecutive sim states for frame-rate-independent visuals.

Returns `false` on fresh sims (one tick or fewer have run) and on
mirror sims whose snapshot ring hasn't filled yet. The renderer
checks this before switching from the 20 Hz `npcs_near` polling
path to the per-frame snapshot-pair lerp.

See `docs/book/src/planning/threaded-sim-plan.md` §4 for the
snapshot contract.

### `func snapshot_current_tick() -> int`

Sim tick number of the most recently published snapshot, or `-1`
if no snapshot has been published yet. Useful for GDScript-side
diagnostics — confirms snapshots are advancing at the sim's tick
rate (20 Hz).

### `func snapshot_interp_npcs_near(region_name: String, player_pos: Vector3, max_dist_m: float) -> Dictionary`

Threaded-sim PR B (2026-05-11). Hot-path render lerp. Computes
interpolated poses for every active-region NPC within `max_dist_m`
of `player_pos` by lerping the `(prev, curr)` snapshot pair at
`alpha = (now - prev.published_at) / (curr.published_at -
prev.published_at)`, clamped to `[0, 1]` (no extrapolation). Yaw
uses shortest-path wrap. NPCs in `curr` but not `prev` (fresh
spawns) are emitted at `curr` pose with no interp; NPCs only in
`prev` (despawned) are omitted.

Returns an empty `Dictionary` if `has_snapshot_pair()` is `false`
(< 2 ticks published) or the region isn't loaded. Otherwise three
parallel arrays:

| Key | Type | Notes |
|---|---|---|
| `ids` | `PackedInt64Array` | `NpcId` per visible NPC, sorted ascending. |
| `positions` | `PackedVector3Array` | Interpolated world-space position, in `ids` order. |
| `yaws` | `PackedFloat32Array` | Interpolated yaw (radians, shortest-arc), in `ids` order. |

Called every frame from `game_session.gd::_lerp_npc_dummies`,
which writes `global_position` + `rotation.y` directly onto each
matching `HumanoidDummy`. The dummy's own per-frame smoothing is
a no-op now that this path is authoritative; `set_state` still
updates labels / faction colors / body-part HP at the 20 Hz
roster sync.

### `func chronicle_summary() -> Dictionary`

Every NPC that ever lived, aggregated.

| Key | Type | Notes |
|---|---|---|
| `total_ever_spawned` | `int` | Cumulative count across save lifetime. |
| `currently_alive` | `int` | Live count right now. |
| `by_faction` | `Dictionary` | Keys: faction names; values: `{ alive: int, dead: int }`. |

### `func recent_deaths(limit: int) -> Array`

Newest `limit` deaths from the chronicle.

**Element dict:**

| Key | Type | Notes |
|---|---|---|
| `id` | `int` | `NpcId`. |
| `faction` | `String` | Faction. |
| `birth_tick` | `int` | |
| `death_tick` | `int` | |
| `birth_region` | `String` | Region name. |
| `death_region` | `String` | Region name (empty if unknown). |
| `cause` | `String` | Death-cause enum string. |

### `func recent_pda_events_since(since_seq: int) -> Array`

Offline-tier PDA event feed (Phase 1F). Returns events with
`seq > since_seq`, oldest first. Client tracks its own
`last_seen_seq` bookmark; on first poll passes `0` to get
everything since boot, or `pda_log_high_water()` to skip events
that landed before joining.

**Per-event keys (always present):**

| Key | Type | Notes |
|---|---|---|
| `seq` | `int` | Monotonic sequence. Use to advance bookmark. |
| `tick` | `int` | Sim tick the event landed at. |
| `kind` | `String` | `"OfflineCombatDeath"` / `"OfflineGunfire"` / `"BaseFlip"`. |
| `region` | `String` | Region name (always present). |

**Kind-specific extras:**

| Kind | Extra keys |
|---|---|
| `OfflineCombatDeath` | `killed_faction: String`, `killer_faction: String` |
| `OfflineGunfire` | (none) — one entry per region per offline tick |
| `BaseFlip` | `new_owner: String`, `old_owner: String` (empty if unknown) |

### `func pda_log_high_water() -> int`

Highest seq currently in the PDA event log. `0` if no events
have landed yet. Clients seed their bookmark from this on
`_ready` so events that pre-date the player joining don't all
toast at once.

---

## Regions

### `func region_map_scene(region_name: String) -> String`

Scene file path for a region (e.g., `"map_a"` → `"res://scenes/test/test_map_1.tscn"`). Empty string for unknown region.

### `func region_transitions(region_name: String) -> Dictionary`

Portal positions for a region.

**Returns:** keys are neighboring region names; values are
`Vector3` positions. Empty dict for unknown region.

### `func load_region_terrain(region_name: String, map_id: String) -> void`

Load + attach a canonical heightmap so NPC Y-snapping follows
terrain. `map_id` resolves `res://assets/terrain/<map_id>/`. Side
effect: also builds the region's nav grid (used by `path_in_region`
below) plus its sparse `WaypointGraph` (used by the offline tier).

### `func load_region_terrain_with_obstacles(region_name: String, map_id: String, obstacles: Array) -> void`

Iteration 5-13 Phase B2. Variant of `load_region_terrain` that
also stamps a list of scene-authored AABBs into the freshly built
nav grid. The Godot caller (`real_map.gd` / `test_map.gd`) walks
the group `&"nav_obstacle_markers"` and feeds the per-marker dict
list here. Each dict carries:

- `pos: Vector3` — world-space center (Y ignored).
- `extents: Vector3` — XZ half-size (Y ignored).
- `kind: String` — `"block"` (default) or `"walkable"`. Unknown
  values fall back to `"block"` with a single warn per call.

Merge contract: painted `ForceWalkable` cells win over a POI
`"block"` (painter trumps obstacle). Idempotent per region —
calling again with a new obstacle list replaces the previous
set.

### `func tick_perf() -> Dictionary`

Rolling per-segment tick-perf report (~last 10 s at 20 Hz, 200
samples). Returns `avg_*` and `p99_*` ms-per-tick across these
groups:

- `total` — full `Sim::tick`.
- `player` — clock + survival + meds + wounds + crafting.
- `npc_perception` — sum of the three sub-groups below.
  - `npc_index` — position index, spatial hash rebuild, world-
    event drain, LOS-cache clear, blackboard sweep. Further
    broken down per-system via `clear_los`, `sweep_bb`,
    `position_index`, `drain_events`, `spatial_hash`.
  - `npc_threats` — `sweep_threats`.
  - `npc_aggro` — `npc_aggro` (parallel pair-scan) + threat
    priority apply.
- `npc_planning` — squad planner + goal arbitration + pathfind +
  combat resolution.
- `npc_lifecycle` — kill credits + death + age + spawn + clamp Y
  + broadcast.
- `offline_loot` — offline-tier heartbeat + loot restock.
- `event_count` — `avg_event_count` and `max_event_count` of
  `WorldEventQueue` drains. Useful diagnostic for the
  `drain_world_events` cost; high counts signal aggressive
  re-acquisition broadcasts and should drop after the squad
  blackboard saturates.

All zeros before the first tick completes. Cheap — record cost
is one `VecDeque` push per tick; `tick_perf()` itself sorts a
stack copy of the durations to pick p99.

### `func attach_region_terrain_from_packed_heights(region_name: String, width: int, height: int, spacing_m: float, vert_min_m: float, vert_max_m: float, heights: PackedFloat32Array, obstacles: Array) -> void`

Iteration 5-14 follow-up. Same end-state as
`load_region_terrain_with_obstacles` but takes the heightmap as a
flat `PackedFloat32Array` of `width × height` row-major NW-up
meters instead of reading the canonical `.r32` from disk. Used by
`test_map.gd` to push the *live* Terrain3D surface to the sim, so
NPC Y-snap matches what the player walks on — bypasses the
canonical → Terrain3D import path that loses 10–20 m of precision
per region via `Terrain3DLoader.bake_into`. `obstacles` is the
same Phase B2 `Array<Dictionary>` shape as
`load_region_terrain_with_obstacles`; pass an empty array when no
obstacles need stamping. Validates `heights.size() == width *
height`; logs an error and no-ops on mismatch.

### `func attach_region_interaction_areas(region_name: String, areas: Array) -> void`

Iteration 5-13 Phase D2. Replace the per-region set of designer-
placed interaction areas (rest spots, work benches, guard posts,
etc.). The Godot caller (`real_map.gd` / `test_map.gd`) walks the
group `&"interaction_area_markers"` and ships one dict per
marker. Each dict carries:

- `id: String` — stable area id. Empty string → bridge auto-
  derives `auto:<region>:<x>_<z>`.
- `kind: String` — free-form descriptor (`"rest"`, `"work"`,
  `"socialize"`, `"scavenge"`, `"guard_post"`, `"patrol_node"`,
  `"campfire"`, `"workbench"`, or any mod-defined string).
- `pos: Vector3` — world-space center.
- `extents: Vector3` — half-size; the sim consumes X + Z only.
- `faction: String` — restriction; empty = any. Must match a
  faction id from `factions.toml`; unknown strings fall back to
  "any" with a warn-once.
- `capacity: int` — max concurrent occupants (≥ 1; clamped).
- `tags: Dictionary` — free-form metadata (passed through as
  `HashMap<String, String>` for downstream consumers).

Idempotent per region. Calling again replaces the prior set.
Reservation lives sim-side via Phase D3's squad-planner
integration (squads pick the closest matching `"rest"` area
over a generic base position when scoring `Rest` objectives).

### `func register_authored_base(region_name: String, pos: Vector3, kind: String, faction: String) -> bool`

Iteration 5-14 Phase B. Spawn a scene-authored faction base from
a `PoiMarker3D` (kind `BASE_*`). The Godot caller (`base_spawner.gd`
in Phase E) walks the `&"poi_markers"` group, filters BASE_* kinds,
and dispatches one of these per marker.

- `region_name`: must resolve via the active `RegionGraph`.
- `pos`: world-space center; Y is overridden by terrain Y when a
  heightmap is attached (Y-snap).
- `kind`: PascalCase `BaseKind` variant — `"Checkpoint"`,
  `"Outpost"`, `"Safehouse"`, `"Headquarters"`, `"ResearchPost"`,
  or `"CampSite"`. Unknown strings warn + return `false`.
- `faction`: name from `factions.toml`. `"wanderers"` is the
  neutral placeholder used by `CampSite`. Unknown strings warn +
  return `false`.

Returns `true` after the dispatch enqueues. The sim-side
`register_authored_base` does the actual spawn and stamps the
per-kind nav-obstacle footprint (Checkpoint 3 m, Safehouse 4 m,
Outpost 5 m, ResearchPost 6 m, Headquarters 8 m; CampSite none).

### `func register_activity_point(region_name, kind, pos, facing_yaw_deg, faction, radius_m, capacity, priority, loop_id) -> bool`

Register a smart-terrain activity point. `kind` is a PascalCase
`ActivityKind` variant (`"GuardStatic"`, `"GuardPerimeter"`,
`"PatrolWaypoint"`, `"RestSpot"`, `"Lookout"`, `"Campfire"`,
`"Workbench"`, `"Stash"`, `"SniperNest"`, `"AmbushPoint"`). The
squad planner checks activity points before legacy base-position
fallback for Guard/Patrol/Rest objectives.

### `func register_patrol_route(region_name, route_id, waypoints, faction, is_loop, priority) -> bool`

Register a patrol route from a `PatrolRouteMarker3D`. `waypoints`
is a `PackedVector3Array` of world-space positions.

### `func register_spawn_point(region_name, pos, faction, spawn_rate, max_concurrent, squad_size_min, squad_size_max, spread_radius_m, loadout_tier, initial_delay_ticks) -> bool`

Register an authored spawn point. `spawn_rate` is squads/minute
(0 = one-shot). The sim checks authored points before
`PopulationTargets` backfill.

### `func register_cover_volume(region_name, pos, half_extents, rotation, material_name, height, thickness_mm, destructible, health) -> bool`

Register a cover volume for projectile penetration. `material_name`
is PascalCase (`"Concrete"`, `"Sandbag"`, `"Glass"`, etc.). Physical
projectiles test cover via swept-ray each tick.

---

## Pathfinding

Server-side, deterministic Rust pathfinding. The bridge methods
return `PackedVector3Array` so callers can drop results into
`MultiMeshInstance3D`, draw lines, hand off to a navigation visualizer,
or feed them into a player-side click-to-move state machine without
manual conversion. See `docs/book/src/planning/npc-traversal-plan.md`
for the design and `crates/simn-sim/src/nav.rs` for the
implementation.

### `func path_in_region(region_name: String, from: Vector3, to: Vector3, style: String) -> PackedVector3Array`

Find a navigable path between `from` and `to` in the region's nav
grid, weighted by the caller's `style`. Waypoints include the exact
`from` and `to` (start / end are overwritten with the caller's
points; intermediate waypoints sit at cell centers). Empty array on
unknown region, no nav data, or unreachable target. Phase-1
traversability is heightmap-derived (slope + feature class); static
obstacles like buildings come in a phase-2 follow-up.

`style` is one of:

- `"road"` / `"road_hugger"` — strong road preference. Patrols,
  military movement. Detours through paved / unpaved / trail cells
  even when off-road would be shorter; takes ~2× cost penalty for
  forest / shrubland.
- `"mixed"` (default) — mild road preference; takes roads when
  nearby but doesn't detour for them.
- `"bush"` / `"bushwhacker"` — cross-country, no road preference.
  Wanderers, hunters, NPCs avoiding patrols. Geometrically shortest
  traversable route.

Unknown style strings fall back to `"mixed"`.

Determinism: identical inputs always produce identical waypoints,
across machines and game versions. The path replays cleanly from
`Sim`'s journal.

### `func is_traversable(region_name: String, pos: Vector3) -> bool`

Cheap point query - does `pos` fall on a traversable cell in the
region's nav grid? `false` for unknown region or no nav data. Use
to validate spawn points or click-target legality before calling
`path_in_region`.

### `func nav_grid_dims(region_name: String) -> Vector2i`

Editor / debug helper. Grid dimensions (width, height) for the
region's nav data. `Vector2i.ZERO` if unknown region or no nav
data. Pair with `nav_traversability` to size the debug-viz texture.

### `func los_exposure(observer_npc_id: int, target_npc_id: int) -> float`

Read a cached line-of-sight exposure for the (observer, target) NPC
pair, populated this tick by aggro perception. Returns `-1.0` when
the pair wasn't evaluated this tick (out of FOV / perception range,
or sim not started). Otherwise a value in `0.0..=1.0` where `0.0` is
fully blocked and `1.0` is fully visible.

Direction-keyed: `los_exposure(a, b)` and `los_exposure(b, a)` look
up different entries — LOS is asymmetric because eye height + the
intervening geometry differ between the two ray starts.

Phase 1 has no consumers — the cache is a primitive for the upcoming
cover-system queries, tactical AI peek-shoot decisions, and the
planned hitscan / projectile combat path. See
`docs/book/src/planning/combat-los-plan.md`.

### `func nav_traversability(region_name: String) -> PackedByteArray`

Editor / debug helper. Per-cell traversability snapshot, length
`width * height` (NW-origin, row-major). Each byte is `1` (passable)
or `0` (blocked). Empty when the region has no nav data. Allocates
- call sparingly (once per debug rebuild, not per frame).

---

## Replication (slice-1 coop)

### `func apply_network_snapshot(tick: int, payload: PackedByteArray) -> bool`

Client-side: apply a host-sent snapshot. `payload` is bincoded
`SnapshotBody`. Emits `snapshot_applied(tick)` on success.

**Returns:** `true` on success, `false` on decode failure.

### `func apply_network_delta_batch(tick: int, payload: PackedByteArray) -> bool`

Client-side: apply a host-sent per-tick delta batch. `payload` is
bincoded `Vec<WorldDelta>`. Anchors mirror clock to `tick` after
applying.

**Returns:** `true` on success.

### `func dispatch_network_action(acting_steam_id: int, payload: PackedByteArray) -> bool`

Host-side: decode a client-sent `ActionKind` and route to the
matching mutation method. Resulting deltas broadcast to everyone
via the usual tick path.

**Returns:** `true` on success.

### `func serialize_snapshot_payload() -> Dictionary`

Host-side: serialize current sim state for
`NetworkManager.send_snapshot` / `broadcast_snapshot`.

**Dictionary keys:**

| Key | Type | Notes |
|---|---|---|
| `tick` | `int` | Sim tick at serialization. |
| `payload` | `PackedByteArray` | Bincoded `SnapshotBody`. |

Empty dict if the sim isn't initialized.

---

## Debug

### `func set_behavior_log(enabled: bool) -> void`

Toggle NPC behavior logging (emits `tracing::info!` events under
target `npc.behavior`).

### `func behavior_log_enabled() -> bool`

Query logging state.
