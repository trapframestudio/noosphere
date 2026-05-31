# Sim Hardening - Planning Doc

**Status:** §2 (determinism harness) landed 2026-05-06 (PR #145); §4 (`ActiveRegions` Vec → HashSet) landed 2026-05-09 (PR #150); §3 (persistence migration path) still unstarted.
**Last updated:** 2026-05-09
**Scope:** small pre-netcode hardening items in `simn-sim` that are cheap to do now and painful to retrofit later. Surfaced by the 2026-04-24 architecture audit. Each item is scoped to fit in a single PR.

This is a living design doc. It captures decisions and open questions; it is not a spec.

Companions: `tier-transition-plan.md` (the bigger sim work this unblocks), `physics-backend-plan.md` (the dedicated-server path this hardening is prerequisite for).

---

## 1. Why This Doc Exists

These are three items that came out of an architecture audit as "cheap now, expensive later." None of them are blocking any current gameplay work. All of them become load-bearing when `simn-net` starts carrying replication traffic or the tier-transition handoff goes live.

They don't merit individual plan docs. They do merit a home so they don't get forgotten.

---

## 2. Determinism Harness for Ticked Simulation

**✅ landed 2026-05-06.** `crates/simn-sim/tests/determinism.rs` ticks two same-seed `Sim` instances side-by-side and asserts their in-memory snapshots are byte-identical at tick 200 (seed 42), at three checkpoints (seed 7), and that different seeds DO produce different state. The harness caught (and forced fixes for) `HashMap` iteration drift in `npc_spawn` / `npc_aggro` / `npc_combat` / `squad_planner`, two `Entity::to_bits()` RNG seeds in `npc_goals` / `npc_migrate`, and bevy archetype-storage order leaking into snapshot bytes (now sorted via `entity_sort_key` before emit). See the crate-guide entry for the full set of supporting changes; the section below records the original design intent for context.

### What exists today

`crates/simn-sim/tests/factions.rs::seed_is_deterministic` verifies that two `Sim::new_with_seed(.., 42)` instances produce identical `RegionControl` and `bases_in_region` at t=0. This confirms world-seed determinism at construction time.

### What doesn't exist

No test ticks the sim forward and compares results across runs. That's where divergence actually bites - a `HashMap` iteration-order leak, a stray `SystemTime::now()`, an unseeded `rand::thread_rng()`, or platform-dependent `fmadd` - none of those would fail `seed_is_deterministic` today.

### Proposed addition

One new test in `crates/simn-sim/tests/`:

```rust
#[test]
fn ticked_sim_is_deterministic() {
    let graph = RegionGraph::default_test_graph();
    let mut sim_a = Sim::new_with_seed(paths_a(), graph.clone(), 42).unwrap();
    let mut sim_b = Sim::new_with_seed(paths_b(), graph, 42).unwrap();

    // Drive identical inputs. Player actions, region changes, damage - all
    // the public API surface that's expected to be deterministic.
    for _ in 0..200 {
        sim_a.tick(Duration::from_millis(50));
        sim_b.tick(Duration::from_millis(50));
    }

    let snap_a = sim_a.write_snapshot_to_vec().unwrap();
    let snap_b = sim_b.write_snapshot_to_vec().unwrap();
    assert_eq!(snap_a, snap_b, "ticked sim snapshots diverged");
}
```

Signature of `write_snapshot_to_vec` is a minor API addition - today snapshots go to disk via `Sim::save`. An in-memory variant is wanted anyway for the eventual replication path (§7 of `tier-transition-plan.md`).

### What this does *not* guarantee

- **Cross-platform byte equality.** Floating-point math (`fmadd`, compiler intrinsics, FPU mode) can vary across Linux / Windows / macOS and across compiler versions. This test catches single-platform divergence; cross-platform determinism is a bigger problem that needs fixed-point arithmetic or explicit FP mode pinning, and is out of scope for this harness.
- **RNG stream stability across schema changes.** Adding a new component that consumes RNG during spawn will shift every subsequent draw. That's expected churn; re-record baseline when it happens.

### Extended variant (for `tier-transition-plan.md`)

Once tier handoff lands, extend this test to exercise projection round-trips:

```rust
// After ticking, force-project every online entity to offline and back.
sim_a.force_project_all_offline();
sim_a.force_materialize_all_online();
let snap_a2 = sim_a.write_snapshot_to_vec().unwrap();
assert_eq!(snap_a, snap_a2, "projection round-trip drifted");
```

Catches any change to the projection schedule that accidentally loses information.

---

## 3. Persistence Format Migration Path

### What exists today

Both journal and snapshot write a `FORMAT_VERSION: u32` header (currently `25`, in `crates/simn-sim/src/persistence/format.rs:5`). Load-time mismatch produces a clear error:

```
snapshot version {version} unsupported (expected {FORMAT_VERSION})
```

Bumps are tracked in `crate-guide.md` (21→22→23→24→25 with reasons).

### What's missing

Every bump is a hard break. A save written at v24 fails to load on v25 - no migration, no "read the old struct and map it." Pre-release this is acceptable; between any two development sessions the user just starts a fresh save.

Becomes a problem when:

- **Public playtests.** Testers have saves they care about.
- **Live multiplayer.** A server can't push a hotfix that bumps the schema without forcing everyone to reroll.
- **Mod ecosystem.** Mods may persist their own state via the same pipeline; forcing all mod saves to invalidate on every sim schema bump is hostile.

### Proposed approach (when this lands, not today)

Two-phase migration:

1. **Graceful error with user-facing guidance.** Replace the current panic-y error with a specific `PersistenceError::VersionMismatch { found, expected, minimum_supported }` variant. UI can surface "this save is from an incompatible build (v24, this build requires v25). Start a new run or downgrade your build."
2. **Per-version upgrade functions.** `fn upgrade_v24_to_v25(bytes: &[u8]) -> Result<Vec<u8>>`. Chain them to migrate v21 → v22 → … → current. Only implement forward migrations; never support downgrade.

Snapshot is easier to migrate than journal, because journal is a stream of `WorldDelta` enum variants - variant removal/renaming during a bump breaks the stream mid-replay. Policy: on a breaking journal change, snapshot the state fresh and start a new journal rather than migrate deltas. This is already the natural crash-recovery path.

### Scoping note

This is **not** urgent. The current hard-break behavior is fine until there are saves worth preserving. Capture now so the migration story is designed before the first user-impacting break lands.

---

## 4. `ActiveRegions` Vec → HashSet

**✅ landed 2026-05-09.** `ActiveRegions::regions` is now `HashSet<RegionId>`; the `clear + push` callsites in `Sim::set_active_region` and `Sim::move_player` swapped to `clear + insert`. `is_active(region)` is now `O(1)`. No iteration consumers, so HashSet ordering doesn't impact determinism. Snapshot-transient (per the existing comment), so no format bump.

### What exists today

`crates/simn-sim/src/resources.rs:115`:

```rust
#[derive(Resource, Default, Clone, Debug)]
pub struct ActiveRegions {
    pub regions: Vec<RegionId>,
}

impl ActiveRegions {
    pub fn is_active(&self, region: RegionId) -> bool {
        self.regions.contains(&region)
    }
}
```

`is_active` was originally an O(n) linear scan on `Vec<RegionId>`.
With `n = 1` (single active region today), the cost was free. The
field landed as a `HashSet` for O(1) lookups on 2026-05-09, ahead
of the tier-filter wiring that landed 2026-05-11 — `is_active` is
now hot, read by every NPC-bearing system per tick (see
`tier-transition-plan.md` §1 for the current list of consumers).

### Why this matters later

In co-op (up to 12 players per the design overview), `n` can grow to
double-digit regions simultaneously active. The HashSet bound is
O(1) per check regardless of `n`, so the scaling is already
correct — the prior Vec scan would have been wasteful at `n = 12`.

### Proposed change

```rust
use std::collections::HashSet;

#[derive(Resource, Default, Clone, Debug)]
pub struct ActiveRegions {
    pub regions: HashSet<RegionId>,
}

impl ActiveRegions {
    pub fn is_active(&self, region: RegionId) -> bool {
        self.regions.contains(&region)
    }
}
```

Callsites to update:

- `Sim::set_active_region` (`world/mod.rs:492`) - `clear` + `push` becomes `clear` + `insert`.
- Serialization: `ActiveRegions` is transient (`// ActiveRegions is transient (not saved)` comment in `world/mod.rs:653`) so no snapshot impact.

### Determinism note

Once `is_active` starts gating per-tick behavior, any iteration over `ActiveRegions.regions` must be sorted before use (HashSet iteration order is non-deterministic). Today nothing iterates it, but flag this for the tier-transition implementer.

---

## 5. Execution Order

§2 and §4 are landed. The remaining item is §3:

- ~~**One PR, ~30 lines:** §4 (HashSet swap).~~ **✅ landed 2026-05-09 (PR #150).**
- ~~**One PR, ~80 lines:** §2 (determinism harness).~~ **✅ landed 2026-05-06 (PR #145).**
- **One PR, ~200 lines, when user-facing saves matter:** §3 (migration path). Don't pre-build; wait until the first planned break where preserving saves matters.

---

## 6. Out of Scope

Things the audit flagged that this doc does *not* cover, intentionally:

- **Cross-platform float determinism.** Needs a real fixed-point or soft-float strategy and is a project-wide call, not a hardening item.
- **Replication projection.** Lives in `tier-transition-plan.md` §7 because the projection function is shared with the offline-tier handoff.
- **`simn-net` determinism contract.** Out of scope until `simn-net` starts carrying replication traffic; that's a `simn-net` plan doc, not this one.
