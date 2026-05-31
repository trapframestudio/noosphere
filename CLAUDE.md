# CLAUDE.md, Noosphere

## AI Assistant Rules, STRICT, NO EXCEPTIONS

**Rule 1: Plan mode for non-trivial tasks.** Any task involving new gdext classes, cross-crate changes, networking protocol changes, or multi-file modifications MUST use plan mode first.

**Rule 2: Update documentation before ending sessions.** Every session that changes code MUST update the relevant docs before the final commit. Check the Documentation Manifest below. This is not optional.

**Rule 3: Agent dispatch for domain work.** Use specialist agents for their domains. See the Agent Team table below.

**Rule 4: Cargo clippy clean.** All code must pass `cargo clippy --workspace -- -D warnings` before committing.

**Rule 5: Pre-commit + pre-push gates are enforced by hook.** Every `git commit` is blocked by `.claude/hooks/pre-bash.sh` until fresh markers exist for clippy, fmt, AND docs-verified. Every `git push` additionally requires a fresh test-pass marker. See "Pre-Commit Gate" below. Don't try to work around the hook.

**Rule 6: Pushing requires the literal word "push" from the user in the current turn.** Each push is a distinct authorization. Vague approvals like "looks good", "ship it", "go ahead" do NOT authorize a push. If unclear, ask: *"I'm about to push - confirm with 'push'?"*

Before any `git push`, output this checklist verbatim:
```
[ ] User said the literal word "push" in the current turn (quote it)
[ ] `touch .claude/state/push-allowed` written immediately before the push
[ ] Not a force-push (if yes → STOP; user runs it via `!` prefix themselves)
[ ] Not pushing to main/master directly (PR flow unless user says otherwise)
```

**Rule 7: Never use `git add -A` or `git add .`** Stage explicit paths by name.

**Rule 8: "Task complete" requires the docs-verified marker.** Don't tell the user a task is done before the Documentation Manifest is satisfied.

**Rule 9: Keep the worker tick path clean.** The sim runs on `SimWorker` at 20 Hz; render reads via `ArcSwap<SimView>` (lock-free). Keep off the tick path: disk I/O (use `SnapshotWriter` mpsc → bg thread), hot per-tick O(n) aggregates (maintain incrementally instead), main-thread-only Godot calls (prefetch + cache), Rust→Variant marshaling (cache by state_hash). Pattern: owner thread owns data; workers communicate via channels or ArcSwap; expensive encode/disk/FFI happens off the hot loop.

## Pre-Commit + Pre-Push Gates

### Commit gate

Before any `git commit`:
1. `cargo clippy --workspace -- -D warnings` passed in last 30 min (`.claude/state/clippy-pass`)
2. `cargo fmt --all -- --check` passed in last 30 min (`.claude/state/fmt-pass`)
3. `docs-keeper` agent dispatched and returned PASS (`touch .claude/state/docs-verified`)

### Push gate

Before any `git push`:
1. User said "push" in current turn (`.claude/state/push-allowed`)
2. `cargo test --workspace` OR `cargo test -p simn-sim` passed in last 30 min (`.claude/state/test-pass`)

**Pre-commit checklist** (output verbatim before any `git commit`):
```
[ ] cargo clippy --workspace -- -D warnings  (clippy-pass marker fresh)
[ ] cargo fmt --all -- --check                (fmt-pass marker fresh)
[ ] docs-keeper dispatched, returned PASS     (docs-verified marker written)
[ ] Documentation Manifest satisfied for every changed path
[ ] No `git add -A` or `git add .` used
[ ] Commit message follows convention
```

**Pre-push checklist** (in addition to Rule 6 checklist):
```
[ ] cargo test --workspace OR -p simn-sim     (test-pass marker fresh)
```

**Waivers** (auto-clear after one commit):
- **Rust checks waiver**: genuinely rust-irrelevant commits (docs-only). Verify: `git diff --cached --name-only | grep -vE '\.(md|txt|yml|yaml|toml)$|^docs/'` prints nothing → `echo 'docs-only' > .claude/state/checks-waived`
- **Docs waiver**: no applicable doc target. `echo 'reason' > .claude/state/docs-waived`

