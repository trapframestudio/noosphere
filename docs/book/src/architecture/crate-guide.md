# Crate Guide

The Noosphere workspace currently has five crates. The pure-Rust
crates (`simn-common`, `simn-sim`, `simn-terrain`, `simn-net`) must
compile without `godot` so they remain portable; only `simn-godot`
depends on the engine.

```
simn-godot (cdylib, the Godot extension)
  ├── simn-sim      (world simulation, online/offline tiers, engine-agnostic)
  ├── simn-terrain  (canonical heightmap + sampler, engine-agnostic)
  ├── simn-net      (Steam P2P session, engine-agnostic)
  └── simn-common   (utilities, engine-agnostic)
```

**Planned additions** (design complete, implementation pending): `simn-world`
(SQLite-backed persistent world-object ledger alongside journal+snapshot -
see `../planning/world-ledger-plan.md`) and `simn-server` (pure-Rust headless
dedicated-server binary - see `../planning/physics-backend-plan.md`). A
`PhysicsBackend` trait in `simn-sim` will abstract Godot's Jolt
(listen-server, via `simn-godot`) from Rapier (dedicated, via
`simn-server`) so sim logic is physics-engine-agnostic.

## simn-common

Shared utilities used across all crates.

- **Logging configuration** with `tracing` setup helpers.

Zero engine dependencies, used by everything else.

## simn-sim

World simulation. Pure Rust, engine-agnostic, built on `bevy_ecs`. The
foundation, persistent NPC chronicle, and group-based behavior are all
in place; tier hand-off (per-fidelity online/offline split) and richer
goal AI are still ahead.

### Content pack (`ContentSource`)

All game content (items, recipes, factions, names, loadouts,
ballistics, behavior tuning, loot tables) is loaded through
`content::ContentSource` rather than hard-baked into the engine:

- `ContentSource::Embedded` is SIMN's generic example pack (organized by
  concern: `factions/ items/ loot/ crafting/ combat/ poi/ ai/ world/
  names/`), embedded into the engine via `include_dir!`. It ships in the
  SIMN repo and is vendored into the game at `godot/addons/simn/content/`
  by `scripts/sync-simn.sh` (there is no repo-root `content/` in the game).
  It's the default for every constructor, the test suite, and standalone
  use, so the sim runs with zero external files. It carries no
  proprietary content: faction `display` strings derive from their keys,
  names are generic placeholders, and chatter is a minimal default block.
- `ContentSource::Dir(PathBuf)` is a complete content directory on disk.
  A missing file is an error (no fallback). Logical paths are
  `/`-separated and relative to the pack root (e.g. `items/weapons.toml`).
- `ContentSource::Overlay(PathBuf)` layers on-disk files over the
  embedded base. A logical path resolves to the on-disk file if present,
  otherwise it falls back to `Embedded`. A game ships only the files it
  overrides (its `factions.toml`, `names/`, `chatter_lines.toml`) and
  inherits all mechanics and items from the embedded base. This is how
  Noosphere supplies its proprietary creative content: the bridge's
  `SimHost::set_content_root("res://content")` (called from
  `game_session.gd` before `start()`) selects `Overlay(res://content)`.
  The mirror/coop-client path stays `Embedded` (cosmetic display only,
  since faction keys and relations are identical across packs).

Each registry exposes `load()` (cached embedded) and
`load_from(&ContentSource)`. `Sim` constructors gain `_with_content`
variants (`new_with_content`, `new_with_seed_and_content`,
`load_with_content`, `load_or_new_with_content`,
`new_in_memory_with_content`) threaded through `build_world` and
`load`, and the plain constructors default to `Embedded`. Stable IDs
that derive from content (e.g. `FactionId` from sorted faction names)
sort before consuming RNG, so the source never perturbs determinism.
That's verified by `tests/determinism.rs::embedded_and_explicit_dir_match`.
A few tables read embedded-only (no per-source override, they're on the
tick path with no content handle): `WorldTimeConfig`, `cover::material_table`,
and the `crate::poi` base/activity behavior tables (`poi/base_types.toml`,
`ai/activity_types.toml`). Renaming or relocating files under `content/`
is a content edit, not a code change.

Per-faction tuning is data-driven too: `factions.toml` carries each
faction's `squad_size`, `combat` doctrine costs, and `base_kinds` weights
(read via `FactionRegistry::squad_size` / `combat_costs` /
`base_kind_weights`), so the engine hardcodes no faction names. POI base
behavior (nav footprint, victory flag) and activity-point behavior
(`is_guard` / `is_rest` / hunt-target) live in `poi/base_types.toml` and
`ai/activity_types.toml`; the `BaseKind` / `ActivityKind` tags remain the
engine's POI/activity vocabulary.

Foundation (landed):

- **Data model** - components (`Position`, `Rotation`, `InRegion`,
  `Actor`, `PlayerOwned`, `Health`, `Stamina`, `BodyParts`,
  `SurvivalStats`, `InFaction`, `Base`) and resources (`SimClock`,
  `RegionGraph`, `WorldTime`, `WeatherState`, `RegionControl`).
- **Player vitals + meds (stats foundation + wounds + drugs +
  contamination, survival/crafting plan §1–§5 + GAMMA §6 medical
  depth)** - `BodyParts { head, torso, l/r arm, l/r leg }` per-part HP;
  `SurvivalStats { hunger, thirst, fatigue }` 0–100 meters drained by
  `drain_survival_stats` with §3.3 degraded-function gates;
  `Contamination { radiation, toxicity }` decayed by
  `tick_contamination` with HP gate at threshold; `Pain` derived per
  tick from wounds + active painkillers; `Wounds` Vec of discrete
  `Wound` instances minted by `WoundIdCounter`, with treatment
  pipeline `Untreated → Disinfected → Bandaged → Stitched → Healed`
  (light) and `Untreated → Tourniquet | WoundPacked → Stitched →
  Healed` (heavy); `tick_infection` flips Untreated wounds to
  `infected` after the trigger window; `tick_necrosis` drains a
  tourniqueted limb past the warning window; `apply_bleed_damage`
  combines bleed + infection drain on the wound's body part and
  scales by per-NPC `bleed_rate_multiplier(endurance)` (linear inverse
  in `[1.3, 0.7]` over endurance `0..=100`, 1.0× at 50 — frail NPCs
  bleed faster, tough NPCs slower; players collapse to baseline);
  antibiotics clear infection. `ActiveEffects` Vec holds drug + status effects
  (id from `EffectIdCounter`); `tick_active_effects` retires expired;
  `apply_drug` (Painkiller / Morphine / Adrenaline / StimCocktail /
  AntiRad / AntiTox) gates overdose on `tolerance > 75 + active dose`,
  schedules deferred crash phases (FatigueRebound after Stim,
  AdrenalineCrash after Adrenaline), and revives from low HP via
  Adrenaline. `DrugTolerance` per-drug counter decays at 25/in-world
  hour. `Sim::eat`/`drink` apply per-`FoodKind`/`WaterKind` profiles
  (defined in `food_profile`/`water_profile`). All mutations
  (treatment, drug application, contamination set, wound
  spawn/treatment) journal; per-tick decays / system-derived state
  (pain, tolerance decay, effect aging, bleed/infection drain) are
  pure. Aggregate `Health.current` mirrored to `min(head, torso)`.
  NPCs carry `BodyParts` + `Wounds` + `ActiveEffects` alongside the
  same aggregate `Health` mirror. `Sim::apply_damage_to_npc_part` /
  `heal_npc_part` route damage or healing per-part and journal a
  `WorldDelta::SetNpcBodyPart`; above-threshold damage also spawns a
  Bleed wound and journals `NpcWoundAdded`. `npc_combat`'s
  probabilistic NPC-vs-NPC path drains torso and spawns an ephemeral
  Bleed wound without journaling (recovered from the next snapshot).
  All four per-tick wound systems (`apply_bleed_damage`,
  `age_and_heal_wounds`, `tick_infection`, `tick_necrosis`) iterate
  every entity with the required components - players and NPCs share
  the pipeline. **`LimbStates` component** (sibling to `BodyParts`,
  six `LimbState::{Intact, Wounded, Severed}` slots) is spawned for
  both players and NPCs; wound-spawn sites call `mark_wounded(part)`
  and `age_and_heal_wounds` calls `recompute_from_wounds(&Wounds)`
  after the `Healed`-retain to flip parts back to `Intact` once their
  last wound resolves. `Severed` is permanent - production sever
  arrives with the caliber-driven `WoundKind::Sever` work
  ([`planning/dismemberment-plan.md`](../planning/dismemberment-plan.md));
  test-only `Sim::sever_limb_for_test` is the current flip-it path. Seven NPC treatment methods (`apply_bandage_npc`,
  `apply_tourniquet_npc`, `remove_tourniquet_npc`,
  `apply_disinfectant_npc`, `apply_stitch_npc`, `apply_wound_pack_npc`,
  `apply_antibiotics_npc`) mirror the player API and journal via
  `NpcWoundTreatmentChanged` / `NpcEffectApplied`. **NPC self-heal +
  squad-medic** is live via `npc_treat_wounds` (scheduled after
  `age_and_heal_wounds`, before `tick_pain`; uses `ParamSet` to
  disambiguate read-scan vs. write-apply views on `Wounds` +
  `Inventory`). Runs every `NPC_HEAL_TICK_INTERVAL = 20` ticks
  (1 Hz); for each online NPC with an active untreated bleed it
  picks the worst wound and tries to apply an appropriate item -
  light bleed (sev ≤ 3) → `bandage`, heavy bleed (sev ≥ 4) →
  `wound_pack` preferred (no necrosis) or `combat_tourniquet` as
  fallback (stops bleed, starts necrosis timer). Self-heal consumes
  from the wounded NPC's inventory first; if empty, falls back to
  any same-group squad-mate within `SQUAD_MEDIC_RADIUS_M = 10 m`
  who has the item (mate's inventory is debited, wounded NPC is
  treated). Per-applicator throttle of `NPC_HEAL_COOLDOWN_TICKS =
  60` (~3 s) prevents same-tick bandage flurries; transient
  `NpcLastHealTick` resource (Default, no persistence) carries the
  cooldown table and is registered alongside the schedule in
  `new`, `load`, and `new_mirror`. **Limit:** the medic side only
  fires when a healthy mate is *already* within 10 m of the
  wounded NPC - the system doesn't navigate a remote medic in.
  That's a planned `goal_arbitration::HealAlly` candidate;
  formation_offset clustering covers the common case until it
  lands. Player-to-NPC medical still rides on a later UI slice.
  Tunable in `MedConfig`. Player-facing tuning + protocols
  documented in `docs/book/src/mechanics/damage-and-healing.md`,
  `drugs-and-effects.md`, and `food-and-water.md`.
- **Items + inventory + crafting + salvage** - every consumable /
  junk / component / tool is defined in `content/items.toml`
  (bundled at compile-time via `include_str!`) and loaded into a
  read-only `ItemRegistry` resource at `Sim::new` / `Sim::load`.
  Each `ItemDef` carries optional `consume_action` (tagged enum
  routing to `eat` / `drink` / `apply_drug` / `apply_bandage` /
  `apply_tourniquet` / `apply_disinfectant` / `apply_stitch` /
  `apply_wound_pack` / `apply_antibiotics`), optional
  `perishable_ticks`, and optional `salvage` recipe. As of the
  inventory-grid PR, each `ItemDef` also carries `size: GridSize { w, h }`
  (default 1×1), `rotatable: bool`, and `inner_grid: Option<GridSize>`
  (set on container items). Player-only `Inventory(GridInventory)`
  component is a Tarkov/STALKER-hybrid 2D grid (default 4×4
  pockets); each placed stack records `(x, y, rotation)` in
  addition to the legacy `(id, count, spawned_tick)`. The placement
  engine lives at `crate::inventory_grid` - pure functions
  (`grant_or_merge`, `consume_from_grid`, `place_at`, `move_within`,
  `remove`, `count_of`, `find_first_fit_any_rotation`) operating on
  `GridInventory` + `ItemRegistry`, no ECS. `tick_perishables`
  retires expired stacks each tick (deterministic from `spawned_tick`,
  not journaled). Operations:
  `grant_item` / `pickup` (stack + journal `ItemPickedUp`),
  `drop_item` (delegates to `drop_item_to_ground` - spawns or merges
  into a private [`WorldContainer`] at the player's feet),
  `move_between_slots` (in-pockets swap),
  `move_between_grids` (cross-grid first-fit move; pockets ↔
  equipped-container inner grid; preserves nested grids),
  `consume_from_slot` (lookup
  `consume_action`, route to existing API, decrement on success),
  `salvage` (roll deterministic ChaCha8-seeded outputs from
  `SalvageRecipe`, journal actual outputs). **Crafting**: `craft`
  (instant, legacy path) + Step 5's `queue_craft` / `cancel_craft` /
  `crafting_queue` / `can_craft`. Queue jobs live on a per-player
  `CraftingQueue(Vec<CraftJob>)` component; `tick_crafting_queue`
  advances the head job deterministically each tick and mints
  outputs when a unit completes (pure system, not journaled -
  same pattern as `tick_perishables`). Discrete lifecycle events
  emit `CraftJobQueued` / `CraftJobCancelled` so mirrors see
  material debits / refunds; per-unit completions don't need
  per-tick deltas.
- **Crafting stations + kits** - recipes can demand a
  `required_context: CraftStation` (Campfire / BasicBench /
  AdvancedBench / ExpertBench, cumulative - higher tier satisfies
  lower) and a `required_kit: { specialty, min_tier }`. Specialties:
  `General` / `Gunsmith` / `ArmorRepair` / `WeaponRepair` /
  `DrugMaking` / `Shards` - matches GAMMA's specialty-kit
  ladder. `ToolTier`: Basic / Advanced / Expert, cumulative within
  specialty. Kit items are marked on `ItemDef` via
  `tool = { specialty, tier }` and are **not consumed** on craft.
  Tool / kit checks are **pooled across coop players within 6m**
  (`CRAFTING_SHARE_RADIUS_M`) - crewmate's toolkit satisfies the
  requirement for a shared bench. Campfire context is still a
  debug flag (`NearCampfire`) toggled by `Sim::set_player_near_campfire`;
  workbench tier uses `NearWorkbench(Option<ToolTier>)` toggled by
  `Sim::set_player_near_workbench`. Scene-placed station entities
  + proximity system land with the UI slice.
- **Weight cap** - Step 5 activates the soft cap wired through
  `InventoryConfig { weight_cap_kg, overweight_regen_mult }` (a
  non-snapshotted resource). `regen_stamina` reads it alongside
  the existing hunger / pain / drug modifiers and multiplies
  stamina regen by `overweight_regen_mult` while carry exceeds
  `weight_cap_kg`. No hard-cap on pickup.
- **Paper doll + equipment slots** (PR-2 of the inventory rewrite) -
  slot layout lives in `content/equipment_slots.toml` and loads into an
  [`EquipmentSlotRegistry`] resource alongside `ItemRegistry` /
  `RecipeRegistry`. `EquipmentSlotDef` carries `accepts:
  Vec<ItemCategory>`, `position`, and optional `is_hotbar` +
  `hotbar_index`. `ItemDef` gains `equip_slots: Vec<SlotId>` - when
  non-empty, it overrides the slot's category whitelist. Player
  entities now carry an `Equipment(HashMap<SlotId, EquippedItem>)`
  component. An `EquippedItem` owns an optional `inner_grid:
  GridInventory` so equipping/unequipping a loaded backpack moves
  it with its contents intact. `PlacedItem` also gains
  `inner_grid: Option<GridInventory>` so containers can sit in
  pockets with their payload attached. Sim API:
  `equip(sid, slot_id, source_grid, source_idx)` /
  `unequip(sid, slot_id, dest_grid)` /
  `equipment_view(sid)` /
  `consume_from_hotbar(sid, idx, body_part)`. Source-grid strings are
  `"pockets"` or `"equipped:<slot_id>"` for nested grids. Crafting
  kit-pooling (`collect_shared_inventories`) now recursively scans
  pockets + every equipped container's inner grid + nested
  containers - a gunsmith kit in your backpack satisfies the check
  without moving to pockets. New world deltas: `ItemEquipped` /
  `ItemUnequipped` (replay-safe, carry the nested grid).
- **Looting UI bridge** (PR-4c of the inventory rewrite) - adds five
  `#[func]`s on `SimHost` that mirror `Sim`'s container API to
  GDScript: `containers_in_range(sid, radius_m) → Array[Dict]`,
  `container_view(cid) → Dict` (same `{width, height, items}` shape
  as player pockets so the renderer is shared),
  `take_from_container(sid, cid, idx) → bool`,
  `put_in_container(sid, cid, source_grid, idx) → bool`, and
  `spawn_world_container(region_name, pos, w, h, is_public) → int`
  (host-only, returns `-1` on client). Two new `ActionKind` variants
  - `TakeFromContainer` / `PutInContainer` - carry the client→host
  dispatch. GDScript side as of Phase 3E:
  `InventoryPanel.open_for_container(id)` in
  `godot/scripts/menus/inventory_panel.gd` (the unified panel)
  plus `godot/scripts/loot_controller.gd` (polls nearest
  container at 20 Hz, drives the `[F] LOOT` HUD prompt, routes
  the `F` press into the inventory panel). The legacy
  `godot/scripts/menus/loot_panel.gd` + its scene are no longer
  in the loop and are slated for removal once any lingering
  references shake out. The `F` key is the `interact` action;
  the old debug `toggle_near_campfire` moved to `F3`. `real_map.gd` spawns a test crate at every real
  region's `PlayerSpawn` so the loop is exercisable without killing
  NPCs. No `FORMAT_VERSION` bump - container persistence was already
  set up in PR-4a.
- **NPC loadouts + corpse loot** (PR-4b of the inventory rewrite) -
  faction-keyed loadouts in `content/npc_loadouts.toml`
  load into an `NpcLoadoutRegistry` resource at sim init (mirrors
  `ItemRegistry::load()`). Each loadout is a list of independent rolls
  `{ id, count, chance }`; `chance = 1.0` is guaranteed, lower
  chances roll once per spawn against the existing squad RNG so a
  given seed/tick produces deterministic gear. `npc_spawn` calls
  `NpcLoadoutRegistry::build_inventory` and attaches the resulting
  `Inventory(GridInventory)` to the NPC entity (4×4 default,
  overflow silently dropped same as player pickup). Both death gates
  (`npc_death_check.rs`, `npc_age.rs`) call
  `world::containers::spawn_corpse_container` before despawning the
  NPC entity: a private (`is_public = false`) `WorldContainer` lands
  at the NPC's position carrying their pocket grid as initial state.
  Empty inventories produce no corpse (no clutter from NPCs that
  rolled empty loadouts). Player-facing contract in
  `docs/book/src/mechanics/npcs-and-combat.md`. No `FORMAT_VERSION`
  bump - `SerializedEntity.inventory` already supported any entity;
  this PR just attaches it to NPCs at spawn.
- **World containers** (PR-4a of the inventory rewrite) - non-player
  entities carrying `WorldContainer { id: ContainerId, grid:
  GridInventory, is_public: bool }` + sibling `Position` + `InRegion`.
  Used for ground drops (private, 4×4, auto-spawned by
  `drop_item_to_ground` with a 1.5m merge radius), scene-placed crates
  (caller chooses public/private), and PR-4b NPC corpses. `is_public`
  controls crafting kit-pool participation: only public containers
  count toward `collect_shared_inventories`, so player stashes and
  ground drops never silently satisfy a recipe. World-level
  `ContainerIdCounter` resource mints ids; counter persists +
  advances on mirror replay so authoritative + mirror sims stay in
  lockstep. Sim API: `spawn_world_container(pos, region, w, h,
  is_public)` / `despawn_world_container(id)` / `container_view(id)` /
  `container_position(id)` / `containers_in_range(sid, radius)` /
  `take_from_container(sid, id, idx)` / `put_in_container(sid, id,
  source_grid, idx)` / `drop_item_to_ground(sid, slot_idx)`.
  Implementation in `crates/simn-sim/src/world/containers.rs`.
- **Loot container scatter (Phase 3A)** — separate from the
  equipable `content/items/containers.toml` (backpacks / rigs), a new
  `content/loot_containers.toml` defines scene-placed crate kinds
  (`small_crate` 4×4, `medium_stash` 6×6, `large_cache` 8×10) with
  weighted `spawn_weight`. The
  `crates/simn-sim/src/loot_containers.rs::LootContainerRegistry`
  resource loads the TOML once at sim init (same `OnceLock`-cached
  pattern as `ItemRegistry`); `weighted_pick(rng)` returns a kind
  in proportion to its weight. `world_seed.rs::seed_loot_containers`
  scatters 8–15 containers per procedurally-seeded region, each
  anchored on a random base position with ±80 m XZ jitter. The
  same `ChaCha8Rng` stream feeds bases + scatter so identical seeds
  reproduce identical world layouts. Containers spawn empty +
  private; **Phase 3B** fills them with faction-flavored pool tables
  and **Phase 3C** handles deterministic first-approach restock.
  Test helpers `Sim::all_world_containers_for_test` /
  `Sim::all_bases_for_test` expose the seeded state to integration
  tests without exposing `Sim::world`.

  **Authoring marker** —
  [`godot/scripts/world/loot_container_marker.gd`](../../../../godot/scripts/world/loot_container_marker.gd)
  is the `@tool` `Node3D` level authors drop into a scene to place
  a container by hand (distinct from procedural scatter). Inspector
  surfaces:
  - `kind` enum (`SMALL_CRATE` / `MEDIUM_STASH` / `LARGE_CACHE`) —
    drives the inner-grid footprint the sim will use.
  - `model_variant` dropdown populated per-kind from the script's
    `_MODELS_BY_KIND` table; adding a new visual is one row + a
    `res://…` scene path (scaffolded today, art lands later).
  - `interaction_mode` (`OPENABLE` / `BREAKABLE`) — picks between
    the existing `[F] open` looting flow and a smash-to-loot path
    that destroys the container and dumps contents as a ground
    pile. `BREAKABLE` runtime semantics (damage routing, break VFX,
    contents transfer) land with the Phase 3D runtime walker; the
    field is scaffolded on the marker today so authored placements
    aren't blocked.
  - `is_public` (kit-pool participation) + `container_id` (stable
    id the Phase 3C restock seed hashes against).

  Markers register themselves in the `loot_container_markers`
  group; the runtime walker (`loot_container_spawner.gd`) hands
  each marker's `(kind, mode, transform, is_public, container_id)`
  to `SimHost.register_authored_container` — shipped in Phase 3D,
  see the "Authored marker runtime walker" bullet below.
- **Loot pools (Phase 3B)** — `crates/simn-sim/src/loot_pools.rs`
  + `content/items/loot_pools.toml` define faction × depth_tier ×
  family pool tables (8 families: `weapons` / `magazines` /
  `ammo` / `armor` / `medical` / `food` / `tools` / `junk`).
  `LootPoolRegistry::roll_one(rng, faction, tier, family)` picks
  one weighted entry; stack size rolls in the entry's declared
  `[count_min, count_max]`. Lookup falls back through
  `(faction, tier, family) → (faction, 1, family) →
  (wanderers, tier, family) → (wanderers, 1, family)` so a region
  with an unknown faction or unauthored tier still yields plausible
  scavenger loot. `loot_containers.toml` extended with per-kind
  `family_weights` (what each kind tends to carry),
  `items_per_roll` (`[min, max]` slots per restock), and
  `difficulty_weights` (`[difficulty, weight]` pairs driving
  quest-reward kind picking).
  **Quest-reward roll** uses **best-of-K**: `roll_quest_reward`
  picks K candidates from the pool and keeps the rarest
  (lowest-weight) one. `quest_lottery_k(difficulty)` maps quest
  difficulty 1..5 → K 1..5, so harder quests skew strongly toward
  rare entries without duplicating pools per difficulty.
  `LootContainerRegistry::weighted_pick_for_difficulty` picks the
  container kind itself by quest difficulty — small crates for
  trivial quests, large caches for hard ones. The Phase 3C
  initial roll + restock sweep + the Phase 3D authored-marker
  walker all consume `roll_one` (eager weighted pick) — the
  quest-reward best-of-K path is currently unused by any
  shipped walker; it's the surface a future
  `QuestRewardMarker` / mission-script bridge will call when
  hand-authored reward containers land.
- **Initial content + restock (Phase 3C)** — containers no longer
  spawn empty. `world_seed.rs::seed_loot_containers` eager-rolls
  initial contents using the per-kind `family_weights` +
  `items_per_roll`, anchored to the region's primary faction (via
  `RegionControl`) and depth tier 1 (until zones author tiers).
  The roll uses the same `ChaCha8Rng` stream as base placement so
  identical seeds reproduce identical worlds, **and new saves
  with different seeds get different loot** — no deterministic-
  hash design needed, the seed parameter already varies per
  save. Contents persist via the existing snapshot machinery.

  `systems/loot_restock.rs::tick_loot_restock` is a periodic
  partial-restock system added to the build_schedule after
  `advance_clock`. Fires every `RESTOCK_SWEEP_INTERVAL_TICKS`
  (72_000 ticks ≈ 1 in-world hour); each container in an active
  region rolls `RESTOCK_CHANCE_PER_CONTAINER` (30%) and gets
  `[1, 3]` new items if picked. Partial top-up matches the
  in-fiction model — wanderers / supply squads dropping
  things off, not the world resetting. Player drops + corpses
  (`faction = None`) are skipped. `apply_squall_restock` is
  the pull surface the future faults system will call to fire a
  full-sweep restock when a squall resolves; currently
  `#[allow(dead_code)]` until internal design notes Step 7 lands.

  `WorldContainer` gained three `#[serde(default)]` fields for
  the restock metadata: `faction: Option<String>`,
  `depth_tier: u8`, `last_restock_tick: u64`. Pre-3C snapshots
  load with `(None, 1, 0)` and the restock sweep treats them
  identically to fresh containers.
