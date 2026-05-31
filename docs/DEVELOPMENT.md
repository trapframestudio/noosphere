# Development Guide

How to get a Noosphere checkout building and running.

## What you need

- **Rust** (stable toolchain) - [rustup.rs](https://rustup.rs/)
- **Godot 4.x** - [godotengine.org](https://godotengine.org/download/) (4.1+ for gdext)
- **mdbook** (optional) - for building the developer guide locally; install via `cargo install mdbook`. Without it, `mdbook build docs/book` fails with "command not found" (exit 127).

### System dependencies

**Linux (Fedora/RHEL):**
```bash
sudo dnf install gcc-c++ alsa-lib-devel systemd-devel libudev-devel
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt install g++ libasound2-dev libudev-dev pkg-config
```

**macOS:** `xcode-select --install`

**Windows:** Visual Studio C++ Build Tools

## Quick start

```bash
git clone https://github.com/noosphere/noosphere.git
cd noosphere

# Vendor the SIMN engine first (the five simn-* crates are NOT committed
# here - they're synced read-only from the public SIMN repo into the
# gitignored godot/addons/simn/, pinned by scripts/SIMN_VERSION). A fresh
# clone has no engine source until you run this:
./scripts/sync-simn.sh

# Build the Rust workspace (members live under godot/addons/simn/crates/)
cargo build --workspace

# Open the Godot project (Godot must be in PATH)
godot godot/project.godot
```

### The SIMN engine is vendored, not in-tree

`simn-common/sim/terrain/net/godot` live in the public SIMN repo
(`github.com/trapframestudio/simn`). `scripts/sync-simn.sh` (copy mode) clones
it at the pin in `scripts/SIMN_VERSION` and drops `crates/` + `content/` into
`godot/addons/simn/`; the root `Cargo.toml` lists those as workspace members,
so `cargo` from the repo root works normally and the build output still lands
in repo-root `target/`. That's what contributors and CI use.

**If you're actively changing the sim**, use link mode instead: clone SIMN
beside the game and

```bash
./scripts/sync-simn.sh --link /path/to/simn
```

symlinks the addon at your clone, so editing the engine there builds straight
into the game with no copy or pin bump. Commit/push engine changes from the
clone; when the game adopts a version, bump `scripts/SIMN_VERSION` (every
adopted change, so `main` always pins a real engine commit). Full workflow:
[walkthroughs/simn-addon.md](book/src/walkthroughs/simn-addon.md).

### After pulling new assets

Godot lazily imports source assets (textures, models, fonts) into
`.godot/imported/` on first use. On a fresh clone or a pull that
brings in new assets, the first launch races import against
resource loads - you'll see transient `Unable to open file:
res://.godot/imported/…ctex` errors until the cache catches up,
and the font/theme pipeline can fail the same way.

Prewarm the cache once before running the game:

```bash
godot --headless --import godot/project.godot
```

It scans the tree, imports everything, and exits. Subsequent
launches (editor or runtime) are clean.

## Build commands

```bash
# Rust
cargo build --workspace                      # Build all crates
cargo build -p simn-godot                    # Build gdext extension only
cargo build --release                        # Release build

# Godot
godot godot/project.godot                    # Open project in editor
godot --headless --quit godot/project.godot  # Headless build (CI)
```

## Tests

```bash
cargo test --workspace                       # All tests
```

## Lint

```bash
cargo clippy --workspace -- -D warnings      # Must pass before commits
cargo fmt --all -- --check                   # Check formatting
cargo fmt --all                              # Auto-format
```

## Docs

### mdbook (developer guide)

```bash
cargo install mdbook                         # Install (one-time)
mdbook build docs/book                       # Build to target/book/
mdbook serve docs/book                       # Serve at localhost:3000
```

### Rust API docs

```bash
cargo doc --workspace --no-deps --open       # Build and open in browser
```

## Project structure

See [`CLAUDE.md`](../CLAUDE.md) for the full crate layout, architecture, and code
conventions.

## Environment variables

| Variable | Description | Required |
|----------|-------------|----------|
| `RUST_LOG` | Log level filter (e.g., `info,simn_sim=debug`) | Optional |
