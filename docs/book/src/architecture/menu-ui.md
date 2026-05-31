# Menu / Shell UI

The "outside-the-Valley" interface - main menu, server browser,
settings. Built in native Godot using `Control` scenes and GDScript,
driven by a design system exported from `claude.ai/design` (see the
**Menu / Shell design system** entry in
[`CREDITS.md`](../../../CREDITS.md)).

The launcher has four primary capabilities: start a fresh solo run,
host a coop session (new or resumed from save), join a dedicated
session via the server browser, and change settings. **Characters
belong to individual servers and are picked after the session
connects** - there is no launcher-level character picker. The
in-game HUD, PDA, Document Trail reader, and per-server character
roster live in their own chapters when they land.

## Layer map

```
Screen (.tscn)              scripts/menus/*.gd       scripts/ui/*.gd
─────────────────            ──────────────────        ──────────────
mainMenu.tscn          →  main_menu.gd             ┐
soloRunsScreen.tscn  ┐                             │   MenuShell
                     │→  menus/runs_screen.gd      │   ├── ClassificationStrip
coopRunsScreen.tscn  ┘                             │   ├── body slot (this screen)
serverBrowser.tscn     →  menus/server_browser.gd  │   └── StatusBar
settingsMenu.tscn      →  menus/settings_menu.gd   │
                                                   │
                                 compound panels   │
                                 ──────────────   ┤   AdvisoryPanel
                                                   │   CRTPanel
                                                   │   GorgeBackdrop
                                                   │
                              atoms / helpers      │
                              ──────────────       ┤   NSWidgets.button(label, variant)
                                                   │   NSWidgets.badge / stamp / stencil /
                                                   │     label_mono / typewriter / eyebrow
                                                   │   NSColors (palette constants)
                                                   │   NSFonts (font preloads)
                                                   │   RunsStore (named-run index)
                                                   ┘
```

Every screen has the same shape:

1. The `.tscn` is a thin wrapper - a root `Control` with a script
   attached and nothing else.
2. The script instantiates a `MenuShell` in `_ready`. `MenuShell`
   owns the always-on classification strip at the top and the status
   bar at the bottom; its middle slot is filled by
   `shell.set_body(node)`.
3. The screen builds its own body tree in GDScript using the widget
   helpers in `scripts/ui/`.

This keeps scene files short and puts all the layout code where it
can be read and diffed as plain GDScript.

## Design tokens

All colors, fonts, spacing, and border rules live in three files:

- **`scripts/ui/ns_colors.gd`** - [`NSColors`](../../../../godot/scripts/ui/ns_colors.gd)
  exposes every palette entry from the design system's
  `colors_and_type.css` as a `Color` constant. The palette is three
  concentric layers - `BASALT_BLACK` / `WET_SLATE` / `MOSS_SHADOW` /
  `LICHEN` (Ground), `CARBON_PAPER` / `RUST` / `INK_BLACK` (Material),
  `VLF_PHOSPHOR` / `WARNING_RUST` / `PWA_SLATE` (Signal). Purple, teal,
  and neon blue are banned; the only cult-purple allowed is
  `FAC_ATTUNED`, used only on the faction sigil.
- **`scripts/ui/ns_fonts.gd`** - [`NSFonts`](../../../../godot/scripts/ui/ns_fonts.gd)
  exposes the four vendored font files via lazy static getters
  (`NSFonts.STENCIL`, `NSFonts.MONO`, etc.). `const preload(...)` was
  swapped for property-getter loads because the import cache can be
  empty when consts first resolve on a cold project open, cascading
  parse failures through every script that reads the constants. Oswald
  is shipped as a variable font; call `NSFonts.stencil(weight)` to get
  a `FontVariation` at a specific weight (600 = SemiBold, 700 = Bold).
- **`resources/theme/noosphere_theme.tres`** - the global `Theme`,
  applied at runtime by `GameSession._ready` (`get_tree().root.theme = …`)
  *after* the sim has started. Wiring it as `gui/theme/custom` in
  `project.godot` race-loads the theme before font imports finish on a
  cold project open, which cascades into the same NSFonts parse
  failures noted above. Sets JetBrains Mono as the default font, dark
  LineEdit / Button / Panel styles, and zero corner radii across the
  board.

When you need a styled component, prefer `NSWidgets.button(...)` over
applying theme overrides by hand - the variant switch (`PRIMARY` /
`SECONDARY` / `GHOST` / `DANGER`) already sets the right
stylebox/border/fg/bg combination.

## Chrome

Three scripts, all in `scripts/ui/`:

- **`ClassificationStrip`** - `PanelContainer` with a centered
  `UNCLASSIFIED // FOR WANDERER USE // …` label. 10px JetBrains Mono
  Bold in `FG_3`, hairline rules top and bottom.
