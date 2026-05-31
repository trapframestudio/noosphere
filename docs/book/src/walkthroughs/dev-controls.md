# Dev controls

Hotkeys, debug surfaces, and QOL features available in the editor and
in standalone runs. Updated when controls change.

## Movement

| Key            | Action                                            |
|----------------|---------------------------------------------------|
| WASD           | Walk (walk mode) / fly (noclip)                   |
| Mouse          | Look                                              |
| Shift          | Sprint (walk) / fast fly (noclip, ~250 m/s)       |
| Space          | Jump (walk) / up (noclip)                         |
| Ctrl           | Down (noclip)                                     |
| `\` (backslash)| Toggle noclip mode                                |
| Esc            | Open in-game shell (game menu) - releases mouse   |
| LMB            | Capture mouse (when uncaptured)                   |

Mouse-capture state while in-game is owned by the game menu: opening
it releases the cursor, closing it re-captures. The old
"Esc toggles mouse" shortcut was removed when the shell took over.

Walk speed is 5 m/s, sprint 10 m/s. Noclip fly is 50 m/s normal,
250 m/s with Shift - tuned for the 5km test maps. To traverse the
full 5km on foot is ~17 minutes sprinting; in noclip it's 20 seconds.

## Dev surfaces

| Key            | Action                                            |
|----------------|---------------------------------------------------|
| Esc            | Open/close in-game shell (game menu, in-game)     |
| P              | Open/close PDA overlay (in-game)                  |
| `` ` `` / `~`  | Toggle debug overlay (anywhere); also summons the launcher dev panel on the main menu |
| Tab            | Toggle per-NPC state labels (Label3D above pills) |
| F9             | Toggle NPC behavior logging (stdout/console)      |
| Ctrl + Shift + R | Wipe saves + re-enter region (in-game reseed)   |
| Ctrl + S       | Force a sim snapshot now (no quit)                |
| F12            | Screenshot to `user://screenshots/`               |
| B              | Apply bandage to torso (Step 2 dev binding)       |
| T              | Apply tourniquet to torso (Step 2 dev binding)    |
| 1 / 2 / 3 / 4  | Hotbar consume - belt slots 1..4 (PR-3)           |
| G              | Toggle the Debug Spawn panel - categorized item picker, search + per-row +1 / +10 / +stack quick-grant; reads the full `items.toml` catalog |
| H              | Consume slot 0, body_part=torso (Step 4)          |
| F              | Interact - open the looting panel when near a WorldContainer (PR-4c) |
| F3             | Toggle "near campfire" flag (debug; moved from F in PR-4c) |
| F2             | Cycle near-workbench tier (Step 5 Slice A)        |
| I              | Toggle inventory + crafting panel (Step 5)        |
| R              | Rotate held item inside inventory panel (PR-3)    |
| X              | Drop held item to the ground (inventory panel; pockets only - unequip equipped-container contents first) |
| P              | Toggle PDA                                        |

The debug overlay (top-left, styled as a CRT readout) shows: FPS, sim
tick, in-world clock as `Day N, HH:MM`, current region + primary
faction + tension, the local player's world position, and the triage
block when applicable - a `vitals:` line with pain/rad/tox, a
`wounds:` section listing each active wound's body part / severity /
treatment / bleed rate / infected flag, an `effects:` section listing
active drugs / statuses with remaining duration, and a `tolerance:`
line summarising per-drug tolerance counters. Below that, the
`inventory:` section lists every slot with index / name / count /
category, plus total weight and the campfire context flag (toggled
with `F`). It lives on `session_root` so it persists across every
scene - including the launcher, not only in-game.

The in-game overlay stack (by CanvasLayer priority, high covers low):
debug readout (100) → launcher dev panel (95, main-menu only) →
`ConnectingOverlay` (95, instanced on demand, not auto-wired yet) →
game menu (80) → PDA (50) → HUD (10). See
`../architecture/menu-ui.md` for the per-surface breakdown.

## Modes

The redesigned launcher has four primary capabilities plus Quit:

- **SOLO** - opens `soloRunsScreen.tscn`. Pick an existing named solo
  run to load, or create a new one. Load routes to
  `GameSession.solo(run_id)` - no Steam, no peers, synthetic Steam ID
  `0xDEADBEEF` so the sim's player-keyed lookups still work. The
  run's save data lives in its own dir at `user://saves/<run_id>/`.
- **HOST COOP** - opens `coopRunsScreen.tscn` (same shape, coop-scoped).
  Load routes to `GameSession.host(run_id)` - creates a Steam lobby,
  emits `lobby_id_changed`, copies the lobby ID to clipboard. The
  host's world state persists to `user://saves/<run_id>/`.