## Test Suite

```bash
cargo test -p simn-sim                    # fast (~6s), default
cargo test -p simn-sim -- --include-ignored  # full (~5min), before push
```

Default to `Sim::new_in_memory(graph)` for new tests (90 µs/tick, no NPCs). Opt in:
- `set_population_target_for_test(region, faction, count)` — tiny manual seed
- `Sim::new(paths, graph)` + `scale_all_population_targets(0.02)` — ~40 NPCs
- `Sim::new(paths, graph)` unscaled — only for full-population / `#[ignore]` tests

Persistence-roundtrip tests need disk paths; don't switch to `new_in_memory`. Registry loads cache via `OnceLock`.

**Concern → test-file mapping:**

| Touched code | Run these tests |
|---|---|
| `components.rs` (NpcCharacter, traits, rank, names) | `npc_character.rs`, `personality_traits.rs`, `npc_rank.rs`, `npc_names.rs`, `lived_experience.rs` |
| `systems/squad_planner.rs` | `squad_planner_utility.rs`, `npcs.rs` |
| `systems/npc_aggro.rs` | `perception_sight.rs`, `threat_board.rs`, `npcs.rs` |
| `systems/npc_combat.rs` | `accuracy_combat.rs`, `endurance_bleed.rs`, `npcs.rs` |
| `systems/threat_board.rs` | `threat_board.rs` |
| `systems/goal_arbitration.rs` | `personality_traits.rs`, `npcs.rs` |
| `systems/wounds.rs` / `world/wounds.rs` | `wounds.rs`, `endurance_bleed.rs`, `limb_state.rs` |
| `systems/kill_credits.rs` | `lived_experience.rs` |
| `world_event_bus.rs` / caliber / `ammo.toml` | `caliber_class.rs`, `effects.rs` |
| `content/items/*.toml` | `inventory.rs` |
| `content/items/ammo.toml` | `caliber_class.rs`, `inventory.rs`, `weapons.rs`, `ballistics_matrix.rs`, `projectiles.rs` |
| `factions.toml` / `faction/registry.rs` | `factions.rs`, `npc_character.rs` |
| `nav.rs` / `los_cache.rs` / pathfinding | `pathfinding.rs`, `terrain.rs` |
| `persistence.rs` / `world/replication.rs` | `persistence.rs`, `network_replay.rs`, `determinism.rs` |
| Broad change | full suite `--include-ignored` |

## Agent Team & Tools

| Agent | Trigger | Domain |
|---|---|---|
| `architect` | Cross-crate design, crate boundaries | All crates |
| `engine-architect` | gdext plugin design, Godot node arch | `simn-godot`, `godot/` |
| `sim-engineer` | Two-tier sim, factions, NPC AI, ecology | `simn-sim` |
| `gameplay-engineer` | Inventory, combat, medical, economy | `simn-sim` + `simn-godot` |
| `network-engineer` | Multiplayer, replication, prediction | `simn-net` (future) |
| `modding-engineer` | Config schemas, scripting hooks | All crates |
| `code-reviewer` | Pre-commit review, Rust idioms | All crates |
| `docs-keeper` | Pre-commit doc check, session wrap-up | `docs/`, `CLAUDE.md` |

**MCP servers** — don't mix: `godot` MCP = editor/runtime/scenes/screenshots. `gdscript` MCP = LSP diagnostics/syntax only.

## Documentation Manifest

Every changed path has a known doc target. `docs-keeper` uses this table.

**Engine crates are vendored** under `godot/addons/simn/crates/` (synced from the SIMN repo, gitignored). Edit engine code UPSTREAM in SIMN, not here — but the API doc targets below still live in this repo and must track engine API changes when you bump the pin. The globs use the vendored paths.

