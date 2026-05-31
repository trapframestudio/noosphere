# Architecture Overview

Noosphere is a hybrid Godot 4.x + Rust (gdext) project. Performance-critical
systems live in Rust. GDScript handles UI, scene management, and the
gameplay logic that benefits from hot reload.

## The two layers

### Rust (gdext) Layer
- **simn-godot** - gdext crate, the only crate that depends on `godot`. Bridges the simulation core into Godot.
- **simn-sim** - World simulation on `bevy_ecs`; authoritative state + journal-then-snapshot persistence (pure Rust, engine-agnostic).
- **simn-terrain** - Canonical heightmap loader + sampler; server-master terrain elevation shared by sim and Godot (pure Rust, engine-agnostic).
- **simn-net** - Networking and session layer over Steam (pure Rust, engine-agnostic).
- **simn-common** - Shared utilities.

### GDScript Layer
- Scene management and transitions
- UI (menus, HUD, inventory)
- Gameplay iteration and hot-reload workflows

### The line between them

GDScript calls into Rust via `#[func]`-annotated methods on gdext
classes. Rust never reimplements what Godot already provides
(rendering, physics, audio, scene system). GDScript never reimplements
logic that belongs in Rust (simulation, networking core).

## Crate dependency graph

```
simn-godot (cdylib, the Godot extension)
  ├── simn-sim      (world simulation, engine-agnostic)
  ├── simn-terrain  (canonical heightmap + sampler, engine-agnostic)
  ├── simn-net      (Steam P2P session, engine-agnostic)
  └── simn-common   (utilities, engine-agnostic)
```

**Rules:**
- `simn-common`, `simn-sim`, and `simn-terrain` have zero engine dependencies. They must compile without `godot`.
- `simn-godot` is the only crate that depends on `godot`. Contains all engine integration.
- Domain crates never depend on each other except through `simn-common`.

**Planned** (design complete, implementation pending):

- **`simn-world`** - SQLite-backed persistent world-object ledger (destructibles, loot nodes, containers, corpses, settled Tier 3 physics objects). Sits alongside the existing journal+snapshot. Engine-agnostic. See `../planning/world-ledger-plan.md`.
- **`simn-server`** - pure-Rust headless dedicated-server binary (no Godot). Parallels `SimHost` for the listen-server P2P path. See `../planning/physics-backend-plan.md`.
- **`PhysicsBackend` trait** in `simn-sim` - abstraction so sim logic calls into physics without knowing whether Godot's Jolt (listen-server) or Rapier (dedicated) is the live backend.

## Extension entry point

```rust
// crates/simn-godot/src/lib.rs
use godot::prelude::*;

struct NoosphereExtension;

#[gdextension]
unsafe impl ExtensionLibrary for NoosphereExtension {}
```

The gdext extension registers itself with Godot at load time. Custom
nodes and `#[func]` methods become available to GDScript automatically.
