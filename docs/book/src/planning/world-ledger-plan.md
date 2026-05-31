# World Ledger - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-23
**Scope:** the second persistence layer - a SQLite-backed `simn-world` crate - that sits alongside the existing journal+snapshot and holds queryable persistent world-object state: destructibles, loot nodes, containers, corpses, player bases, settled Tier 3 physics objects. Companion to `physics-tiering-plan.md` (Tier 3 definition), `destruction-plan.md` (what destructibles persist), and the existing `loot-and-economy-plan.md`.

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**Journal + snapshot stays authoritative for the ECS sim. The Ledger is a queryable, indexed, materialized view over persistent world-object state that would bloat the snapshot if folded in.**

The existing journal+snapshot design (`../walkthroughs/sim.md`) is great for what it does: deterministic replay of high-velocity sim events, crash recovery with ≤50ms granularity, full world state round-trip. It's not designed for storing 50,000 persistent destructible-state rows per long-played server; that would inflate snapshot size unacceptably and make queries ("what's damaged in region X?") require a full ECS scan.

Consequence: persistent world-object facts live in the Ledger; the sim dispatches writes alongside its journal entries; the Ledger is rebuildable at any time by replaying the journal from the last snapshot.

---

## 2. What the Ledger Holds

| Concern                         | Ledger table         | Row count (year-one, 12-player)  |
|---------------------------------|----------------------|----------------------------------|
| Destructible state (non-Intact) | `world_object_state` | ~50,000 (2 MB)                   |
| Loot node rolls                 | `loot_node_state`    | ~5,000 live (250 KB)             |
| Container contents (opened)     | `container_state`    | ~10,000 (5 MB incl. blobs)       |
| Player base metadata            | `player_base`        | ~50 (4 KB)                       |
| Base section composition        | `base_section`       | ~5,000 (40 KB)                   |
| Corpse state (until scrub)      | `corpse_state`       | ~2,000 live (400 KB incl. poses) |
| Tier 3 settled physics objects  | `settled_object`     | ~100,000 (4 MB)                  |
| Squall cycle log               | `squall_log`        | ~1,000 (50 KB)                   |

**Total ~12 MB of persistent state after a year of heavy play.** Journal+snapshot would balloon by orders of magnitude if it had to absorb this as ECS snapshot entities.

---

## 3. Crate Layout

New workspace member: `crates/simn-world`. Engine-agnostic, no `godot` dep.

```
crates/simn-world/
├── Cargo.toml                  # deps: rusqlite (bundled-sqlcipher optional), serde,
│                               #       bincode, tracing, anyhow, parking_lot
├── migrations/
│   ├── 001_initial.sql
│   └── ...
└── src/
    ├── lib.rs
    ├── schema.rs               # Rust-side DDL constants, column enums
    ├── ledger.rs               # WorldLedger type, public API
    ├── batching.rs             # dirty-write coalescing, flush task
    ├── migrations.rs           # migration runner
    ├── ids.rs                  # stable_id generation (xxh3 / uuid_v7)
    └── records.rs              # WorldObjectRecord / LootNodeRecord / ... structs
```

Adds one dep to the `simn-server` and `simn-godot` crates (both bind a `WorldLedger` into their `Sim`).

---

## 4. SQLite Configuration

- **WAL journal mode** (`PRAGMA journal_mode=WAL`) - lock-free reads during writes.
- `PRAGMA synchronous=NORMAL` - fsync at checkpoint, not per write. Trades off crash window for throughput; paired with our own batching.
- `PRAGMA busy_timeout=5000` - tolerate transient lock contention.
- One DB file per server at `<save_dir>/world.db`. Same directory as `world.save` + `world.journal`.
- Migrations applied at server start via embedded migration runner: read `migrations/*.sql` in lexical order, compare to `schema_migrations` table, apply missing ones in a single transaction.

---

## 5. Schema v1

