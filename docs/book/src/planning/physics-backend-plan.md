# Physics Backend & Dedicated Server - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-23
**Scope:** how physics queries and rigid-body simulation work across the two deployment modes (listen-server P2P, dedicated server). Companion to `physics-tiering-plan.md` (the tier system and replication) and `world-ledger-plan.md` (persistence).

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**Sim logic should not know which physics engine is running.** Damage resolution, AI perception, loot spawning, and destructible state transitions all need physics queries (raycasts, overlap tests, ground-height sampling) and the ability to register/step rigid bodies. Whether those queries run against Godot's Jolt (listen-server, in-process with the client) or Rapier (dedicated headless server) is an implementation detail behind a small trait.

Consequence: one simulation codebase, two deployment modes, zero divergence in sim behavior.

---

## 2. The Two Deployment Modes

### 2.1 Listen-server P2P (current code path)

The Godot client process also hosts the authoritative sim. `SimHost` (in `simn-godot`) owns the `Sim` instance and ticks it inside Godot's process loop. Physics queries route to Godot's `PhysicsDirectSpaceState3D`; Godot's Jolt integration handles rigid-body simulation.

This is what ships today and stays working.

### 2.2 Dedicated server (new)

A standalone Rust binary (`simn-server`) runs the sim headless. No Godot. No rendering. Physics queries route to Rapier directly. Clients connect over the network layer and receive authoritative state.

This is the deployment model the design doc (§8.2) targets for full 12-player servers. Residential P2P stays supported for smaller sessions.

---

## 3. The `PhysicsBackend` Trait

Lives in `simn-sim`. Every sim system that needs physics calls through this trait.

```rust
pub trait PhysicsBackend: Send + Sync {
    // --- Queries ---
    fn raycast(
        &self,
        from: Vec3,
        dir: Vec3,
        max_dist: f32,
        mask: u32,
    ) -> Option<RayHit>;

    fn overlap_sphere(
        &self,
        center: Vec3,
        radius: f32,
        mask: u32,
    ) -> Vec<BodyId>;

    fn ground_height(&self, x: f32, z: f32) -> Option<f32>;

    // --- Rigid-body management (Tier 2) ---
    fn add_body(&mut self, desc: BodyDesc) -> BodyId;
    fn remove_body(&mut self, id: BodyId);
    fn set_body_kinematic(&mut self, id: BodyId, awake: bool);
    fn apply_impulse(&mut self, id: BodyId, impulse: Vec3, point: Vec3);
    fn body_state(&self, id: BodyId) -> Option<BodyState>;

    // --- Step ---
    fn step(&mut self, dt: f32);
}
```

`BodyId` is an opaque handle. Each backend maintains its own mapping from `BodyId` to whatever native handle it uses (Godot RID, Rapier `RigidBodyHandle`).

Collision-layer masks use the constants already defined in `simn-godot::los` (`LAYER_SOLID` = bit 0, `LAYER_CONCEALMENT` = bit 1, `LAYER_NPC_HITBOX` = bit 2) - shared across both backends via a moved constants module in `simn-common`.

### 3.1 What's already through the trait

The existing `LosProvider` trait in `simn-sim` (used by `npc_aggro`) is a precursor. It'll be folded into `PhysicsBackend` as one of its query methods (`raycast` subsumes `LosProvider::exposure`).

### 3.2 Test backend

A `NullPhysicsBackend` impl for unit tests. Raycasts always hit/miss based on fixture data; rigid bodies are tracked in a `HashMap` and stepped mathematically. Keeps `simn-sim` tests fast and hermetic.

---

## 4. Backend Implementations

### 4.1 `GodotJoltBackend` (in `simn-godot`)

Wraps Godot's physics server. Used when the sim runs in-process with Godot (listen-server mode).

```rust
pub struct GodotJoltBackend {
    space: Rid,                 // PhysicsDirectSpaceState3D handle
    bodies: HashMap<BodyId, Rid>,
    // ... caches and lookups
}

impl PhysicsBackend for GodotJoltBackend {
    fn raycast(&self, ...) -> Option<RayHit> {
        // delegates to PhysicsDirectSpaceState3D::intersect_ray
    }
    // ... etc
}
```

Constructed when `SimHost._ready()` runs, wired into `Sim` via a constructor arg.

### 4.2 `RapierBackend` (in `simn-server`)

Uses `rapier3d = "0.22"` directly - not `bevy_rapier3d`, which brings a full bevy plugin with its own schedule management that would fight `Sim::tick`.

```rust
pub struct RapierBackend {
    physics: PhysicsPipeline,
    islands: IslandManager,
    broad_phase: BroadPhase,
    narrow_phase: NarrowPhase,
    bodies: RigidBodySet,
    colliders: ColliderSet,
    body_map: HashMap<BodyId, RigidBodyHandle>,
    // ...
}

impl PhysicsBackend for RapierBackend {
    fn raycast(&self, ...) -> Option<RayHit> {
        // delegates to narrow_phase.cast_ray
    }
    // ... etc
}
```

Terrain collision: loaded from `simn-terrain::Heightmap` as a `Collider::heightfield` at region-load time. Parity with Godot-side collision is automatic because the same heightmap file is the source of truth.

### 4.3 Determinism

Jolt (via Godot) is not deterministic across platforms. Rapier can be configured for determinism (`integration_parameters.deterministic = true`) at ~10% perf cost. For dedicated server replay purposes, same-machine determinism suffices. No cross-platform determinism requirement.