- **Authored marker runtime walker (Phase 3D)** —
  `Sim::register_authored_container(kind_id, region, pos,
  is_public, faction, depth_tier, mode, seed)` is the sim-side
  entry point for hand-placed `LootContainerMarker3D` nodes.
  Resolves grid from `LootContainerRegistry`, rolls eager
  contents via the Phase 3C helper, stamps the new
  `WorldContainer.interaction_mode: ContainerInteractionMode`
  field (`#[serde(default) = Openable]`). The matching gdext
  `#[func]` is `SimHost.register_authored_container(...)`;
  GDScript walker `loot_container_spawner.gd` iterates the
  `loot_container_markers` group on map-ready and dispatches
  each marker through it (`real_map.gd` calls it from
  `_on_terrain_ready`). `Breakable` runtime semantics — HP,
  damage routing, destruction → ground pile — are still
  scaffold-only; the field flows through to the snapshot so a
  future destruction system has the data it needs.
- **Weapons (Phases 1 + 2)** - `ItemDef` carries optional
  `weapon_config` / `magazine_config` / `ammo_config` / `armor_config`
  blocks (caliber as a stringly-typed `Caliber` tag so modders can
  add calibers without touching Rust). `EquippedItem` on a weapon
  slot carries `weapon_state: Option<EquippedWeaponState>` with the
  loaded magazine as a full `ItemInstance`;
  `MagazineState { loaded_rounds, variant }` rides on the mag.
  Phase 2 adds projectile ballistics: `AmmoConfig` now includes
  mass_g, muzzle_velocity_mps, drag_k, penetration_class,
  damage_soft, damage_blunt, reference_energy_j. New
  `ArmorConfig { protection_class, coverage: Vec<BodyPart> }` on
  armor items. Sim API: `reload_weapon(sid, slot)` swaps best-
  loaded matching-caliber mag; `eject_magazine(sid, slot)` unloads;
  `fire_weapon(sid, slot, aim_yaw, aim_pitch)` spawns a
  `Projectile` entity; `load_rounds_into_mag(sid, slot, round_id)`
  tops an equipped mag up to capacity. Actions: `ReloadWeapon`,
  `EjectMagazine`, `FireWeapon`, `LoadRoundsIntoMag`. World deltas:
  `WeaponReloaded`, `WeaponMagazineEjected`, `WeaponFired`,
  `ProjectileSpawned`, `ProjectileImpacted`, `MagazineLoaded`.
  **Projectile tick** (`world/projectiles.rs`) integrates gravity +
  drag from `BallisticsConfig` (loaded from `ballistics.toml`) and
  swept-ray tests against **humanoid body-part hitboxes**
  (`world/hitbox.rs` - pure-math sphere + capsule primitives,
  head/torso/limb approximations). Impact damage runs the
  penetration-vs-armor formula: `pen_eff = round.pen_class -
  armor.protection_class`; full soft damage on penetrate, scaled
  blunt on block (–25% per class short, floor 0). Damage routes
  through existing `apply_damage_to_npc_part` so wound + HP mirror
  paths are untouched. Client renders tracer + impact FX from
  two new `SimHost` signals (`projectile_spawned`,
  `projectile_impacted`). Attachments (Phase 3), parts condition
  (Phase 4), full material-class penetration (Phase 5) still
  deferred. All tuning flows from `items.toml` + `ballistics.toml` -
  engine never supplies fallback defaults.

  **Phase 4A v1 — NPC projectile spawn (cosmetic).** `Projectile`
  gained `source_npc_id: Option<NpcId>` with `#[serde(default)]`.
  `Sim::npc_fire_projectile(shooter, shooter_pos, region,
  target_pos, accuracy, round_id, rng)` mints a tracer-only
  projectile with cone-of-fire jitter scaled by accuracy
  (acc 100 → 0°, acc 0 → ±5°). Phase 4B v1 added the
  `round_id` parameter — see below. `npc_combat` writes a `PendingNpcShots`
  resource entry on each fire decision; `Sim::tick` drains the
  queue and calls `npc_fire_projectile` before
  `tick_projectiles` so spawn-frame tracers get one tick of
  advancement.

  **Phase 4A v2 — projectile-borne NPC damage (dice path
  retired).** `tick_projectiles` now resolves damage for
  NPC-fired projectiles too (the v1 carve-out is gone). The
  hit loop walks NPC and player candidates in the projectile's
  region; the closest hit wins. `WorldDelta::ProjectileSpawned`
  carries `source_npc_id: Option<NpcId>` and
  `WorldDelta::ProjectileImpacted` carries
  `hit_player_steam_id: Option<u64>`, both with
  `#[serde(default)]` so v1 snapshots load cleanly (legacy
  spawns = player-fired, legacy hits = NPCs only). Aim flows
  from the muzzle (shooter Y + `muzzle_up_m`) to the target's
  center mass (target Y + 1.2 m) — the muzzle-to-feet aim of
  v1 grazed the leg capsule's bottom edge. Attribution
  (`LastDamager`, `RecentAttackers`, kill credits, blackboard
  `UnderFireAt`) migrates onto the projectile-impact site via
  `Sim::apply_npc_attribution_for_hit(victim, attacker,
  attacker_pos, damage)` — so projectile damage, future melee,
  and any future damage source all land at one seam. The
  `npc_combat` system is reduced to a pure fire-decision pass:
  FOV / LOS / range / aggression gates + `NpcShotIntent`
  queue, no more direct damage. Aggression now drives *fire
  cadence* (`fire_chance = 0.5 + 0.5 * aggression`) instead of
  hit chance — hit/miss is geometric. `accuracy_hit_multiplier`
  is retained for legacy unit-test compatibility but unused by
  the live system. `Sim::force_npc_hp_for_test` floors every
  body part to `hp` (not just torso) so a single hit on any
  part kills.

  **Phase 4B v1 — faction-flavored NPC round selection.** New
  top-level `crate::default_npc_round_for_faction(&str) ->
  ItemId` re-export maps each shipped faction to its
  characteristic round (PWA / Linemen / Revere Guard →
  5.45×39; Federal / Aegis → 5.56×45; Attuned → 7.62×39;
  bandits / wanderers → 9×18; Gulf Compact → 9×19; unknown
  factions fall back to 5.45×39). `NpcShotIntent` carries the
  round id; `npc_combat` resolves the shooter's faction name
  via `FactionRegistry::name_of(InFaction.0)` and writes it
  onto the intent. `Sim::tick`'s drain passes the round id
  through to `npc_fire_projectile`. The Gunshot world-bus
  event's `caliber_class` now sources from the round's
  authored `ammo_config.caliber_class`, so audible ranges per
  `world_event_bus::audible_radius_m` immediately diverge —
  bandit pistols carry ~180 m, PWA intermediates ~250 m,
  full-power rifles ~350 m.

  **Phase 4B v2 — ammo variant family tag.** `AmmoConfig` gains
  `variant: AmmoVariant` (`Fmj` default, `Hp`, `Ap`, `Tracer`,
  `Overpressure`) with `#[serde(default)]`. Damage / penetration
  numbers stay per-row in `content/items/ammo.toml` (each variant
  is its own hand-tuned `[[items]]` block — the original
  spec's per-variant multipliers would have double-applied),
  so the variant tag is FX / AI / loot metadata only. All ~32
  shipped non-FMJ rounds (HP / JHP / AP / BP / 7N## / flechette
  shotgun / `45acp_p`) carry their declared variant; three new
  tracer rounds (`round_5_45x39_t`, `round_556x45_tracer`,
  `round_762x54r_t46`) round out the canonical loadout.
  `WorldDelta::ProjectileSpawned` carries
  `variant: AmmoVariant` resolved at fire time via
  `Sim::resolve_round_variant(round_id)`; the bridge dict
  emits a snake-case `variant` string so GDScript can drive
  tracer color, casing-eject SFX, and (future) impact-FX
  selection without a round-id parse. The Projectile entity
  doesn't denormalize the tag — `round_id` is on the entity
  and consumers re-query when needed.

  Phase 4B's TOML-driven faction → round mapping (originally
  scoped under v2) is still parked; the in-Rust
  `default_npc_round_for_faction` table from v1 covers the
  shipped faction roster without a TOML schema change.

  **Phase 4C — attachment slot-tag graph (data only).**
  `WeaponConfig.slots: Vec<WeaponSlot>` declares each weapon's
  native mount surfaces; each `WeaponSlot { id, tags }` exposes
  one or more mount-fingerprint strings. New
  `ItemCategory::Attachment` + `AttachmentConfig {
  consumes_tag, provides_tags, effects }` describes the
  attachment side. `validate_attachment_chain(registry,
  weapon_id, &[ItemId]) -> Result<Vec<String>,
  AttachmentError>` resolves a proposed chain in order:
  pool starts with weapon's slot tags, each attachment must
  find its `consumes_tag` in the pool (or in earlier
  `provides_tags`), and a successful consume swaps in the
  attachment's new tags. Errors name the first failing
  step (`NoMatchingSlot`, `TagAlreadyConsumed`, etc.) for
  surface-able UI messages. Authored in
  `content/items/weapons.toml` (AKS-74 slot tags) +
  `content/items/attachments.toml` (PSO-1, dovetail→pic adapter,
  Aimpoint CompM4, PBS-1 suppressor, Ultimak rail). Effect
  fields on attachments (`recoil_control`, `barrel_wear_mult`,
  `sound_signature`, ...) are authored for forward-compat —
  not yet consumed at runtime; the runtime apply lands with
  Phase 4D / 5 alongside parts condition + the equip-an-
  attachment UI.

  **Phase 4D — weapon condition + jams (v1).**
  `EquippedWeaponState.condition: f32` (0–100, default 100 via
  manual `Default` impl + `#[serde(default)]`) plus
  `jam_state: JamState` (`Cleared` / `FailureToFeed` /
  `FailureToExtract` / `Stovepipe`). `WeaponConfig.wear_per_shot`,
  `jam_threshold`, `jam_chance_floor` are TOML-overridable
  with defaults (0.05 / 70 / 0.18). `jam_chance_at_condition`
  returns a linear ramp: 0 above threshold, hits the floor at
  `condition == 0`. `Sim::fire_weapon` checks jam state
  (jammed → dry-click), rolls jam against current condition
  (jammed → set state + journal `WeaponJammed`), and on a
  successful shot decrements condition (`WeaponConditionChanged`).
  New `Sim::clear_weapon_jam` clears the state + emits
  `WeaponJamCleared`; doesn't repair condition. Per-part
  roster (§5.1 of `weapons-plan.md`), NPC jam handling, and
  attachment wear-multiplier consumption are all deferred to
  later iterations on top of this v1.
- **Resource init parity between `build_world` and `Sim::load` (2026-05-28)** —
  recurring bug class: adding a new ECS resource only to
  `Sim::build_world` (the fresh-sim path, `crates/simn-sim/src/world/mod.rs`)
  panics the worker thread on the **first tick after a save load**
  because `Sim::load` constructs its world from scratch using the
  `SnapshotBody` and only re-inserts the resources it knows about.
  Symptom in-game: `worker inspect failed: sim inspect channel
  rejected: sending on a disconnected channel` after Resume, with
  GDScript backtraces from whatever ran the first inspect call
  (commonly `spawn_activity_points` during `_enter_region`). For
  every new resource decide up front:
    - **Persisted** — add to `SnapshotBody`, derive
      `Serialize`/`Deserialize`, insert from `body.<field>` in
      `Sim::load`. Bump `FORMAT_VERSION`.
    - **Transient** — insert `::default()` in *both*
      `build_world` *and* `Sim::load` (the load-path insert can be a
      one-liner with a comment explaining how it re-seeds — e.g.
      `CorpseIndex` re-populates from `NpcDied` events as combat
      runs). Comment with `re-populates from <source>` for future
      reviewers.
  Regression test: `tests/persistence.rs::load_then_tick_runs_all_schedules`
  — loads a fresh save and ticks 5×; any missing resource panics the
  schedule. The existing `journal_replay_after_crash` test loads
  without ticking after, so it can't catch this; the new test exists
  specifically to gate this bug class.
- **Journaling + persistence** - `ItemPickedUp` / `ItemDropped` /
  `ItemMoved` / `ItemConsumed` / `ItemsSalvaged` / `ItemsCrafted` /
  `ItemEquipped` / `ItemUnequipped` / `NearCampfireSet` /
  `NearWorkbenchSet` / `CraftJobQueued` / `CraftJobCancelled` /
  `WorldContainerSpawned` / `WorldContainerDespawned` /
  `WorldContainerItemAdded` / `WorldContainerItemRemoved` /
  `WeaponReloaded` / `WeaponMagazineEjected` / `WeaponFired` /
  `ProjectileSpawned` / `ProjectileImpacted` / `MagazineLoaded`.
  Snapshot stores `Inventory` + `Equipment` + `NearCampfire` +
  `NearWorkbench` + `CraftingQueue` on player entities + `WorldContainer`
  on container entities; world-level `JobIdCounter` and
  `ContainerIdCounter` are persisted. `FORMAT_VERSION` bumped 21→22
  (Step 5 Slice A), 22→23 (inventory-grid PR - `Inventory` shape
  changed from `Vec<ItemInstance>` to `GridInventory`), 23→24
  (equipment PR - new `Equipment` component + `PlacedItem.inner_grid`
  + extended `ItemCategory`), 24→25 (PR-4a - added `WorldContainer`
  serialization + `ContainerIdCounter`). Player-facing contract in
  `docs/book/src/mechanics/inventory.md` and
  `docs/book/src/mechanics/crafting.md`.
- **Factions** - TOML-driven `FactionRegistry` (canonical config at
  `content/factions.toml`, embedded via `include_str!`;
  modders override at the sim's overlay path). `FactionId(u16)` is
  the ECS-side handle; persistence keys on the registry **name
  string** (`"pwa"`) so saves stay valid across registry edits.
  `Relation` is the 5-anchor spectrum (`Hostile`/`Cold`/`Neutral`/
  `Warm`/`Friendly`) with continuous `i16` scores; `anchor_score` /
  `band_from_score` snap. See the "Faction registry — step 4" entry
  below for the migration that retired the legacy `Faction` enum.
- **Bases** - first-class entities with `Base{kind}` + `InFaction` +
  `InRegion` + `Position` + `Health`. `BaseKind`: Checkpoint,
  Outpost, Safehouse, Headquarters, ResearchPost.
- **Random world content** - deterministic `world_seed` module seeds
  `RegionControl` (primary faction + contested-by + tension) and
  spawns 25–40 bases per region via stratified placement on a 7×7 grid
  (±2300m square, ~660m cells, one base max per cell) so they spread
  rather than clump. `Sim::new_with_seed` exposes the seed; `Sim::new`
  uses a fixed default for reproducible dev demos. The Merged are
  excluded from random seeding (endgame-only). `Sim::load_or_new`
  gracefully falls back to a fresh sim if a stale snapshot fails to
  load. Replaced wholesale when authored region content lands.
- **NPC foundation + chronicle** - the bottom layer of the NPC
  architecture defined in `../walkthroughs/ai-generation.md` and
  `../walkthroughs/tactical-ai.md`. Higher layers (Personas, Memory,
  LLM narration, sim brain, GOAP/squad tactical AI, scripted quests)
  are designed in detail and parked; they plug into `NpcId`/`Group`
  hooks here. Today this layer ships: `Npc { id: NpcId }` +
  `NpcGoal` (Idle/MoveTo/RestAt FSM) + `Lifespan` + optional `Group`
  + `Aggression(f32)` + `NpcCharacter { character_id, stats }`
  components, plus transient `Aggro` /
  `LastDamager`; `NpcCharacter` carries a stable `CharacterId` derived
  from `(npc_id, faction_id)` plus an eight-stat `NpcStats` block
  (accuracy, perception, stealth, strength, endurance, marksmanship,
  leadership, luck — each `0..=100`). Substrate-only today: no system
  reads stats yet. Re-rolled deterministically on snapshot reload from
  the same identity inputs, so no inline persistence is needed; future
  identity-evolution fields (personality drift, rank progression) get
  inline storage + a `FORMAT_VERSION` bump when they land.
  `spawn_npcs` tops up populations toward
  `PopulationTargets` in faction-flavored squads near same-faction
  bases; `tick_npc_goals` drives wandering (with a 30% chance of a
  long-march target up to 1.2km away) and overrides patrol with
  pursue-to-engage when aggroed; `rebuild_spatial_hash` builds a
  per-region 100m-cell grid (`NpcSpatialHash`) every tick so
  `npc_aggro` Pass 2 can pair-scan within-cell + 4 directional
  neighbors - dropping the scan from `O(Σ n_r²)` to near-linear and
  enabling aggro + combat to run in offline regions without tanking
  tick time; **the Pass 2 pair scan is rayon-parallel across cells**
  (each cell writes into a per-cell `CellWork` buffer; a deterministic
  sequential merge over the sorted cell list drains side-effects in
  stable order); **Pass 2 also runs on a coarser cadence at high pop**
  (`PASS_2_TICK_INTERVAL = 3` when online snapshot > 64 NPCs — the
  decay window `AGGRO_DECAY_TICKS = 200` is two orders of magnitude
  larger so a 3-tick acquisition gap is invisible to gameplay; the
  `LosCache` retains entries for the same window so `npc_combat`'s
  fire gate reads a fresh exposure on off-cadence ticks); `npc_aggro` acquires hostile-faction
  targets in same-region sight (~80m) and squad-shares within
  `Group`; `squad_planner` (every ~10s) rolls a per-squad
  `SquadObjective` (Patrol/Guard/Rest/Explore/Investigate/Relieve/Wander/Regroup) from
  per-faction archetype weights, biases Patrol toward unvisited
  bases, and overrides to Regroup if any member drifts past the
  squad's cohesion-break threshold from the squad centroid (default
  80 m, scaled per-squad by `cohesion_multiplier_for_leadership(mean_leadership)`
  — linear in `[0.7, 1.3]` over mean group leadership `0..=100`, 1.0× at
  50, so leader-rich squads stretch ~104 m and unled grunts collapse
  at ~56 m; squads with no `NpcCharacter` carriers fall back to the
  flat 80 m). Aggroed squads bypass the planner;
  `npc_combat` is a pure fire-decision system every
  `FIRE_INTERVAL_TICKS` (50 ticks ≈ 2.5 s) — FOV / LOS / range /
  aggression gates produce `NpcShotIntent` queue entries, and the
  projectile tick (`world/projectiles.rs` → `world/hitbox.rs`
  swept-ray against humanoid body parts) resolves hit and damage.
  Aggression now drives *fire cadence* (`fire_chance = 0.5 + 0.5
  * aggression`); hit/miss is geometric (cone-of-fire jitter
  scaled by accuracy in `Sim::npc_fire_projectile`). The legacy
  `accuracy_hit_multiplier(accuracy)` helper is retained for the
  `accuracy_combat_endpoints` unit test but no longer consumed at
  runtime;
  `npc_death_check`
  logs `DeathCause::Combat { killer_faction }` from the `LastDamager`
  hint and despawns; `migrate_npcs` rolls rare cross-region
  migrations (suppressed while aggroed); `age_npcs` kills NPCs whose
  lifespan expired. Every NPC ever spawned gets a permanent
  `LifeRecord` in the `LifeChronicle` resource (birth/death ticks,
  regions visited, cause), kept after despawn - so the in-game
  journal and any future "who lived here last week" query has data
  to read. `LifeChronicle::summary()` now returns
  `&ChronicleSummary` from an internal `#[serde(skip)]
  summary_cache` maintained incrementally by `insert` and
  `mark_dead(id, tick, region, cause)`. **All death sites must
  route through `mark_dead`** (`npc_age`, `npc_death_check`,
  offline-combat in `offline_tier`, `world::debug::kill_npc_for_test`)
  - directly mutating `LifeRecord::death_tick` via `get_mut` drifts
  the cache. `rebuild_summary_cache()` reseeds the cache after
  snapshot load (called from `Sim::load`). `ChronicleSummary` and
  `FactionStats` gained `Serialize` / `Deserialize` derives so the
  cache can round-trip if a caller wants it. Drops
  `chronicle_summary()` cost from O(records) per call to O(1).
  The combat layer is partially **placeholder**: the projectile +
  hitbox pipeline (Phase 4A v2) is real, but pathfinding-around-
  cover, peek-shoot decisions, and full GOAP are still parked
  pending tactical AI (`../walkthroughs/tactical-ai.md`). Squads
  do consult `LosCache` (fire-decision gate + perception) and
  fire with cone-of-fire jitter scaled by accuracy.
- **Time + weather** - `WorldTime` (day, seconds_of_day,
  day_length_seconds; `sun_angle_rad()`, `is_daytime()`) +
  `WeatherState` (11-variant PNW palette: Clear / PartlyCloudy /
  Overcast / MarineLayer / Fog / Drizzle / LightRain / HeavyRain /
  Windstorm / Thunderstorm / SmokeHaze). `advance_weather` rolls
  transitions every ~30 in-game minutes using per-kind Markov
  weights. Both snapshot through `SnapshotBody`. gdext bridge
  exposes `SimHost.world_time()` (returns `sun_angle_rad`,
  `is_daytime`, `moon_phase`, `moon_illumination`, `moon_angle_rad`,
  `moon_phase_name`) and `SimHost.weather_state()`
  (`current`, `next`, `transitions_at_tick`); `test_map.gd` drives
  the sun `DirectionalLight3D`, procedurally adds a moon
  `DirectionalLight3D` that fades in at dusk and scales with
  illumination + smoke haze tint, and updates `WorldEnvironment`
  fog density / color / background based on these, lerping smoothly
  between states.