```sql
-- Migration version tracking
CREATE TABLE schema_migrations (
    version    INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);

-- World objects: destructibles, base sections, player-placed dynamic pieces
CREATE TABLE world_object_state (
    object_id     INTEGER PRIMARY KEY,    -- u64 stable_id
    prefab_id     INTEGER NOT NULL,
    class         INTEGER NOT NULL,       -- DestructibleClass discriminant
    state         INTEGER NOT NULL,       -- DestructibleState discriminant
    hp            REAL NOT NULL,
    region_id     INTEGER NOT NULL,
    last_modified INTEGER NOT NULL,       -- sim tick
    metadata      BLOB                    -- bincode extensions (crew_id, fortification tier, ...)
);
CREATE INDEX idx_world_region   ON world_object_state(region_id);
CREATE INDEX idx_world_modified ON world_object_state(last_modified);

-- Player bases (parent entities; sections reference via base_section)
CREATE TABLE player_base (
    base_id    INTEGER PRIMARY KEY,
    crew_id    INTEGER NOT NULL,
    region_id  INTEGER NOT NULL,
    origin_x   REAL NOT NULL,
    origin_y   REAL NOT NULL,
    origin_z   REAL NOT NULL,
    created_at INTEGER NOT NULL,
    name       TEXT
);
CREATE INDEX idx_base_crew ON player_base(crew_id);

-- Base section membership
CREATE TABLE base_section (
    object_id INTEGER PRIMARY KEY REFERENCES world_object_state(object_id),
    base_id   INTEGER NOT NULL REFERENCES player_base(base_id)
);

-- Container state (rolled on first open)
CREATE TABLE container_state (
    container_id INTEGER PRIMARY KEY,
    region_id    INTEGER NOT NULL,
    opened_at    INTEGER,                -- NULL = unrolled
    contents     BLOB                    -- bincode Vec<ItemStack>
);
CREATE INDEX idx_container_region ON container_state(region_id);

-- Loose loot node declarations
CREATE TABLE loot_node_state (
    node_id      INTEGER PRIMARY KEY,
    node_class   INTEGER NOT NULL,       -- LootNodeClass discriminant
    region_id    INTEGER NOT NULL,
    rolled_item  INTEGER,                -- NULL = dead roll this cycle
    qty          INTEGER NOT NULL DEFAULT 0,
    condition    INTEGER NOT NULL DEFAULT 100,
    rolled_cycle INTEGER NOT NULL,
    taken_at     INTEGER                 -- NULL = still present
);
CREATE INDEX idx_loot_region_live ON loot_node_state(region_id, taken_at);

-- Corpse state (Tier 3 loot containers with baked pose)
CREATE TABLE corpse_state (
    corpse_id      INTEGER PRIMARY KEY,
    died_at        INTEGER NOT NULL,
    region_id      INTEGER NOT NULL,
    pos_x          REAL NOT NULL,
    pos_y          REAL NOT NULL,
    pos_z          REAL NOT NULL,
    pose           BLOB NOT NULL,        -- bincode quaternion snapshot
    dismember_mask INTEGER NOT NULL,     -- bitfield: 2 bits × 6 limbs (LimbState)
    inventory      BLOB                  -- bincode Vec<ItemStack>
);
CREATE INDEX idx_corpse_region ON corpse_state(region_id);

-- Tier 3 settled physics objects (dropped items, migrated props)
CREATE TABLE settled_object (
    settled_id INTEGER PRIMARY KEY,
    prefab_id  INTEGER NOT NULL,
    region_id  INTEGER NOT NULL,
    pos_x      REAL NOT NULL,
    pos_y      REAL NOT NULL,
    pos_z      REAL NOT NULL,
    rot_x      REAL NOT NULL,
    rot_y      REAL NOT NULL,
    rot_z      REAL NOT NULL,
    rot_w      REAL NOT NULL,
    state      INTEGER NOT NULL DEFAULT 0,
    metadata   BLOB
);
CREATE INDEX idx_settled_region ON settled_object(region_id);

-- Squall cycle log
CREATE TABLE squall_log (
    cycle        INTEGER PRIMARY KEY,
    triggered_at INTEGER NOT NULL,
    severity     INTEGER NOT NULL,
    regions      BLOB NOT NULL           -- bincode Vec<RegionId>
);
```

---

## 6. Stable ID Scheme

Load-bearing: every Ledger row is keyed on a stable ID that survives server restarts, scene edits, and client patches.

### 6.1 Scene-placed objects

```rust
pub fn stable_id_from_scene(scene_path: &str, placement_hash: u64) -> u64 {
    let scene_hash = xxh3_64(scene_path.as_bytes());
    (scene_hash & 0xFFFF_FFFF_0000_0000) | (placement_hash & 0x0000_0000_FFFF_FFFF)
}
```

`placement_hash` is written to the scene at export time by a small GDScript tool script that walks the tree and assigns hashes per destructible/loot-node path. Stable across edits as long as the node path is stable. If a scene rename or refactor breaks IDs, an optional `stable_id_override` export on the gdext component pins the ID through the rename.

### 6.2 Dynamic (player-placed)

Player-placed bases, dropped items, corpses: `uuid_v7` generated at creation time, stored as u64 (truncated - the 48 bits of timestamp + 14 bits of random give plenty of entropy at 12-player-scale scope).

### 6.3 Migration across scene restructures

If a major scene refactor invalidates many `placement_hash` values, operators can run a migration tool that reads the old Ledger, reconciles old → new IDs via a human-authored map, rewrites the Ledger, and stamps a new schema version. Not a first-class feature; a break-glass tool.

