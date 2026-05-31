# SIMN as a vendored addon

The game doesn't build the engine in-tree. The five `simn-*` crates live in
the public SIMN repo (`github.com/trapframestudio/simn`), and we vendor them
into the game as a Godot addon. This keeps SIMN the single source of truth for
the engine while the game stays focused on its Godot project, its content, and
its docs.

## How it fits together

```
noosphere/
  scripts/
    sync-simn.sh        # clones SIMN @ pin, vendors crates/ + content/
    SIMN_VERSION        # the pinned SIMN commit (bump to update)
  Cargo.toml            # workspace; members -> godot/addons/simn/crates/*
  godot/
    simn.gdextension    # committed; loads target/debug/libsimn_godot.so
    addons/simn/         # GITIGNORED, produced by sync-simn.sh
      crates/simn-*/      #   the engine source (read-only)
      content/            #   SIMN's generic example pack
    content/             # YOUR game content overlay (committed)
```

The root `Cargo.toml` lists the vendored crates as workspace members, so
`cargo build`, `cargo test`, and clippy run from the repo root exactly as
before, and the build output lands in repo-root `target/`. The committed
`godot/simn.gdextension` points there. A fresh clone has no engine source until
you run the sync, so:

```bash
./scripts/sync-simn.sh        # vendor + build the bridge
cargo build --workspace
```

## Why vendored instead of in-tree

- **One source of truth.** Engine code lives in one place (SIMN). No drift
  between a game copy and the library.
- **Pinned, not floating.** `scripts/SIMN_VERSION` holds a specific SIMN
  commit. You only move when you deliberately bump it, so engine changes never
  land under you unreviewed.
- **The game owns its content.** `godot/content/` is the game's content set,
  loaded as a `ContentSource::Overlay`. Sync only ever touches
  `godot/addons/simn/` - it physically cannot overwrite your config.

## Two sync modes

`sync-simn.sh` has two modes, for two kinds of person:

- **Copy mode (default):** `./scripts/sync-simn.sh` clones SIMN at the pin and
  drops a frozen snapshot into `godot/addons/simn/`. Reproducible, needs no
  SIMN clone. This is what contributors who don't touch the engine, CI, and
  release builds use.
- **Link mode:** `./scripts/sync-simn.sh --link /path/to/simn` symlinks
  `godot/addons/simn/{crates,content}` at a local SIMN working clone. The game
  then builds your live engine edits with no copy step. This is the engine-dev
  setup. The symlinks are local and gitignored, so they affect only your
  machine. Re-run plain `./scripts/sync-simn.sh` to drop back to the pinned
  snapshot (removing the symlinks never touches your clone).

## Day-to-day (active engine + game dev)

The sim changes a lot, so the default dev setup is link mode against a SIMN
working clone. There are three loops:

**1. Inner loop (constant).** Edit the sim in your SIMN clone; build and run
the game; iterate. No sync, no pin bump, no push. The game compiles the clone's
code directly through the symlink.

```bash
# one-time, after cloning both repos:
./scripts/sync-simn.sh --link /path/to/simn
# then forever:
#   edit /path/to/simn/crates/...   ->   cargo build / run the game
```

**2. Publish loop (when a change is solid).** In the SIMN clone: `cargo test
-p simn-sim` (+ clippy/fmt by hand - the SIMN repo has no commit gate yet),
then commit and push to the public repo. The engine keeps its own history and
cadence.

**3. Adopt loop (record what the game runs on).** Bump the pin to the engine
commit the game now depends on, and commit that in the game:

```bash
echo <new-sha> > scripts/SIMN_VERSION
git add scripts/SIMN_VERSION   # commit alongside whatever needed the new engine
```

Bump the pin **every time you adopt an engine change the game relies on**, so
`main` always pins a real, pushed engine commit. Then anyone on copy mode
(`./scripts/sync-simn.sh`) gets exactly what you built against, and the game's
pre-push gate (`cargo test -p simn-sim`) tests that engine. Don't let the pin
drift behind what `main` actually needs.

## Content overlay and sync safety

Your `godot/content/` overlay is the full game content set (factions, names,
chatter, items, loot, crafting, combat, POI/activity, world). At runtime the
overlay wins per-file; anything you haven't authored falls back to SIMN's
embedded example pack. Because `sync-simn.sh` only writes inside
`godot/addons/simn/`, pulling SIMN updates never clobbers your content. See
[content packs](../architecture/crate-guide.md) and `godot/content/NOTICE.md`.

## Consuming SIMN in another project

SIMN ships addon scaffolding (`godot-addon/` in the SIMN repo: a generic
`simn.gdextension.template` + a README). Any Godot project can vendor SIMN the
same way: sync `crates/` + `content/` into `addons/simn/`, list the crates as
workspace members, and point a `.gdextension` at the built library.
