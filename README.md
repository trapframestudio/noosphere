# Noosphere

An openly-developed co-op survival game built in Godot 4 and Rust, made by **trapframe**.
Original world, original systems, native cooperative play from day one. Heavy on
simulation, heavier on consequence.

The **code is open source** (MIT or Apache 2.0): build on the engine, the simulation, and
the tooling all you like, commercial or not. The **game itself**, its world, art, story,
and the Noosphere name, is original IP, and the finished game is sold on Steam to fund
development. Contributors share in that success. See
[Open development, openly funded](#open-development-openly-funded) below.

Noosphere is set in an affected stretch of the **Columbia River Gorge**, a decade after a
containment event tore the area open. The locals call it **the Valley**, and several
factions contest it; none of them are the good guys. You go in for what the Valley
leaks. Dedicated servers hold up to 12 players, and the host sets the cap (small crews of
2 to 4 on up to the full 12). It is PvE-first. PvP is an opt-in server toggle. It is not
an extraction shooter. The mood owes a debt to Roadside Picnic and the survival games
that came after it: quiet, patient, indifferent. The setting, the factions, and the story
are original.

See the [design overview](docs/book/src/design/overview.md) for the vision: the co-op
philosophy, the simulation principles, the economy, and the modding story. (The full
creative bible is kept internal.)

---

## Open development, openly funded

Noosphere is an experiment in building a game in the open *and* funding it sustainably.
The deal is simple:

- **The code is open source, MIT or Apache 2.0.** The engine bridge, the world
  simulation, the terrain and networking layers, the tooling: all of it is public and
  permissively licensed. Anyone can read it, learn from it, and build a **different game
  with their own IP** on top of it, commercial or not. The engine is the commons. What's
  proprietary is the game's creative content, not the code.
- **The game is original IP, and it's a paid game.** The Noosphere world, art, audio,
  story, factions, and name are proprietary
  ([Noosphere Content License](LICENSE-ASSETS.md), [trademark policy](TRADEMARK.md)). The
  finished, assembled game is sold on **Steam**. That's what funds the work. It is a
  **one-time purchase**: no microtransactions, no live-service grind, no pay-to-win. You
  buy the game; you own it.
- **Contributors share in the upside.** Steam revenue funds development *and* a
  contributor pool, across every discipline (code, art, writing, audio, design, QA).
  Merge quality work and you share in the game's success; the strongest contributors can
  become paid members of the team. The principles are in
  [docs/book/src/project/contributor-revenue.md](docs/book/src/project/contributor-revenue.md);
  contributions are governed by a [CLA](docs/CLA.md).

The goal: a genuinely community-driven game that can also pay the people who build it. See
[the funding model](docs/book/src/project/funding-model.md) for the full picture.

> The legal entity, exact revenue-share terms, and contributor agreements are still being
> set up with professional counsel. Nothing here is a binding offer yet. It's the
> direction, written down in public.

---

## Releases

**TBD.** Noosphere is in early development. There aren't any playable releases yet. When
the game ships it will be sold on Steam; the source code lives here.

---

## How it's built

### Rust and GDScript, with a strict line between them

The engine is Godot 4.x, paired with Rust via [gdext](https://godot-rust.github.io/book/)
for everything that can't afford to fail. The split is intentional:

**Rust owns the simulation layer**, world simulation, server
authority, networking, game state, and anything where a crash,
deadlock, or type error would break the experience. The simulation
core compiles and tests without Godot. It's portable, safe, and fast
by construction.

**GDScript handles content authorship**, scene transitions, UI, story
scripting, dialogue, and the kind of expressive gameplay logic that
modders and contributors need to write quickly and iterate on. A mod
can't crash the server or corrupt world state. The worst a GDScript
mod can do is misbehave, and that's recoverable.

### Architecture

```
Godot 4.x Project
  └── simn.gdextension → loads Rust extension

Rust Workspace (engine vendored from the public SIMN repo)
  ├── simn-godot    # gdext bridge, the ONLY crate that depends on Godot
  ├── simn-sim      # World simulation, online and offline tiers (engine-agnostic)
  ├── simn-terrain  # Heightmap loader and sampler (engine-agnostic)
  ├── simn-net      # Steam P2P session and transport (engine-agnostic)
  └── simn-common   # Shared utilities (engine-agnostic)
```

The five `simn-*` crates are the [SIMN engine](https://github.com/trapframestudio/simn),
not committed here. They're synced read-only into the gitignored
`godot/addons/simn/` by `scripts/sync-simn.sh` (pinned in `scripts/SIMN_VERSION`)
and listed as workspace members, so the build runs from the repo root as usual.

### Principles we don't bend on

- **Engine-agnostic core.** `simn-sim`, `simn-terrain`, `simn-net`, and
  `simn-common` compile without Godot. They're the portable simulation
  core and they stay portable.
- **Server-authoritative.** The server is the source of truth for all
  game state. Clients render. No client gets to change the world on
  its own.
- **Co-op from day one.** Every system is designed with network
  authority in mind from the start. There's no singleplayer codebase
  that gets networking bolted on later.
- **Mod-friendly by design.** Configuration files, scripting hooks,
  and asset mounting are first-class surfaces. In-game mod management
  with co-op compatibility flagging.

### What's working right now

- **Godot 4 + gdext scaffold** building and linking. The Rust dynamic
  library loads into the editor as a hot-reloadable extension.
- **Rust workspace** with the engine-agnostic rule enforced
  (`simn-common`, `simn-sim`, `simn-terrain`, `simn-net`, `simn-godot`).
- **CI hooks and pre-commit gates** wired up: clippy, test, fmt, and
  documentation verification all enforced before commits land.
- **Documentation pipeline** building cleanly via mdbook with a
  per-file Documentation Manifest keeping docs in sync with code.

---

## Contributing

### What you'll need

- [Rust](https://rustup.rs/) (stable toolchain)
- [Godot 4.x](https://godotengine.org/download/) (4.1+ for gdext compatibility)

### Build it

```bash
git clone https://github.com/joniler/noosphere.git
cd noosphere

# Vendor the SIMN engine (the simn-* crates aren't committed here; a fresh
# clone can't build until this syncs them into godot/addons/simn/)
./scripts/sync-simn.sh

# Build the full Rust workspace
cargo build --workspace

# Run tests
cargo test --workspace

# Lint (must pass before any commit)
cargo clippy --workspace -- -D warnings
cargo fmt --all -- --check

# Open the Godot project
godot godot/project.godot
```

### Working on the sim (engine dev)

The engine (the five `simn-*` crates) lives in the
[SIMN repo](https://github.com/trapframestudio/simn), not in this tree. Plain
`./scripts/sync-simn.sh` vendors a frozen snapshot at the pin in
`scripts/SIMN_VERSION` (what contributors and CI use). But the sim changes a
lot, so if you're actively working on it, **link** a local SIMN clone instead of
round-tripping through copy mode:

```bash
git clone https://github.com/trapframestudio/simn.git ../simn   # once, beside the game
./scripts/sync-simn.sh --link ../simn                            # symlink it in
```

Then the loop is in-tree-fast:

1. **Edit** the sim in your SIMN clone, then `cargo build` / run the game. It
   compiles your live edits straight through the symlink. No push, no pin bump,
   no sync just to test.
2. **Publish** when a change is solid: `cargo test -p simn-sim` (+ clippy/fmt) in
   the clone, then commit and push SIMN.
3. **Adopt**: bump `scripts/SIMN_VERSION` to the pushed commit and commit it
   here, on every adopted change, so `main` always pins a real engine commit.

Don't edit `godot/addons/simn/` in copy mode (the next sync overwrites it). Full
detail: [SIMN addon walkthrough](docs/book/src/walkthroughs/simn-addon.md).

### Where to start

- **Rust devs**, the engine is vendored under `godot/addons/simn/crates/` (run
  `./scripts/sync-simn.sh` first); engine changes land upstream in the
  [SIMN repo](https://github.com/trapframestudio/simn). The simulation
  core (`simn-sim`), terrain heightmap layer (`simn-terrain`), Steam
  P2P transport (`simn-net`), shared utilities (`simn-common`), and
  the gdext bridge (`simn-godot`) are where new contributors can dig
  in. The engine-agnostic rule is enforced: only `simn-godot` may
  depend on `godot`.
- **Godot/GDScript devs**, the Godot project is at `godot/`. UI,
  scene management, and gameplay scripting live there.
- **Designers and writers**: the world, the factions, the faults and Squalls, and the
  systems around them are all being built out. The public [design overview](docs/book/src/design/overview.md)
  covers the philosophy and systems; the full creative bible is internal. If you want to
  help shape what Noosphere is, open an issue.

See [`DEVELOPMENT.md`](docs/DEVELOPMENT.md) for the full build guide,
[`CONTRIBUTING.md`](docs/CONTRIBUTING.md) for how PRs work, and the
[documentation site](docs/book/src/) for architecture and code
conventions.

### Credit

If your work is in here, your name is in here. No exceptions. See
[`CREDITS.md`](docs/CREDITS.md).

---

## License

Noosphere uses a split license:

- **Code → MIT or Apache 2.0.** All source code (the Rust workspace, GDScript, build
  files) and the systems/mechanics data, dual-licensed [MIT](LICENSE-MIT) /
  [Apache 2.0](LICENSE-APACHE). Build new games on it, commercial or not.
- **Creative content → [Noosphere Content License](LICENSE-ASSETS.md)** (proprietary, all
  rights reserved). Art, audio, world, story, lore, faction names, and other Noosphere IP.
  Bring your own content if you build something new.
- **Name & brand → [trademark policy](TRADEMARK.md).** Use the code; call your project
  your own thing.

Contributions are accepted under a [Contributor License Agreement](docs/CLA.md).
Third-party addons and assets retain their own licenses.

---

## Legal

Noosphere is an original game by trapframe, with an original world, original systems, and
original IP. It is inspired by the S.T.A.L.K.E.R. lineage but is not affiliated with,
endorsed by, or sponsored by GSC Game World. S.T.A.L.K.E.R. and all related trademarks,
characters, locations, and content are the property of GSC Game World. Noosphere ships no
S.T.A.L.K.E.R., Anomaly, GAMMA, or other third-party game content in this repository, in
any release, or in any installer.