| Path glob | Required doc updates |
|---|---|
| `godot/addons/simn/crates/simn-sim/**` | `docs/book/src/architecture/crate-guide.md` if API changed |
| `godot/addons/simn/crates/simn-terrain/**` | `crate-guide.md` if public API changed |
| `godot/addons/simn/crates/simn-godot/src/lib.rs` (registration) | `overview.md` + `crate-guide.md` |
| `godot/addons/simn/crates/simn-godot/**` | `crate-guide.md` if public API changed |
| `godot/addons/simn/crates/simn-godot/src/sim/**` (`#[func]`/`#[signal]`) | `docs/book/src/api/sim-host.md` |
| `godot/addons/simn/crates/simn-godot/src/network.rs` (`#[func]`/`#[signal]`) | `api/network-manager.md` |
| `godot/addons/simn/crates/simn-godot/src/terrain.rs` (`#[func]`/`#[signal]`) | `api/terrain-node.md` |
| `godot/addons/simn/crates/simn-godot/src/physics_setup.rs` (`#[func]`) | `api/physics-setup.md` |
| `godot/addons/simn/crates/simn-common/**` | `crate-guide.md` if API changed |
| `scripts/sync-simn.sh`, `scripts/SIMN_VERSION` (sync/pin) | `docs/book/src/walkthroughs/simn-addon.md` + `docs/DEVELOPMENT.md` |
| New crate (upstream in SIMN) | `crate-guide.md` + `overview.md` |
| `godot/scripts/**` | `docs/book/src/architecture/` (relevant chapter) |
| `godot/project.godot` | `getting-started/configuration.md` |
| `.claude/agents/**` | Agent Team table in this file |
| `.claude/hooks/**` | This file (Pre-Commit Gate section) |
| New code convention/gotcha | This file (Critical Rules) |
| `LICENSE-MIT`, `LICENSE-APACHE`, `LICENSE-ASSETS.md`, `TRADEMARK.md` (license/IP terms) | README `## License`, `docs/GOVERNANCE.md` Licensing, `docs/book/src/project/funding-model.md` |
| `docs/CLA.md` (contributor terms) | `docs/CONTRIBUTING.md`, `docs/GOVERNANCE.md`, `docs/book/src/project/contributor-revenue.md` |
| Funding / revenue-share / legal-entity change | `docs/book/src/project/funding-model.md` + `contributor-revenue.md` + `docs/book/src/planning/internal planning notes (+ the design overview) |
| `godot/assets/**` | keep `godot/assets/NOTICE.md` + `LICENSE-ASSETS.md` accurate |
| `godot/addons/simn/content/**` (SIMN's embedded example pack; vendored, gitignored — edit UPSTREAM in SIMN) | keep SIMN's `content/NOTICE.md` accurate in the SIMN repo; bump `scripts/SIMN_VERSION` to pull |
| `godot/content/**` (the game's full content overlay; loaded via `SimHost.set_content_root("res://content")`; identity files proprietary, mechanics seeded from the open pack) | keep `godot/content/NOTICE.md` + `LICENSE-ASSETS.md` accurate |
| `Cargo.toml` (workspace) | Note in commit body; waiver allowed |
| New major system | `docs/book/src/walkthroughs/<system>.md` + link from `SUMMARY.md` |
| Forward-looking design | `docs/book/src/planning/<system>-plan.md` + link from `SUMMARY.md` |
| Faction/lore chapter | (internal lore vault) + `SUMMARY.md` |
| Player-facing mechanic change | `docs/book/src/mechanics/` chapter + `SUMMARY.md` |
| `*.md` only | Self-documenting |
| Test-only (`tests/`, `#[cfg(test)]`) | None if not changing public behavior |

**Rules:** Stale docs are worse than missing docs — fix or surface contradictions. Single source of truth — link, don't duplicate. New mdbook chapters must be added to `SUMMARY.md` in the same commit.

## Commands

```bash
cargo build --workspace                    # Build everything
cargo build -p simn-godot                  # Build gdext extension
cargo test --workspace                     # Test everything
cargo clippy --workspace -- -D warnings    # Clippy (must pass)
cargo fmt --all -- --check                 # Format check
cargo fmt --all                            # Auto-format
mdbook build docs/book                     # Build doc site
mdbook serve docs/book                     # Serve locally (port 3000)
```

---

## What Is This

Noosphere is an openly-developed co-op survival game built in Godot 4.x with a Rust core via gdext. Original world, systems, and lore. Inspired by S.T.A.L.K.E.R.: Anomaly/GAMMA but an independent project. **Split license: code is MIT OR Apache-2.0 (permissive, open source, commercial use OK); the Noosphere creative content/IP is proprietary ([LICENSE-ASSETS.md](LICENSE-ASSETS.md) + [TRADEMARK.md](TRADEMARK.md)).** The finished game is a paid, one-time-purchase title on Steam (no microtransactions) that funds development and shares revenue with contributors; contributions are accepted under a [CLA](docs/CLA.md). See `docs/book/src/project/funding-model.md`.

## Architecture

```
Rust Workspace (Cargo.toml)
  simn-godot (cdylib)    # ONLY crate with `godot` dependency
  ├── simn-sim           # World sim, online/offline tiers, bevy_ecs (engine-agnostic)
  ├── simn-terrain       # Heightmap loader + sampler (engine-agnostic)
  ├── simn-common        # Shared utilities (engine-agnostic)
  └── simn-net           # Steam P2P session + transport (engine-agnostic)

Godot 4.x Project (godot/)
  simn.gdextension → loads libsimn_godot.so
  GDScript: UI, scene transitions, gameplay iteration
  Rust (simn-godot): simulation bridge, networking core
```

**The engine is vendored, not in-tree.** The five `simn-*` crates live in the public SIMN repo (`github.com/trapframestudio/simn`) and are synced into the gitignored `godot/addons/simn/crates/` by `scripts/sync-simn.sh`, pinned to a commit in `scripts/SIMN_VERSION`. The game's root `Cargo.toml` lists them as workspace members, so `cargo build` from the repo root works as before. **Run `scripts/sync-simn.sh` before your first build** (a fresh clone has no engine source until then). The game keeps only its Godot project, proprietary content overlay (`godot/content/`), and docs.

**Dev workflow (the sim is under heavy active development):** edit the engine in a local SIMN clone (e.g. `/mnt/data/Development/simn`), linked in via `scripts/sync-simn.sh --link <clone>` so the game builds your live edits with no copy step. Inner loop: edit clone → build/run game. Publish: `cargo test -p simn-sim` + clippy/fmt **in the clone** (the SIMN repo has no commit gate yet), then commit + push SIMN. Adopt: bump `scripts/SIMN_VERSION` to the pushed SHA on **every** adopted engine change, so `main` always pins a real engine commit. Copy mode (plain `sync-simn.sh`) is for contributors/CI. **Never edit the vendored copy in copy mode** (sync overwrites it); in link mode you ARE editing the clone, which is correct. Full detail: `docs/book/src/walkthroughs/simn-addon.md`.

**Key rule:** `simn-common`, `simn-sim`, `simn-terrain`, `simn-net` must compile without `godot`. Only `simn-godot` touches Godot types.

**simn-sim**: Pure Rust world sim. Two-tier fidelity: online (near player, full AI) and offline (abstract graph simulation). Both run continuously. Engine-agnostic.

**simn-godot**: Single gdext crate bridging sim into Godot via `GodotClass` + `#[func]`. GDScript calls Rust; Rust does the work.

## Code Conventions

### Rust
- Engine-agnostic crates must NEVER depend on `godot`
- `#[class(tool, init)]` on all editor plugins (gdext requires init)
- Use `PackedVector3Array` etc. for geometry (10-100x faster than `Array<Vector3>`)
- Log: `godot_print!()`/`godot_warn!()`/`godot_error!()` in gdext; `tracing::info!`/`warn!`/`error!` in engine-agnostic crates
- No `unwrap()` in library code (use `?`/`anyhow::Result`); OK in tests; sparingly in `simn-godot` with `// PANIC:` comment
- All `#[func]` methods handle errors gracefully — never panic into Godot

### GDScript
- `@tool` on all editor scripts; type annotations on all signatures
- No game logic — GDScript calls Rust, Rust does the work
- Signal-based communication between nodes

### Commits
```
sim: basic NPC patrol system    godot: gdext bridge for input
ui: main menu (GDScript)        docs: design vision update
ci: Linux + macOS builds         chore: workspace cleanup
```

## Critical Rules

*Hard-won lessons. Add entries as gotchas are discovered.*

### Hook & CI

- **The pre-commit hook is real.** `.claude/hooks/pre-bash.sh` blocks `git commit` without fresh markers, blocks `git push` without authorization, blocks force-pushes and `git add -A`/`.`. State files in `.claude/state/` (gitignored), auto-clear on use.
- **Hook paths need `$HOME` prefix.** `$CLAUDE_PROJECT_DIR` is unset at runtime; bare relative paths broke in Claude Code 2.1.139. Current form: `$HOME/Development/noosphere/.claude/hooks/...`. Settings loaded once at session start.
- **Bash `tool_response` has no `exit_code` field.** Hooks infer success from output patterns: clippy looks for `Finished` without `error:`; test looks for `test result: ok`; fmt-check treats empty output as success.

### Sim / Determinism

- **`HashMap` iteration is non-deterministic.** Sort by stable key (RegionId, Faction, NpcId, etc.) BEFORE consuming RNG. Apply `sorted_map` serde to any HashMap in snapshots. Never use `Entity::to_bits()` in RNG seeds. Run `cargo test -p simn-sim --test determinism` after editing tick code.
- **Engine-agnostic core stays engine-agnostic.** `simn-common`, `simn-sim`, `simn-terrain`, `simn-net` must compile without `godot`.
- **New ECS resource? Insert in BOTH `Sim::build_world` AND `Sim::load`.** Recurring bug class: a resource added only to `build_world` (the fresh-sim path in `crates/simn-sim/src/world/mod.rs`) panics on first tick after a save load because `Sim::load` builds the world from scratch with the snapshot body and only re-inserts what it knows about. Symptom in the game: `worker inspect failed: sim inspect channel rejected` after Resume — the worker died on its first tick. Decide per-resource: **persisted** (add to `SnapshotBody` + serialize round-trip) or **transient** (insert `::default()` in both paths and re-seed from journal events). Regression test: `tests/persistence.rs::load_then_tick_runs_all_schedules` — load a fresh save and tick a few times; missing resources panic the schedule.

### Godot / gdext

- **`Node3D.global_position =` requires the node to be in the tree.** Always `add_child()` before setting `global_position`. Local `position` and `basis` are safe pre-parenting.
- **PackedArrays for geometry.** 10-100x faster than `Array<Vector3>` in gdext.
- **Never panic into Godot.** Log with `godot_error!()` and return error codes.
- **Hot reload works for method body changes only.** `reloadable = true` in `.gdextension`. Restart Godot for new/removed classes or `#[func]` methods.
- **Godot 4.6.2 inspector segfaults on Resource swaps in arrays.** Workaround: store paths as `String` (`@export_file`), `load()` lazily. Don't use `Array[Resource]` exports for user-edited fields.

### Terrain

- **Heightmap extent is `(W-1) * spacing`, not `W * spacing`.** W samples, W-1 cells.
- **Canonical maps are region-aligned.** Bake snaps to next multiple of `region_size_m` (2048 m default). `TerrainMetadata::region_size_m` carries this everywhere.
- **Canonical heightmap is `.r32` (f32 LE), format_version 2.** Literal meters above sea level, row-major NW-up. Legacy v1 `.r16` retired; `Heightmap::load` rejects format_version != 2.
- **`CullMode::DISABLED` on debug terrain material** prevents invisible-terrain debugging spirals from inverted winding or under-surface camera.
- **Production maps use shared `default_environment.tres`.** Don't inline env/sky/fog in map `.tscn` files. Test maps keep inline envs for fog experiments.
- **Never set `Terrain3D.region_size` from a `.tscn`** — segfaults before `data` init. Use `Terrain3DBaker` exports instead.
- **Terrain3D bake outputs at `godot/assets/terrain/<map>/terrain3d/`** (LFS). `.res` files are canonical for editor edits. Bake Now seeds once; Sync to Canonical pushes back. See [walkthroughs/terrain3d.md](docs/book/src/walkthroughs/terrain3d.md).
- **`enable_shader_override` checkbox required** for Terrain3DMaterial override shader to take effect (defaults off, no warning). Diagnostic: add `ALBEDO = vec3(1,0,0)` — if not red, checkbox is off.

### Foliage / Scatter

- **`NoiseTexture3D` generates async** — gate compute uniform sets on RD-texture validity AND validate `uniform_set_create` return. Self-heal on invalid RID by clearing sets + forcing rebuild.
- **`VISIBILITY_RANGE_FADE_SELF` dither is incompatible with cross-fading two MMIs.** Fix: per-instance world-XZ hash, complementary discard rules, `VISIBILITY_RANGE_FADE_DISABLED`. See [walkthroughs/foliage-tuning.md](docs/book/src/walkthroughs/foliage-tuning.md).
- **Don't `ResourceSaver.save` on Terrain3DMaterial after `set_shader_parameter`** — it silently drops user's inspector tweaks. Re-apply texture bindings at runtime in `_ready()` instead.
- **Rocks placed by terrain geology, not noise.** `terrain_rocky_score` (neighborhood height delta) gates placement. Old `cluster_strength`/`cluster_scale_m` knobs removed — do not reintroduce. See [walkthroughs/rocks.md](docs/book/src/walkthroughs/rocks.md).
- **Placement caches are gitignored** (`godot/assets/foliage_bake/`). Re-bake locally. Cache key is `cache_version + seed` only — don't add density/biome hashes.
- **`Faction`/`BaseKind` enums mirrored Rust↔GDScript.** `poi_enum_sync` test catches drift. Update Rust first, test tells you what to add to GDScript.
- **`@tool` scatter caches stale data across re-imports.** Call `_invalidate_species_cache()` at top of any bake/clear method.
- **Rock `.glb` meshes must be AABB-centered at origin.** Run `scripts/recenter_glb_meshes.py` on any imported rock pack.
- **Use ellipsoid projection for lowest visible point of rotated rock meshes** — not AABB corners, not un-rotated `aabb.position.y`. See `RockScatter._lowest_world_y_offset`.
- **Distant impostors: baked unlit albedo + runtime lighting.** `imposter_bake_albedo.gdshader` bakes color; `tree_cluster.gdshader` runs live `light()`. If color drift returns, fix with runtime grading sliders, NOT re-baking lighting. See [walkthroughs/foliage-tuning.md](docs/book/src/walkthroughs/foliage-tuning.md).
- **Per-instance collision shapes use `xf.basis.get_scale()`**, NOT `sp.size_multiplier`. Scale lives in the placement Basis.

## Key Files

| What | Where |
|------|-------|
| Build/debug guide | `docs/DEVELOPMENT.md` |
| Vision doc | `docs/the design overview |
| Project plan | `docs/PROJECT_PLAN.md` |
| Agent definitions | `.claude/agents/` |
| Documentation site | `docs/book/` |
| SIMN engine (vendored, read-only) | `godot/addons/simn/crates/` (synced; not committed) |
| World simulation | `godot/addons/simn/crates/simn-sim/` |
| gdext extension | `godot/addons/simn/crates/simn-godot/` |
| SIMN sync script + pin | `scripts/sync-simn.sh`, `scripts/SIMN_VERSION` |
| Godot project | `godot/` |