- **`StatusBar`** - bottom strip. Pulls the build version from
  `ProjectSettings.get_setting("application/config/version")` and
  ticks the local-time label once a second via a `Timer`. Frequency
  and squall countdown are cosmetic for now.
- **`MenuShell`** - glues the two strips around a `MarginContainer`
  body slot. Every top-level menu instantiates this in `_ready` and
  fills the slot.

Background:

- **`GorgeBackdrop`** - full-bleed `TextureRect` that renders the
  distant-basalt SVG at `assets/backdrops/gorge.svg`. Mouse-transparent.
  Only the main menu uses it; sub-screens stay on the flat basalt-black
  background so the data is the foreground.

## Compound panels

The three non-trivial panels are exported as `class_name`-d scripts.
You can drop them into a scene tree and set their `@export`
properties directly.

- **`AdvisoryPanel`** - wet-slate card with an eyebrow label +
  timestamp header, body paragraph, and a trailing row of badges.
  Used for the PWA Western Line advisory on the main menu.
- **`CRTPanel`** - phosphor-green body text on a dark slate well
  with a thin scanline shader, subtle inner shadow. Used for the
  broadcast block on the main menu and the MOTD on the server
  browser detail pane.

## In-game surfaces

CanvasLayers live as children of `session_root.tscn` and coexist by
`layer` priority:

| layer | surface | toggle | note |
|---|---|---|---|
| 100 | `DebugOverlay` | `` ` `` | Dev readout. Shows on every screen. |
| 95  | `ConnectingOverlay` | instanced | Reusable async-op modal. Not auto-wired yet. |
| 80  | `GameMenu` | ESC (in-game) | System shell. Not a pause; the sim stays live. |
| 50  | `PDA` | `P` (in-game) or via game menu | Five stub pages under a tab rail. |
| 40  | `InventoryPanel` | `I` (in-game) | Paper doll + 2D grid + crafting, two tabs. |
| 12  | `HotbarHUD` | always-on when `in_game()` | 4 belt slots bound to keys 1-4. |
| 10  | `HUD` | always-on when `in_game()` | Five labeled empty slots. |
| 0   | world / launcher | - | Gameplay + shell screens. |

- **`HUD`** (`scenes/hud.tscn`, `scripts/hud.gd`) - five slots in the
  corners + bottom-center, each a panel with a placeholder caption
  (`[ COMPASS ]`, `[ HP · STAM · STRESS ]`, etc). Real widget scripts
  will replace each slot's label once the sim exposes the underlying
  values. Polls `GameSession.in_game()` 4× per second to gate
  visibility - no HUD on the launcher.
- **`HotbarHUD`** (`scenes/hud_hotbar.tscn`,
  `scripts/menus/hotbar_hud.gd`) - bottom-center belt row. Driven by
  `SimHost.equipment_slot_catalog()` - any slot flagged
  `is_hotbar = true` shows up, sorted by `hotbar_index`. Each widget
  shows key hint + item name + count; number keys 1..N trigger
  `consume_hotbar(idx)`. Poll-refreshed on `SimHost.view_updated`
  (Phase 2G; 4 Hz).
- **`InventoryPanel`** (`scenes/menus/inventory.tscn`,
  `scripts/menus/inventory_panel.gd`) - two-tab panel. **Inventory
  tab**: STALKER-style 8×7 paper-doll widget on the left (slots laid
  out via `equipment_slot_catalog().position` + `.size` for the
  cell footprint, dark steel cells with a faded category watermark
  per Phase 2C, slot-name chip top-left, count badge bottom-right
  on full slots) + 2D grid renderer on the right showing pockets
  and each equipped container's `inner_grid`. Native Godot
  drag-and-drop (Phase 2B): drag any card to another grid cell, an
  empty doll slot, or the doll itself; targeting + accept-check
  lives in `scripts/menus/inventory_drop_target.gd`'s
  `_get_drag_data` / `_can_drop_data` / `_drop_data` overrides.
  Right-click any card or slot (Phase 2A) for a context menu (Use /
  Equip / Drop / Unequip / Examine, depending on item category and
  source grid). Phase 2C hover tooltips show name, category,
  per-unit + total stack weight, stack max, and magazine load
  state; resolved against `SimHost.item_catalog()` cached on panel
  open and threaded through each card's `item_catalog` export.
  Phase 2D filter toolbar above the grids — chips for
  `ALL / WPN / AMMO / MED / FOOD / ARMOR / PARTS` plus a free-text
  search box on the right; non-matching cards dim to ~28 % alpha
  while keeping their grid positions (highlight, not re-layout).
  The toolbar lives outside `_grids_column` so the search
  LineEdit survives per-tick rebuilds and never loses focus
  mid-typing.
  **Crafting tab**: specialty filter chips, "CRAFTABLE NOW"
  toggle, recipe list (rows green when ready, red when blocked,
  with a `can_craft`-driven "Requires:" line), per-recipe detail
  panel, `queue × N` spinner. A live queue strip shows in-flight
  jobs with progress bars + Cancel. Refresh is driven by
  `SimHost.view_updated` (Phase 2G; 4 Hz). `I` toggles; ESC
  closes.
  **Looting (Phase 3E)** — when the player presses `F` near a
  `WorldContainer`, `LootController` calls
  `InventoryPanel.open_for_container(id)`. The panel opens with
  the container's grid prepended to the right-side stack
  (grid-ref `"container:<id>"`); drag, right-click, tooltips, and
  the filter toolbar all apply. Drop dispatcher routes
  container ↔ pockets via the `take_from_container` /
  `put_in_container` bridge methods; container ↔ equipped is a
  two-step (chain via pockets). The legacy standalone `LootPanel`
  is no longer in the loop.
- **`PDA`** (`scenes/menus/pda.tscn`, `scripts/menus/pda.gd`) - a
  diegetic "surplus PDA, Model 7" chassis with a tab rail (Map /
  Dossiers / Chronicle / Radio Log / Settings) and stub pages. `P`
  opens it while in-game; ESC closes. The game menu also has an
  Open PDA action as a fallback.
- **`ConnectingOverlay`** (`scripts/ui/connecting_overlay.gd`) -
  phosphor modal with a heading, body, animated dot ticker, and an
  optional cancel button. `show_failure(message)` flips it to a
  terminal error state (rust border, static red body). Not currently
  wired - it needs `GameSession.solo()` / `.host()` / `.join()` to
  gate the scene swap on lobby_ready / sim_ready before it has
  anything to cover.

## Reusable layout components

Three shared components deduplicate patterns that appear on every
sub-screen. Prefer these over inlining the pattern:

- **`ScreenHeader`** (`scripts/ui/screen_header.gd`) - the eyebrow +
  stencil-title + Back-button strip. Set `eyebrow_text`, `title_text`,
  connect `back_pressed`, add to the top of your body. Used by
  runs / server browser / settings.
- **`TabColumn`** (`scripts/ui/tab_column.gd`) - 220-px left rail of
  tab buttons with the phosphor left-edge accent on the active tab.
  Set `tabs: PackedStringArray`, `initial_tab`, connect `tab_selected`.
  Owns its own selection state; the caller just re-renders its
  content slot on the signal. Used by settings today; any tabbed
  screen (mod manager, character creation categories) should reuse it.
- **`NSWidgets.form_row(label, hint, control)`** - the settings-row
  pattern (fixed-width label column + optional hint + control that
  fills, with a bottom hairline). Factory, not a class - takes the
  control by reference and wraps.

If you find yourself copying more than a dozen lines from one screen
to another, stop and extract. The shell is small; duplication is
cheap to spot and expensive to drift.

## Named runs

Players create as many named saves ("runs") as they want per mode -
solo or coop. The shell keeps a lightweight metadata index at
`user://runs.json` managed by
[`RunsStore`](../../../../godot/scripts/ui/runs_store.gd). Each run
entry carries an id, display name, mode, timestamps, and an integer
play-time counter.

