# Runs & Saves

A "run" is a named save slot the player creates from the shell. Each
run has its own isolated world state - player positions, NPC
populations, weather, inventory, wounds - and survives between
launches. Runs come in two flavors:

- **Solo** - single-player. No Steam, no network, synthetic
  `SOLO_STEAM_ID` for sim lookups.
- **Coop-host** - the host plays with friends. The host's run is
  the canonical world; joiners run mirror sims that consume host
  state. Joiners don't create their own runs (and don't save
  locally).

## On-disk layout

```
user://
├─ runs.json                 # RunsStore metadata index
└─ saves/
   ├─ alpha-1747203600/      # one dir per run, keyed by run id
   │  ├─ world.save          # snapshot (bincode + blake3)
   │  └─ world.journal       # append-only delta log
   ├─ coop-test-1747203700/
   │  ├─ world.save
   │  └─ world.journal
   └─ ...
```

Run IDs are slug-stamped with creation time
(e.g. `alpha-1747203600`) so collisions are impossible even with
the same display name. The index in `runs.json` holds the
human-readable name, mode (`solo` / `coop`), created / last-played
timestamps, and play time.

## Creating / resuming / deleting

All of this lives in the main menu shell:

- **Solo or Host Coop → choose a run**. The runs screen lists every
  existing run of that mode sorted by last-played. Click **Load**
  on an existing row or **Create new run** at the top.
- **Continue** (main menu quick-action) picks the most-recently-played
  run across all modes and resumes it.
- **Delete a run**. The runs screen row has a delete button that
  asks for confirmation, then removes both the `runs.json` entry
  AND the save directory. No orphans.

## Coop-host flow

```
Main menu → Host Coop → CoopTest run → Load
                                        ↓
                        GameSession.host("cooptest-1747...")
                                        ↓
                    SimHost.start("user://saves/cooptest-1747.../")
                                        ↓
                        NetworkManager.host_session()
                                        ↓
                       Steam lobby ready → invite overlay
                                        ↓
                  Friend joins → GameSession spawns their player
                                        ↓
                 JoinRequest from friend → snapshot send → play
```

The host's sim journals every mutation, keeps snapshots every 600
ticks (~30s), and the run directory accumulates normally. If the
host quits mid-session, the save captures the state at that moment;
reloading resumes cleanly. If the *client* quits, the host keeps
playing and the client rejoins with a fresh snapshot (no local
state was persisted).

## Joiner flow

```
Main menu → Server Browser → Join by Lobby ID → lobby_id
                                        ↓
                      GameSession.join(lobby_id)
                                        ↓
                     SimHost.start_mirror()  (no save dir!)
                                        ↓
                       NetworkManager.join_session(...)
                                        ↓
                  lobby ready → send JoinRequest → wait for snapshot
                                        ↓
              snapshot applied → enter region → gameplay
```

Joiners call `start_mirror` which builds a mirror sim without any
disk persistence. The `runs.json` index is untouched. There's
nothing to resume.

## Save format + version

- `world.save` - magic `b"NSPHSAVE"`, `FORMAT_VERSION` u32, tick u64,
  bincoded `SnapshotBody`, blake3 hash.
- `world.journal` - magic `b"NSPHJRNL"`, snapshot-tick u64, then a
  length-prefixed + crc32 record per `WorldDelta`.

When `FORMAT_VERSION` bumps (typically with each plan step that adds
fields), existing saves hard-error on load. The runs UI surfaces
the error and offers to wipe the run. Mid-dev this is frequent;
post-v1 we'll add a migration path.

## Debug helpers

- **`Ctrl+S`** - force-save now. Runs `SimHost.shutdown()` +
  `SimHost.start()` to roll a fresh snapshot and rotate the journal.
  Host/solo only - mirror clients no-op.
- **`Ctrl+Shift+R`** - wipe the current run. Removes the save files
  on disk and reinitializes the sim at tick 0. Useful for
  world-seed iteration without touching `runs.json` metadata.

## What's deferred

- **Per-run character rosters.** `character_picker.gd` is scaffolded
  but empty. Multi-character-per-run lands with the inventory UI in
  Step 5 of the survival/crafting plan.
- **Coop client resume.** If a client disconnects and rejoins
  mid-session, they get a full resync (not their state from when
  they left). Mid-session client-state persistence is a later
  polish.
- **Run export / import.** No way to share saves across machines.
  Post-v1 if there's demand.