Decision: enable Rapier determinism in dev builds (helps reproduce bugs), disable in release builds (perf).

---

## 5. The `simn-server` Crate

New crate in the workspace. Binary only.

```
crates/simn-server/
├── Cargo.toml                   # deps: simn-sim, simn-net, simn-terrain, simn-world,
│                                #       rapier3d, tokio, serde, toml, anyhow, tracing
└── src/
    ├── main.rs                  # entry point, Tokio runtime, config loader, signal handling
    ├── backend.rs               # RapierBackend impl
    ├── net.rs                   # network loop (peer sockets, snapshot build, send)
    ├── config.rs                # server.toml schema
    └── health.rs                # /healthz endpoint, metrics
```

### 5.1 Architecture

```
simn-server main
  ├── tokio runtime
  ├── sim thread          (owns Sim, ticks at 20Hz)
  ├── net tasks           (one per peer; fan-in/out via channels)
  ├── persist tasks       (journal + snapshot writer, world ledger flusher)
  └── health task         (metrics exporter, /healthz)
```

Sim thread is fixed-timestep 50ms with a wall-clock accumulator (same pattern as `SimHost`). Net tasks are async Tokio and message the sim thread via MPSC channels. Persistence tasks drain dirty state from the sim and flush to disk on their own cadence.

### 5.2 Config

```toml
# server.toml
[server]
bind_address   = "0.0.0.0:7777"
max_peers      = 12
save_dir       = "/var/lib/noosphere/saves"

[sim]
snapshot_interval_ticks = 600    # ~30s at 20Hz

[physics]
# see physics-tiering-plan.md

[replication]
# see physics-tiering-plan.md
```

### 5.3 Networking (forward-ref)

Dedicated server networking is out of scope for this doc. It'll follow the design in `../architecture/networking.md` once the listen-server slice advances; the existing `simn-net` Steam P2P code doesn't translate to dedicated directly. Likely moves to ENet or WebRTC. Separate doc.

### 5.4 Dockerfile

Ships in `deploy/Dockerfile.server`. Multi-stage build: cargo build in a rust:slim image, runtime in alpine with the binary + systemd service file. Image size target: <50MB.

---

## 6. Two Physics Engines in One Project - Is That OK?

Yes, because they're doing different jobs in different processes:

- **Rapier** (dedicated server): authoritative simulation. Decides the truth.
- **Jolt** (Godot client): presentation physics. Decorative debris, severed limbs, local effects that never replicate.
- **Jolt** (listen-server host via Godot): authoritative simulation *and* presentation, in the same process.

For a pure listen-server deployment, Jolt is doing both jobs. For dedicated deployment, Rapier is authoritative and each client's Jolt is purely cosmetic.

The `PhysicsBackend` trait hides the engine choice from sim logic. The only code that touches engine-specific types is in the backend impls themselves.

---

## 7. Migration Path

Sequenced, each step shippable on its own:

1. **Define the trait** in `simn-sim`. No impl yet. Add a `NullPhysicsBackend` for tests. No gameplay change.
2. **Port the existing `LosProvider`** into `PhysicsBackend::raycast`. Update `npc_aggro` and `GodotLosProvider` to use the new trait. Verify listen-server behavior unchanged.
3. **Add rigid-body methods** to the trait. Implement them in `GodotJoltBackend`. Add the first Tier 2 body consumer (destructible gib burst, likely). Listen-server Tier 2 works.
4. **Stand up `simn-server` skeleton.** Empty binary, Tokio runtime, config loader, graceful shutdown. No sim running. CI builds and runs a smoke test.
5. **Implement `RapierBackend`.** Sim runs on the server binary against Rapier. No networking yet - just proves the backend abstraction holds.
6. **Wire networking** (separate plan doc). Dedicated server accepts clients.

Items 1–3 unlock the current slice's destructibles and reactive physics. Items 4–6 unlock the dedicated-server deployment mode. They can run in parallel after item 3.

---

## 8. Open Questions

- **Heightmap collider size.** A 5 km × 5 km heightmap at 1m spacing is 25M samples. Rapier's heightfield collider should handle it but memory footprint needs measuring. Fallback: chunk the heightmap into 500m tiles and load/unload per region-online.
- **BodyDesc shape vocabulary.** What shape primitives does the sim need to express? Box, sphere, capsule, convex mesh, heightfield. Start with those five; extend if modding requires.
- **Physics tick rate vs sim tick rate.** Both run at 20Hz by default. If we ever want 60Hz physics sub-steps for high-velocity collisions (fast projectiles), the trait needs a sub-step interface. Defer until a concrete need.
- **Shared collision-layer constants.** Currently defined in `simn-godot::los`. Move to `simn-common`? Yes - both backends need them and `simn-common` is the engine-agnostic home.
- **Rapier's API surface vs our needs.** Rapier is feature-rich; we're using a small subset. No plan to expose advanced features (joints, motors) through the trait until a feature demands them.

---

## 9. Cross-References

- `physics-tiering-plan.md` - how Tier 2 bodies are governed and replicated.
- `world-ledger-plan.md` - Tier 3 persistence, also part of the `simn-server` runtime.
- `../architecture/networking.md` - current Steam P2P design; dedicated networking is a future milestone.
- `../architecture/crate-guide.md` - current crate layout; `simn-world` and `simn-server` are the new additions.
- `../walkthroughs/sim.md` - the existing sim tick loop and `SimHost` pattern that `simn-server` parallels.