---

## 7. Delta-Only Storage

Fresh worlds don't touch `world_object_state`. A row only appears when a scene object is damaged or a player places a dynamic piece. `Intact` prefabs without a row are served their default state from the scene data.

**Lookup path:**

1. Sim system references an object by `object_id`.
2. Query `world_object_state`. Hit → use the row's state. Miss → default to `Intact` / prefab-default.

This is what makes storage scale with *play*, not *world size*. A pristine new world has 0 rows; a year-played world has ~50,000.

---

## 8. Write Batching

The sim never writes to SQLite from the tick hot path. Instead:

- `WorldLedger` holds an in-memory `HashMap<DirtyKey, DirtyRecord>` of pending writes.
- A dedicated async flush task (on the dedicated server: Tokio; on the listen-server: a Godot-side timer) drains and commits the map.

**Flush triggers:**

| Trigger                                    | Latency            |
|--------------------------------------------|--------------------|
| Periodic timer                             | every 3s (configurable 2–5s) |
| SIGTERM / graceful shutdown                | synchronous before exit  |
| Commit-now events                          | within 100ms       |
| Pressure valve (`dirty_count > 2000`)      | immediate          |

**Commit-now events** (bypass the 3s timer):

- Character death
- Base construction / destruction
- Crew join / leave
- Squall end
- Player-initiated stash move
- Operator command (backup, flush)

Each flush is one transaction. `INSERT OR REPLACE` for upserts. WAL mode means reads never block.

---

## 9. Write API (called by sim systems)

```rust
impl WorldLedger {
    // --- Writes (enqueued, non-blocking) ---
    pub fn upsert_world_object(&self, id: u64, record: WorldObjectRecord);
    pub fn remove_world_object(&self, id: u64);
    pub fn upsert_loot_node(&self, id: u64, record: LootNodeRecord);
    pub fn take_loot_node(&self, id: u64, tick: u64);
    pub fn put_container(&self, id: u64, state: ContainerState);
    pub fn upsert_settled(&self, id: u64, record: SettledRecord);
    pub fn remove_settled(&self, id: u64);
    pub fn upsert_corpse(&self, id: u64, record: CorpseRecord);
    pub fn remove_corpse(&self, id: u64);
    pub fn record_squall(&self, cycle: u64, severity: u8, regions: &[RegionId]);

    // --- Reads (synchronous, through cache) ---
    pub fn get_world_object(&self, id: u64) -> Option<WorldObjectRecord>;
    pub fn get_container(&self, id: u64) -> Option<ContainerState>;
    pub fn live_loot_in_region(&self, region: RegionId) -> Vec<LootNodeRecord>;
    pub fn world_objects_in_region(&self, region: RegionId) -> Vec<WorldObjectRecord>;
    pub fn settled_in_region(&self, region: RegionId) -> Vec<SettledRecord>;
    pub fn corpses_in_region(&self, region: RegionId) -> Vec<CorpseRecord>;

    // --- Transactional (rare) ---
    pub fn transaction<F, R>(&self, f: F) -> Result<R>
    where F: FnOnce(&mut LedgerTx) -> Result<R>;
}
```

Reads use a per-region cache that refreshes when the region transitions online → offline or vice versa. Cache invalidation is scoped by region, so a write to region A doesn't stall reads from region B.

---

## 10. Boundary Discipline Between Journal+Snapshot and Ledger

**Two stores, one invariant: journal is always the ultimate authority.**

- Sim systems write to *both* the journal (via `PendingDeltas`) *and* the Ledger (via `WorldLedger`) when mutating persistent world state. Not the same system - typically a journal-writing system produces a `WorldDelta::DestructibleStateChange`, and a separate Ledger-writing system reads that delta and upserts the row.
- The journal replay can fully rebuild the Ledger from scratch. Ledger is a materialized view.
- If a crash leaves the Ledger stale relative to the journal, a startup reconciliation pass replays journal-tail deltas into the Ledger before accepting new writes. The journal is truth.
- The Ledger never writes to the journal. No cycle.
- The only coupling: stable IDs. A journal delta names an `object_id`; the Ledger stores rows keyed on the same `object_id`.

---

## 11. Squall Refresh Pass

At Squall end, the sim runs a world-refresh that reads prefab metadata and writes to the Ledger in one transaction:

