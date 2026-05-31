# Iteration 5-12 — Roadmap Plan

**Status:** sequenced execution plan
**Last updated:** 2026-05-12
**Scope:** the next four major arcs of work after the threaded-sim merge (PR #152). Sequences existing planning docs (offline-tier, tier-transition, loot-and-economy, weapons) into commit-sized phases with explicit MVP / acceptance criteria. The point of this doc is *ordering* — each phase points at the design doc that owns the deep detail.

This doc retires once Phase 4 ships; until then it's the authoritative iteration plan.

---

## Why this exists

Threaded sim is in. The world ticks on a dedicated thread at 200+ fps total budget. We now have four piled-up problems to address before the next big architectural push:

1. **Spawn flood on region transition.** Walking through a transition cube triggers ~3 s of NPC spawning in the newly-active region — visible to the player as a frame-spike and a pop-in wave. The cause: `PopulationTargets` aren't pre-seeded at world init, and `spawn_npcs` doesn't gate on `ActiveRegions`. Symptom of a deeper gap: there's no offline tier yet, so the world doesn't *simulate* in unobserved regions, it just *freezes* them.
2. **No background events.** Without an offline tier, factions don't take bases, squads don't take casualties, and the PDA never lights up with "we just lost Aegis Forward Comms." The world feels static the moment you leave a region.
3. **Inventory UI is unusable.** No right-click context menu. Clicks unreliably register on item cards (regression rolled into PR #152). No tooltips, no filtering, no real drag-and-drop. Player has to alt-tab to a wiki to remember what an item does. Has to be fixed *before* loot & economy ships content the player can't usefully interact with.
4. **Ballistics is half-done.** Player projectile path landed in PR #27; NPC firing still uses distance-bucketed hitscan. Caliber roster + per-category TOMLs landed in PR #150. Attachment graph, parts condition, jams — all still planning-only.

Phase ordering reflects what blocks what: offline tier unblocks Phase 2-4 because every later system queries it; inventory UX unblocks Phase 3 because content without UX is unusable; loot unblocks Phase 4's weapon parts feedback loop.

---

## Phase 1 — Offline Tier MVP

**Goal:** the world *simulates* in unobserved regions at a small fraction of online-tier cost, emits coarse-grain events into the world event bus, and surfaces those events to the player as PDA notifications. NPCs no longer spawn en masse on transition because populations are pre-seeded across the world from sim init.

**Design source:** [`offline-tier-plan.md`](offline-tier-plan.md), [`tier-transition-plan.md`](tier-transition-plan.md), [`world-event-bus-plan.md`](world-event-bus-plan.md).

### 1A — Pre-seed + active-region gate (smallest meaningful slice)

- At `Sim::new`, after `seed_random_world_content` populates `PopulationTargets`, run a one-shot **bulk seed** that drains each region's target straight into ECS — bypassing `spawn_npcs`'s 8-squads-per-tick cap. World boots with every region's NPCs already alive, sitting at their bases.
- Gate `spawn_npcs` per-region: still run, but for *inactive* regions only top up populations on the offline-tier cadence (every 10 ticks, slower pace) and never burst.
- Active-region transition no longer triggers a spawn wave because the NPCs already exist.

**Acceptance:** walk from `test_map_1` → `test_map_2`. No frame spike at the cube; no NPCs pop in over the next 3 s; debug overlay shows expected NPC count from tick 0.

**Files:** `crates/simn-sim/src/world_seed.rs`, `crates/simn-sim/src/systems/npc_spawn.rs`, `crates/simn-sim/src/sim.rs::Sim::new`.

### 1B — `OfflineNpc` parallel schema

- New module `crates/simn-sim/src/offline_tier.rs`. Component shape per `offline-tier-plan.md` §3 — `OfflineNpc { id, region, position_2d, waypoint, waypoint_eta_tick, faction, group, health_class, loadout_class, personality_seed, stats, combat_state }`.
- New resource `OfflineTierClock` ticking at 2 Hz (every 10 sim ticks).
- Schedule: add an `OfflineTier` `SystemSet` running after the online schedule. Empty system for now — just verifies the schedule cadence.

**Acceptance:** sim still ticks, no offline NPCs created yet, `simn-sim` unit tests green.

### 1C — Projection function (online ↔ offline)

- Per `tier-transition-plan.md` §5: when `set_active_region` *removes* a region, project every online NPC in it down to `OfflineNpc` (despawn online entity, insert offline). When it *adds* a region, do the reverse.
- BodyParts → HealthClass: any limb < 25% → `Wounded`, vital part < 25% → `Critical`.
- Inventory → LoadoutClass: faction + a coarse tier inferred from weapon class.
- Squad cohesion preserved via `group` field.

**Acceptance:** `cargo test -p simn-sim` includes new `projection.rs` tests covering round-trip (online → offline → online) preserves health-class and faction, and that a wounded NPC stays wounded across the transition.

### 1D — `offline_movement`

- Per `offline-tier-plan.md` §4.1: NPCs hop along their region's waypoint graph; `waypoint_eta_tick` schedules arrival. On arrival, pick next waypoint per current squad objective.
- Reuse `goal_arbitration` / `squad_planner` objective selection — offline doesn't re-implement the planner, only the action resolution.

**Acceptance:** an offline-tier squad assigned Patrol visits its base waypoints in sequence; sim test asserts position changes over offline ticks.

### 1E — `offline_combat` + event emission

- Per `offline-tier-plan.md` §4.2: pairs of opposing-faction `OfflineNpc`s within engagement radius (150 m, tunable) roll combat dice each offline tick. Outcomes shift `HealthClass`; `Critical` + bleed roll → death + chronicle entry.
- Emit `Gunshot` / `AllyDown` / (new) `BaseFlip` events into the existing `WorldEventQueue`. Bus already routes these (PR #145) — we're just adding emitters.

**Acceptance:** start sim, let two contested-region offline squads tick for 60 s of sim time, observe at least one death + chronicle entry; `cargo test -p simn-sim --test offline_combat`.

### 1F — Cross-tier event delivery + PDA hook

- Offline-tier events become observable from online regions per `offline-tier-plan.md` §6. `BaseFlip` is global within faction; `Gunshot` near a region boundary may cross.
- New `#[func] all_world_events_for_player(steam_id) -> Array<Dictionary>` on `SimHost`. Returns recent (last 60 s of in-world time) events filtered by player faction + visibility rules.
- GDScript: PDA picks events off the signal, queues notifications (toast UI). Anomaly-style — one-line text, fades after 5 s. New scene `godot/scenes/ui/pda_notification.tscn`.

**Acceptance:** stand in `test_map_1`. Offline squad takes a base in `test_map_3`. Within 2 s of sim time, a "Linemen captured a Federal supply outpost" notification appears in the bottom-right.

**Phase 1 docs to update:** graduate `offline-tier-plan.md` portions to `walkthroughs/offline-tier.md`. Update `tier-transition-plan.md` to mark projection function as delivered.

---

## Phase 2 — Inventory UI Overhaul

**Goal:** the inventory feels good. Right-click contextual actions, real drag-and-drop, tooltips, filtering, sort, and visual polish. **Player can do everything they need without opening a wiki.**

**Design source:** new — capture decisions in `docs/book/src/mechanics/inventory.md` (player-facing contract) as we go; no separate plan doc needed for UI iteration.

**Status (2026-05-14):** 2A / 2B / 2C / 2D / 2G shipped on branch `sim-iteration-5-12`. **2E and 2F are deferred** to when their sim-side prerequisites land (see notes below). Moving on to Phase 3 next.

### 2A — Right-click context menu ✅ shipped

- `_gui_input` on item cards: `MOUSE_BUTTON_RIGHT` → spawn `PopupMenu` with `[Use, Equip / Unequip, Drop, Split…, Examine]`.
- Item kind drives which actions appear — medical/food gets `Use`, weapons/armor gets `Equip`, all show `Drop` / `Examine`.
- `Split…` opens a small modal for stackable items (rations, ammo, salvage).

**Landed in commit `45a363164f`** ("sim+godot: iter 5-12 phase 2 + worker offload").

### 2B — Real drag-and-drop ✅ shipped

- Replace click-carry with Godot's native drag system: `_get_drag_data`, `_can_drop_data`, `_drop_data` on each slot.
- Drag from grid → doll (equip), doll → grid (unequip), grid → grid (reorder), grid → world-container slot (transfer).
- Drag preview = item icon at 60 % opacity tracking the mouse.

**Landed in commit `45a363164f`.** Drop targeting + accept-check live in `godot/scripts/menus/inventory_drop_target.gd`.

### 2C — Tooltips on hover ✅ shipped

- ~0.5 s hover delay (Godot default) → rich tooltip panel: name, category badge, per-unit + total stack weight, stack max, magazine load state, perishable hint, rotation indicator. Empty doll slots show slot label + accepted categories.
- Powered by `SimHost.item_catalog()` cached once on panel open and threaded by reference into each card via the drop-target's `item_catalog` export — no per-hover bridge traffic.

**Landed in commit `096af8f528`** ("godot/inventory: phase 2C tooltips + tarkov-style doll cells").

The same commit also did a paper-doll cosmetic pass: tarkov-style dark-steel cells with a faded category watermark, slot-name chip top-left, count badge bottom-right on populated slots.

### 2D — Filter tabs + search ✅ shipped

- 7 chip buttons across the top of the right column (`ALL / WPN / AMMO / MED / FOOD / ARMOR / PARTS`) mapping item categories into coarse filter groups; one active at a time.
- Search box on the right of the toolbar matches against display name AND stable id (so power users can search `ak_mag_30`).
- Non-matching cards dim to ~28 % alpha rather than hide — keeps the grid layout stable so positions don't shift mid-filter (tarkov pattern: "highlight, not re-layout").
- Toolbar lives outside `_grids_column` so the search LineEdit survives per-tick rebuilds.

**Landed in commit `e463ed97c1`** ("godot/inventory: phase 2D filter chips + search box").

### 2E — Sort options ⏸ deferred (blocked on sim API)

Original spec: header dropdown for Name / Weight / Condition / Recency.

**Why deferred:** a 2D grid inventory has fixed positions per item, so "sort" doesn't apply the way it does to a flat list — the equivalent is an *auto-arrange / compact* action that needs a new sim API to re-pack pockets. That's sim work, not UI work, and there's no flat-list view today to attach a sort dropdown to.

**Unblock prerequisites:**
- Either: a `Sim::compact_pockets(sid)` action that emits the moves to repack items by sort key.
- Or: an alternate flat-list inventory view (toggle: Grid / List) that sorts the items array client-side and renders them as a scrolling list with the same drag-source / right-click affordances. The list view skips the spatial-layout cost but needs new UI scaffolding.

Either approach is its own iteration; 2E will land alongside one of them.

### 2F — Visual polish ⏸ deferred (blocked on sim fields)

Original spec: rarity tint, condition bar per card, equipped indicator, ghosted slot type on empty doll slots.

**Why deferred:** the four polish layers need data the sim doesn't surface yet.
- *Rarity tier* — no `rarity` field on `ItemDef`. Item rarity is a loot-table concept (Phase 3 territory) and would need a TOML schema extension.
- *Condition bar* — condition lands in weapons-plan Step 3 ("parts + condition + jams"). Per `crate-guide.md` this is explicitly the GAMMA-style wear layer and is deferred until ballistics is in place.
- *Equipped indicator on grid cards* — the inventory's grid-title vocabulary (POCKETS vs `equipped:armor_vest`) and the doll already convey what's mounted; a per-card "E" badge would mostly duplicate that. Worth doing once condition bars give us a reason to crowd more chrome on the card.
- *Ghosted slot-type placeholder* — partially shipped already: the Phase 2C doll cosmetic pass renders a faded category watermark (`RIFLE` / `VEST` / `HEAD` etc.) on every empty slot, which is the same affordance the original 2F spec was reaching for.

**Unblock prerequisites:** rarity surfaces on `ItemDef` (Phase 3's loot-pool work may motivate it), and condition surfaces on equipped weapons + magazines (weapons-plan Step 3, currently Phase 4D in this iteration).

### 2G — `view_updated` signal (replaces tick-poll) ✅ shipped

- `SimHost` emits a `view_updated()` signal when a new `SimView` is published, throttled to 4 Hz to match the inventory's perceptual refresh budget.
- Inventory panel listens; refreshes only on signal, not in `_process`. Same migration applied to `HotbarHUD` and the debug overlay.

**Landed in commit `45a363164f`** alongside the other Phase 2 work (the `view_updated` plumbing was a prerequisite for the inventory + HUD + debug-overlay perf throttles).

**Phase 2 docs:** `docs/book/src/mechanics/inventory.md` exists from the inventory-grid PR. The "In-game panel + hotbar" section was updated alongside the Phase 2A–2D/2G work to reflect drag-and-drop, the right-click context menu, hover tooltips, and the filter toolbar; rarity / condition / sort sections will land when 2E/2F unblock. Architecture-side mirror lives in `docs/book/src/architecture/menu-ui.md` (InventoryPanel bullet).

---

## Phase 3 — Loot & Economy Step 1

**Goal:** containers in the world have meaningful, faction-flavored contents. Restock is deterministic and seedable. Ambient scatter near recent NPC activity. Foundation laid for full circulating-inventory loop in Step 2.

**Design source:** [`loot-and-economy-plan.md`](loot-and-economy-plan.md), specifically §2 (three loot surfaces) and §3 (container model).

### 3A — Container registry + spawn ✅ shipped

- New TOML `data/loot_containers.toml` (separate from the equipable `data/items/containers.toml` — those are backpacks / rigs). Three shipped kinds: `small_crate` (4×4), `medium_stash` (6×6), `large_cache` (8×10) with weighted `spawn_weight` (70 / 25 / 5).
- New `crates/simn-sim/src/loot_containers.rs` module + `LootContainerRegistry` resource, loaded at sim init alongside the other TOML catalogs. Mirrors the `ItemRegistry` pattern — content config, never snapshotted.
- `world_seed.rs::seed_loot_containers` scatters 8–15 containers per procedurally-seeded region, anchored on a random base in that region with up to ±80 m XZ jitter. Same `ChaCha8Rng` stream the bases use, so the scatter is deterministic per seed.
- Containers start with **empty grids and `is_public = false`**. 3B fills them; 3C handles restock. The Phase 1 corpse + ground-drop containers (`spawn_corpse_container`, `drop_item_to_ground`) are unchanged.

**Field `(family, depth_tier, last_restock_tick)` and the persistence of those on `WorldContainer` is deferred to 3C** — they only become load-bearing once restock cares about them. For 3A the minimum surface is "the world has containers in the right places."

**Landed in commit `<pending>`** with tests in `crates/simn-sim/tests/loot_containers.rs` (registry parse, weighted-pick distribution, per-region count, near-base proximity, deterministic-seed roundtrip).

**Authoring marker (companion piece, same iteration).** `godot/scripts/world/loot_container_marker.gd` is a `@tool` `Node3D` for hand-placing containers on real maps (procedural scatter only covers the synthetic test maps). Inspector surfaces: `kind` (size), per-kind `model_variant` dropdown (visual scaffolding — model paths land later), `interaction_mode` (`OPENABLE` / `BREAKABLE`), `is_public` (kit-pool flag), `container_id` (stable id for the 3C restock seed). Markers register in the `loot_container_markers` group; the runtime walker that hands each placement to the sim lands with **Phase 3D**.

### 3B — Pool tables — faction × depth × family ✅ shipped

- New file `crates/simn-sim/data/items/loot_pools.toml`. One pool per `(faction, depth_tier, family)` tuple; entries are `{ id, weight, count_min, count_max }`. Surface-tier (1) coverage shipped for `pwa` / `bandits` / `wanderers` / `attuned` across 8 families (`weapons` / `magazines` / `ammo` / `armor` / `medical` / `food` / `tools` / `junk`). Interior + deep tiers (2, 3) land as zones are authored.
- New module `crates/simn-sim/src/loot_pools.rs` with `LootPoolRegistry` resource + `roll_one` + `roll_quest_reward` APIs. Lookup falls back through `(faction, tier, family) → (faction, 1, family) → (wanderers, tier, family) → (wanderers, 1, family) → None`, so a region with an unknown faction or unauthored tier still produces plausible scavenger loot.
- `loot_containers.toml` extended with per-kind `family_weights` (which families a kind tends to carry), `items_per_roll` (`[min, max]`), and `difficulty_weights` (`[difficulty, weight]` pairs driving quest-reward kind selection).
- `LootContainerRegistry::weighted_pick_for_difficulty` picks a kind biased by quest difficulty — 1 (trivial) skews toward `small_crate`, 5 (very hard) skews toward `large_cache`.
- Quest reward roll uses **best-of-K**: `roll_quest_reward` picks K candidates and keeps the rarest (lowest-weight) one. `quest_lottery_k(difficulty)` maps difficulty → K (1→1, 5→5), so harder quests skew strongly toward rare entries without rewriting weights per difficulty.

**Landed in commit `<pending>`** with tests in `crates/simn-sim/tests/loot_pools.rs` (9 cases): registry parse, fallback chain coverage, distribution within tolerance, K=5 vs K=1 rare-bias verification, difficulty curve constants, kind selection per difficulty, family pick honors kind weights, items_per_roll range.

### 3C — Eager initial roll + partial restock sweeps ✅ shipped

**Design pivot from the original plan.** The earlier
deterministic-hash design (`seed = hash(container_id, world_seed,
last_restock_faction, …)`) was rejected by the user — "same seed
produces same loot across runs" makes runs feel repetitive even
when seeds vary. Replaced with:

- **Eager initial roll at world-gen.** `seed_loot_containers`
  now rolls contents inline using the same `ChaCha8Rng` stream
  that places the containers. Each kind's `items_per_roll`
  drives the count; each slot picks a family via
  `pick_family` then an entry via `LootPoolRegistry::roll_one`.
  Faction comes from the region's `RegionControl.primary`
  (falls back to `wanderers` when missing). Contents persist
  via the existing snapshot machinery — reload of a save
  produces the same world, but **new saves with different seeds
  get different loot**.
- **Periodic restock sweep.** New system
  `systems/loot_restock.rs::tick_loot_restock` fires every
  `RESTOCK_SWEEP_INTERVAL_TICKS` (72_000 ticks ≈ 1 in-world
  hour ≈ 5 real min). For each container in an active region:
  roll `RESTOCK_CHANCE_PER_CONTAINER` (30 %); if win, add
  `[1, 3]` items via the kind's family-weighted pool roll.
  Partial top-up, not full refill — in-fiction this is supply
  squads / wanderers stashing a few items, not the world
  resetting. Player drops + corpses (`faction = None`) are
  skipped.
- **Squall-driven restock scaffold.** `apply_squall_restock`
  is the pull surface the faults system (internal design notes Step 7)
  will call when a squall resolves — same machinery as the
  periodic sweep with a caller-supplied salt and no cadence
  gate. Currently `#[allow(dead_code)]` until faults ship.
- **WorldContainer schema additive change.** `faction`
  (`Option<String>`), `depth_tier` (`u8`, default 1),
  `last_restock_tick` (`u64`, default 0) — all
  `#[serde(default)]` so pre-3C snapshots load cleanly. Player
  drops + corpses keep `faction = None` to opt out of restock.
- **Multiplayer note (TODO).** `RESTOCK_CHANCE_PER_CONTAINER`
  is currently a flat 30 %. When player-count plumbing
  exists, scale by `1.0 + 0.15 * (players - 1)` so 4-player
  worlds get ~1.5× the restock rate of solo, matching the
  user's "more loot for MP" requirement. Item counts already
  scale via `items_per_roll` ranges and the kind's
  `family_weights` lean junk-heavy enough that the
  break-down-to-crafting feedback is real.

**Landed in commit `<pending>`** with tests in
`crates/simn-sim/tests/loot_restock.rs` (4 cases): fresh
containers spawn with loot + factions, different seeds produce
different totals, restock fires only on cadence and only
partially (between 1 item and partial-of-max), factionless
drops skipped.

### 3D — Corpse + ambient scatter regression, authored-marker runtime walker ✅ shipped

- Corpse + ground-drop regression: existing `npcs.rs` / `inventory.rs` / `persistence.rs` test files (52 + 24 + 13 cases) cover the unchanged corpse → ground-container path. All pass post-3A/B/C/E. No new dedicated regression test — the contract is "no constructor changes broke the old paths," which the full sim suite catches.
- Ambient scatter (casings near recent fights): still deferred to Step 2.
- **`Sim::register_authored_container(kind_id, region, pos, is_public, faction, depth_tier, mode, seed)`** — new API resolves the kind grid from `LootContainerRegistry`, rolls eager initial contents via `roll_initial_container_contents` (same helper procedural scatter uses), stamps the `interaction_mode` onto the spawned `WorldContainer`. Caller-supplied `seed` lets each marker get deterministic-per-save contents from its `container_id` hash; `0` falls back to a `(tick, kind_id)` mix. Errors on unknown kind / zero grid / unknown region.
- **`SimHost.register_authored_container(...) #[func]`** — gdext bridge with the same parameter list (GString-flavored for cross-language). Host-only; clients refuse. Returns the new container id or `-1`.
- **`WorldContainer.interaction_mode: ContainerInteractionMode`** — new `#[serde(default)]` field (defaults to `Openable`). `Breakable` runtime semantics (HP / damage routing / destruction → ground pile) are still scaffold-only; the data flows through `register_authored_container` → snapshot, and a future "container destruction" system will consume it.
- **`godot/scripts/world/loot_container_spawner.gd`** — static walker. Each map scene calls `LootContainerSpawner.spawn_authored_containers(get_tree(), region_name, terrain_node)` from its `_on_terrain_ready` hook; the walker iterates the `loot_container_markers` group, Y-snaps to terrain when available, and dispatches each marker through the bridge. Wired into `real_map.gd` (hand-authored maps) alongside the existing test-crate spawn.

**Acceptance landed:** (a) full sim suite green — no regression in corpse / ground-drop paths after the schema additions. (b) `cargo test -p simn-sim --test authored_containers` (6 cases) verifies grid resolution from kind id, mode persistence onto the spawned component, deterministic-per-seed contents, and unknown-kind errors. (c) Markers placed in real-map scenes spawn `WorldContainer` entities at runtime (verified by the walker registering count > 0). `BREAKABLE` destruction runtime is intentionally **not** in this slice — the field carries through, the destruction system follows.

### 3E — UI integration (uses Phase 2 work) ✅ shipped

- `InventoryPanel.open_for_container(id)` opens the unified
  inventory + crafting panel with the world container's grid
  prepended to the right-side grid stack. The container's
  contents come from `SimHost.container_view(id)` and render
  via the same `_build_grid_widget` used for pockets +
  equipped-container grids — so Phase 2A right-click, 2B drag-
  and-drop, 2C tooltips, and 2D filter chips / search ALL apply
  to looting too. No separate panel.
- New grid-ref vocabulary: `"container:<id>"`. Drop dispatcher
  routes:
  - `container → pockets` via `take_from_container`
  - `pockets / equipped → container` via `put_in_container`
  - `container → equipped` / `container → doll` not supported
    by the bridge; user chains via pockets and the dispatcher
    logs a hint.
- `LootController` now routes `F` (the `interact` action) to
  `InventoryPanel.open_for_container` instead of the legacy
  standalone `LootPanel`. The old `LootPanel` scene still exists
  for now but no production code paths reach it — slated for
  removal in a follow-up once we've shaken any references out.
- Restock cadence note (per loot-and-economy §3.5) deferred —
  the periodic sweep landed in 3C but a "next restock in X
  days" line in the looting view isn't actionable without an
  authored cadence-per-faction TOML. Add when zones gain
  per-faction supply cadence data.

**Acceptance:** walk to a crate, press `F`, inventory panel
opens with the crate's grid at the top, drag items between
pockets and the crate, close → state persists via the snapshot
machinery.

**Phase 3 docs:** create `docs/book/src/mechanics/loot.md` with the player-facing contract (where loot comes from, why same crate → same contents, what "restock" means); link from `SUMMARY.md`. Graduate `loot-and-economy-plan.md` §3 portions to a walkthrough chapter on first content-pass landing.

---

## Phase 4 — Ballistics / Weapons Step 3

**Goal:** NPCs and players share the same projectile pipeline. Round variants (FMJ / HP / AP / tracer / overpressure) matter. Attachments are real items. Parts condition affects accuracy and reliability. Jams happen.

**Design source:** [`weapons-plan.md`](weapons-plan.md) (§3 attachments, §5 parts/jams, §6 material penetration), [`physical-combat-plan.md`](physical-combat-plan.md) (combat pipeline).

### 4A — NPC firing path → shared `Projectile` ECS ✓ v1 + v2 shipped

**Scope split.** The full migration (NPC projectiles ARE the
damage source, dice path retired) was too large for one cut. 4A
landed in two halves:

**v1 (shipped).** NPCs spawn visible cosmetic projectile
entities on every fire decision, but the existing `npc_combat`
dice damage path is unchanged — projectiles are tracers, the
dice still resolve hits. Acceptance for the "tracer rounds
visibly arc" line lands without touching combat balance.

- `Projectile` component gains
  `source_npc_id: Option<NpcId>` with `#[serde(default)]`. The
  player path sets `None`; NPC-fired projectiles set
  `Some(shooter)`.
- New `Sim::npc_fire_projectile(shooter_id, shooter_pos,
  shooter_region, target_pos, accuracy, round_id, rng)` mints
  a projectile and journals `ProjectileSpawned`. Accuracy
  100 → 0° jitter; accuracy 0 → ±5° jitter (10° cone). The
  `round_id` arg was added in 4B v1 (see below); 4A v1 in
  isolation hardcoded `round_5_45x39` intermediate-caliber.
  4B v2 will swap the faction-flavored mapping for the
  equipped magazine's variant.
- `npc_combat` writes a `PendingNpcShots` resource entry on
  every fire decision (whether hit-roll lands or not).
  `Sim::tick` drains the queue and spawns projectiles before
  `tick_projectiles` runs, so tracers get one tick of
  advancement on their spawn frame.
- `tick_projectiles` skips damage application when
  `source_npc_id.is_some()` — keeps NPC tracers cosmetic so
  the dice damage path isn't double-counted.
- Tests in `crates/simn-sim/tests/npc_projectiles.rs` (3
  cases): projectile carries the NPC source, accuracy
  controls yaw spread (rms_lo > 5× rms_hi), NPC projectiles
  don't damage offline targets.

**v2 (shipped).** Damage migrated onto the projectile-hit
branch; the dice path in `npc_combat` is retired. Attribution
(`LastDamager`, `RecentAttackers`, kill credits, blackboard
`UnderFireAt`) now writes from the projectile impact site, so
projectile + future melee + any future damage source land at
one seam. The player is added as a hit candidate so NPCs can
damage the player via projectiles — and player vs NPC fire
already used the same path, so the seam closes both directions.

- `tick_projectiles` no longer skips NPC-fired projectiles.
  The hit loop walks both NPC and player candidates in the
  shooter's region; first hit (`HitTarget::Npc` /
  `HitTarget::Player`) wins. Self-hit prevention checks
  `proj.source_npc_id == Some(npc_id)` for NPCs and
  `proj.source_steam_id` for players.
- `WorldDelta::ProjectileSpawned` gains `source_npc_id:
  Option<NpcId>`; `WorldDelta::ProjectileImpacted` gains
  `hit_player_steam_id: Option<u64>`. Both fields use
  `#[serde(default)]` so old snapshots load with
  `source_npc_id = None` (legacy = player-fired) and
  `hit_player_steam_id = None` (legacy hits were NPCs only).
- `npc_fire_projectile` aims from the *muzzle* (shooter Y +
  `muzzle_up_m`) to the target's *center mass* (target Y +
  1.2 m). Previously aim was muzzle-to-feet and grazed the
  bottom of the leg capsule. The center-mass offset puts the
  shot through the torso unless cone-of-fire jitter pushes
  it off.
- `npc_combat` is simplified to a pure fire-decision system:
  it gates on FOV / LOS / range / aggression and queues a
  `NpcShotIntent`. No more dice rolls, no more direct
  `apply_damage_to_npc_part` calls, no `LastDamager` /
  `RecentAttackers` / `blackboards` / `kill_credits`
  parameters on the system signature. Aggression now drives
  *fire cadence* (`fire_chance = 0.5 + 0.5 * aggression`)
  instead of hit chance — hit/miss is a geometric question
  resolved by the projectile tick.
- `Sim::apply_npc_attribution_for_hit(victim, attacker,
  attacker_pos, damage)` consolidates the attribution writes
  previously inlined in `npc_combat`. Called from the
  projectile-tick hit branch when `source_npc_id.is_some()`.
- `accuracy_hit_multiplier` is retained but no longer
  consumed — kept for the `accuracy_combat_endpoints` legacy
  unit test that documents the old curve shape.
- `Sim::force_npc_hp_for_test` floors *every* body part to
  `hp` (head, torso, all four limbs) so a single geometric
  hit on any part can kill in unit tests. Pre-v2 we only
  floored torso because all dice hits landed there.
- The bridge dicts in `simn-godot::sim::conversions`
  (`projectile_spawned_to_dict`,
  `projectile_impacted_to_dict`) expose `source_npc_id` and
  `hit_player_steam_id` so GDScript can drive tracer color,
  hit-shake direction (incoming vs outgoing), and decide
  whether the local player took the hit.

**Acceptance (v1):** NPCs spawn projectile entities visible to
the renderer; tracers arc through the air. Different caliber
NPCs still produce different audible Gunshot ranges via the
existing world-event-bus path. Damage continues working via
dice — no regression.

**Acceptance (v2):** NPC-vs-NPC kills come from projectile
impacts (no more wall-piercing dice damage). Attribution
(`LastDamager`, `RecentAttackers`, kill credits) records
correctly through the projectile seam — verified by the
existing `npcs.rs` combat tests. Player-vs-NPC and NPC-vs-player
both run through the same hit pipeline.

### 4B — Round variants in TOML + per-shot effects ✓ v1 + v2 shipped

**v1 (shipped) — faction-flavored NPC round selection.** Each
faction now fires a specific round id, propagated through
`npc_fire_projectile` and into the audible `Gunshot`
`caliber_class`. PWA / Linemen / Revere Guard fire 5.45×39;
Federal / Aegis fire 5.56×45; Attuned fire 7.62×39; bandits +
wanderers fire 9×18; Gulf Compact fires 9×19. Unknown factions
fall back to 5.45×39.

- `crate::default_npc_round_for_faction(&str) -> ItemId` —
  authored mapping. Phase 4B v2 will drive it from
  `factions.toml` so mods can add factions without Rust.
- `NpcShotIntent` carries `round_id: ItemId`; `npc_combat`
  reads `FactionRegistry` to resolve the shooter's faction name
  → round id, then passes through the bridge to
  `Sim::npc_fire_projectile`.
- `Gunshot { caliber_class }` now sources from the round's
  authored `ammo_config.caliber_class` (falls back to
  intermediate on missing data). Audible-radius bands per
  `world_event_bus::audible_radius_m` immediately diverge —
  bandit pistols carry ~180 m, PWA intermediates ~250 m,
  full-power rifles ~350 m.

Tests in `crates/simn-sim/tests/npc_projectiles.rs` (6 cases
total — 3 from 4A v1, 3 new for 4B v1): faction → round table
matches the authored mapping, every faction's authored round
resolves an `ammo_config`, pistol-caliber muzzle velocity is
clearly lower than rifle-caliber.

**v2 (shipped) — variant tag on every round, delta-borne to
the client.** The original v2 spec called for per-variant
*multipliers* (FMJ-baseline × HP/AP/Tracer/Overpressure
multiplier scales) layered on top of one base row per caliber.
That direction would have double-applied with the existing
TOML, which already authors each variant as its own row with
hand-tuned mass / velocity / damage / penetration (e.g.,
`round_9x18` vs `round_9x18_hp` vs `round_9x18_ap`). The
shipped v2 keeps the per-row tuning as the source of damage
truth and introduces a *variant family tag* for FX, AI, and
loot use:

- `AmmoConfig.variant: AmmoVariant` (re-exported as
  `simn_sim::AmmoVariant`). Values: `Fmj` (default), `Hp`, `Ap`,
  `Tracer`, `Overpressure`. `#[serde(default)]` so baseline FMJ
  rows can keep their TOML minimal — only non-FMJ entries
  declare `variant = "..."`.
- Tagged all ~32 authored non-FMJ rounds across the GAMMA
  roster (HP / JHP families, AP / BP / 7N## families,
  `45acp_p` overpressure, flechette shotgun, etc.).
- Added three tracer rounds: `round_5_45x39_t`,
  `round_556x45_tracer`, `round_762x54r_t46` (M196 / T-46
  flavored). NPC fire still uses the FMJ baseline per faction;
  tracers exist for player loadouts and future per-faction
  loadout tables.
- `WorldDelta::ProjectileSpawned` gains
  `variant: AmmoVariant` with `#[serde(default)]`. Resolved
  via `Sim::resolve_round_variant(round_id)` at fire time
  (both `fire_weapon` player path and `npc_fire_projectile`),
  so mirror clients and snapshot-load replay observers see
  the variant without an extra registry lookup.
- Bridge dict (`projectile_spawned_to_dict` in
  `simn-godot::sim::conversions`) emits a `variant: String`
  key (`"fmj"` / `"hp"` / `"ap"` / `"tracer"` /
  `"overpressure"`) so GDScript can drive tracer color,
  casing-eject SFX, and (future) impact-FX selection.

The Projectile component itself does **not** denormalize the
variant — `round_id` is on the entity and a registry lookup
in any consumer that needs it is cheap. Damage formulas are
unchanged; per-variant balance lives entirely in the TOML
row's damage / pen / mass / velocity numbers.

**Acceptance (v1):** observe NPCs across factions in-engine —
bandit gunfire is shorter-range audibly than PWA rifle fire;
NPCs spawn faction-appropriate tracer rounds.

**Acceptance (v2):** non-FMJ rounds resolve their variant tag
correctly through the projectile spawn delta; client + bridge
receive the variant string per shot; legacy snapshots load
with `variant = Fmj` via the serde default. Tracer rounds
exist in the registry for the three GAMMA-canonical tracer
calibers.

### 4C — Attachment slot-tag graph (data only first) ✓ shipped

Per `weapons-plan.md` §3: weapons declare a list of attachment
slots, each slot exposes one-or-more mount-surface tags;
attachments consume one tag and optionally provide new tags
downstream. A linear chain validator walks the chain in order
and rejects the first invalid step.

- `WeaponConfig.slots: Vec<WeaponSlot>` (each `WeaponSlot { id:
  SlotId, tags: Vec<String> }`). Defaults to empty for legacy
  weapons that haven't authored attachment data — empty slots =
  no attachments allowed.
- New `ItemCategory::Attachment` + `AttachmentConfig {
  consumes_tag, provides_tags: Vec<String>, effects: HashMap<String,
  f32> }` on the `ItemDef`. Phase 4C is data-only: `effects`
  values are authored (`recoil_control`, `barrel_wear_mult`,
  `sound_signature`, etc.) but not yet consumed by the sim.
  Phase 5 (the UI + integration slice) wires them through
  `EquippedWeaponState`.
- `validate_attachment_chain(registry, weapon_id, &[ItemId]) ->
  Result<Vec<String>, AttachmentError>` in `simn-sim::items`.
  Returns the residual tag pool on success (useful for "what
  can still be attached" UX). Errors: `UnknownItem`,
  `NotAnAttachment`, `NotAWeapon`, `NoMatchingSlot {
  attachment, needed_tag }`, `TagAlreadyConsumed {
  attachment, attached, tag }`.
- New `data/items/attachments.toml` with five canonical entries
  (`att_pso1_scope`, `att_ak_dovetail_picatinny`,
  `att_aimpoint_compm4`, `att_pbs1_suppressor`,
  `att_ultimak_rail`) exercising direct mounts, 2-stage
  adapters, parallel mounting routes, and muzzle devices.
- AKS-74 (`rifle_aks74` in `weapons.toml`) gains five native
  slot tags: `threaded_14x1_lh`, `dovetail_side`, `ak_handguard`,
  `warsaw_stock`, `ak_545_mag`. Other shipped weapons are
  unaffected (they have no `slots` array yet → no attachments
  allowed); authoring rolls out incrementally.
- Tests in `crates/simn-sim/tests/attachments.rs` (10 cases):
  slot-tag exposure, parse correctness, direct mount, 2-stage
  chain, missing-tag rejection, duplicate-consume rejection,
  parallel mounting route via Ultimak, unknown-item and
  not-a-weapon error paths, empty-chain residual pool.

**Acceptance:** unit tests attach a scope to an AKM via the
slot graph (both direct dovetail and dovetail→pic→red-dot
chains validate; missing-adapter rejects). UI integration
deferred to Step 4 (Phase 5). Stat effects deferred to
Phase 4D / 5 since they're entangled with the parts/condition
work.

### 4D — Parts condition + jams (basic) ✓ v1 shipped

Scope reduced from `weapons-plan.md` §5's per-part roster to a
single aggregate `condition` per weapon, with a linear jam-
probability curve gated below a threshold. v1 ships the
end-to-end pipeline (wear → curve → jam → clear-jam) so the
*economy* exists; the per-part breakdown (§5.1 — receiver /
barrel / bolt / extractor / spring_set / trigger_group /
gas_system) lands in a later iteration on top of this v1
scaffold.

- `EquippedWeaponState` gains `condition: f32` (0..100, default
  100 via a manual `Default` impl + `#[serde(default =
  "default_full_condition")]` for legacy snapshots) and
  `jam_state: JamState` (`Cleared` / `FailureToFeed` /
  `FailureToExtract` / `Stovepipe`). Catastrophic failure
  (`Receiver` zero) is deferred until per-part lands.
- `WeaponConfig` gains `wear_per_shot`, `jam_threshold`,
  `jam_chance_floor` with TOML-overridable defaults
  (0.05 / 70 / 0.18 — Kalashnikov-class reliability). Authored
  on the weapon row so modders rebalance per archetype without
  touching Rust.
- `jam_chance_at_condition(condition, &WeaponConfig)` returns
  the linear curve: 0 above `jam_threshold`, ramps to
  `jam_chance_floor` at `condition == 0`.
- `Sim::fire_weapon`: pre-check `jam_state.is_jammed()` →
  dry-click; roll jam against current condition → on jam,
  emit `WorldDelta::WeaponJammed { jam, condition }` + set
  state, no round expended. On a successful shot, decrement
  condition by `wear_per_shot` (floor at 0) + emit
  `WorldDelta::WeaponConditionChanged`. Jam-kind selection is
  condition-banded: <20 → FailureToExtract, <45 → Stovepipe,
  else FailureToFeed (heavier wear biases toward harder
  clears).
- New `Sim::clear_weapon_jam(steam_id, slot_id)` action
  resets the jam to `Cleared` and emits
  `WorldDelta::WeaponJamCleared`. Errors on un-jammed weapon
  (avoid silently consuming a clear-jam animation slot when
  the gun is fine). **Does not** repair condition.
- Persistence reapplies all three new deltas (`WeaponJammed`,
  `WeaponJamCleared`, `WeaponConditionChanged`) for mirror
  replay + journal load.
- Tests in `crates/simn-sim/tests/weapons_4d.rs` (6 cases):
  curve endpoints + midpoint, fresh-weapon wear journals
  delta, fresh weapon never jams over a full mag, clapped-out
  weapon jams within bounded tries, jammed weapon dry-clicks
  + clear-jam restores firability without wear repair,
  clear-jam errors on an un-jammed weapon.

Deferred to a future iteration on top of this v1:

- **Per-part roster + cannibalization economy** (§5.1, §5.5
  of weapons-plan.md). v1's single aggregate keeps the
  scoring simple; lifting to per-part is a data shape change
  (HashMap<PartId, Condition>) plus per-part wear curves.
- **NPC jam handling** (`weapons-plan.md` §5 reactor —
  switch to sidearm / flee per personality). NPCs share
  the projectile-spawn path but don't yet carry weapon
  condition; they fire jam-free in v1.
- **Stat degradation curves** (accuracy / muzzle-velocity
  drift with condition). Phase 5 wiring through
  `EquippedWeaponState`.
- **Attachment wear multipliers** (§5.6 → §3.4 stat
  aggregation). The data exists on every attachment
  (`barrel_wear_mult`, `gas_system_wear_mult`) but isn't
  consumed yet.

**Acceptance:** fresh AKS-74 fires a full magazine without
jamming; setting condition to 0 produces a jam within ~80
tries; jammed weapon dry-clicks until `clear_weapon_jam`
runs. UI integration (HUD condition meter, clear-jam input
binding) is Phase 5 work.

**Phase 4 docs:** update `weapons-plan.md` status — flip §3, §5, §6 to "delivered." Add `docs/book/src/mechanics/ballistics.md` with the player-facing contract (round variants, what jams feel like, how attachments work). Link from `SUMMARY.md`.

---

## Cross-cutting work (touches every phase)

- **Performance budget.** Every commit must hold the post-PR-152 baseline (sim + render ≥ 200 fps on test_map_1 with 540-NPC region population). The hook's test-pass gate covers correctness; performance is on the author. If a phase commit drops fps, flag it in the PR body — no silent regressions.
- **Determinism.** Any new tick-time system that consumes RNG or iterates a HashMap must be checked against `tests/determinism.rs`. Run that test in addition to the targeted suite before push.
- **Threading.** Worker thread can't call Godot APIs. If a new sim system needs LOS, perception, or any other engine-side query, it goes through the existing `GodotLosProvider` cache pattern (main-thread prefetch → worker reads). See `docs/TODO.md` "Main-thread LOS prefetch."
- **Mechanics docs.** Each phase ends with a player-facing `mechanics/*.md` chapter so the contract is recorded outside of architecture/walkthroughs.

---

## Out of scope

- Multiplayer / `simn-net` work. Deferred until the four phases here land. The threaded-sim architecture is shaped to make networking land cleanly later.
- New maps / asset content. Test maps and existing assets are the canvas.
- Story / quest / encounter dispatcher beyond what `world-event-bus-plan.md` already covers.
- LLM / author-time content pipeline.