- **SERVER BROWSER** - mock list for now; the real "Join by Lobby ID"
  input lives at the bottom of that screen and routes to
  `GameSession.join(lobby_id)`. Joiners run a **mirror sim** with no
  local save - they consume the host's snapshot + per-tick deltas.
- **SETTINGS** - tabbed shell (Audio / Video / Radio / Input /
  Accessibility / Server Rules). All tabs have interactive controls
  backed by `SettingsStore` (`user://settings.json`). Video's window
  mode / vsync / UI scale are applied via `DisplayServer` /
  `Window.content_scale_factor` on change *and* at startup.

The raw dev actions - Resume Solo / Host Lobby / Join by Lobby ID /
Wipe World - moved to the **launcher dev panel**: press `` ` `` on
the main menu to summon it. This is the fast path for smoke-testing
lobbies without going through the named-runs shell.

Per-run save isolation is wired end-to-end as of sim/net slice 1:
each named run owns its own save directory, and deleting a run from
the runs screen removes both the metadata entry and the on-disk
save. `Ctrl+Shift+R` (Wipe World) now scopes to the *active* run's
save - mirror clients no-op. See
[Runs & saves](runs-and-saves.md) for the full flow.

## World scale

The test maps are 5km × 5km flat planes (so 2.5km from spawn to any
cardinal edge). All scale references are engine-native nodes spawned
procedurally by `scripts/test_map.gd`, shared by both maps:

- **Compass** - four short white posts at the spawn point labeled
  N / E / S / W.
- **Inner ruler** - 100m-tall white posts every 100m along all four
  cardinal axes out to 500m. Near-field scale.
- **Outer ruler** - 25m-tall colored posts every 500m along all four
  axes out to 2.5km. The marker color differs per map so it doubles
  as a "which map am I on" cue.
- **Mountain ring** - ~220 procedurally-placed cone meshes around the
  perimeter, ~200m past the floor edge. Heights 120–380m. Temporary
  visual containment until real terrain lands.
- **Base markers** - one per faction-owned base in the current region,
  spawned by `GameSession` from `SimHost.bases_in_region(name)`. Mesh
  shape encodes `BaseKind` (Checkpoint = box, Outpost = cylinder,
  Safehouse = sphere, Headquarters = capsule, ResearchPost = prism);
  color encodes the owning `Faction` via the shared palette in
  `scripts/faction_colors.gd`. A floating Label3D shows
  `kind\nfaction` so the world reads without a HUD yet.
- **NPC pills** - one per live NPC within 400m of the local player
  in the current region. Smaller capsules tinted by faction, sharing
  one material per faction for batching. Distance-culled visually
  (sim still ticks them server-side); pill sync runs at the sim's
  20Hz rather than the renderer's 60Hz. Walk between bases under
  the sim's goal FSM. The debug overlay's `chronicle: ever=N
  alive=N` line tracks total population history; `ever` keeps
  growing as old NPCs die and new ones spawn to replace them. Tab
  toggles per-NPC state labels (off by default - Label3D billboards
  are a fill-rate cost at spawn density).

## NPC behavior logging

When enabled (F9 in-game, or `Sim::set_behavior_log(true)` from Rust),
NPC systems accumulate counters and flush a single summary line every
`BehaviorLog::FLUSH_INTERVAL` (100 ticks ≈ 5s at the sim's fixed 20Hz)
under target `npc.behavior`:

```
tick=T spawns=N(fac:n,…) deaths=N(cause:n,…) migrations=N aggro=N objectives=[kind:n,…]
```

Off by default. Use `RUST_LOG="npc.behavior=info"` to scope console
output to just these events.

## Headless watcher

`cargo run --example watch -p simn-sim` ticks a fresh sim (temp save
dir) at 20Hz and streams the behavior log to stdout without Godot.
Useful for observing emergent behavior without renderer overhead.

Env vars: `NSPH_WATCH_SECONDS` (default 30), `NSPH_WATCH_SUMMARY_TICKS`
(default 100), `RUST_LOG` (default `npc.behavior=info,simn_sim=warn`).

## Save files

Saves live under `OS.get_user_data_dir() + "/saves/"`:

- Linux: `~/.local/share/godot/app_userdata/Noosphere/saves/`
- Windows: `%APPDATA%\Godot\app_userdata\Noosphere\saves\`

Two files: `world.save` (snapshot, atomic-rename writes) and
`world.journal` (append-only delta log). When the format version
bumps, old saves load with a hard error - delete the contents of the
saves dir to start fresh. See `../getting-started/configuration.md` for
the current format version.