```rust
pub fn apply_squall_refresh(
    sim: &mut Sim,
    world: &WorldLedger,
    cycle: u64,
    severity: u8,
) {
    world.transaction(|tx| {
        // 1. Destructibles tagged `SquallBehavior::Reset`: delete rows,
        //    scene defaults reassert on next observation.
        tx.delete_world_objects_by_behavior(SquallBehavior::Reset);

        // 2. `DamageRoll` class: apply severity-scaled stochastic damage.
        apply_squall_damage_roll(tx, severity);

        // 3. `Preserve`: untouched (hub states, player bases).

        // 4. Shard nodes: delete all untaken shard rolls, re-declare.
        tx.delete_loot_nodes_by_class(LootNodeClass::ShardSpot);
        declare_shard_nodes(sim, tx, cycle);

        // 5. Corpses older than 1 in-game day: scrub.
        let cutoff = sim.tick() - ticks_per_ingame_day();
        tx.delete_corpses_older_than(cutoff);

        // 6. Log the cycle.
        tx.record_squall(cycle, severity, sim.affected_regions(cycle));
    });
}
```

Squalls are also a journal event - the journal captures `WorldDelta::SquallEnd { cycle, severity }`, and replay re-runs the refresh deterministically. The Ledger write is a materialization of the same decision.

---

## 12. Backup and Rollback

SQLite's online backup API makes operator workflows pleasant:

- **Live backup**: `sqlite3_backup_init/step/finish`. Produces a consistent snapshot without pausing the sim. Triggered by operator command or scheduled interval (default: hourly).
- **Paired snapshot**: operator tools bundle the latest `world.save`, `world.journal`, and `world.db` into a single `backup-<timestamp>.tar.zst`. Restoring is atomic across both persistence layers.
- **Rollback**: operator picks a bundled backup, stops server, swaps files, starts server. ~30s operation.
- **Retention policy**: last 5 hourly + last 7 daily by default. Operator configurable.

### 12.1 Crash recovery sequence

On server start:

1. Open `world.db`, apply any pending migrations.
2. Load `world.save` (snapshot). Verify blake3.
3. Replay `world.journal` tail on top of snapshot to recover up to the crash.
4. For each `DestructibleStateChange`/`LootNodeRoll`/etc. delta in the replayed tail, verify the corresponding Ledger row is present; if absent, write it. This closes the Ledger-vs-journal drift window.
5. Begin accepting new writes.

The reconciliation in step 4 is cheap: journal tail between snapshots is bounded to ~30s of deltas.

---

## 13. Testing

### 13.1 Unit tests (`simn-world::ledger`)

- Migration runner: empty DB → schema v1 applied → schema_migrations has row; v1 → v2 idempotent.
- Write batching: enqueue N writes, flush, verify all present. Concurrent enqueue during flush doesn't lose writes.
- Crash recovery: simulate mid-transaction kill with a fault-injecting SQLite wrapper; verify WAL recovery leaves consistent state.
- Region cache invalidation: read region X, write region X, read again → new state visible.

### 13.2 Integration tests (with `simn-sim`)

- Destructible state transition journaled + Ledger-written; server restart; state preserved.
- Container open is idempotent: open, restart, open again → same contents.
- Squall refresh: shards re-roll, documents don't, corpses older than cutoff scrubbed.
- Journal-Ledger reconciliation: force Ledger stale, restart, verify reconciliation catches up.

---

## 14. Open Questions

- **`rusqlite` features.** Start with `bundled` (static SQLite build). Add `bundled-sqlcipher` if operator encryption becomes a requirement. Defer.
- **Metadata blob schema.** `metadata BLOB` is bincode-serialized, but bincode versions need to survive schema upgrades. Leading `metadata_version: u16` per blob, handled by a small typed-dispatch layer.
- **Region cache sizing.** Cache all live regions? Cap at N most-recently-accessed regions? At 12-player scale, "all live" is ~4-8 regions max, which fits trivially. Start simple.
- **Multi-server data sharing.** If RP communities federate multiple servers, does any Ledger data need cross-server semantics? Explicitly deferred per design doc §8.3.
- **Schema migration for mod data.** Mods may add custom destructible classes or loot node classes. Need a `custom_*` class with data-driven discriminants that don't collide with engine classes. v0.3 of this plan.
- **Write amplification during Squalls.** A Squall triggers hundreds of writes in one transaction. Check that flush completes within the commit-now 100ms window; if not, Squall-specific batching.

---

## 15. Cross-References

- `../walkthroughs/sim.md` - existing journal + snapshot, which the Ledger sits alongside.
- `physics-tiering-plan.md` - Tier 3 objects persist through the Ledger.
- `destruction-plan.md` - destructible state transitions drive Ledger writes.
- `loot-and-economy-plan.md` - container and loot node state live in Ledger tables.
- internal design notes / internal design notes - Squall mechanics that trigger the refresh pass.
- `physics-backend-plan.md` - `simn-server` binary that hosts the Ledger for dedicated deployments.
