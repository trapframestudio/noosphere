# Contributing - Code Conventions & Dev Loop

> **First time here?** Start with [`CONTRIBUTING.md`](../../../CONTRIBUTING.md)
> for the workflow, ground rules, and where things live. This page is
> the deeper technical reference: code conventions, hot reload, and
> the testing setup. For how shipped contributions may share in the game's
> proceeds, see [Contributor Revenue](../project/contributor-revenue.md).

## Code conventions

### Rust

- Pure-Rust crates (`simn-common`, `simn-sim`, `simn-terrain`, `simn-net`) must compile **without** the `godot` dependency. Don't pull engine types into them.
- `simn-godot` is the only crate that depends on `godot`. All `Node3D` subclasses and `#[func]` methods live here.
- All classes exposed to Godot use `#[derive(GodotClass)]` + `#[godot_api]`. Editor plugins use `#[class(tool, base=...)]`.
- Logging:
  - `godot_print!` / `godot_warn!` / `godot_error!` inside `simn-godot` (engine console)
  - `tracing::info!` / `warn!` / `error!` in pure-Rust crates (no engine dependency)
- No `unwrap()` in library code, use `?` or `anyhow::Result`. `unwrap()` is OK in tests.
- `simn-godot` may use `unwrap()` sparingly with a `// PANIC:` comment explaining why it's safe.
- All `#[func]` methods must handle errors gracefully, never panic into Godot. Wrap the body in a private `do_thing() -> anyhow::Result<()>` and catch at the boundary with `godot_error!()`.
- Doc comments: `//!` for modules, `///` for public items.
- Use `PackedVector3Array` / `PackedVector2Array` / `PackedInt32Array` / `PackedFloat32Array` for bulk geometry data, they are 10-100x faster than `Array<Vector3>` etc. across the FFI boundary.

### GDScript

- `@tool` annotation on all editor plugin scripts.
- Type annotations on all function signatures.
- No game logic in GDScript, GDScript calls into Rust, Rust does the work. GDScript handles UI, scene transitions, and input plumbing.
- Signal-based communication between GDScript nodes where possible.

## Dev loop, hot reload

The gdext extension is configured as `reloadable = true` in `simn.gdextension`. After rebuilding with `cargo build -p simn-godot`, **you do not need to restart Godot** for most changes. Just save a file in the editor (or the focus-changed event) and Godot picks up the new `.so` / `.dll` / `.dylib` and reloads the extension in place.

This works for:
- **Method body changes** on existing classes (`#[func]` implementations)
- **Bug fixes** in any pure-Rust crate (`simn-common`, `simn-sim`)
- **Minor signature tweaks** as long as the GDScript callers don't break

This **does not** work reliably for:
- **Adding or removing classes**, Godot needs a fresh extension load
- **Adding or removing `#[func]` methods**, GDScript class cache may go stale

If hot reload misbehaves (crashes, weird state), the safe fallback is restarting Godot. If even that doesn't help, `rm -rf godot/.godot/` to wipe the entire cache.

## Documentation rules

If you change code, update the relevant docs in the same PR. Mapping:

| When these files change... | Update these docs |
|----------------------------|-------------------|
| `crates/simn-godot/` | `docs/book/src/architecture/crate-guide.md` |
| `crates/simn-sim/` | `docs/book/src/architecture/crate-guide.md` |
| `crates/simn-terrain/` | `docs/book/src/architecture/crate-guide.md` |
| `crates/simn-net/` | `docs/book/src/architecture/crate-guide.md` |
| `crates/simn-common/` | `docs/book/src/architecture/crate-guide.md` |
| `godot/scripts/` | `docs/book/src/architecture/` (relevant chapter) |
| New code conventions or gotchas | This file (Code Conventions section) |

The full per-glob mapping is in the Documentation Manifest in `CLAUDE.md`;
this table is a quick-reference summary.

## Before you commit

1. `cargo fmt --all`, auto-format
2. `cargo clippy --workspace -- -D warnings`, must pass
3. `cargo test --workspace`, all tests pass
4. Update documentation (see [Documentation Rules](#documentation-rules) above)

## Commit message format

```
prefix(scope): short description

Prefixes:
  feat:       New functionality
  fix:        Bug fix
  refactor:   Internal restructuring with no behavior change
  perf:       Performance improvement
  docs:       Documentation
  chore:      Tooling, deps, config
  test:       Test additions/improvements
  ci:         CI/CD

Common scopes:
  godot:         Godot integration (simn-godot)
  sim:           World simulation (simn-sim)
  terrain:       Terrain heightmap (simn-terrain)
  net:           Networking / transport (simn-net, Steam P2P listen-server)
  common:        Shared utilities (simn-common)
```

## Testing

Use original or generated test fixtures only. Do not commit or
reference any third-party game content. Test data lives in
`tests/fixtures/` per crate.