- **Terrain Y-clamping** - `TerrainMaps` resource holds an
  `simn_terrain::Heightmap` per `RegionId`; `Sim::attach_region_terrain`
  inserts one and snaps every existing `Base` in that region to ground
  in the same call. The per-tick `clamp_npc_terrain_y` system snaps
  every `Npc`'s `Position.y` to `terrain.sample(x, z)` for any region
  whose entry is populated. Regions without attached terrain skip
  clamping and retain the legacy flat-floor (Y=0) behavior.
  `TerrainMaps` is transient - not serialized; the engine bridge
  re-attaches on every sim startup.
- **Neutral campsites** - `BaseKind::CampSite`, seeded 4–7 per region
  under `Faction::Wanderers` (placeholder neutral owner). Not counted
  by `RegionControl`; any faction's `Rest` objective prefers camps
  before same-faction Safehouse/Outpost.
- **Perception** - `PerceptionConfig` (fov_deg, sight_radius_m,
  exposure_required, sample_heights_m, concealment_visibility) +
  `LosProvider` trait. `npc_aggro` gates candidates by distance,
  mutual FOV cone, and `LosProvider::exposure` ≥
  `exposure_required`. Default provider (`AlwaysVisibleLos`) returns
  1.0. `simn-godot` installs a `GodotLosProvider` that multi-samples
  heights via `PhysicsDirectSpaceState3D::intersect_ray` and weights
  concealment-only hits at `concealment_visibility`. Collision-layer
  contract: solid (bit 0), concealment (bit 1), NPC hitbox (bit 2,
  scaffold). **Per-NPC sight scaling** - the
  `NpcCharacter::stats.perception` stat scales `sight_radius_m` per
  NPC via `sight_radius_for_perception(perception, base)`: linear
  multiplier `[0.6, 1.4]` over perception `0..=100`, centered on 1.0
  at perception 50. `npc_aggro` checks distance asymmetrically — A
  spotting B gates on A's range, B spotting A gates on B's range —
  so a high-perception sniper can acquire aggro on a low-perception
  target at distances the inverse pair can't reach. Pre-cull uses
  the larger of the two. NPCs without `NpcCharacter` (legacy /
  bare-spawn paths) collapse to the flat baseline.
- **Pathfinding (phase 1, 2026-05-05/06)** - `nav` module exports a
  `NavQuery` trait, `GridNavQuery` (uniform-grid A* with deterministic
  NW-to-SE tie-breaking + style-aware line-of-sight simplification),
  a `TravelStyle` enum (`RoadHugger` / `Mixed` / `Bushwhacker`) that
  drives per-cell cost multipliers based on `FeatureClass`, and a
  `NavQueries` resource keyed by `RegionId`. Built lazily inside
  `Sim::attach_region_terrain` from each region's `Heightmap` -
  per-cell passability (slope > ~35° or `FeatureClass::{Water,
  Cliff}` -> impassable), feature class for cost-mult lookup, and
  precomputed Y. Public API: `Sim::path_in_region(region, from, to,
  style)`, `Sim::is_traversable(region, pos)`,
  `Sim::nav_grid_dims(region)`, `Sim::nav_traversability(region)`.
  Engine-agnostic; bridged into Godot via `SimHost::path_in_region`
  (now takes a style string: `"road"` / `"mixed"` / `"bush"`) /
  `is_traversable` / `nav_grid_dims` / `nav_traversability`.
  **Iteration 5-13 Phase A1:** `GridNavQuery::from_heightmap` consults
  the heightmap's optional designer-painted `NavOverride` per nav
  cell. `ForceBlocked` overrides slope+class and marks the cell
  impassable; `ForceWalkable` overrides cliff/water/slope and marks
  it passable; `Default` defers to the existing slope+class logic.
  The override byte is cached per cell in `GridNavQuery.cell_override`
  (exposed via `cell_override(cx, cz) -> NavOverride`) so Phase B2's
  in-memory POI obstacle stamping can enforce the painter-wins merge
  rule without re-reading the heightmap. Maps without a painted
  mask continue to build identical grids to the pre-A1 baseline.

  **Iteration 5-13 Phase B2:** `NavObstacle { center: [f32; 2],
  extents: [f32; 2], kind: NavOverride }` represents a single
  scene-placed AABB nav override. `GridNavQuery::apply_obstacles`
  walks each obstacle's AABB → cell range → flips `cells[idx]` per
  the painter-wins merge rule (painter `ForceWalkable` survives a
  POI `block`; POI `walkable` overlays everything). `Sim::attach_region_terrain_with_obstacles(region, heightmap, obstacles)` is the
  obstacle-aware variant of `attach_region_terrain`; the original
  signature stays as a thin back-compat wrapper. `NavQueries::apply_obstacles`
  uses `Arc::make_mut` for the zero-copy fast path when no
  snapshots are outstanding. Obstacles are transient — never
  persisted; the Godot scene is the source of truth and the
  bridge re-enumerates on every region attach. New bridge
  `#[func] SimHost::load_region_terrain_with_obstacles(region_name,
  map_id, obstacles: Array<Dictionary>)` accepts `{ pos: Vector3,
  extents: Vector3, kind: String }` dicts (kind = `"block"` /
  `"walkable"`; unknown defaults to block with a once-per-call
  warn). Authoring lives in `godot/scripts/world/nav_obstacle_marker.gd`
  (`NavObstacleMarker3D`, group `&"nav_obstacle_markers"`); the
  Godot caller that walks the group + ships dicts to the bridge
  lands once production maps actually place markers.

  **Iteration 5-13 Phase C1:** `WaypointGraph { nodes: Vec<[f32; 2]>,
  edges: HashMap<u32, Vec<(u32, f32)>> }` is a sparse offline-tier
  path graph derived from the (painted + obstacle-stamped) grid.
  `WaypointGraph::build_from_grid(grid, spacing_m)` samples walkable
  cells on a configurable stride (default 32 m via
  `DEFAULT_WAYPOINT_SPACING_M`) and connects sample-stride
  neighbors that pass a Bresenham walkability trace, with cost =
  straight-line distance. `WaypointGraph::nearest_node`, `path`
  (A* with straight-line heuristic), and `reachable` (cheap BFS)
  cover the offline-tier query shapes. `NavQueries` stores one
  graph per region alongside the grid; `build_for` lands both in
  one pass and `detach` drops both.

  **Iteration 5-13 Phase C2:** `OfflineNpc` gains
  `waypoint_chain: Vec<u32>` + `waypoint_chain_idx: u32`.
  `offline_movement` now consumes the per-region `WaypointGraph`
  via the new `Res<NavQueries>` parameter:
  - `pick_offline_target` accepts an optional graph reference and
    filters base candidates by `WaypointGraph::reachable` —
    offline NPCs no longer pick targets on the wrong side of a
    painted/stamped wall. Falls back to the unfiltered pool
    when reachability empties the pool (a stranded NPC still
    picks *something* rather than freezing).
  - On no-target → target transition, the system resolves a
    chain via `WaypointGraph::path(start_node, goal_node)` and
    sizes the arrival tick to the chain's total length, not
    the bee-line distance. Empty chain (no graph, or `start_node
    == goal_node`) falls back to legacy bee-line behavior.
  - On in-flight progress, when `waypoint_chain` is non-empty,
    the NPC's `position_2d` interpolates along the segment
    list `start → chain[0] → ... → target`, each segment
    weighted by its distance. Empty chain falls back to a
    straight-line lerp (matches pre-C2 behavior so legacy
    NPCs / snapshot-loaded NPCs continue working).
  - On arrival, the chain + index are cleared so the next
    target picks a fresh chain.
  Tests: `crates/simn-sim/tests/offline_waypoint_routing.rs`
  e2e — paint a wall between (-40, 0) and (40, 0), spawn an
  offline NPC at the left side, set its target to the right
  side, tick 2000 sim ticks, assert the NPC's visited
  positions trace a path around the wall (no point lands
  inside the painted band) and the NPC made it to the right
  side. New test helpers `set_offline_target_for_test` and
  `offline_npc_position_for_test` on `Sim`.

  **Iteration 5-13 Phase D2:** `InteractionAreas` (new `Resource`
  in `resources.rs`) registers designer-placed interaction
  points — rest spots, work benches, guard posts, etc. — keyed
  by `RegionId`. `InteractionArea { id, kind, pos, extents,
  faction, capacity, occupants, tags }` is the row shape; `kind`
  is a free-form string so modders extend the vocabulary
  without code changes (canonical set: `"rest"`, `"work"`,
  `"socialize"`, `"scavenge"`, `"guard_post"`, `"patrol_node"`,
  `"campfire"`, `"workbench"`). New `Sim` API surface:
  - `attach_region_interaction_areas(region, areas)` — replaces
    the region's set wholesale; deduplicates by id (last wins)
    and rebuilds the `by_id` index. Idempotent across reloads.
  - `reserve_interaction_area(area_id, faction)` — increments
    occupants if under capacity AND the area's faction filter
    accepts. `None` faction context is rejected for any
    faction-locked area.
  - `release_interaction_area(area_id)` — decrements occupants;
    saturates at zero.
  - `interaction_areas_in_region(region)` — slice view for
    squad planner + tests.

  Lifecycle is **transient** — `InteractionAreas` is content-
  rebuilt from scene markers on every `attach_region_interaction_areas`
  call (no snapshot persistence), the same contract as
  `NavQueries`. The Godot bridge `#[func]
  attach_region_interaction_areas` parses an
  `Array<Dictionary>` (each `{ id, kind, pos, extents, faction,
  capacity, tags }`) into `InteractionArea` rows;
  `parse_interaction_areas` in `simn-godot/src/sim/mod.rs`
  resolves faction names to `FactionId`s, auto-derives missing
  ids from `auto:<region>:<x>_<z>`, and warns once on unknown
  factions or missing fields. Tests:
  `crates/simn-sim/tests/interaction_areas.rs` —
  `register_and_query_areas`, `reserve_respects_capacity`,
  `release_frees_slot`, `faction_filter_restricts_reservation`,
  `duplicate_ids_keep_last`. Phase D3 will graft this onto
  squad-objective scoring (squads prefer nearby `"rest"` areas
  over generic base positions) and fire `InteractionStarted` /
  `InteractionEnded` events from `tick_npc_goals`.

  **Iteration 5-14 Phase C — `scene_authored_pois` gate on `Region`.**
  New `Region::scene_authored_pois: bool` field (with
  `#[serde(default)]` for snapshot back-compat) marks regions whose
  bases come from scene-authored `PoiMarker3D` nodes via
  `Sim::register_authored_base` instead of the procedural scatter
  in `world_seed::seed_random_world_content`. When `true`:

  - `world_seed` skips the per-region base + camp stratified
    scatter (lines 79-148 in `world_seed.rs`).
  - `RegionControl` + `PopulationTargets` for the region still
    seed normally — squads can still form once bases exist.
  - `systems::npc_spawn` (both `spawn_npcs` and `bulk_seed_npcs`)
    skips the region if zero `Base` entities exist there yet —
    without this gate, `pick_spawn_pos`'s no-bases fallback
    clusters every squad at origin in a 200 m radius and the
    O(N²) combat pass collapses the per-tick budget.

  `default_test_graph` sets the flag `true` on map_a..d. Real
  DEM-backed maps (corbett, latourell, …) stay `false`. Tests
  that exercise the procedural-scatter path (`offline_movement`,
  `loot_containers`, `loot_restock`, `terrain`, `network_replay`,
  `npcs`, `npc_projectiles`) build a `legacy_procedural_graph()`
  helper locally with the flag off. Tests:
  `crates/simn-sim/tests/scene_authored_gating.rs` —
  `scene_authored_region_has_no_seeded_bases`,
  `procedural_region_still_seeds_bases`,
  `scene_authored_region_has_population_targets`,
  `scene_authored_region_has_region_control`.

  **Iteration 5-14 Phase B — `Sim::register_authored_base`.**
  New public `Sim` API for spawning a faction base from a scene-
  authored `PoiMarker3D` (kind `BASE_*`). Signature:

  ```rust
  pub fn register_authored_base(
      &mut self,
      region: RegionId,
      pos: [f32; 3],
      kind: BaseKind,
      faction: FactionId,
  ) -> Result<Entity>;
  ```

  Spawns the same component tuple the procedural seeder uses
  (`Base`, `InFaction`, `InRegion`, `Position`, `Health::new_full()`),
  Y-snaps to attached terrain when present, and stamps the
  per-kind nav-obstacle footprint via `NavQueries::apply_obstacles`
  so squads route around the structure. `CampSite` (which returns
  `None` from `BaseKind::nav_footprint_xz_m`) does not stamp.
  Errors on unknown region.

  Bridge surface: `#[func]
  register_authored_base(region_name, pos, kind, faction) -> bool`
  on `SimHost` resolves the kind / faction strings via
  `BaseKind` variant names + `FactionRegistry::id_of`, then
  dispatches through `worker_or_direct_mut`. Returns `false` on
  validation failure (unknown region / kind / faction) with a
  `godot_warn!`. Phase E's `base_spawner.gd` is the consumer.

  Tests: `crates/simn-sim/tests/authored_bases.rs` —
  `register_spawns_full_component_tuple`, `unknown_region_errors`,
  `camp_site_has_no_nav_footprint`,
  `structured_kind_stamps_nav_footprint`.

  **Iteration 5-13 follow-up — `BaseKind::nav_footprint_xz_m`.**
  Every `BaseKind` (except `CampSite`) carries a small, conservative
  XZ half-extent the sim stamps as a `NavObstacle::ForceBlocked`
  during `attach_region_terrain`. Footprints scale with kind:
  Checkpoint 3 m, Safehouse 4 m, Outpost 5 m, ResearchPost 6 m,
  Headquarters 8 m. CampSite returns `None` (open camps don't
  block their own center). Stamping runs *after* caller-provided
  obstacles so the painter-`ForceWalkable` rule from Phase A still
  wins. Side effect: NPC pathfinding now naturally routes around
  faction structures instead of cutting through them, even with
  no scene-authored `NavObstacleMarker3D` placed. Future authored
  bases (real buildings with walls + doors) can drop the auto-stamp
  on a per-base basis once that surface lands; the footprint
  constants are the placeholder until then. Tests:
  `crates/simn-sim/src/components.rs::tests::base_kind_nav_footprint_scales_with_kind`
  (unit), `crates/simn-sim/tests/pathfinding.rs::attaching_terrain_stamps_base_footprints`
  + `camp_site_kind_does_not_block_nav` (integration).

  **Iteration 5-13 Phase D3:** `SquadObjective::Rest` gains
  `area_id: Option<String>`. Existing un-`area_id`'d `Rest`
  objectives keep working (base-position fallback). The squad
  planner's `build_rest` first probes `InteractionAreas` for a
  `kind == "rest"` candidate within
  `REST_INTERACTION_AREA_PREFER_RADIUS_M` (150 m) of the squad
  centroid, faction-matching, with free capacity — and reserves
  it before returning the objective. The release path runs on
  the next objective swap (cohesion override, expiration,
  squad death). `tick_npc_goals` emits
  `WorldEventKind::InteractionStarted { npc_id, area_id, kind }`
  on first arrival per `(npc_id, area_id)` pair (deduped on
  `InteractionAreas.started`); the planner emits the matching
  `InteractionEnded` for every NPC that was Started at the
  area when the objective gets replaced. Both events carry a
  0 m audible radius and `Audience::Anyone` so they flow
  through the bus to PDA / replication consumers without
  polluting nearby squad blackboards. Tests:
  `crates/simn-sim/src/systems/squad_planner.rs::tests` —
  `picks_in_range_rest_area_over_far`, `rejects_full_capacity_area`,
  `rejects_mismatched_faction`,
  `accepts_unrestricted_faction_for_any_squad`,
  `skips_far_area_outside_radius`. Plus
  `started_set_dedupes_and_drains` and
  `attach_clears_started_for_replaced_areas` in
  `tests/interaction_areas.rs`.
- **NPC path-following (2026-05-06)** - `Path` component carries
  cached waypoints, recomputed on goal change or target drift > 8 m.
  `tick_npc_goals` consumes it in all three branches (aggro pursuit
  uses `Bushwhacker`; squad objectives pick a style from
  `style_for(faction, objective)` so PWA/Linemen/Federal patrols
  hug roads while Wanderers / NoosphereWorshippers stay
  bushwhackers; solo FSM uses `Mixed`). On pathfinding failure or
  exhaustion, falls back to straight-line `move_toward` so the NPC
  doesn't freeze. `Path` is not journaled - rebuilds from
  goal/target/heightmap on replay.
- **Determinism harness (2026-05-06)** - `crates/simn-sim/tests/determinism.rs`
  ticks two same-seed `Sim` instances side-by-side and asserts their
  in-memory snapshots are byte-identical. Catches `HashMap` iteration
  drift, stray `Entity::to_bits()` in RNG seeds, query-iteration order
  leaks, and any other source of nondeterminism that could break
  journal+snapshot replay or multiplayer mirror sync. Three tests:
  byte-identical at tick 200 (seed 42), at three checkpoints (seed 7),
  and that different seeds DO produce different state.
  Supporting changes:
  - `det_serde::sorted_map` / `sorted_nested_map` serde adapters
    apply to `RegionGraph::regions`, `Region::transitions`,
    `RegionControl::by_region`, `PopulationTargets::by_region`, and
    `Equipment` (custom `Serialize` impl).
  - `Sim::write_snapshot_to_vec()` produces the same bytes as
    `roll_snapshot` would write to disk; used by the harness and
    earmarked for the eventual replication broadcast path.
  - `serialize_world` now sorts entities by `entity_sort_key`
    (NpcId / steam_id / ContainerId / ProjectileId / base
    region+pos hash) before emitting, so bevy's archetype storage
    order doesn't bleed into snapshot bytes.
  - Removed `Entity::to_bits()` from RNG seeds in `npc_goals` and
    `npc_migrate`; bevy entity ids aren't stable across instances.
  - Sorted HashMap iterations in `npc_spawn`, `npc_aggro`,
    `npc_combat`, `squad_planner` so tick-seeded RNG draws happen
    in a stable order.
  See `docs/book/src/planning/sim-hardening-plan.md`.
- **World event bus (2026-05-06)** - `world_event_bus::WorldEventQueue`
  resource is the AI-strategic event broadcaster (cousin of the
  encounter-dispatcher; see plan for the scope split). `WorldEventKind`
  enum: `Gunshot { caliber_class }`, `Explosion`, `AllyDown`,
  `EnemySighted`, `CorpseSpotted`, `BaseFlip`, `PlayerSighted`,
  `PortalUsed`, `Chatter`, `ModExtension`. Producers push during
  their normal pass; `drain_world_events` runs at tick start
  (after `index_npc_positions`, before `npc_aggro`) and delivers
  events to listening squad blackboards via per-kind audible-radius
  + `Audience` filter (Anyone / SameFaction / HostileTo /
  GlobalFaction). Linear distance falloff scales blackboard TTLs;
  global events (BaseFlip) bypass region + radius checks.
  No de-duplication (locked decision: 5 squadmates firing = 5
  events). Public API: `Sim::push_world_event(kind, position,
  region, ttl)`, `Sim::world_event_queue_len()`. One emitter wired:
  `npc_aggro` pushes `EnemySighted` on new acquisition so adjacent
  hostile-faction squads pick up the target via their own
  blackboards next tick. **Perf optimizations (2026-05-23)**: both
  `drain_world_events` AND `npc_aggro` pre-compute a per-tick `F×F`
  hostility matrix so neither calls `faction_relation` in their
  inner loops (the routed path allocates two `String`s per call
  via `canonical_pair_names`). `apply_to_blackboard` short-circuits
  when an `EnemySighted` would just overwrite the same fresh
  `LastKnownEnemyId`. **Squad-level event throttle (2026-05-23)**:
  `npc_aggro` now skips emitting `EnemySighted` whenever the
  spotter's squad already has *any* fresh `LastKnownEnemyId` entry
  (not just one matching this target). The direct `bb_write` to
  the spotter group still fires, so the spotter's own squad sees
  the new target; only the broadcast to other hostile-faction
  groups is suppressed. **Consumer-visible**: `EnemySighted`
  events/tick observed at the bus dropped from ~1100 to ~73 at
  dense pop. Other hostile factions get fewer notifications
  through the bus, but their own `npc_aggro` pair-scan still picks
  up enemies on its own cadence. `drain_world_events` also
  spatial-bins groups by `EVENT_BUCKET_CELL_M = 200 m` cells
  (matches the largest audible radius); each event walks only the
  3×3 cells around its position instead of the whole region's
  group list. At dense pop (720 NPCs) these collapsed
  `drain_world_events` from ~98 ms/tick to ~3 ms/tick. No Godot
  bridge yet. See `docs/book/src/planning/world-event-bus-plan.md`.
- **Threat board — step 3, target switching (2026-05-06)** — new
  `apply_threat_priority` system runs between `npc_aggro` and
  `squad_planner`. For every grouped NPC with `Aggro`, it reads
  the squad's `BlackboardKey::ThreatList` and switches
  `Aggro.target` to the top entry when the new threat dominates
  by hysteresis: top score ≥ current × `THREAT_SWITCH_MULTIPLIER`
  (1.5×) OR top score ≥ current + `THREAT_SWITCH_ABSOLUTE_DELTA`
  (2.0). Squad-coordinated focus fire emerges naturally — every
  member ends up pursuing the squad's most-threatening attacker.
  Lone NPCs (no `Group`) are unaffected. Test-only
  `Sim::set_npc_aggro_for_test(victim, target)` helper lets
  integration tests stage initial-aggro scenarios. 3 new
  integration tests in `tests/threat_board.rs` (target switch on
  3× damage, hysteresis hold on 1.01× damage, ungrouped NPC
  unaffected). Step 2 (sweep + aggregation) and step 3 together
  give squads multi-target awareness; the underlying combat
  pipeline still uses the single `Aggro.target` for fire
  decisions.
- **Threat board — step 2, sweep + aggregation (2026-05-06)** —
  new `systems::threat_board::sweep_threats` system runs at tick
  start (after the position index rebuild, before any consumer).
  Two passes:
  1. Sweep each NPC's `RecentAttackers`, dropping events past
     `THREAT_TTL_TICKS`.
  2. For every `Group` with members carrying surviving events,
     aggregate per-attacker damage across the squad, score by
     `damage × recency × proximity`, sort descending by score
     (with a deterministic attacker_id tiebreak), and write
     `BlackboardKey::ThreatList` → `BlackboardValue::Threats(Vec<ThreatEntry>)`.
  Proximity is computed against the closest squadmate (the squad's
  "nearest face"). Constants: `PROX_FULL_RADIUS_M = 30`,
  `PROX_FADE_RADIUS_M = 80`, both in `systems::threat_board`.
  Test-only `Sim::record_npc_hit_for_test(victim, attacker, tick, damage)`
  helper on `world::debug` lets integration tests stage threat
  scenarios without running the combat pipeline. 7 unit tests
  (recency / proximity scoring) + 4 integration tests in
  `tests/threat_board.rs` (aggregation, top-score-is-highest-
  damage, solo-no-board, recency-decay-changes-ranking). Step 3
  wires the threat board into goal arbitration so squads switch
  targets on dominant new threats. See
  `docs/book/src/planning/threat-board-plan.md`.