- The main menu's `SOLO` and `HOST COOP` items route to
  `soloRunsScreen.tscn` / `coopRunsScreen.tscn`. Both scenes
  instantiate the same script
  [`runs_screen.gd`](../../../../godot/scripts/menus/runs_screen.gd);
  the `.tscn` differ only in their `mode` `@export` value.
- The runs screen shows the filtered roster, an inline **+ New Run**
  action that prompts for a name, and per-row **Load** / **Delete**
  actions. `Load` calls `GameSession.solo()` or `.host()`.
- `RunsStore` rejects duplicate names within a mode and sorts runs
  newest-first by `last_played_unix`.

> **Sim-side gap.** The sim currently owns a single persistent save
> state (see `scripts/game_session.gd`). Until `simn-sim` grows per-run
> isolation, loading different named runs reuses the same underlying
> save on disk - the run names are metadata only. The UI, store, and
> selection flow are ready to bind to real per-run persistence; the
> follow-up is to make each run id key its own sim snapshot/journal
> directory.

## Adding a new screen

1. Create `godot/scenes/menus/myScreen.tscn` - a root `Control`
   anchored full-rect with your script attached. That's all the
   scene file should contain.
2. Create `godot/scripts/menus/my_screen.gd`:

   ```gdscript
   extends Control
   const PATH_MAIN_MENU := "res://scenes/menus/mainMenu.tscn"

   func _ready() -> void:
       set_anchors_preset(Control.PRESET_FULL_RECT)
       var shell := MenuShell.new()
       add_child(shell)
       shell.set_body(_build_body())

   func _build_body() -> Control:
       var v := VBoxContainer.new()
       v.add_child(NSWidgets.stencil("MY SCREEN", 36))
       # ...
       var back := NSWidgets.button("← Back", NSWidgets.Variant.GHOST)
       back.pressed.connect(func() -> void:
           get_tree().change_scene_to_file(PATH_MAIN_MENU))
       v.add_child(back)
       return v
   ```

