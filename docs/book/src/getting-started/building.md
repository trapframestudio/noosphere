# Building Noosphere

## What you'll need

- **Rust toolchain** (stable) - install via [rustup](https://rustup.rs/)
- **Godot 4.x** - [godotengine.org](https://godotengine.org/download/) (4.1+ for gdext compatibility)
- **Git**

### System dependencies

**Linux (Fedora/RHEL):**
```bash
sudo dnf install gcc-c++ alsa-lib-devel systemd-devel libudev-devel
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt install g++ libasound2-dev libudev-dev pkg-config
```

**macOS:** Xcode command line tools (`xcode-select --install`)

**Windows:** Visual Studio C++ Build Tools

## Clone and build

```bash
git clone https://github.com/noosphere/noosphere.git
cd noosphere

# Vendor the SIMN engine first. The simn-* crates aren't committed here -
# they're synced from the public SIMN repo into the gitignored
# godot/addons/simn/. A fresh clone can't build until you run this.
./scripts/sync-simn.sh

# Build the entire workspace
cargo build --workspace

# Build a specific crate
cargo build -p simn-sim
```

The engine is consumed as a vendored, pinned addon rather than built in-tree.
See [SIMN as a vendored addon](../walkthroughs/simn-addon.md) for the why and
the day-to-day workflow (bumping the pin, where engine edits go).

## Running tests

```bash
# All tests
cargo test --workspace
```

## Linting

```bash
cargo clippy --workspace -- -D warnings
cargo fmt --all -- --check
```