- **Threat board — step 1, data model (2026-05-06)** — extends the
  single-target `Aggro` substrate with multi-target tracking.
  - `LastDamager` gains `attacker_id: Option<NpcId>` + `tick: u64`
    so we know who shot us recently, not just their faction.
  - New `RecentAttackers` component on every NPC: capped (`MAX_RECENT_ATTACKERS = 8`)
    Vec of `AttackerHit { attacker_id, tick, damage }`.
    Same-attacker hits accumulate damage in place; oldest evicts
    FIFO at cap. `record(...)` and `sweep(cutoff)` helpers.
  - New `BlackboardKey::ThreatList` + `BlackboardValue::Threats(Vec<ThreatEntry>)`
    on the squad blackboard. `ThreatEntry { target_id, score, last_seen_tick }`.
    Squad-shared, populated each tick by the sweep system in step 2.
  - Constants `THREAT_TTL_TICKS = 600` (~30s at 20 Hz) and
    `MAX_RECENT_ATTACKERS = 8` exported from `systems::npc_combat`.
  - `npc_combat` now stamps the new `LastDamager` shape and records
    hits on `RecentAttackers`. Squad aggregation lands in step 2;
    target-switching arbitration lands in step 3. See
    `docs/book/src/planning/threat-board-plan.md`.
- **Squad blackboard (2026-05-06)** - `squad_blackboard::SquadBlackboards`
  resource holds a per-`Group` typed key/value store with TTLs. Drives
  squad coordination: shared "last known enemy position", "ally went
  down at X", "heard gunshot", "rally point", etc. `BlackboardKey` is
  a closed enum for engine facts plus a `Custom { mod_id, name }`
  variant for mod extension. Per-tick `sweep_squad_blackboards`
  system evicts expired entries (and prunes empty groups). Persistence:
  derived state, not journaled - rebuilds from world state + recent
  events on tier transition. Public API: `Sim::squad_blackboard(group_id)
  -> Option<&GroupBlackboard>`. One writer hooked up so far: `npc_aggro`
  records `LastKnownEnemyId` + `LastKnownEnemyPos` on new aggro
  acquisition (TTL = `AGGRO_DECAY_TICKS`); future PRs add `npc_combat`
  / `npc_death_check` / world event bus writers and the squad-planner /
  goal-arbitration readers. See
  `docs/book/src/planning/squad-blackboard-plan.md`.
- **LOS cache (2026-05-06, retention bumped 2026-05-23)** -
  `los_cache::LosCache` resource caches per-tick line-of-sight
  exposure values keyed `(observer, target)` (asymmetric — both
  directions store separately). Written by `npc_aggro`'s Pass 2
  when its FOV pass calls the LOS provider; the `clear_los_cache`
  system runs at the top of each tick and now **retains entries
  for `PASS_2_TICK_INTERVAL` ticks** (via the new
  `LosCache::retain_newer_than` helper) instead of clearing
  unconditionally — needed because Pass 2 itself only runs every
  `PASS_2_TICK_INTERVAL` ticks at dense pop, and consumers
  reading on off-cadence ticks must see the most-recent reading
  rather than a cleared cache. Public API:
  `Sim::los_exposure(observer, target) -> Option<f32>`. Godot
  bridge: `SimHost::los_exposure(observer_npc_id, target_npc_id)
  -> f32` (returns `-1.0` for no entry). **Consumers now live**:
  `npc_aggro` itself reads the cache to avoid re-raycasting
  symmetric pairs, and `npc_combat`'s fire-decision gate keys off
  it (no entry / low exposure → no shot, exposure ≥
  `LOS_FIRE_THRESHOLD` → fire). Future cover-system queries +
  tactical AI peek-shoot will plug in the same way. See
  `docs/book/src/planning/combat-los-plan.md`.
- **Faction registry — steps 6+7 (2026-05-06)** — debug-color
  bridge + drift journaling close out the migration.
  - **Step 6**: renamed `FactionDef.color` to `debug_color` (with
    `#[serde(alias = "color")]` for back-compat with existing
    overlay TOML), added `Sim::faction_debug_color(name)` accessor
    + `SimHost::faction_debug_color(name) -> Color` gdext bridge.
    GDScript `FactionColors.refresh_from_sim(sim_host)` walks the
    registry once at session start and primes a Dictionary cache;
    callers (`base_marker`, `faction_materials`, `humanoid_dummy`)
    keep the static `FactionColors.of(name)` API. Hardcoded
    palette table dropped — colors are sourced from
    `content/factions.toml` per faction's `debug_color`
    field. Cache primes on `_start_authoritative_sim`,
    `join` (mirror sim), `force_save`, and `delete_save`.
  - **Step 7**: drift journaling. New `WorldDelta` variants
    `FactionRelationShift { a, b, delta, reason }` and
    `PlayerRepShift { steam_id, faction, delta, reason }`. New
    `Sim::shift_faction_relation(a, b, delta, reason)` and
    `Sim::shift_player_rep(steam_id, faction, delta, reason)` APIs
    that apply the drift in-memory AND journal/broadcast the delta.
    `apply_delta` handles both variants (resolves names against the
    active registry; drops the shift on replay if the registry no
    longer contains a faction the journal references).
    `SnapshotBody` gains `relation_deltas` + `player_reputation`
    fields; `Sim::load` and `apply_external_snapshot` restore them
    instead of defaulting to empty. Tests:
    `faction_relation_drift_persists_across_save_load` (push
    pwa↔revere_guard from Hostile to Friendly, shutdown, reload,
    verify net) and `player_rep_drift_persists_and_isolates`
    (player A trashes their Linemen rep to Hostile, player B nudges
    +50 to Warm, both survive save/load and stay isolated).
  Migration complete; faction registry is now the single
  source of truth for roster, relations, debug colors, and runtime
  rep evolution. See
  `docs/book/src/planning/faction-registry-plan.md`.