3. Add a ledger entry in `main_menu.gd` that calls
   `get_tree().change_scene_to_file("res://scenes/menus/myScreen.tscn")`
   from `_on_ledger_pressed`.

## Dev surfaces

Two developer-facing overlays, both toggled with `` ` `` (the
`toggle_debug` input action registered in `project.godot`):

- **In-game debug readout** -
  [`scenes/debug_overlay.tscn`](../../../../godot/scenes/debug_overlay.tscn)
  is a CanvasLayer child of the `GameSession` autoload scene, so it
  persists across every in-game scene change. Shows FPS, sim tick,
  in-world time + moon phase, weather, chronicle summary, region
  control / tension, population density tier, and local player
  position. Styled as a diegetic CRT readout - dark slate well,
  phosphor-green JetBrains Mono, 1px `VLF_PHOSPHOR_DIM` border - to
  match the launcher's CRT panel vocabulary. Toggle with `` ` ``;
  extra in-game keys (Tab / M / F / F2 / F9–F12 / G / H / I / B / T
  / 1–4 hotbar consume / Ctrl+S / Ctrl+Shift+R)
  are documented in the overlay's own footer line.

- **Launcher dev panel** -
  [`scenes/menus/devOverlay.tscn`](../../../../godot/scenes/menus/devOverlay.tscn)
  is a modal CanvasLayer instanced on-demand by `main_menu.gd`. Exposes
  the raw Steam lobby actions (resume solo / host lobby / join by id /
  wipe world) behind a "DEV // PRIVILEGED" classification strip. The
  redesigned main menu routes solo and coop through the named-runs
  screens - this overlay is the shortcut for smoke-testing a lobby
  without touching the roster UI. Toggle with `` ` `` on the main
  menu; close with `` ` ``, ESC, the scrim, or the explicit Close
  button.

- **In-game overlay ("game menu")** -
  [`scenes/menus/gameMenu.tscn`](../../../../godot/scenes/menus/gameMenu.tscn)
  is a CanvasLayer child of `session_root.tscn`, so it persists across
  map changes. ESC opens it while in a live session; ESC closes it.
  The Valley keeps running behind the scrim - this is **not a pause
  menu**, it's a system shell for housekeeping. Actions: Resume,
  Save Now (calls `GameSession.force_save`), Disconnect to main menu
  (calls `GameSession.leave_session_to_menu`), Quit to desktop.
  Owns mouse-capture state in-game: opens → release cursor, closes →
  re-capture. `GameSession.in_game()` gates the toggle so ESC on the
  launcher falls through to the launcher's own handlers.

  **Known gap (network side):** `leave_session_to_menu` force-saves
  and returns to the main menu, but does not tear down the Steam
  lobby - `simn-net` needs a `leave_session` entrypoint. Quitting to
  desktop is the reliable way to drop a lobby today.

## Session preservation across screens

The `GameSession` singleton (registered as an autoload in
`project.godot`) persists across `change_scene_to_file` calls, so any
Steam lobby state survives navigation between the shell screens.
`main_menu.gd` connects to `GameSession.lobby_id_changed` to echo the
lobby ID back to the status label when hosting. Other screens call
`GameSession.solo()` / `.host()` / `.join(id)` directly.

## Out of scope (follow-ups)

- **Per-run sim save isolation.** `RunsStore` maintains the named-run
  index; the sim still uses a single save directory. Plumb the run id
  through `GameSession.solo()` / `.host()` into `simn-sim`'s
  snapshot/journal paths so each run is truly independent. See the
  gap note in the Named runs section above.
- **In-game HUD and PDA.** Separate design iteration; no prototypes
  exported yet.
- **Document Trail reader.** The in-fiction found-documents reader is
  a later kit, scoped out here; it will live inside the in-game
  surfaces rather than the launcher.
- **Per-server character roster / picker.** Characters are scoped to
  individual servers, so the pick-a-wanderer UI lives after a
  session connects, not on the launcher.
- **Pause menu and debug menu.** Still `Node2D` stubs at
  `godot/scenes/menus/pauseMenu.tscn` and `.../debugMenu.tscn`. They
  get their own rebuild when gameplay is in a state to need them.
- **Broadcast-shadow glitch.** The design calls for diegetic text
  corruption modulated by the player's position in the world; this
  requires sim integration and is not shell-only work.
- **Licensed logo / faction sigils.** The wordmark, roundel, and
  faction SVGs under `assets/logos/` and `assets/icons/` are
  first-principles placeholders. Replace when final art lands.