- **Faction registry — step 5 (2026-05-06)** — canonical roster
  expansion + lore scrub. `content/factions.toml` now
  contains the full 16-id roster: 9 top-level (`pwa`,
  `revere_guard`, `federal`, `gulf_compact`, `aegis_pacific`,
  `attuned`, `merged`, `bandits`, `wanderers`) + 7 subfactions
  (`linemen`→`pwa`, `ghost_teams`→`federal`, `registry`→
  `gulf_compact`, `recovery_division`→`aegis_pacific`, `choir`→
  `attuned`, `looters`→`bandits`, `cartel`→`bandits`). Subfactions
  inherit their parent's relation row unless they declare an
  override; the canonical TOML lists ~40 lore-mandated relations
  total. `mexican_spec_ops` deleted (faction + lore doc +
  the design overview paragraph + TODO line + SUMMARY entry). Per-faction
  tuning tables (`weights_for`, `squad_size_for`, `pick_base_kind`)
  are now parent-walk-aware via the new
  `FactionRegistry::resolve_with_parent_walk` helper — Choir
  inherits Attuned's tuning, Linemen inherits PWA's, Cartel and
  Looters inherit Bandits, etc., and any unrecognized faction
  (mod-defined) gets a balanced default. `pick_primary_faction` now
  emits only top-level faction names (subfactions never become
  region primaries — they spawn within their parent's territory).
  New `FactionRegistry::top_level()` iterator. Tests:
  `default_toml_loads_clean` updated for the 16-id roster;
  `subfaction_inherits_parent_relations` proves Looters inherits
  Bandits→PWA hostility and Cartel's explicit override flips
  Compact relation. See
  `docs/book/src/planning/faction-registry-plan.md`.
- **Faction registry — step 4 (2026-05-06)** — legacy `Faction`
  enum + hardcoded relation matrix DELETED. Every reader migrated
  to the registry: `InFaction(FactionId)`, `SpatialEntry.faction:
  FactionId`, `LastDamager.faction: FactionId`, `Aggression`
  baseline reads from `registry.def(id).base_aggression`. Persisted
  state (`PopulationTargets`, `RegionControl`, `LifeRecord.faction`,
  `WorldDelta::NpcSpawned.faction`, `DeathCause::Combat.killer_faction`,
  `BehaviorLog.spawns_by_faction`, `ChronicleSummary.by_faction`,
  `NpcLoadoutRegistry.by_faction`) all keyed by registry **name
  string** (`"pwa"`) so saves stay valid across registry edits.
  `Relation` keeps the 5-step spectrum + score / band helpers.
  Godot bridge migrated: `SimHost::all_factions()` reads from
  `sim.faction_registry().defs()`, `faction_relation` resolves names
  through the registry. `Sim::set_population_target` /
  `_for_test` / `spawn_npc_for_test` now take `&str` faction names.
  `weights_for` / `squad_size_for` / `pick_base_kind` /
  `pick_primary_faction` match on registry name strings — modders
  adding a new faction get the registry default weights, and step 5
  moves these tables onto `FactionDef` so they become pure config.
  Test files migrated: `Faction::Pwa` → `"pwa"`,
  `Faction::ALL` → `sim.faction_registry().defs()`,
  `b.faction as u8` → `b.faction.0`. The `legacy_faction_id` /
  `legacy_faction_name` shims and the parity test against the
  hardcoded matrix are gone — the registry is now the single source
  of truth. See `docs/book/src/planning/faction-registry-plan.md`.
- **Faction registry — step 3 (2026-05-06)** — `InFactionId(FactionId)`
  parallel component lands. Set at every NPC and base spawn site
  alongside the legacy `InFaction(Faction)`: `npc_spawn::spawn_npcs`,
  `world_seed::seed_random_world_content`, `Sim::spawn_npc_for_test`,
  `WorldDelta::SpawnNpc` replay, and `spawn_serialized` (loads
  derive `InFactionId` from the legacy `InFaction` via
  `legacy_faction_id` since the numeric registry id isn't stable
  across rebuilds). Not serialized — derived on load. Test-only
  accessor `Sim::npc_in_faction_id_for_test`. The legacy
  `InFaction` still drives every reader (npc_aggro, npc_combat,
  squad_planner, npc_join_group, …); steps 4-5 migrate readers
  file-by-file. Step 6 deletes `InFaction` and the `Faction` enum
  once nothing reads them.
- **Faction registry — step 2 (2026-05-06)** — registry boots on
  every `Sim::new` / `Sim::load` / mirror-sim init. Canonical
  config lives at `content/factions.toml` and is
  embedded via `include_str!` (`DEFAULT_FACTIONS_TOML`); modders
  override at the sim's overlay path (step 5). New
  `Sim::faction_registry()`, `relation_deltas()` /
  `relation_deltas_mut()`, `player_reputation()` /
  `player_reputation_mut()` accessors. `legacy_faction_name(f)` and
  `legacy_faction_id(reg, f)` shims map the still-living `Faction`
  enum to registry ids during steps 3-4 of the migration. The
  registry's `default_self_relation` is configurable in TOML
  (defaults to `warm` so legacy `npc_join_group` semantics —
  `relation == Warm` means "same-faction squadmate" — keep working
  unchanged). Parity test `registry_parity_with_legacy_matrix`
  cross-checks all 100 legacy `Faction × Faction` pairs against the
  registry, catching drift between the two systems during the
  migration window. Step 3 starts cutting `InFaction(Faction)` →
  `InFaction(FactionId)`.
- **Faction registry — step 1 (2026-05-06)** — TOML-driven faction
  registry lands as a parallel system; the legacy closed `Faction`
  enum + hardcoded relation matrix continue to drive gameplay during
  the migration. New module `faction::registry` exports
  `FactionId(u32)`, `FactionDef`, `FactionRegistry`, `RelationDeltas`,
  `PlayerReputation`, `RegistryError`, plus the lookup APIs
  `faction_relation` / `player_relation` (and `_score` variants),
  `shift_faction_relation` / `shift_player_rep`, and the loaders
  `load_from_path` / `load_from_str`. Re-exported from `lib.rs` with
  a `registry_*` prefix so legacy `relation()` (closed-enum matrix)
  and the new path coexist. The `Relation` enum got the spectrum
  rename: variants are now `Hostile / Cold / Neutral / Warm /
  Friendly` (ordered along a number line), with `Detente` collapsed
  into `Neutral` and `Friendly` added on top. `anchor_score(r)`
  exposes the canonical `i16` anchors (`-100 / -50 / 0 / +50 / +100`)
  and `band_from_score(score)` snaps continuous scores back to a
  band, with anchor-centered thresholds at `±25 / ±75` so small drift
  doesn't immediately re-classify. The legacy matrix's one
  `Detente` cell (`Pwa ↔ GulfCompact`) is now `Neutral`. Step 2
  migrates `InFaction(Faction)` → `InFaction(FactionId)`. See
  `docs/book/src/planning/faction-registry-plan.md`.
- **Goal arbitration (2026-05-06, blackboard-urgency landed 2026-05-11)** -
  `goal_arbitration` system runs per tick after `squad_planner`, before
  `tick_npc_goals`. Collects candidate goals from every source the
  resolver knows about (`IndividualAggro`, `SquadAggro`,
  `BlackboardUrgency` for `DownedAlly` / `UnderFireAt` /
  `HeardGunshot`, `SquadObjective`, `PersonalityBias`, `Idle`), picks
  max by priority + recency tiebreak, applies hysteresis (new winner
  must beat current `ActiveGoal.priority` by ≥ 20 points to preempt;
  same-source re-derivations refresh `expires_at` instead), writes
  the winner to the per-NPC `ActiveGoal` component. Default priority
  table: `ScriptedClaim` 240, `IndividualSurvival` 220,
  `BlackboardUrgency::DownedAlly` 180, `SquadAggro` 160,
  `IndividualAggro` 150, `BlackboardUrgency::UnderFireAt` 140,
  `BlackboardUrgency::HeardGunshot` 100, `SquadObjective` 80,
  `PersonalityBias` 60, `Idle` 0. `tick_npc_goals` no longer
  branches on `Aggro`/`Group`/`SquadObjectives` directly; it
  dispatches on `ActiveGoal.kind` (`PursueTarget` /
  `SquadFollowObjective` / `InvestigateAt { pos }` /
  `RegroupOnAlly { id, pos }` / `SoloIdleFsm`) so future Stage 2+
  goal sources slot in by writing into arbitration without growing
  the executor. Blackboard-urgency kinds (`InvestigateAt` and
  `RegroupOnAlly`) move the NPC toward the blackboard position at
  `Bushwhacker` travel style, halting at squad-member arrival
  radius; reactive take-cover / suppress-back / revive behavior is
  a tactical-AI follow-up. `ActiveGoal` is component data on every
  NPC (default Idle/SoloIdleFsm at spawn) and is not serialized —
  it re-derives from the source components every tick on load.
  Test-only API: `Sim::npc_active_goal_for_test`. Stage 2 follow-up
  adds the flank-bonus rule (let `IndividualAggro` outrank
  `SquadAggro` when a different attacker engages from side/rear)
  and individual-survival candidates. Determinism: multiple
  `DownedAlly` entries on the same blackboard pick the lowest-id
  ally as the representative so two same-seed sims agree. See
  `docs/book/src/planning/goal-arbitration-plan.md`.
- **NPC realism overhaul (2026-05-27)** - amplified personality
  weights and turned the four stub personality drives into real
  behaviors:
  - `objective_utility` and `personality_bias_for_objective` triple
    their trait multipliers (range now ~[0.3, 2.5] vs the old
    [0.7, 1.5]) so personality differences are visible in playtest;
    `pick_objective` injects a personality-floor weight of 2 on
    matching objectives even when the faction archetype zeros them.
    `weights_for_known` re-tuned for clearer faction identity.
  - `GoalKind::Hunt`, `Loot`, `Socialize`, `SeekMedical` gained
    payloads (target_pos + optional context id). The legacy
    `PersonalityTraits::introduces_goals` was replaced with
    `introduces_drives` returning a new `PersonalityDrive` enum
    (`Hunt | Socialize | Loot | Bloodsport`); `goal_arbitration`
    resolves each drive into a fully-targeted `GoalKind` using
    contextual lookups (group centroid for Socialize, activity
    point catalog for Hunt, new `CorpseIndex` for Loot).
  - `Socialize` is gated to Rest-arrived squads, priority
    `PRIO_SQUAD_OBJECTIVE + 5` (85) so social NPCs visibly break
    formation into a 2 m face-inward ring. `Hunt` targets unowned
    `Stash`/`Lookout`/`Workbench` activity points; `Loot` targets
    hostile-faction corpse containers (Warm/Friendly factions are
    skipped — taboo, not greed).
  - Wounded behavior: `BodyParts` worst-leg HP gates a movement
    speed multiplier (1.0×/0.7×/0.4× at 75/25 HP thresholds);
    `vital_min() < 25.0` nominates `GoalKind::SeekMedical` at
    `PRIO_INDIVIDUAL_SURVIVAL` (220) targeting the nearest
    same-faction rest spot.
  - Dwell polish: `DwellState { pose, last_shift_tick }` component
    + `DwellPose` enum (Standing/Sitting/Crouching) drive
    renderer-side animation choice via `NpcView.dwell_pose`;
    `DwellConfig` gained `jitter_frac` / `guard_shift_interval_ticks` /
    `guard_shift_radius_m`. Per-NPC dwell durations randomized
    ±30 % so squad members exit a Rest/Guard dwell at different
    ticks; guards at Standing pose nudge position by ±1.8 m every
    ~25 s so they visibly shift weight instead of standing frozen
    for the full ~20 min tenure.
  - New `CorpseIndex` resource (`BTreeMap<ContainerId, CorpseIndexEntry>`)
    populated by `npc_death_check` + `age_npcs`, swept by
    `prune_corpse_index` (TTL ~10 min real) in the lifecycle
    schedule. `CorpseMarker { dead_npc_id, dead_faction }` component
    attaches to the spawned container for downstream queries.
  - Test-only API additions: `set_npc_personality_for_test`,
    `set_squad_objective_for_test`, `npc_yaw_for_test`. Bloodsport
    drive is intentionally deferred — needs an arena/sparring
    concept that doesn't exist yet.
- **Wanderer group sizes (2026-05-06)** - `squad_size_for` now takes
  the spawn RNG and weights Wanderer rolls 65/25/10 for solo / pair /
  trio. Mutants (`Merged`) stay strictly solo. Group component
  attaches when the actual rolled size > 1, so Wanderer pairs / trios
  participate in squad-objective behavior.
- **Active-region tier filter (2026-05-11)** - `ActiveRegions` is no
  longer a stub; the hot per-tick systems short-circuit non-active
  regions. Wired into: `npc_aggro` (skips the per-region pair-scan
  in Pass 2; Pass 1 aggro decay still runs globally), `npc_combat`
  (per-shooter check + early return when no active region),
  `tick_npc_goals` (per-NPC freeze in offline regions; matches the
  eventual offline-tier abstract sim), `goal_arbitration` (per-NPC
  skip; offline-region NPCs keep their existing `ActiveGoal`),
  `squad_planner` (per-NPC + per-group skip in both the leadership/
  personality aggregation and the planner pass), `sweep_threats`
  (per-NPC skip; offline `RecentAttackers` rings drift but
  auto-decay via TTL), `broadcast_npc_positions` (filters NPCs to
  active regions before serialization, plus full early-return when
  no active region). Net effect: with 2 regions × 800 NPCs and one
  active region, the hot path's per-tick work is ~halved. Cheap
  maintenance systems (`age_npcs`, `spawn_npcs`,
  `advance_world_time`, `tick_perishables`, etc.) still run
  globally — population dynamics and time keep moving everywhere.
- **`AggroScratch` resource (2026-05-11)** - `npc_aggro` was
  re-allocating four scratch containers every tick (`Vec<Snap>`
  snapshot + three `HashMap`s for lookups + a `pending` Vec). At
  full population that's a ~100 KB allocation churn + ~6,400
  HashMap inserts every 50 ms. The system now reads
  `ResMut<AggroScratch>` and calls `clear()` to reuse the buffers;
  bucket arrays + Vec capacity stick around across ticks.
  `AggroScratch` is engine-private (pub, but only `simn-sim`
  consumes it); re-exported from `systems::AggroScratch` and
  inserted by `Sim::build_world` / `Sim::load`.
- **`squad_planner` personality gating (2026-05-11)** - aggregation
  of `personality_sum` per group used to run every tick even though
  it only feeds the planner-interval (every 200 ticks) objective
  roll. Now gated behind `is_planner_tick` so 199/200 ticks skip
  the per-NPC personality accumulation.
- **Base capture mechanic (2026-05-25)** - same-faction squads can
  now take enemy POIs in active regions, and `Investigate` is the
  planner-side hook that gets them there. Two halves:
  1. `build_investigate` in `systems/squad_planner.rs` gained
     `bases` / `registry` / `deltas` parameters (threaded through
     `pick_objective` and the `squad_planner` system signature)
     and prefers a hostile-faction non-`Headquarters` non-`CampSite`
     base in the squad's region as the Investigate target. Picks
     from the nearest-3 with squad-RNG jitter so multiple squads
     don't all converge on the same outpost. Falls back to a
     random open-world point only when no hostile bases exist in
     region. Captures the "PWA squad walking through a Federal
     region eyes a Federal outpost" intuition without needing a
     dedicated `Raid` objective kind.
  2. New `base_capture_check` system in
     `systems/base_capture.rs`, scheduled in
     `build_schedule_npc_lifecycle` after `spawn_npcs` and gated
     to every `CAPTURE_CHECK_INTERVAL_TICKS = 60` sim ticks (3 s
     at 20 Hz). Per non-`Headquarters` base in an active region,
     counts defenders (owner faction) vs. attackers (hostile to
     owner) within `CAPTURE_RADIUS_M = 40.0` m. If defenders = 0
     AND a single hostile faction has at least
     `MIN_ATTACKERS_FOR_CAPTURE = 2` NPCs on site, flips
     `InFaction` on the base entity, vacates any matching
     `GuardPosts` claim (the old holder's squad is dead or
     routed, the new owner hasn't claimed the post via planner
     yet), and emits both a `WorldEventKind::BaseFlip { new_owner,
     old_owner }` bus event (TTL 4 ticks; pairs with the existing
     placeholder-side emit in `offline_combat`) and a
     `PdaEvent::BaseFlip` toast. Headquarters bases are immune by
     design - they're narrative anchors, not mechanically
     flippable. Tiebreak between same-count attacker factions is
     by `FactionId.cmp` for determinism. The radius is tighter
     than `OFFLINE_ENGAGEMENT_RADIUS_M = 150 m` because "at the
     base" is more specific than "fighting nearby" - a passing
     patrol shouldn't capture from a distance.

  This is the **first online-tier `BaseFlip` emitter** - the
  `offline_combat` heuristic in Phase 1F (2026-05-12) was a
  placeholder for offline regions; full contestation (per-base
  contest tier, attack cooldowns, garrison repopulation, ledger
  persistence) still lives in
  [`../planning/contestation-plan.md`](../planning/contestation-plan.md)
  and supersedes both emitters when it lands. Player-facing
  contract: [`../mechanics/npcs-and-combat.md`](../mechanics/npcs-and-combat.md)
  "Base capture (placeholder)".
- **Squad spawn-disperse gate (2026-05-24)** - fresh squads were
  piling up at their spawn base and immediately rolling
  `Guard` / `Rest` / `Patrol` against that same base, producing a
  visible NPC pileup. `SquadObjectiveState` now carries
  `disperse_target: Option<[f32; 3]>`; on a squad's first
  planner-visit `squad_planner` seeds a `Wander` objective plus a
  one-shot `disperse_target` 60–120 m away in a random direction
  (`DISPERSE_MIN_DIST_M = 60.0`, `DISPERSE_MAX_DIST_M = 120.0`) and
  refuses to roll a real objective until the squad's centroid is
  within `DISPERSE_ARRIVE_RADIUS_M = 20.0` of that point.
  `npc_goals::squad_target` returns `disperse_target` when `Some`,
  overriding the active objective's nominal target so every member
  walks toward the dispersion point. Once the centroid arrives the
  field clears and the normal `needs_new` re-roll path takes over.
  `world::debug::force_squad_objective_expiry_for_test` clears
  `disperse_target` alongside the objective so existing
  expiry/reroll tests still exercise a real re-roll instead of
  re-seeding dispersion.
- **Stuck-squad detection (2026-05-24)** - companion to the spawn-
  disperse gate. `SquadObjectiveState` gained
  `last_progress_pos: Option<[f32; 3]>` and `last_progress_tick: u64`
  (transient, not serialized; all literal constructions updated).
  Each planner pass over a group with a movement-oriented
  objective (`Patrol` / `Investigate` / `Explore` / `Relieve` /
  `Wander`) compares the current centroid against
  `last_progress_pos`; if XZ travel ≥ `STUCK_PROGRESS_M = 5.0 m`
  the observation refreshes, otherwise the gap to
  `last_progress_tick` is checked against `STUCK_TICKS = 600`
  (≈ 30 s at 20 Hz). On overrun the planner force-expires the
  objective and pushes the dead target into `recently_visited`
  via `push_recent`, so the immediate re-roll inside
  `pick_objective` won't pick the same wedged destination.
  Stationary objectives (`Rest` / `Guard` / `Regroup`) skip the
  check entirely — they're supposed to be still. Catches
  unreachable targets, geometry wedges, and multi-squad pile-ups
  where the centroid is anchored by peer separation.
- **Rest formation widened (2026-05-24)** - `formation_offset`
  branch for `SquadObjective::Rest` is now its own arm instead of
  sharing `Regroup`'s tighter ring. Mirrors the `Guard` branch:
  base radius 10 m + per-squad jitter (0..20 m via
  `squad_radius_jitter`) + per-NPC ±2 m jitter, clamped to
  ≥ 6 m. Several squads routinely converge on the same outpost
  (often the only same-faction base in a region); the prior
  4–24 m shared band stacked them on the same disk. Wider per-
  squad rings interleave over a larger disk so multi-squad
  Rest pile-ups read as a loose camp rather than a clump.
- **Peer separation strengthened (2026-05-24)** -
  `SEPARATION_RADIUS_M` 2.5 → 3.5 m and `SEPARATION_NUDGE_M`
  0.1 → 0.3 m. The original 2.5 m / 0.1 m settling took ~30 s
  to visibly de-clump stacked NPCs; the new values converge in
  ~1 s on the same scenarios. The dense-population gating
  (`SEPARATION_TICK_INTERVAL = 2`, `SEPARATION_DENSE_THRESHOLD
  = 32`) is unchanged so tests + small scenarios still skip
  the pass.
- **Guard spacing relaxed (2026-05-24)** - `MIN_GUARD_SPACING_M`
  dropped 60 → 30 m in `squad_planner`. The 60 m gate was over-
  rejecting Guard rolls in regions where the POI baker stamped
  multiple same-faction bases within ~50 m of each other, forcing
  legitimate Guard squads down to Wander. 30 m still prevents two
  squads from stacking on the same base entrance but stops vetoing
  the natural base-cluster spacing the POI bakers emit.
- **Wander drift target (2026-05-24)** - prior Wander squads passed
  their own centroid back through `squad_target`, so members had
  no destination and Wander visually meant "stand still".
  `SquadObjectiveState` gained `pub wander_drift_target:
  Option<[f32; 3]>` (all literal sites updated). The planner
  refreshes the field per group every tick the squad holds
  `SquadObjective::Wander`: picks a random XZ offset
  `WANDER_DRIFT_MIN_M = 50 m`..`WANDER_DRIFT_MAX_M = 150 m` from
  the centroid on first entry, on arrival within
  `WANDER_DRIFT_ARRIVE_M = 20 m`, or every
  `WANDER_DRIFT_REROLL_TICKS = 800` (≈ 40 s) mid-leg. Cleared
  whenever the active objective is not `Wander`.
  `npc_goals::squad_target` returns the drift target for Wander
  squads in preference to the centroid, so members actually
  meander.
- **Stuck-kind one-pick ban (2026-05-24)** - companion to the
  stuck-squad detector. New `pub enum SquadObjectiveKindTag` in
  `resources.rs` (Copy, mirrors `SquadObjective` variants with no
  payload) and new field `pub last_stuck_kind:
  Option<SquadObjectiveKindTag>` on `SquadObjectiveState` (all
  literal sites updated). When stuck-detection force-expires an
  objective the planner stashes the tag via the new
  `objective_kind_tag(&SquadObjective) -> SquadObjectiveKindTag`
  helper. `pick_objective` now takes a `banned_kind:
  Option<SquadObjectiveKindTag>` argument and skips that variant in
  the kind-utility loop via `objkind_matches_tag(ObjKind,
  SquadObjectiveKindTag) -> bool`. The ban clears after one
  successful pick. Prevents the thrash loop where a stuck Wander
  immediately re-picks Wander against the same region geometry
  and re-wedges.
- **`goal_arbitration` per-group urgency cache (2026-05-11)** - the
  per-NPC arbitration loop used to read the squad blackboard once
  per squadmate. A 5-NPC squad hit the same `BlackboardKey` lookups
  five times per tick. The system now lazily memoizes a
  `HashMap<group_id, Vec<Candidate>>` populated by
  `push_blackboard_candidates` on first access and reused for the
  rest of the squad.
- **`drain_world_events` spatial-bin (2026-05-11, upgraded 2026-05-23)** -
  the bus drain used to iterate `events × every-group-in-the-world`
  even though only active-region groups can act on the result (their
  blackboard reads are short-circuited by the active-region filter
  above). First pass (2026-05-11) pre-binned active-region group
  centroids by `RegionId`, dropping per-event cost by ~4×. **Second
  pass (2026-05-23)** upgrades the bin key to `(RegionId, cell_x,
  cell_z)` at `EVENT_BUCKET_CELL_M = 200 m` cells (matches the
  largest audible radius). For non-global audiences (the common case
  — `Gunshot`, `EnemySighted`, `AllyDown`, etc.) each event walks only
  the 3×3 cells around its position instead of the whole region's
  group list (~10 candidates vs ~200). Combined with the squad-level
  event throttle and hostility-matrix hoist documented in the
  `EnemySighted` section above, the system's typical cost dropped
  from ~14ms/tick at full population to ~3ms/tick.
- **`npc_aggro` snapshot filter (2026-05-11)** - the snapshot Vec +
  `by_id` / `sight_sq_by_id` HashMaps used to be built for *every*
  NPC in the world (~3600 at full pop). Now filtered to NPCs in
  active regions OR NPCs with existing `Aggro` (Pass 1 refreshes
  those regardless of region). At 1 active / 4 total regions the
  snapshot drops from ~3600 to ~900 entries. ~6ms → ~3.5ms.
- **`spawn_npcs` per-tick budget (2026-05-11)** - was every-50-ticks
  bulk spawn (up to ~1280 NPCs spawned in one tick on cold start);
  now runs every tick, capped at `MAX_SQUADS_PER_TICK = 8` squads
  globally per tick. Cold-start reaches 3600-NPC target in ~6 sim-
  seconds without any spike. Implements the "every NPC is its own
  player making real-time decisions" principle for the spawn side.
- **`npcs_near` view-cached + PDA log view-cached (2026-05-12,
  perf audit follow-up)** - `_sync_npc_dummies` runs at 20 Hz on
  the main thread (game_session.gd) and was calling `sim.npcs_near`
  which routed through `worker.inspect` — each call blocked the
  main thread ~25 ms waiting for the worker's reply, costing up
  to 500 ms / sec of main-thread block at 800 NPCs / region.
  Fixed by adding `SimView.npcs_by_region: HashMap<RegionId, Vec<NpcView>>`
  populated once per tick by `Sim::active_region_npc_views` (uses
  the existing `npcs_near` query with a 25 km radius — covers
  the full test-map extent). The bridge's `npcs_near` now reads
  this Vec lock-free and filters by distance on the main thread.
  Cost on the worker: ~800 NpcView clones per tick (~80-100 KB).
  Cost saved on the main thread: ~50 % of frame time at 800 NPCs.
  Same pattern applied to PDA log
  (`SimView.pda_recent` / `pda_high_water`) — was hitting inspect
  at 4 Hz from PDA toast poller. Per-frame inspect call sites
  audit pass: all remaining `worker.inspect` uses are either
  mutations (input-driven, rare) or one-shot (boot / shutdown /
  debug nav viz). Nothing else fires per-frame.
- **FPS regression triage + offline-tier rate-limit (2026-05-12,
  post-Phase-1 feedback pass)** - several perf fixes in one pass.
  (1) `PdaEventLog` was inserted in `build_world` but NOT in
  `load`, so snapshot-loaded sims panicked the worker thread the
  first time `offline_combat` ran (`Resource does not exist`).
  Fixed: also inserted in the load path.
  (2) `offline_movement` + `offline_combat` previously ran
  bunched at the offline heartbeat (all regions, every 10 sim
  ticks). Pattern matched user-reported "ticks run then hang then
  run." Both now process **one region per tick in round-robin**
  AND only fire every `OFFLINE_PROCESS_INTERVAL_TICKS = 4` sim
  ticks (5 Hz total burst rate). With 4 procedurally-seeded
  regions, each region updates at ~1.25 Hz — slow but matches
  the abstract dice-resolution design intent.
  (3) `offline_combat` now uses spatial bucketing (150 m cells,
  Moore neighborhood + `seen_pair` dedup) → O(n) instead of
  O(n²). With 800 NPCs/region this drops per-tick pair-scan
  cost from ~320k comparisons to ~7k.
  (4) `SimHost::view_updated` signal throttled from 20 Hz to
  4 Hz (`VIEW_UPDATED_TICK_INTERVAL = 5`). UI listeners
  throttle their own refreshes to ≤ 4 Hz so a 20 Hz signal
  cascade was pure overhead.
  (5) Inventory `_refresh_all` throttle on view-updated
  ticks (`_REFRESH_THROTTLE_TICKS = 5`) so even when visible
  the panel rebuilds at 4 Hz max, not 20 Hz.
  (6) Inventory grid widget switched from `GridContainer` to
  absolute positioning — GridContainer was propagating each
  cell's min-width to the entire column, so a 4-wide rifle in
  column 0 stretched the grid to ~1500 px wide. Now items sit
  at `(x, y) × _CELL` directly and the grid stays a fixed
  `width × height × _CELL` square.
  (7) PDA gunfire toast cooldown — combat firing per sim tick
  would have flooded the toast queue; `OfflineGunfire` PDA
  entries debounce per-region with `GUNFIRE_PDA_COOLDOWN_TICKS = 10`.
- **`view_updated` signal + drag-to-magazine + ammo stacking +
  paper-doll layout (2026-05-12, Phase 2G + feedback pass of
  `sim-iteration-5-12-plan.md`)** - new `SimHost` signal
  `view_updated(tick)` fires every tick in worker mode (whenever
  the worker publishes a new view via the `last_view_tick_emitted`
  tracker) AND in direct mode (replacing the host-only
  `tick_completed` gating). Inventory panel + PDA toast subscribe
  here for auto-refresh. Without this, solo sessions never saw
  `tick_completed` (host-only) and the inventory stayed stale
  after drag-drop / equip / consume — players had to close + reopen
  to see the result.
  Drag-and-drop routing: dropping an ammo stack onto a magazine in
  pockets now routes through `load_rounds_into_pocket` instead of
  position-swap; matches the existing LOAD-link affordance.
  Ammo stacking: every entry in `content/items/ammo.toml`
  bumped to `stack_size = 9999` (practical infinite — weight is
  the only constraint, per design intent). LOAD button visual
  polish: non-flat styling with visible background + border, font
  size up to 11, expanded-fill width, fixed 22 px height — easier
  click target.
  Paper-doll layout: `equipment_slots.toml` rearranged to a
  STALKER-style 5×6 doll — center column carries head / eyes /
  vest, right column carries primary / secondary / melee, sidearm
  next to vest, backpack bottom-left, four belt slots along row 5.
  Also fixed a pre-existing position collision between `melee` and
  `belt_3` (both at `(3, 4)`).
- **Native drag-and-drop + placeholder category icons (2026-05-12,
  Phase 2B of `sim-iteration-5-12-plan.md`)** - new
  `godot/scripts/menus/inventory_drop_target.gd` attaches to every
  draggable / droppable card and overrides Godot 4's
  `_get_drag_data` / `_can_drop_data` / `_drop_data` virtuals, plus
  `_gui_input` for the 2A right-click context menu. Three card
  kinds: `grid_card` (drag source + drop target),
  `doll_slot` (drag source when populated, always drop target with
  category-accept check from `equipment_slots.toml`'s `accepts`
  array), `empty_cell` (drop target only). The background-`Button`
  intermediary used by Phase 2A is gone — input goes straight to
  the `PanelContainer` so drag-init and right-click both work on
  the same Control. `_on_drop_received` routes the five
  source-kind × target-kind combinations: `equip` for
  grid → doll, `unequip` for doll → grid (always lands in
  pockets), `move_slot` for pockets ↔ pockets,
  `move_between_grids` for cross-grid. The click-carry flow
  (`_carried` / `_drop_carried` / `_update_carry_badge`) is now
  vestigial — Phase 2F can clean it out once drag-and-drop is
  proven. Also adds placeholder category icons:
  `_CATEGORY_VISUAL` maps each item category to a tinted panel +
  3-4 char ASCII tag (RIFLE / MAG / MED+ / FOOD / etc.) so a
  stack of bandages and a stack of ammo no longer look identical
  at a glance. Real iconography lands with the Phase 2F rarity-
  tier visual pass.
- **Inventory right-click context menu (2026-05-12, Phase 2A of
  `sim-iteration-5-12-plan.md`)** - item-card and doll-slot
  buttons now read `gui_input` directly (instead of `pressed`) so
  the handler can branch on `MOUSE_BUTTON_LEFT` vs
  `MOUSE_BUTTON_RIGHT`. Left-click keeps the existing pickup-carry
  flow. Right-click opens a `PopupMenu` anchored at the cursor;
  entries depend on context — pocket consumables get `Use` (routes
  through existing `consume_slot` SimHost `#[func]`), gear gets
  `Equip` (the GDScript-side `_first_free_slot_for_category` walks
  the doll's live equipment view to pick the first compatible
  empty slot from a category → slot-preference table, then calls
  `equip(sid, slot_id, "pockets", idx)`), pocket items get `Drop`
  (routes to existing `drop_slot`), and everyone gets `Examine`
  (placeholder console line — proper detail panel lands with the
  Phase 2C tooltip work). Doll-slot right-click offers
  `Unequip` / `Examine`. PopupMenus self-destruct on
  `close_requested` so panel refreshes don't leak them. Category →
  slot preference table mirrors `content/equipment_slots.toml`;
  drift between them would silently break the menu so keep them
  paired. The full player-facing inventory contract lands at
  `docs/book/src/mechanics/inventory.md` once Phase 2A-G all ship.
- **Cross-tier PDA event surface + toast UI (2026-05-12, Phase 1F
  of `sim-iteration-5-12-plan.md`)** - new `crates/simn-sim/src/pda_log.rs`
  module with `PdaEvent` enum (`OfflineCombatDeath`, `OfflineGunfire`,
  `BaseFlip`) and `PdaEventLog` resource (bounded ring, 256-entry
  cap, 60 s TTL via `evict_old`). Sequence ids start at 1 so callers
  can use `since(0)` to mean "everything since boot" with
  exclusive-bookmark semantics. `offline_combat` now pushes
  `OfflineCombatDeath` per combat death, coalesces raw per-pair
  `Gunshot` bus events into one `OfflineGunfire` PDA entry per
  region per offline tick, and runs a placeholder base-dominance
  heuristic that emits `BaseFlip` when an opposing-faction majority
  (≥ 2 NPCs within 80 m) is hostile to the base's authored owner —
  full contestation lives in [`contestation-plan.md`](../planning/contestation-plan.md)
  and will own ownership properly. New SimHost `#[func]`s
  `recent_pda_events_since(since_seq) -> Array<Dictionary>` and
  `pda_log_high_water() -> int` expose the log to clients; entries
  carry `seq` / `tick` / `kind` plus per-variant fields. Tests in
  `tests/pda_events.rs` cover combat-death surfacing, gunfire
  coalescing, bookmark redelivery prevention, and high-water growth.
  Godot side: `godot/scripts/pda_toast.gd` + `scenes/pda_toast.tscn`,
  added to `session_root.tscn` at CanvasLayer 40 (above HUD's 10,
  below PDA modal's 50). Polls at 4 Hz, formats per-event toast
  strings, fades in 0.25 s / holds 5 s / fades out 0.8 s; capped
  at 6 simultaneous toasts.
- **Offline combat + event emission (2026-05-12, Phase 1E of
  `sim-iteration-5-12-plan.md`)** - new `offline_combat` system,
  added to the offline-tier schedule chain after `offline_movement`,
  runs at 2 Hz and walks every pair of opposing-faction
  `OfflineNpc`s within `OFFLINE_ENGAGEMENT_RADIUS_M = 150.0` (per
  region). Per pair, each side rolls a hit (`OFFLINE_COMBAT_HIT_CHANCE =
  0.05` baseline + accuracy scaling) — hits degrade the defender's
  `HealthClass` (Healthy → Wounded → Critical → death). Per-pair
  RNG is keyed off `(min_id, max_id, offline_tick)` so two same-seed
  sims fight identically. Same system handles natural-causes death:
  NPCs with `die_at_tick <= sim_clock.tick` get chronicled with
  `DeathCause::NaturalCauses` (no `AllyDown` event since squad
  blackboards shouldn't react to old age). Combat deaths get
  `DeathCause::Combat { killer_faction }` plus an `AllyDown` event
  pushed onto `WorldEventQueue`; every engagement also pushes a
  `Gunshot { Intermediate }` event (audibility takes over from
  there per `world_event_bus::audible_radius_m`). `LoadoutClass` →
  weapon caliber refinement deferred — Phase 1E uses
  `CaliberClass::Intermediate` as the default. The test helper
  `spawn_offline_npc_for_test` now inserts a chronicle entry
  (matches what `spawn_one_squad` does on the online path) so
  combat-death recording works end-to-end. Tests in
  `tests/offline_combat.rs` cover the acceptance criterion (two
  hostile squads → at least one combat death in 60 s), allied
  factions don't fight, neutral factions don't engage, and the
  Healthy → Wounded/Critical degradation chain.
- **Offline movement (2026-05-12, Phase 1D of
  `sim-iteration-5-12-plan.md`)** - `OfflineNpc` extended with
  `target_2d` / `arrival_offline_tick` / `travel_start_*` fields;
  new `offline_movement` system gated on `offline_tick_just_advanced`
  walks every offline NPC at 2 Hz, either picking a new target or
  linearly interpolating along the current leg. Phase 1D uses
  existing `Base` entities as de facto waypoints (proper waypoint
  graph from `npc-traversal-plan.md` lands later) — same-faction
  bases preferred, any-region fallback, idle if none. Walking
  speed `OFFLINE_WALK_SPEED_M_PER_S = 6.0`; a 200 m hop takes 33 s
  / 66 offline ticks. Iteration is `NpcId`-sorted so RNG
  consumption stays deterministic across sim instances. Tests in
  `tests/offline_movement.rs` cover target-acquisition, position
  change over time, no-bases idle behavior, and leg cycling.
  Gotcha caught here: bevy_ecs 0.18 auto-orders systems by data
  conflict (one mut, one read on `SimClock`), but doesn't guarantee
  which comes first — `tick_offline_clock` would happily run
  BEFORE `advance_clock` and see the pre-bump tick value. Fixed
  with explicit `.after(advance_clock)` on the offline-tier chain
  in the schedule. New test helper `spawn_offline_npc_for_test` in
  `world/debug.rs` for movement tests that don't want to round-
  trip through projection.
- **Aggro carry-over across tier transitions (2026-05-23,
  follow-up to Phase 1C).** `OfflineNpc` gained two fields —
  `aggro_target: Option<NpcId>` and `aggro_last_seen_tick: u64` —
  populated by `project_online_to_offline` from the live `Aggro`
  component (also sets `combat_state = Engaged { opponent,
  since_tick }` instead of always `Idle`). `project_offline_to_online`
  re-inserts the `Aggro` component when `aggro_target.is_some()`,
  so an NPC mid-firefight whose region goes offline doesn't lose
  its target on the way out or back. `offline_movement` now skips
  travel-target selection for NPCs in `OfflineCombatState::Engaged`
  (they hold position so the offline dice can continue resolving
  the firefight without one side wandering off), and `offline_combat`
  refreshes `combat_state` + `aggro_target` + `aggro_last_seen_tick`
  for every hostile pair within `OFFLINE_ENGAGEMENT_RADIUS_M = 150.0`
  on the tick they're seen. Stale engagements age out to `Idle`
  after `OFFLINE_ENGAGE_STALE_TICKS = 200` sim ticks (10 s) with
  no refresh — required because the freeze-in-place rule would
  otherwise pin a survivor in `Engaged` forever after its opponent
  dies. Fixes the reported symptoms "firefights freeze on online
  → offline transition" and "NPCs stop aggro after the boundary
  flip"; behavioral fix, no new test (the determinism harness +
  the existing `tests/offline_combat.rs` / `tests/projection.rs`
  cover the touched paths).
- **Projection function online ↔ offline (2026-05-12, Phase 1C of
  `sim-iteration-5-12-plan.md`)** - `Sim::set_active_region` now
  projects state across the tier boundary on every transition.
  Regions leaving `ActiveRegions` have their online NPCs collapsed
  to `OfflineNpc` via `project_online_to_offline(world, region)`:
  `BodyParts` → `HealthClass` (head/torso < 25 → Critical, any limb
  < 25 → Critical, anything 25-75 → Wounded, all ≥ 75 → Healthy),
  inventory destroyed, character / lifespan summarized into the
  offline component. Regions entering `ActiveRegions` reverse the
  flow via `project_offline_to_online`: `BodyParts` re-materialize
  deterministically from the `HealthClass` enum (seeded off NpcId
  so the same NPC reconstructs identically), `Inventory` rolls
  fresh from the faction's `NpcLoadoutRegistry`, and `NpcCharacter`
  re-derives from `(npc_id, faction_id)` (same deterministic-roll
  pattern used by `spawn_one_squad`). The invariant: an NPC is an
  online entity iff its region is in `ActiveRegions`.
  `Sim::initial_bulk_seed_npcs` now demotes everything to offline
  at boot so the invariant holds from tick 0 — SimHost's first
  `set_active_region(start_region)` re-projects just that region
  to online. Tests in `crates/simn-sim/tests/projection.rs` cover
  the round-trip identity / health-class preservation, group
  cohesion, Critical class derivation, and the redundant-call
  no-op. New test helpers `Sim::offline_npc_for_test`,
  `offline_npc_count_for_test`, `offline_npc_count_in_region_for_test`,
  `set_npc_body_part_for_test` in `world/debug.rs`. The
  `LoadoutClass` selection is coarse for now (wanderers/bandits →
  Improvised; ghost_teams/recovery_division/choir/registry →
  Elite; rest → Standard tier 1) — Phase 1E may refine when offline
  combat actually reads the class.
- **`OfflineNpc` parallel schema + 2 Hz heartbeat (2026-05-12,
  Phase 1B of `sim-iteration-5-12-plan.md`)** - new module
  `crates/simn-sim/src/offline_tier.rs` introduces the lightweight
  per-NPC component for regions with no observers: `OfflineNpc`
  (region, 2D position, faction, health-class, loadout-class,
  combat-state, personality seed) plus the coarse enums
  `HealthClass` (Healthy/Wounded/Critical), `LoadoutClass`
  (Standard/Elite/Improvised), `OfflineCombatState`
  (Idle/Engaged/Routed). A new resource `OfflineTierClock` (persisted
  in snapshots) advances once every `OFFLINE_TIER_TICK_DIVISOR = 10`
  sim ticks — 2 Hz at the stock 20 Hz sim rate — via the
  `tick_offline_clock` system added to the schedule. Phase 1B is
  plumbing only: no projection (Phase 1C), no movement (1D), no
  combat (1E), no event emit (1F). The component intentionally
  doesn't derive serde — `FactionId` isn't `Serialize`/`Deserialize`,
  so Phase 1C will introduce a `SerializedOfflineNpc` shape that
  converts faction id ↔ name string at the snapshot boundary,
  mirroring `SerializedEntity::in_faction`. The schedule's NPC chain
  already hit bevy_ecs 0.18's `.chain()` tuple-arity cap, so
  `tick_offline_clock` is added as an unchained system (no ordering
  deps with the NPC pipeline — only reads `SimClock`, only writes
  `OfflineTierClock`).
- **`Sim::initial_bulk_seed_npcs` + active-region gate on `spawn_npcs`
  (2026-05-12, Phase 1A of `sim-iteration-5-12-plan.md`)** - the
  per-tick budget alone wasn't enough: crossing into a fresh region
  still triggered visible NPC pop-in because the world started at
  zero. SimHost now calls `sim.initial_bulk_seed_npcs()` right after
  `Sim::load_or_new` on a fresh world, which drains every region's
  `PopulationTargets` in one pass with a deterministic per-(region,
  faction) seed. The method is idempotent (no-op if any NPC already
  exists, so snapshot-loaded sims skip it). `spawn_npcs` itself now
  reads `ActiveRegions` and only tops up populations in active
  regions — Phase 1E will wire the offline-tier dynamics that handle
  population replenishment for inactive regions. Tests that need
  natural tick-time spawning across all regions call
  `sim.activate_all_regions_for_test()` (added to `world/debug.rs`).
  Refactor extracts the per-squad spawn block from `spawn_npcs` into
  `spawn_one_squad`, shared by both the per-tick budgeted system and
  the one-shot bulk seed system.
- **`Sim::npcs_near(region, player_pos, max_dist_m)` (2026-05-11)** -
  server-side distance-filtered variant of `npcs_in_region`. The
  unfiltered call marshaled every NPC in the active region into a
  heavy `Dictionary` via the gdext bridge at 20 Hz; at 800+ NPCs
  that's tens of thousands of `Variant` allocations per second for
  data the renderer immediately threw away (only ~50 NPCs are
  within draw distance). `SimHost::npcs_near` exposes the filter to
  GDScript; `_sync_npc_dummies` switched over.
- **Pathfinding overhaul (2026-05-11)**:
  - **Empty-waypoint `Path` tombstones** — when `nav.path()` fails
    (target unreachable or A* hits the node cap), `advance_with_path`
    now caches a Path with empty waypoints instead of removing the
    component. Without this, every NPC whose target was unreachable
    re-ran the full A* search every tick — observable as 38-second
    `tick_npc_goals` spikes. The tombstone is refreshed only when
    the target drifts >`PATH_RECOMPUTE_DIST_M` or
    `computed_tick` ages past `PATH_MAX_AGE_TICKS`.
  - **Path retention on arrive + walk-exhausted** — the arrive
    branch and the walk-loop-exhausted branch no longer drop the
    `Path` component. NPCs whose formation target jitters by sub-
    `PATH_RECOMPUTE_DIST_M` per tick used to re-run A* every cycle
    (arrive → drop → next-tick no path → recompute → arrive);
    keeping the cached path lets the drift check short-circuit
    until the target genuinely moves >8 m. Dropped steady-state
    `pathfind_calls/tick` from ~60 to single-digits.
  - **`MAX_NODES_EXPANDED`: 50_000 → 5_000** — each failed A* now
    costs ~5 ms instead of ~60 ms. Unreachable targets are
    tombstoned and retried only on drift / age, not every tick.
  - **`PATH_BUDGET_PER_TICK = 4`** (was 8 until 2026-05-23) —
    global per-tick cap on A* calls; over-budget NPCs straight-
    line this tick and pick up on the next. Per-segment profiling
    surfaced a `tick_npc_goals` p99 spike of 34 ms at the old
    budget; halving the cap cut it to ~24 ms p99, well under the
    50 ms / 20 Hz tick budget.
  - **Peer-separation pass (2026-05-23, tuned 2026-05-24)** —
    after the movement + pathfind passes, walks every active-
    region NPC and applies a 1/dist²-weighted repulsion against
    peers within `SEPARATION_RADIUS_M = 3.5 m` (was 2.5 m),
    capped at `SEPARATION_NUDGE_M = 0.3 m` (was 0.1 m) of
    position delta per tick. Gated on `SEPARATION_TICK_INTERVAL
    = 2` and `SEPARATION_DENSE_THRESHOLD = 32` online NPCs so
    tests + small scenarios skip the work. Cost at 240-NPC
    playtest pop: ~0.6 ms / tick on the every-other-tick
    cadence. Catches non-pursue clumping (squads converging on
    a rest area, base centroid, regroup point); the 2026-05-24
    tuning takes visible de-clump time from ~30 s down to ~1 s
    on stacked-NPC scenarios.
  - **Pursue engagement-offset slots (2026-05-23)** — replaces the
    "every pursuer walks to the target's exact position" path that
    caused observable stacking at engage range. Each pursuer's
    deterministic angular slot is derived from a golden-angle
    multiple of its stable `NpcId`; the slot sits on a ring of
    radius `ENGAGE_RANGE_M × 0.95 ≈ 28.5 m` around the target. The
    NPC walks to its slot with `PURSUE_ARRIVE_SQ_M ≈ 4 m`
    tolerance, fires from there, and stays put (no jitter — the
    slot is a function of id, not of frame state). Gated on
    `dist_sq_to_target > RELOCATE_THRESHOLD_SQ_M` (≈ 15 m): NPCs
    already inside firing range hold their current position and
    just fire — they don't skitter to a "preferred" slot mid-
    combat, and point-blank test scenarios continue to work
    unchanged. Squad cohesion is preserved because pursuers share
    the *target*, not the engagement spot. With ~10 pursuers,
    adjacent slots are ~18 m apart, well outside the peer-
    separation radius, so the two systems don't fight.
  - **Rayon-parallel pathfind cascade** — `tick_npc_goals` is now
    three-pass: (1) sequential mutable iter walks existing paths
    and collects `PathfindRequest`s; (2) parallel `rayon::par_iter`
    runs `nav.path(...)` calls across cores (the `NavQuery` trait
    is already `Send + Sync` and the grid is read-only during
    query); (3) sequential `Commands::insert` applies results.
    At 8 calls × ~5 ms each, parallel completes in ~5-10 ms on an
    8-core machine vs ~40 ms single-threaded. Required `rayon`
    1.10 as a new direct dependency.
- **`HeardGunshot` priority drop: 100 → 40 (2026-05-11)** - distant
  gunshots used to preempt active `SquadObjective` (priority 80
  with 20-point hysteresis = bar at 100). A patrolling/regrouping
  squad would scatter to investigate any audible shot. Dropped
  below `SquadObjective` baseline so a working squad finishes its
  task; idle / personality-biased NPCs still react. Combat
  distractions (`UnderFireAt` 140, `DownedAlly` 180, visible aggro
  150-160) remain above `SquadObjective` priority — those *are*
  important.
- **`BlackboardUrgency` formation offset (2026-05-11)** - the
  `InvestigateAt` and `RegroupOnAlly` executor branches used to
  target the exact same world position for every squad member,
  causing them to stack within 1 m at the urgency point. Now apply
  the same per-NPC `formation_offset` (circular 8-slot spread,
  3 m radius) so members fan around the urgency target. Lone NPCs
  get deterministic per-id jitter via the same path.
- **`SquadObjective` per-group temporal stagger (2026-05-11)** -
  was: `is_planner_tick` (every 200 ticks) re-rolled every
  expired-objective group simultaneously, producing a ~30-second
  hang every 10 seconds when ~500 NPCs simultaneously needed new
  paths. Now: each group rolls only on its own slot within the
  cycle (`group_id % 200 == now % 200`), spreading the rerolls
  across the full window. Personality aggregation runs every tick
  to keep up with the staggered slots (still cheap).
- **Faction `nationality_weights` filled in (2026-05-11)** -
  `factions.toml` previously only had explicit weights on `linemen`
  and `cartel`; every other faction fell through to a uniform
  default that produced 12.5 % per bucket. Result: American
  factions (PWA, RG, Federal) rolled non-American names 75 % of
  the time. Each faction now has a lore-grounded weighted block
  (e.g. PWA: heavy American + meaningful East Asian / Latin
  American per West Coast demographics; Federal: heavy American
  with W. European / W. African per US-military demographics;
  Bandits: NW-local American + small Latin / Slavic refugee mix;
  etc.).
- **Diagnostic instrumentation (2026-05-11)** - `SysTimer` Drop
  guard logs any system that exceeds a 2 ms threshold;
  `Sim::tick` logs total/schedule/projectile timing for any tick
  >25 ms; `spawn_npcs` logs per-pass live/target counts;
  `tick_npc_goals` tracks per-tick pathfind call count via a
  thread-local. All gated by absence of `NSPH_QUIET=1` so they
  default-on for diagnosis but can be silenced.
- Static-obstacle integration (OSM buildings, hand-placed obstacles)
  is a phase-2 follow-up. See
  `docs/book/src/planning/npc-traversal-plan.md`.
- **Threaded-sim snapshot scaffold (2026-05-11, PR A of the
  threaded-sim plan)** - new `simn_sim::snapshot` module defines
  `SimSnapshot { tick, published_at, npcs: Vec<NpcSnapshot> }`.
  `Sim::tick` now publishes one snapshot per tick into a 2-slot
  ring (`prev`, `curr`) on the `Sim` struct. Snapshots include
  active-region NPCs only (offline-region NPCs are frozen anyway),
  sorted by `NpcId` for stable iteration + O(log n) binary-search
  `find`. Read API: `Sim::snapshot_pair() -> Option<(&prev, &curr)>`
  and `Sim::current_snapshot() -> Option<&curr>`. gdext bridge
  exposes `SimHost::has_snapshot_pair()` and
  `SimHost::snapshot_current_tick()` for now; PR B adds the
  position-lerp API on top. PR C will move the sim onto a
  dedicated worker thread, at which point this ring becomes the
  cross-thread handoff. See
  `docs/book/src/planning/threaded-sim-plan.md`.
- **Threaded-sim render lerp (2026-05-11, PR B of the threaded-sim
  plan)** - the renderer no longer drives NPC motion from the 20 Hz
  roster sync. New `snapshot::interp_npcs_near(prev, curr, region,
  player_pos, max_dist_m, now)` walks the active-region NPCs in
  `curr`, distance-gates with XZ² math, binary-searches each id in
  `prev`, and emits `NpcInterpPose { id, pos, yaw }` at
  `alpha = snapshot_alpha(prev, curr, now)` clamped to `[0,1]`
  (never extrapolates — visual glitches on direction reversal, per
  plan §4.3). Yaw uses `lerp_angle` for shortest-path wrap. NPCs
  in `curr` but not `prev` (fresh spawns) emit at `curr` pose with
  no interp; NPCs only in `prev` (despawned) are omitted. `Sim`
  exposes the wrapper `snapshot_interp_npcs_near(region,
  player_pos, max_dist, now)`. gdext bridge:
  `SimHost::snapshot_interp_npcs_near(region_name, player_pos,
  max_dist_m) -> Dictionary` returning parallel `PackedInt64Array`
  ids / `PackedVector3Array` positions / `PackedFloat32Array`
  yaws. GDScript `game_session.gd::_lerp_npc_dummies` calls this
  every frame in `_process` and writes `global_position` +
  `rotation.y` directly onto each `HumanoidDummy`; the dummy's
  own per-frame smoothing is now a no-op. Hot-path cost: one
  binary-search + one f32 lerp + one yaw lerp per visible NPC —
  ~50 NPCs × 144 FPS = 7,200 ops/s, well under any budget.
- **Squad-relief same-faction gate (2026-05-11)** -
  `GuardPostInfo` now carries the holder's `FactionId`, and
  `build_relieve` skips posts whose `info.faction !=
  summary.faction`. Previously a squad in a contested region
  with `has_territorial_standing` could "relieve" any other
  faction's guard — observed in-game as a PWA squad walking up
  and quietly taking over a federal post. Cross-faction post
  takeover should require combat, not a peaceful handoff;
  allied / NAP-partner reinforcement shows up as a separate
  Guard objective in the same region, not as a `Relieve`.
  The post-takeover branch in `handle_relief_arrivals` also
  re-tags the post with the arriving squad's faction on swap,
  so the gate stays correct after an in-faction relief
  succeeds.
- **Threaded-sim PR C step 1 — `SimView` builder (2026-05-11)** -
  new `worker` module lands the denormalized read-only view
  type that step 4 will wire `SimHost`'s HUD reads onto.
  `SimView { tick, world_time, weather, chronicle_summary,
  players: HashMap<u64, PlayerView> }` is rebuilt at
  end-of-tick via `worker::build_sim_view(&mut sim)`; once the
  worker thread exists (step 3) it gets published through an
  `Arc<ArcSwap<SimView>>` so any number of main-thread readers
  load it lock-free. No call-site rewires yet — this is
  passive scaffolding. Builder iterates connected players via
  the new `Sim::connected_player_ids()` (sorted, deterministic)
  + per-player `Sim::player_view`. Fields are intentionally a
  subset of the eventual read surface; step 4 extends them
  alongside the matching `SimHost` rewires. Test:
  `crates/simn-sim/tests/view_builder.rs` — 6 cases pinning
  empty-world / tick / world-time / weather / multi-player
  / player-drop coherence between the view and the equivalent
  `Sim::*` direct reads.
- **Threaded-sim PR C step 2 — `SimCommand` dispatcher
  (2026-05-11)** - the vocabulary the (future) worker thread
  drains from its command channel. `SimCommand::Action {
  steam_id, kind: ActionKind }` wraps the existing
  `ActionKind` vocabulary 1:1 so we don't fork the
  ~30-variant client-action surface; non-player ops
  (`UpsertPlayer`, `RemovePlayer`, `SetActiveRegion`) get
  their own variants. `worker::dispatch_command(&mut sim,
  cmd)` runs each on whatever thread holds `&mut Sim` —
  today the main thread, after step 3 the dedicated worker
  — and the dispatcher itself is unchanged across that
  transition. Step 4 extends the variant set in lockstep
  with each `SimHost` call site it rewires off direct
  `&mut self.sim`. Tests:
  `crates/simn-sim/tests/command_dispatch.rs` — 5 cases:
  upsert spawns the entity, action-move updates position,
  remove clears, set-active-region survives a tick, action
  on unknown steam_id errors rather than panics (worker
  loop logs + keeps going).
- **Threaded-sim PR C step 3 — `SimWorker` runtime
  (2026-05-11)** - the dedicated thread (named
  `"simn-sim"`) that owns `Sim` and runs the tick loop.
  `SimWorker::spawn(sim) -> Self` consumes `Sim` and returns a
  handle exposing `send(SimCommand) -> Result<()>`,
  `snapshots() -> Option<Arc<PublishedSnapshots>>`,
  `view() -> Option<Arc<SimView>>`, and `shutdown() ->
  Result<()>` (signals + joins).
  Internals: bounded `crossbeam_channel<SimCommand>` (cap 256
  = ~3 ticks of worst-case 12-player × 144 Hz Move input),
  two `Arc<ArcSwap<Option<T>>>` cells (snapshots + view) for
  lock-free reads on the main thread, and a separate
  shutdown signal channel. Loop body: drain commands until
  the next-tick deadline (`recv_timeout` → `Timeout` is the
  unified wake signal — no `thread::sleep`), check shutdown,
  call `Sim::tick`, build the published-snapshot pair from
  the prev/curr rotation, build the `SimView`, store both
  into their ArcSwaps. Catch-up: if the previous tick
  overruns 50 ms, deadline rolls forward one period at a
  time without double-ticking (caps at 20 Hz on overload
  per plan §10 Q5). Smoke test:
  `crates/simn-sim/tests/worker_smoke.rs` — 4 cases:
  spawn+shutdown, snapshot pair + view published after 2
  ticks, command processing (upsert + Move action both
  reflected in the next view), tick rate advances ≥4 per
  250 ms wall clock. `SimHost` is not yet wired onto the
  worker — that's step 4. Deferred to later steps: panic
  propagation (7), `Load` lifecycle (7), delta/FX
  forwarding (6).
- **Threaded-sim PR C step 4a — `SimWorker::inspect`
  escape hatch (2026-05-11)** - generic
  `worker.inspect(|sim| sim.foo()) -> Result<R>` that runs
  a `FnOnce(&mut Sim) -> R + Send + 'static` closure on
  the worker thread and blocks the caller until the reply
  lands. Built on a second bounded
  `crossbeam_channel<InspectFn>` drained between commands
  and tick. Worst-case wait is one full tick (~50 ms) +
  closure cost, so this is the cold-path read API —
  hot-path frame reads still go through `view()` /
  `snapshots()`. Why it exists: step 4 of the rollout
  flips ~100 `self.sim.foo()` call sites in `SimHost`
  onto the worker. The typed `SimCommand` vocabulary
  today only covers Action / UpsertPlayer / RemovePlayer /
  SetActiveRegion; expanding it to cover every remaining
  mutation upfront is a 60-variant lift before any
  rewire lands. `inspect` lets the rewire happen
  incrementally — each call site flips to
  `self.worker.inspect(|sim| ...)?` immediately and later
  graduates to a typed `SimCommand` variant if it's
  hot-path. New `worker_smoke` cases: `inspect` returns a
  query result; `inspect` can mutate then observe in one
  closure.
- **Threaded-sim PR C step 4b-i — `SimHost` lifecycle on
  the worker (2026-05-11)** - first migration commit of
  the step-4b subsystem-by-subsystem rewire. `SimHost`
  now carries a parallel `worker: Option<SimWorker>`
  slot alongside `sim: Option<Sim>`, plus a
  `use_worker_thread: bool` opt-in flag. New `#[func]
  enable_worker_thread() -> bool` (must be called BEFORE
  `start`) flips the backend choice for the session;
  default stays direct-mode until step 4b-vi flips it
  globally. In worker mode: `start` builds the `Sim`,
  installs the LOS provider, hands ownership to
  `SimWorker::spawn`; `process` skips the entire
  tick-driver body (the worker self-drives at 20 Hz,
  owns its own clock); `shutdown` runs `Sim::shutdown`
  via the inspect escape hatch then joins the thread.
  The worker loop gained an end-of-tick
  `sim.drain_tick_deltas()` discard so the in-sim
  buffer doesn't grow unbounded — step 6 wires those
  deltas back to the host's network broadcaster.
  **Status of worker mode**: only lifecycle is migrated
  in this commit. Mutating `#[func]`s and read paths
  still bind to `self.sim` directly, so calling most of
  them while in worker mode is a no-op (or returns
  default / `None`) until the corresponding subsystem
  migrates in 4b-ii through 4b-v. The first observable
  in-engine win lands when 4b-ii migrates hot-path
  reads (snapshot lerp / player_state).
- **Threaded-sim PR C step 4b-ii — hot-path reads on the
  worker (2026-05-11)** - `SimWorker` gains
  `regions() -> &Arc<RegionGraph>` (cloned at spawn —
  region graph is immutable for the session) and
  `snapshot_interp_npcs_near(region, pos, max_dist, now)
  -> Vec<NpcInterpPose>` (lock-free pair load + the same
  `snapshot::interp_npcs_near` math direct mode uses).
  `SimHost` migrates four `#[func]`s to read through the
  worker when in worker mode: `current_tick` (now reads
  `worker.view().tick`), `has_snapshot_pair`,
  `snapshot_current_tick`, `snapshot_interp_npcs_near`.
  Each function keeps its direct-mode branch as a
  fall-through so the migration is non-breaking — the
  same call works in both modes; the worker path goes
  through `Arc` loads and the direct path goes through
  `&Sim` borrows. Region-name lookups land on the cached
  `Arc<RegionGraph>` rather than round-tripping through
  `inspect`, which is what makes the lerp hot path
  actually fast in worker mode (one Arc clone + one
  binary search per NPC, no thread sync). **Observable
  in-engine**: with `enable_worker_thread()` set before
  `start`, the NPC lerp + tick counter keep working —
  the sim ticks on the named `simn-sim` thread, and
  the renderer reads the snapshot ring across threads.
  Mutating `#[func]`s (player input, weapons, inventory)
  still bind to `self.sim` and remain direct-mode-only
  until 4b-iii–v.
- **Threaded-sim PR C step 4b-iii — world-state HUD reads
  on the worker (2026-05-11)** - three `#[func]`s
  migrated: `world_time`, `weather_state`,
  `chronicle_summary`. Each function's dict-builder body
  factored out into a free helper (`world_time_to_dict`,
  `weather_state_to_dict`, `chronicle_summary_to_dict`)
  so both modes pipe through the same conversion and
  produce byte-identical GDScript output. Worker-mode
  branch reads from `worker.view()` (the SimView already
  carries `world_time`, `weather`, `chronicle_summary`
  fields from step 1); direct-mode branch reads from
  `sim.*()` as before. `npcs_near` / `npcs_in_region` /
  `region_info` / `player_state` are heavier reads that
  need either SimView expansion or per-region NPC view
  data; they migrate in 4b-iv alongside the player
  mutations.
- **Threaded-sim PR C step 4b-iv — player lifecycle +
  vitals HUD on the worker (2026-05-11)** - five
  `#[func]`s migrated: `upsert_local_player`,
  `move_local_player`, `change_region`, `remove_player`,
  `player_state`. Mutations route through `worker.send`
  with the existing typed `SimCommand` variants
  (`UpsertPlayer`, `RemovePlayer`, `SetActiveRegion`,
  `Action { Move | ChangeRegion }`); the
  `SimCommand::Action` wrapper means we don't fork the
  `ActionKind` vocabulary just for the worker path.
  `player_state` reads `PlayerView` from
  `worker.view().players` in worker mode (the vitals —
  HP / stamina / wounds / hunger / pain / contamination
  / effects / drug tolerance — survive the threading
  switch). Inventory / equipment / crafting / near-
  station / weapons return empty placeholders in worker
  mode for now; 4b-v expands `SimView` with those
  per-player fields. Region-name → id resolution still
  hits the cached `Arc<RegionGraph>` so the bridge
  doesn't round-trip through inspect for movement.
  **Observable in-engine**: WASD works, region
  transitions work, the vitals HUD shows real HP /
  stamina / wounds. Inventory panels render as 0×0
  until 4b-v.
- **Threaded-sim PR C step 4b-v — full player_state +
  inventory/equipment/weapons on the worker
  (2026-05-11)** - `SimView` extended with a
  `player_extras: HashMap<u64, PlayerExtras>` field
  carrying the inventory grid, encumbrance weight,
  near-station flags, crafting queue, and equipment
  map per connected player; populated by the same
  end-of-tick walk that builds the `PlayerView` map.
  `SimWorker` gains a second cached `Arc<ItemRegistry>`
  alongside the `Arc<RegionGraph>` (also immutable for
  the session — TOML-loaded once at boot) so the
  bridge's inventory / equipment / weapon dict
  conversions don't need a live `&Sim`. The four
  affected converters (`inventory_to_array`,
  `grid_to_dict`, `equipped_item_to_dict`,
  `equipment_to_dict`, `equipped_weapons_to_dict`)
  switched signatures from `&Sim` / `&mut Sim` to
  `&ItemRegistry`. New `Sim::item_registry()` public
  accessor. Worker-mode `player_state` now returns the
  same payload as direct mode — inventory grid,
  weight, near-campfire flag, near-workbench tier,
  crafting queue, equipment slots, and equipped
  weapons all populate. **Observable in-engine**: the
  full inventory panel + equipment slots + weapon
  HUDs work in worker mode; everything the HUD reads
  per frame is now lock-free. Mutation `#[func]`s
  (drop / move / consume / equip / craft / queue /
  fire / reload / treatments / drugs / survival) and
  the remaining bridge surface (containers, terrain,
  network, NPC mutations, save / load) still bind
  directly to `self.sim` and migrate in 4b-vi.
- **Threaded-sim PR C step 4b-vi batch 1 — inventory
  + crafting + station mutations on the worker
  (2026-05-11)** - new `SimHost::worker_send_action`
  private helper wrapping
  `worker.send(SimCommand::Action { … })` with
  ergonomic `Option<bool>` return semantics: `Some(ok)`
  if worker mode + the send succeeded/failed, `None`
  if we're in direct mode and the caller should fall
  through. First wave of mutation migrations using
  it: `drop_slot`, `move_slot`,
  `move_between_grids`, `consume_slot`,
  `salvage_slot`, `craft_recipe`, `set_near_campfire`,
  `set_near_workbench`. All are existing
  `ActionKind`-shaped operations; the worker-mode
  branch is a 4-line shim. Return-value semantics:
  bool now signals "command accepted onto the queue"
  in worker mode (state updates reflect in the next
  view tick — 50 ms worst case), versus "operation
  actually succeeded" in direct mode. For these
  user-driven inventory clicks the optimistic
  semantic is fine; the HUD reconciles on the next
  view tick. Remaining 4b-vi work: `queue_craft`
  (needs typed return), `cancel_craft`, `equip`,
  `unequip`, weapon mutations (fire / reload /
  eject / load), treatments / drugs / food /
  survival, containers, terrain, network, NPC
  mutations, save / load, then the default flip
  + Direct variant removal.
- **Threaded-sim PR C step 4b-vi batch 2 — dispatch
  consolidation + second mutation wave (2026-05-11)** -
  Refactor: replaced `SimHost::worker_send_action`
  with `SimHost::dispatch_player_action(steam_id,
  kind)`. The new helper folds **all three** branches
  (client emit / worker send / direct apply) into one
  call. Direct mode now routes through
  `Sim::apply_action(sid, kind)` — the same master
  dispatcher the worker thread uses — so the three
  paths share one codepath instead of duplicating
  per-mutation. Each migrated `#[func]` collapses
  from ~25 lines of branch boilerplate to a one-line
  `self.dispatch_player_action(steam_id, ActionKind::Foo
  { … })`. Second mutation wave migrated via the new
  helper: `cancel_craft`, `equip`, `unequip`,
  `consume_hotbar`, `reload_weapon`, `eject_magazine`,
  `grant_item`, `take_from_container`,
  `put_in_container`, the seven player treatments
  (`apply_bandage`, `apply_tourniquet`,
  `remove_tourniquet`, `apply_disinfectant`,
  `apply_stitch`, `apply_wound_pack`,
  `apply_antibiotics`), `eat`, `drink`. Net effect:
  ~250 lines of bridge code deleted, 20 `#[func]`s
  share one branch path. The eight funcs from batch 1
  also collapsed to the same one-line form. Still
  direct-mode-only: typed-return mutations
  (`queue_craft` → i64, `load_rounds` → i64,
  `fire_weapon` → Dictionary, `apply_drug` → i64 —
  these need `SimWorker::inspect` for synchronous
  results), `set_radiation` / `set_toxicity` /
  `set_player_stamina` / `set_survival_stat` /
  `damage_player` / `heal_player` (not `ActionKind`-
  shaped), NPC-target treatments, container
  spawning, terrain attach, network paths, save /
  load.
- **Threaded-sim PR C step 4b-vi batch 3 — typed
  returns + debug setters + NPC treatments
  (2026-05-11)** - third (and largest) mutation wave.
  New `SimHost::worker_or_direct_mut(|sim| …)` helper
  routes a non-`ActionKind` mutation through
  `worker.inspect` in worker mode or runs it inline in
  direct mode — the companion to `dispatch_player_action`
  for ops without an action-vocabulary fit. Closures
  use `tracing::error!` rather than `godot_error!`
  since they may execute on the worker thread where
  gdext APIs aren't safe. Migrated:
  - Typed-return via `inspect`: `queue_craft` (i64 job
    id), `load_rounds` (i64 rounds loaded),
    `load_rounds_into_pocket` (i64), `fire_weapon`
    (closure returns a `Send` `(ok, err, rounds)`
    triple; main thread builds the Variant dict —
    Variant isn't `Send`), `apply_drug` (bool with
    Effect/Overdose preserved).
  - Player debug setters via `worker_or_direct_mut`:
    `damage_player`, `heal_player`,
    `set_player_stamina`, `damage_part`, `heal_part`,
    `set_survival_stat`, `consume_food`,
    `set_radiation`, `set_toxicity`.
  - NPC mutations (host-only,
    `worker_or_direct_mut`): `damage_npc_part`,
    `heal_npc_part`, all seven NPC treatments
    (`apply_bandage_npc`, `apply_tourniquet_npc`,
    `remove_tourniquet_npc`, `apply_disinfectant_npc`,
    `apply_stitch_npc`, `apply_wound_pack_npc`,
    `apply_antibiotics_npc`).
  Still direct-mode-only: `spawn_world_container`
  (returns i64 id — needs inspect closure with
  ContainerId type), `load_region_terrain` (attach
  hook, pre-tick), `attach_network` /
  `apply_network_snapshot` / `apply_network_delta_batch`
  / `dispatch_network_action` (network path needs
  its own command variants), save lifecycle.
- **Threaded-sim PR C step 4b-vi batch 4 — terrain
  attach + container spawn + host action dispatch
  (2026-05-11)** - three more `#[func]`s migrated:
  - `load_region_terrain`: heightmap loaded on main
    thread (Godot path resolution + disk IO); the
    actual `sim.attach_region_terrain(region, hm)` call
    routes through `worker_or_direct_mut`. Region-name
    → id lookup uses the cached `Arc<RegionGraph>` in
    worker mode.
  - `spawn_world_container`: returns the new `i64`
    container id via `worker.inspect` (typed return),
    same pattern as `queue_craft`.
  - `dispatch_network_action`: host-side receiver for
    client-sent `ActionKind` payloads. Decode happens
    on the main thread (synchronous error feedback);
    in worker mode the decoded action goes through
    `worker.send(SimCommand::Action)` — same path
    locally-originated actions take. In direct mode it
    still calls `sim.apply_action` inline.
  Mirror-side paths (`start_mirror`,
  `apply_network_snapshot`, `apply_network_delta_batch`)
  intentionally stay direct-mode-only — mirror sims
  don't run on the worker today (mirrors don't drive
  autonomous ticks; they apply external snapshots /
  deltas), so the worker-mode flag is a no-op for the
  mirror flow. Step 4b-vii will gate
  `enable_worker_thread()` to the authoritative
  (solo / host) path and document the constraint.
  After this batch, the only authoritative-side
  `#[func]`s still binding directly to `self.sim` are
  save-lifecycle wrappers (`set_behavior_log`,
  `scale_population`, etc.) that don't fit the migration
  shape cleanly and are low-traffic. The default-flip
  + Direct-variant removal can land in 4b-vii.
- **Threaded-sim PR C step 4b-vii — default flip +
  opt-in removal (2026-05-11)** - authoritative sims now
  always run on the dedicated worker thread.
  `enable_worker_thread()` `#[func]` and the
  `use_worker_thread: bool` field are gone. `start()`
  unconditionally spawns the worker. `start_mirror()` is
  unchanged (still populates `sim: Option<Sim>` directly —
  mirror sims don't tick autonomously). The `sim` field
  stays on `SimHost` but is now exclusively a mirror-sim
  slot. Every `#[func]` body keeps its `if let Some(worker)
  … else if let Some(sim) …` pattern; the `sim`
  fall-through is now the mirror code path. Final tail of
  authoritative mutations migrated this commit:
  `set_behavior_log`, `behavior_log_enabled`,
  `scale_population`, `set_population_target`,
  `set_weather`, `cycle_weather`, `set_time_of_day`,
  `advance_time`. Read-only catalog helpers
  (`item_catalog`, `region_transitions`,
  `region_map_scene`) read from the cached
  `Arc<ItemRegistry>` / `Arc<RegionGraph>` directly — zero
  round-trip. **PR C is functionally complete**: every
  hot-path read + every authoritative gameplay mutation
  works on the threaded sim. Open follow-up surface (low
  priority, low traffic): a handful of debug-query
  `#[func]`s with complex Variant returns
  (`region_control`, `can_craft`, `nav_traversability`,
  `npcs_in_region`, `npcs_near`, `recent_deaths`,
  inspector helpers) still hit `self.sim.as_ref()` and
  return empty in worker mode until they graduate to
  either SimView expansion or inspect-with-Send-payload-
  then-Variant-on-main-thread. None are hot path; the
  migration pattern is well-trodden by now and these can
  be picked up incrementally.
- **NPC name gender split + male-skewed default
  (2026-05-11)** - first-name pools now carry an inline
  `M `/`F ` prefix per line. `NameRegistry` parses these
  into per-bucket male/female slices; the roll path
  picks a gender first (default 92% male), then samples
  from the matching pool. The setting assumes a
  male-skewed combatant population so individual NPCs
  rolled by `npc_spawn` / `world::debug::spawn_npc` /
  `persistence` come up male by default. New per-faction
  `male_name_weight: Option<f32>` in `FactionDef` /
  `factions.toml` lets a medical or civilian-leaning
  faction widen the split (e.g. `0.55`); when omitted,
  the constant
  `crate::names::DEFAULT_MALE_NAME_WEIGHT = 0.92` applies.
  `NpcCharacter::roll` gains a `male_name_weight:
  Option<f32>` parameter threaded from the spawning
  site's `FactionDef`. `NameRegistry::roll_for_faction`
  preserves the old API (uses the default weight);
  callers with the def can use
  `roll_for_faction_gendered` for explicit control.
  Untagged lines in data files default to the male pool
  for forward compatibility — adding new names without
  thinking about gender is biased correctly for the
  setting.
- **Threaded-sim PR C step 4b-vii hotfix — visualization
  read paths (2026-05-11)** - first in-engine smoke
  surfaced that `npcs_near`, `npcs_in_region`, and
  `bases_in_region` were still direct-mode-only, so test
  POIs + NPC dummies didn't render in worker mode even
  though the worker was ticking and spawning correctly.
  Cached `Arc<FactionRegistry>` added to `SimWorker`
  (same pattern as `RegionGraph` / `ItemRegistry` —
  TOML-loaded once, immutable for the session). Worker
  branch on each query: `worker.inspect` returns the
  `Send` `Vec<NpcView>` / `Vec<BaseView>` /
  `Vec<(ContainerId, [f32;3], bool)>` payload; main
  thread builds the Variant dicts using the cached
  registry. Also migrated `containers_in_range` and
  `faction_relation` for completeness. Mirror path
  unchanged (direct fall-through still works for
  start_mirror sims).
- **Dev panel (2026-05-11)** -
  `godot/scenes/menus/dev_panel.tscn` +
  `godot/scripts/menus/dev_panel.gd`, toggled with **F1**
  (new `toggle_dev_panel` input action). Tabbed control
  hub for the debug `#[func]` surface: **Hotkeys** (full
  keybind legend), **Player** (HP/stamina/survival
  setters), **Spawn** (NPC population-target nudge,
  container drop in front of player), **Region**
  (direct-jump teleport to any region in
  `all_regions()`), **Weather/Time**
  (`set_weather`/`cycle_weather`/`set_time_of_day`/
  `advance_time`), **World** (population scale,
  behavior-log toggle, save/wipe). All mutations route
  through the existing `SimHost` `#[func]`s so
  direct-mode + worker-mode share one path — every
  control works post-PR-C. `debug_overlay.gd` (backtick
  toggle) is trimmed back to just stats + a one-line
  `[F1] dev panel  [`] toggle this overlay` hint at the
  bottom; the previous hardcoded legend block migrated
  into the dev panel's Hotkeys tab so it's editable in
  one place.
- **Dev tooling** - `BehaviorLog` resource (togglable via
  `Sim::set_behavior_log`) emits structured `tracing` events under
  target `npc.behavior` for spawn / death / migration / objective
  change / aggro. The `watch` example
  (`cargo run --example watch -p simn-sim`) ticks a fresh sim at
  20Hz and streams these to stdout for headless evaluation.
- **Pure vs journaled systems** - pure per-tick systems (`tick_npc_goals`,
  `regen_stamina`, `advance_world_time`) don't journal. Discrete
  events (`spawn_npcs`, `migrate_npcs`, `age_npcs`, player API
  mutations) push to a `PendingDeltas` resource that `Sim::tick`
  drains to the journal each tick.
- **Region graph** - named, id-keyed regions with neighbor edges;
  seeds a two-region test graph that maps to the existing test scenes.
- **Tick loop** - fixed-timestep `bevy_ecs` schedule. Pure systems
  (`advance_clock`, `advance_world_time`, `regen_stamina`) run each
  tick without journaling; explicit mutations through the public
  `Sim` API (move, damage, heal, …) journal a `WorldDelta`.
- **Persistence** - journal-then-snapshot: every tick appends deltas
  to a journal file, every ~30s a full snapshot rotates the journal.
  Writes are atomic (tmp + fsync + rename). Load replays the journal
  tail on top of the latest snapshot; torn tails are skipped rather
  than erroring.
- **Persistence — worker offload (per `CLAUDE.md` Rule 9).**
  `JournalWriter` is a handle around a background
  `simn-sim-journal-writer` thread. `append` bincode-encodes the
  delta + crc on the caller's thread (so serialization errors
  propagate synchronously) then ships bytes via a crossbeam
  channel; the writer thread owns the `BufWriter<File>` and runs
  the periodic / idle `fsync` itself via `recv_timeout`. `rotate`
  and `flush_and_sync` queue like any op but block on an ack
  channel so the disk-side state has settled before the caller
  continues. `maybe_fsync` is a no-op kept for API parity. Channel
  ordering is FIFO, so journal record order matches tick order.
  The paired `persistence::SnapshotWriter`
  (`persistence/snapshot_writer.rs`) is the snapshot-side mirror:
  the worker serializes the ECS to bytes on its own thread, hands
  the bytes to `simn-sim-snapshot-writer`, which does the atomic
  tmp+rename + `sync_all`. `Sim::shutdown` joins both writers
  before returning so the final state actually hits disk.
  `write_snapshot_bytes` is re-exported from `persistence` so the
  bg writer can call straight into the disk path. Net effect:
  multi-MB snapshot writes and the 1 s journal fsync no longer
  stall the 20 Hz tick.
- **Per-run save isolation** - `SavePaths::in_run_dir(root, run_id)`
  resolves to `<root>/saves/<run_id>/world.{save,journal}`. Solo and
  coop-host sessions each pass a unique run id so named runs never
  stomp each other. Joining clients don't use `SavePaths` at all.
- **Mirror sim for clients** - `Sim::new_mirror(graph)` builds a sim
  with `journal: None` and `save_paths: None`. `tick()` runs a
  reduced schedule (pure per-tick player systems only - no
  `spawn_npcs`, `tick_npc_goals`, `npc_combat`, etc.) because those
  systems' RNG seeds mix in `Entity::to_bits()` which isn't stable
  across sim instances. `apply_external_snapshot` + `apply_external_delta`
  feed host state in. The `MirrorMode` marker resource lets
  downstream code detect the mode if ever needed. `drain_tick_deltas`
  exposes the host's per-tick output for broadcast.
- **In-memory sim for tests** - `Sim::new_in_memory(graph)` /
  `Sim::new_in_memory_with_seed(graph, seed)` build a full-schedule
  sim with `journal: None`, `save_paths: None`, and
  `PopulationTargets` cleared after seeding. Tests that don't care
  about NPC spawning (inventory, crafting, weapons, wounds) cut
  per-tick cost from ~400 ms to ~90 µs in debug. Tests that *do*
  want NPCs opt back in either by calling
  `set_population_target_for_test` (a few NPCs of one faction in
  one region) or by using `Sim::new` + `scale_all_population_targets(0.02)`
  (~40 NPCs across the test graph instead of ~3000). Registry loads
  (`ItemRegistry`, `RecipeRegistry`, `BallisticsConfig`,
  `NameRegistry`, `FactionRegistry`, `NpcLoadoutRegistry`) are
  cached process-wide via `OnceLock` so the TOML parse + validation
  runs once across the entire test binary. The full sim test suite
  ran in ~9 minutes before this work and ~6 seconds after.
- **Action dispatch** - `Sim::apply_action(steam_id, ActionKind)`
  routes every client-originated mutation variant
  (Move / ChangeRegion / ApplyBandage / Eat / ConsumeSlot /
  CraftRecipe / ...) to the existing mutation method. Enables client
  → host action relay without duplicating logic. Host's resulting
  deltas naturally broadcast back to everyone.

Still to come: online/offline tier hand-off (per-fidelity split when
a player is nearby), richer combat (current `npc_combat` is a
placeholder: distance-bucketed dice scaled by `Aggression` and the
NPC's `accuracy` stat, with an interim LOS gate via the per-tick
`LosCache` populated by `npc_aggro` — no projectile collision yet
(the player projectile pipeline is live but NPCs don't use it),
no cover, no GOAP — see the parked `tactical-ai.md` plan for where
this is headed), static-obstacle integration in pathfinding (phase
2 of `npc-traversal-plan.md`), more world-event-bus emitters
(`EnemySighted` from aggro, `Gunshot` from npc_combat, and
`AllyDown` from npc_death_check are wired; `BaseFlip`,
`PortalUsed`, `CorpseSpotted`, `Chatter` are still stubs),
individual-survival goal candidates, persistent
`LivedExperience.kills` across snapshot reload, creature ecology,
inventory and economy. These land as systems on top of the
existing data/persistence layer, not architectural rewrites.

Planned-but-designed additions in this crate (see the linked plan docs):

- **`PhysicsBackend` trait** - abstraction layer so sim logic calls into
  physics queries (raycast, overlap, step) without knowing whether Jolt
  (listen-server) or Rapier (dedicated) is the live backend. Folds the
  existing `LosProvider` trait in. See `../planning/physics-backend-plan.md`.
- **Reactive physics tiering** - dynamic per-session Tier 2 ceiling and
  per-peer priority-based replication, so reactive destruction scales
  smoothly across connection/compute profiles. See
  `../planning/physics-tiering-plan.md`.
- **`Destructible` component + damage pipeline** - props, world buildings,
  and base sections with state-machine destruction that persists via the
  World Ledger and respects Squall refresh rules. See
  `../planning/destruction-plan.md`.
- **`LimbState` + `WoundKind`** - extension of existing `BodyParts` to
  track `Intact | Wounded | Severed` per limb, with a caliber-driven
  `resolve_wound_kind` that classifies hits into wound types including
  `Sever` and `HeadGib`. Integrates with the existing wound pipeline
  without replacing it. See `../planning/dismemberment-plan.md`.

Smart terrain + content authoring (landed):

- **Activity points** (`resources::ActivityPoints`) — designer-placed
  `ActivityPointMarker3D` nodes register typed NPC goals (GuardStatic,
  GuardPerimeter, PatrolWaypoint, RestSpot, Lookout, Campfire,
  Workbench, Stash, SniperNest, AmbushPoint) with faction, capacity,
  and priority. The squad planner checks activity points first for
  Guard/Patrol/Rest objectives before falling back to legacy base-
  position selection. POI baker auto-generates activity points per
  BaseKind (3–18 points per base).
- **Patrol routes** (`resources::PatrolRoute`) — `PatrolRouteMarker3D`
  (Path3D-based) defines connected waypoint chains NPCs walk in loop
  or out-and-back mode.
- **Authored spawn points** (`resources::AuthoredSpawnPoints`) —
  `SpawnPointMarker3D` gives designers per-location control over
  faction, spawn rate, squad size, max concurrent, and loadout tier.
  Checked before `PopulationTargets` backfill in `npc_spawn`.
- **Cover volumes** (`cover::CoverVolumes`) — `CoverVolumeMarker3D`
  places authored cover with material type (11 materials from
  `content/cover_materials.toml`), thickness, and destructibility.
  Physical projectiles test cover via swept-ray-vs-AABB each tick;
  `can_penetrate` compares projectile `penetration_class` against
  material `protection_class` with angle-of-incidence and thickness
  scaling. Destructible cover loses health on hit.
- **`cover.rs` module** — `CoverMaterialId` enum, TOML-driven material
  table (`OnceLock`-cached), `can_penetrate()` → `PenetrationResult`
  (Stopped / PartialPenetration / FullPenetration), ray-AABB
  intersection, `CoverVolumes` resource with spatial queries.
- **Distance-based energy falloff** — projectile damage now uses
  retained kinetic energy at impact (`E = 0.5mv²` from drag-decayed
  velocity) instead of muzzle energy. Long-range shots do less damage.

Combat AI (landed):

- **`CombatStance` component** — 6 tactical states (Approaching,
  InCover, Firing, Suppressed, Flanking, Retreating). Drives movement
  target selection in `tick_npc_goals` and fire-decision gating in
  `npc_combat`. NPCs seek cover via `nearest_cover()`, peek-shoot on
  cycle (role-dependent timing), get suppressed under concentrated
  fire, and retreat at low health or when squad takes heavy losses.
- **`CombatRole` component** — 4 squad combat roles (Pointman,
  Support, Flanker, Medic) auto-assigned from `NpcCharacter` stats +
  personality on first combat entry. Roles influence stance: Pointmen
  push forward without cover when healthy, Support holds with longer
  peek windows, Flankers take lateral positions, Medics prioritize
  downed allies.
- **`npc_tactical` system** — per-tick combat brain for aggroed NPCs.
  Threat assessment from `RecentAttackers`, cover-seeking, suppression
  detection (3+ hits or 2+ distinct attackers → pinned for 3s), squad
  retreat (2+ downed allies → all retreat), role-based peek staggering.
- **Focus fire** — `goal_arbitration` reads the squad's `ThreatList`
  blackboard and overrides individual aggro with the top-threat target
  so all squad members concentrate fire on the most dangerous enemy.
- **Tactical chatter** — stance transitions emit `WorldEventKind::Chatter`
  events (Alarm on contact, Callout on suppression/flanking/retreat).
  Per-faction chatter lines in `data/chatter_lines.toml`.
- **Auto-generated cover** — `scatter_cover_generator.gd` walks
  RockScatter/TreeScatter MultiMeshes and registers cover volumes
  from placed rocks (earth-class) and tree trunks (wood-class).

Structural cleanup (landed):

- **`world/mod.rs` split** — 2,836 → 884 lines. Extracted into
  `world/tick.rs` (tick loop + schedules), `world/player.rs` (player
  CRUD + damage), `world/npc_view.rs` (NPC/base views + chronicle),
  `world/population.rs` (terrain + nav + region lifecycle),
  `world/registration.rs` (interaction areas + bases + activity
  points + cover volumes).
- **Pursue-progress timeout** — `ActiveGoal.pursue_progress` tracks
  NPC progress toward aggro target; drops aggro after 30s of no
  progress (fixes "stuck in Pursue" QA complaint).
- **Commitment window** — `ActiveGoal.committed_until_tick` gives
  SquadObjective goals 30s of protection from non-combat preemption.
  Combat sources (priority ≥ 140) bypass.
- **Smoother Wander drift** — `SquadObjectiveState.last_drift_heading`
  biases new drift legs toward the previous heading ±90°.

The core mechanic target is two-tier fidelity: entities near players
run on the online tier with full physics/AI, entities elsewhere run on
an offline graph-level simulation. Implementation ideas may be drawn
from clean-room study of OpenXRay and similar publicly available open
source projects; no code is copied.

## simn-terrain

Canonical heightmap loader + sampler. Engine-agnostic, no `godot`
dependency. The server is authoritative for terrain elevation; this
crate is the single source of truth the server consults. The Godot
side (in `simn-godot`) builds its render mesh + `HeightMapShape3D`
collider from the same canonical file, and a parity test (arriving in
a later phase) ensures both sides agree to < 1 mm at any queried `(x, z)`.

Canonical format per map (format_version 2, since 2026-05-03):

```
godot/assets/terrain/<map_id>/
├── heightmap.r32    // raw 32-bit LE float, row-major, N-up, W*H samples (literal meters)
├── features.r8      // optional: land-cover class per sample (15 classes), W*H bytes
├── nav_mask.r8      // optional: designer-painted nav override per cell, W*H bytes (iter 5-13)
└── terrain.toml     // TerrainMetadata: grid dims, spacing, vert range, UTM origin,
                     //                   BLAKE3 digest of heightmap + optional features_blake3
                     //                   + optional nav_mask_blake3 / nav_mask_format_version
```

The legacy v1 `.r16` (u16 quantized via `vert_min_m`/`vert_max_m`)
was retired by `migrate_canonical_format`. v2 stores literal f32
meters, which round-trips bit-exactly with Terrain3D's editor data
via the `Sync to Canonical` button. `vert_min_m` / `vert_max_m`
survive in `terrain.toml` as gameplay metadata only.

Public API today:

- `Heightmap::load(dir)` - reads the pair (plus optional
  `features.r8`), validates format version + grid dimensions + sample
  count + optional BLAKE3 digest(s).
- `Heightmap::from_raw(metadata, samples)` - procedural constructor
  for tests and generators; takes `Vec<f32>` (literal meters) and
  skips I/O + integrity checks.
- `Heightmap::sample(x, z) -> f32` - bilinear interpolation in
  world-local space; clamps to edges when outside the grid.
- `Heightmap::sample_normal(x, z) -> [f32; 3]` - unit-length surface
  normal via central differences on neighboring samples.
- `Heightmap::has_features() -> bool` - true when the optional
  `features.r8` companion raster was loaded alongside the heightmap.
- `Heightmap::sample_feature(x, z) -> FeatureClass` - nearest-neighbor
  lookup into the features raster; returns `FeatureClass::Unknown` when
  no features are attached.
- **Iteration 5-13 Phase A1: nav-override mask.** `Heightmap` gains an
  optional `nav_mask: Option<Vec<u8>>` field, one byte per cell on the
  same `W × H` grid as `features.r8`. `Heightmap::nav_override_at(col,
  row) -> NavOverride` returns the cell's designer override
  (`Default`, `ForceBlocked`, `ForceWalkable`), defaulting to `Default`
  for cells out of bounds or on maps without a painted mask.
  `Heightmap::nav_mask_bytes()` exposes the raw bytes for the Godot
  side to round-trip back into Terrain3D when re-seeding regions from
  canonical. Loaded strictly when `metadata.nav_mask_blake3` is set
  (length + blake3 + format-version validated); `None` otherwise.
  See `docs/book/src/planning/sim-iteration-5-13-plan.md`.
- `NavOverride` (re-exported from `simn_terrain::nav_mask`) — three-state
  per-cell override consumed by `simn-sim::nav::GridNavQuery`:
  `Default` (defer to slope+class), `ForceBlocked` (designer no-go),
  `ForceWalkable` (carve through Cliff/Water/slope). Byte encoding
  in `nav_mask.r8` is `0` / `1` / `2`; unknown bytes degrade to
  `Default` with a once-per-process warn log via `nav_mask::decode`.
- `Heightmap::from_raw_with_layers(metadata, samples, features,
  nav_mask)` — test-only constructor that takes optional `features.r8`
  and `nav_mask.r8` byte vectors directly, skipping disk I/O.
  Used by `simn-sim`'s nav tests + the `nav_mask_e2e` integration test
  that paints a corridor block and verifies A* routes around it.
- `Heightmap::spacing_m() -> f32` — world-local sample spacing in
  meters; mirrors `TerrainMetadata::spacing_m`. Lets bridge callers
  size a live-Terrain3D heightmap push back to the sim without
  re-reading the canonical `.toml`.
- `TerrainMetadata::extent_m() -> [f32; 2]` - physical size of the
  heightmap, **measured as `(W - 1) * spacing`**, matching the
  `ArrayMesh` vertex layout and Godot's `HeightMapShape3D` collision
  extent. Using `W * spacing` here instead drifts ground sampling by
  half a cell, compounding into real Y error on steep slopes (see
  CLAUDE.md Critical Rules).
- `sampler::legacy_v1::{decode_r16, u16_to_meters}` - v1 read helpers,
  used only by the one-shot `migrate_canonical_format` binary. New
  code should never call these.
- `TerrainMetadata::features_blake3` - optional BLAKE3 digest of the
  features raster; `#[serde(default)]` so older `terrain.toml` files
  load unchanged.
- `TerrainMetadata::region_size_m` - Terrain3D-aligned region edge
  length in world meters (default 2048 m at 2 m spacing). `bake_map`
  snaps `BakeBounds::extent_x` / `extent_z` up to the next multiple
  of this so the canonical map tiles Terrain3D's region grid cleanly.
  `Heightmap::region_size_m()` exposes the loaded value;
  `BakeBounds::aligned_extent_x()` / `aligned_extent_z()` /
  `extent_x_was_aligned()` / `extent_z_was_aligned()` let callers
  inspect the alignment behavior. Without alignment, a canonical
  bake whose extent isn't a region multiple lands partially inside
  unbaked Terrain3D regions and the rendered terrain shifts off
  canonical center by up to a region-width.
- `FeatureClass` - public enum of 15 land-cover classes from three
  stacked sources:
  - **ESA WorldCover v2 (2021), base layer** - `Water`, `Forest`,
    `Shrubland`, `Grassland`, `Cropland`, `BuiltUp`, `Bare`, `Snow`,
    `Wetland`, `Moss`, plus `Unknown`. Mapped 1:1 from the ESA class
    bytes via `features::map_esa_worldcover_class`.
  - **Slope override, middle layer** - `Cliff` (discriminant 20),
    emitted by the baker wherever the heightmap normal tilts past the
    cliff threshold. Always wins over the ESA class so rock faces read
    visually distinct regardless of the 10 m-resolution source raster.
  - **OSM highway overlay, top layer** - `PavedRoad` (21),
    `UnpavedRoad` (22), `Trail` (23). Rasterized from OSM `highway=*`
    ways after ESA + slope. Precedence: never paints over `Water`;
    `UnpavedRoad` never overrides `PavedRoad`; `Trail` never overrides
    any road. Byte discriminants are stable; added variants append so
    stored `.r8` assets remain forward-readable.
- `FeaturesSource` - bake-spec enum (`EsaWorldCover { tile, path }`)
  describing where baked `features.r8` data originates. The
  `features` module also exposes `WorldCoverTile`,
  `parse_worldcover_tile_sw`, `ensure_worldcover_tile` (downloads from
  the ESA S3 bucket and patches the TIFF `PhotometricInterpretation`
  tag in place), and `read_worldcover_tile` (GeoTIFF strip/tile decode
  via the `tiff` crate).
- `OsmOverlay` - bake-spec struct (`{ roads: bool, landcover: bool }`),
  optional `BakeSpec.osm` field. Flags opt in per-map:
  - `roads` - fetch OSM `highway=*` ways via the Overpass API and
    rasterize them as PavedRoad / UnpavedRoad / Trail after the ESA
    + slope passes.
  - `landcover` - fetch OSM `natural=*` / `landuse=*` / `water=*`
    polygons (and multipolygon relations) and rasterize them on top
    of the ESA raster but before the road overlay. OSM is human-
    digitized at real feature edges so treelines, lake shores, and
    built-up boundaries read as organic curves instead of ESA's
    10 m staircase. Roads still win over landcover where they
    overlap.
- `features::smooth_class_boundaries(bytes, w, h, sigma, preserve_mask)`
  - final `features.r8` post-process. ESA WorldCover is a 10 m
  raster sampled onto a ~2 m grid, which bakes hard right-angle
  staircases at every class boundary. For each unique class in the
  input, this pass blurs its binary mask with a separable Gaussian
  of the given sigma (grid cells) and then per-pixel assigns the
  class with the highest blurred response - the boundary becomes a
  smooth curve (the level set between two classes' blurred masks)
  instead of a rasterized step.
  - `preserve_mask: Option<&[bool]>` - caller-supplied per-cell
    boolean. When `mask[i] == true`, cell `i` keeps its input class
    through the smoothing pass. The baker uses this to mark cells
    painted by the OSM polygon overlay so their crisp human-
    digitized edges aren't softened back into ~3σ-wide blobs. ESA
    cells (`mask[i] == false`) get the full smoothing treatment.
  - **Always-restored** classes (regardless of mask): `PavedRoad`,
    `UnpavedRoad`, `Trail`. These 1-3 cell-wide line features have
    too little argmax response to win against any adjacent area
    class.
  Called by the baker immediately after the OSM overlay, contributing
  the final `+ boundary smooth σ=…` stage to the features label.
- `splatmap` module - turns the per-cell `FeatureClass` byte grid
  into two RGBA8 splatmaps, each channel a per-pixel blend weight
  (0..255) for one class group. The terrain shader samples them
  with linear filtering for sub-cell smooth biome blending instead
  of the previous categorical 4-corner class-bilinear.
  - `bake_splatmap_pair(bytes, w, h) -> SplatmapPair` - top-level
    bake. Per-channel binary mask → Gaussian blur with the
    channel's own σ → per-pixel normalize across all 8 channels.
  - `SPLATMAP_A_CHANNELS` (RGBA): R Forest (Forest+Shrubland+Moss,
    σ=3.0), G Grassland (Grassland+Wetland, σ=2.0), B Water
    (σ=1.0), A Cropland (σ=1.5).
  - `SPLATMAP_B_CHANNELS` (RGBA): R Bare (σ=1.0), G BuiltUp
    (σ=0.5), B Cliff (σ=0.5), A Snow (σ=1.0).
  - Per-class σ tuning expresses "increase resolution where
    needed, decrease where needed" - wide homogeneous biomes get
    soft bleed, human-made / geological hard edges keep
    knife-edge sharpness.
  - Line classes (PavedRoad / UnpavedRoad / Trail) stay on
    `features.r8` - too thin to ride a splatmap channel without
    disappearing under blending. The shader paints them as a line
    overlay on top of the splatmap blend.
  - Output: `splatmap_a.rgba8` + `splatmap_b.rgba8` (both 4 × W ×
    H bytes) alongside `features.r8` in each map's asset dir;
    `Heightmap::splatmap_a_bytes` / `splatmap_b_bytes` load them
    best-effort (legacy maps without splatmaps return None and
    the shader uses the categorical fallback path).
- `osm` module - public surface covers the full overlay pipeline:
  `RoadClass` (Paved/Unpaved/Trail with per-class `width_m()`: 8 m /
  5 m / 2.5 m brushes), `classify_highway(tags)` (maps OSM
  `highway=*` + optional `surface=*` tags to `Option<RoadClass>`),
  `classify_osm_polygon(tags)` (maps OSM `natural=*` / `landuse=*` /
  `water=*` / `waterway=*` / `leisure=*` tag bags to an
  `Option<FeatureClass>` with water-wins-over-landuse precedence),
  `OverpassResponse` / `OverpassElement` / `OverpassPoint` /
  `OverpassMember` (serde-deserialized Overpass JSON; `OverpassMember`
  carries per-member geometry for multipolygon relations), `Bbox` +
  `spec_wgs84_bbox(spec)` (WGS84 bbox for a bake spec),
  `fetch_highways(bbox, cache_dir)` and `fetch_osm_landcover(bbox,
  cache_dir)` (Overpass via `curl` with mirror fallback, per-query
  cached under the shared `dem_cache_dir`),
  `wgs84_to_utm_zone_n(lat, lon, zone)` (project OSM node coords
  into the map's UTM frame), `apply_osm_highways_overlay(spec,
  features, width, height)` (distance-to-segment brush rasterizer
  for line features with the road-precedence rules above), and
  `apply_osm_polygon_landcover(resp, spec, zone, w, h, bytes)`
  (even-odd scanline polygon fill for area features; handles
  multipolygon inner-ring holes; water polygons paint through
  everything, other classes skip existing water).

The sampler is pure math in `sampler.rs` (bilinear + r16 codec), kept
separate from I/O for ease of unit testing. When Godot-side parity
lands, the algorithm here may need to switch from bilinear to triangle
interpolation to match `HeightMapShape3D`'s triangulation exactly; that
decision is deferred until the parity test can drive it empirically.

Bakers live under `examples/` (one per map until we generalize into a
CLI once a second real map is baked):

- `generate_test_maps` - synthetic fixtures for `test_map_{1..4}`
  (ramp / hills / basin / ridge).
- `bake_corbett` - pure-Rust pipeline baking the first real DEM-backed
  map from NASA SRTM 1-arcsec source. Inverse-projects UTM → WGS84
  (zone 10N for the Columbia Gorge spine; 11N is also supported for
  endgame Columbia Plateau maps east of -120°, e.g. umatilla /
  hanford_spur) per target vertex and bilinearly samples the `.hgt`
  tile; no GDAL dependency. See `docs/book/src/walkthroughs/terrain.md`
  for the specific bounds + observed elevation range.

## simn-net

Session and transport layer over Steam. Listen-server P2P with
host-authoritative role model for the current slice: Steam lobby for
identity and membership, Steam P2P packets for state. The public
surface is `NetSession` (owns the Steam client, lobby, peer table, and
`NetRole` for the local peer) plus a `NetEvent` enum the engine layer
translates into Godot signals. `tick()` must be called every frame to
pump callbacks, drain incoming packets, and broadcast local state.
Pure Rust, no `godot` dep.

Slice-1 wire protocol adds to the legacy `Msg::State` (unreliable,
pill-lerp) three **reliable** variants for sim replication -
`Msg::Snapshot { tick, payload }` (bincoded `SnapshotBody` for join
handshakes), `Msg::Delta { tick, payload }` (bincoded
`Vec<WorldDelta>` for per-tick broadcast), `Msg::JoinRequest` (client
asks host for a snapshot), and `Msg::Action { steam_id, payload }`
(bincoded `ActionKind` for client → host input relay). Payloads are
opaque `Vec<u8>` at this layer; serialization lives in `simn-sim`.

`NetRole` is `Solo` / `Host` / `Client { host_steam_id }`, set by
`host()` / `join()`. `broadcast(&msg)` and `send_to(peer, &msg)` pick
reliability via `Msg::reliability()`. See
`architecture/networking.md` for scope and non-goals.

## simn-godot

The gdext extension crate. **The only crate that depends on `godot`.**
Compiled as a `cdylib` (`libsimn_godot.so` / `.dll` / `.dylib`) that
Godot loads via `simn.gdextension`.

Bridges the simulation core into Godot via `GodotClass` types and
`#[func]` methods that GDScript can call. Currently registers:

- `PhysicsSetup` - runtime collision shape builder for static props.
- `NetworkManager` - lazy Steam init, signal bridge over `simn-net`.
  Beyond the legacy `peer_joined` / `peer_left` / `peer_state` /
  `lobby_ready` / `join_requested` signals, slice 1 adds
  `snapshot_requested(peer_steam_id)`, `snapshot_received(tick, payload)`,
  `delta_received(tick, payload)`, `action_received(peer, sid, payload)`.
  `#[func]` surface adds `role() -> GString`, `host_steam_id() -> i64`,
  `is_authoritative() -> bool`, `send_action(sid, payload)`,
  `broadcast_snapshot(tick, payload)`, `broadcast_delta(tick, payload)`,
  `send_snapshot(peer, tick, payload)`, `send_join_request()`. Rust-side
  `current_role() -> NetRole` is used by `SimHost` for its mutation
  gate without a GString roundtrip.
- `TerrainNode` - `StaticBody3D` subclass that loads a canonical
  heightmap from `res://assets/terrain/<map_id>/` via
  `simn_terrain::Heightmap::load` and materializes it as a visual
  `MeshInstance3D` (ArrayMesh built from the grid) + collision
  `HeightMapShape3D`. Exports `map_id` and `auto_load`; emits
  `terrain_loaded` / `terrain_error` signals. The visual mesh is
  centered on the node's position, so a 5 km × 5 km map at `(0, 0, 0)`
  extends ±2.5 km. Collision shape is scaled by `spacing_m` on X/Z so
  the physical extent matches the visual. Exposes `grid_dims() ->
  Vector2i` and `spacing_m() -> f32` accessors so callers (notably
  `test_map.gd`) can size a live-Terrain3D heightmap push back to
  the sim without re-parsing `terrain.toml`. Both return zero before
  `load_map` succeeds; await `terrain_loaded` before calling.
- `RegionalBackdrop` - `MeshInstance3D` subclass that loads the
  shared `_regional` heightmap (~80 km × 110 km of the Columbia
  Gorge at 100 m sample spacing) and renders it as a non-collidable
  backdrop wrapping the playable map. On ready: walks siblings to
  find the playable `TerrainNode`, reads its `map_id` export to
  load the playable's UTM origin from `terrain.toml`, builds an
  `ArrayMesh` with the playable extent **hole-punched** (no z-fight
  with the foreground terrain), and positions itself so the
  regional UTM origin lines up with the playable scene's world
  frame. Exports `regional_map_id` (default `_regional`) and
  `regional_material` (defaults to `terrain_regional.tres`).
  Renders with `terrain_regional.gdshader` - ~5-8 texture samples
  per fragment vs ~96 for the playable shader. Frustum-culled and
  fog-faded by the shared `WorldEnvironment`. Each map scene
  instances the shared `regional_backdrop.tscn` as a sibling to
  `Terrain` (mirrors the `weather_rig.tscn` pattern).
- `SimHost` - owns the `simn-sim::Sim`, ticks it each frame, exposes
  the sim API to GDScript: `start`, `load_region_terrain`,
  `attach_region_terrain_from_packed_heights` (live-Terrain3D push;
  bypasses canonical `.r32` so sim Y-snap matches the rendered
  surface — see `walkthroughs/terrain.md`),
  `upsert_local_player`,
  `move_local_player`, `change_region`, `remove_player`,
  `damage_player`, `heal_player`, `set_player_stamina`,
  `player_state` (dict with position/region/health/stamina/maxes),
  `region_control(name)` (dict with primary/contested_by/tension),
  `bases_in_region(name)` (array of {kind, faction, pos, health,
  max_health}), `faction_relation(a, b)` (string),
  `npcs_in_region(name)` (array of NPC views),
  `chronicle_summary()` (alive/ever per faction),
  `recent_deaths(limit)` (array of LifeRecords),
  `world_time` (dict with day, seconds_of_day, day_length_seconds),
  `region_map_scene`, `current_tick`, `shutdown`. Inventory: `grant_item`,
  `drop_slot`, `move_slot`, `consume_slot(sid, slot, body_part_or_empty)`,
  `salvage_slot`, `craft_recipe`, `set_near_campfire`, `item_catalog`.
  Step 5 Slice B adds `recipe_catalog`, `can_craft`, `queue_craft`,
  `cancel_craft`, `set_near_workbench`, plus three new
  `ActionKind` variants (`SetNearWorkbench`, `QueueCraft`,
  `CancelCraft`) routed through `apply_action` for client→host
  dispatch. `player_state` carries `inventory`, `inventory_weight`,
  `near_campfire`, plus the Slice B fields `near_workbench` (string
  tier tag) and `crafting_queue` (array of in-flight jobs). Schemas
  in `docs/book/src/api/sim-host.md`. Inventory + crafting browser
  scenes live at `godot/scenes/menus/inventory.tscn` (toggle: `I`);
  scene-placed workbench entities + a proximity system follow with
  worldbuilding work - `R` cycles the debug workbench tier and `F3`
  toggles the campfire flag in the meantime (`F` is the looting
  `interact` action as of PR-4c).

  **Slice-1 replication**: `start_mirror()` builds a client-side sim
  without save paths; `attach_network(nm)` wires in a `NetworkManager`
  reference for role-based mutation gating; every mutating `#[func]`
  checks `is_client()` and emits an `action_requested(sid, payload)`
  signal instead of mutating locally. Host broadcast fires via the
  `tick_completed(tick, payload)` signal after each host tick.
  Receive side: `apply_network_snapshot(tick, payload)` /
  `apply_network_delta_batch(tick, payload)` /
  `dispatch_network_action(sid, payload)` /
  `serialize_snapshot_payload() -> {tick, payload}`.
  `snapshot_applied(tick)` signal fires when a mirror finishes
  ingesting a host-sent snapshot so `GameSession` can hide its
  "connecting…" state and load the region scene.

The crate's `build.rs` copies `libsteam_api.so` from the `steamworks-sys`
build output into `target/<profile>/` so the runtime loader can find it
next to `libsimn_godot.so` (rpath is set to `$ORIGIN`).

Planned-but-designed additions in this crate (see the linked plan docs):

- **`GodotJoltBackend`** - implementation of `simn-sim::PhysicsBackend`
  that routes queries to Godot's physics server. See
  `../planning/physics-backend-plan.md`.
- **`DestructibleComponent`** - gdext node that mirrors server-side
  `Destructible` state onto scene geometry (mesh/collision variant
  swap, gib-burst prefab instantiation, SFX). See
  `../planning/destruction-plan.md`.
- **Reactive IK controller** - GDScript + `SkeletonModifier3D` stack on
  every humanoid, runs transient IK goals from replicated `HitEvent`s.
  See `../planning/dismemberment-plan.md`.

## simn-world (planned)

SQLite-backed persistent world-object ledger that sits alongside the
existing journal+snapshot. Holds destructible state, loot node rolls,
container contents, corpses, player-base composition, and settled
Tier 3 physics objects - the queryable persistent world-object facts
that would bloat the ECS snapshot if folded in. Engine-agnostic, no
`godot` dep. See `../planning/world-ledger-plan.md` for schema, write
batching, Squall refresh pass, and backup/rollback.

## simn-server (planned)

Pure-Rust headless dedicated-server binary. Owns a `Sim` with a
`RapierBackend` (vs `GodotJoltBackend` in listen-server mode). No
Godot dependency. Networking, persistence, and graceful shutdown. See
`../planning/physics-backend-plan.md` for architecture and migration path.
