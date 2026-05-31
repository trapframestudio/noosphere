# Threaded Sim — Planning Doc

**Status:** planning only, no implementation yet.
**Last updated:** 2026-05-11
**Scope:** decouple sim execution from the Godot main thread. The
sim runs on a dedicated worker thread at fixed 20 Hz; the main
thread reads published snapshots, interpolates visuals between
consecutive snapshots, and forwards player actions back to the sim.
Render never blocks on sim cost; sim never blocks on render frame
timing. The architectural prerequisite for the project's stated
**60+ FPS performance target** under the **multi-region, multi-
player, projectile-combat** load profile.

Companions: [`tier-transition-plan.md`](tier-transition-plan.md)
(online ↔ offline projection runs on this thread),
[`offline-tier-plan.md`](offline-tier-plan.md) (offline-tier
abstract simulation runs alongside online tier on the same worker),
[`multiplayer-alife-plan.md`](multiplayer-alife-plan.md) (the
12-player target this enables), [`physical-combat-plan.md`](physical-combat-plan.md)
(projectile resolution semantics in a threaded world),
[`physics-backend-plan.md`](physics-backend-plan.md) (dedicated-
server binary stops needing Godot at all when this lands).

This is a living design doc.

---

## 1. The Priority Stack

Order matters. Everything in this doc serves the stack below; when
items conflict, the higher item wins.

1. **60+ FPS sustained on the render thread**, regardless of sim
   load. Non-negotiable. Render budget is 16.67 ms per frame
   (60 FPS) or 6.94 ms (144 FPS); sim work that exceeds this on the
   main thread is the failure mode this plan exists to fix.
2. **Performant sim with two-tier execution**. Online (full-fidelity
   per-NPC simulation) and offline (abstract graph-level simulation
   per [`offline-tier-plan.md`](offline-tier-plan.md)) both run on
   the worker thread. Most NPCs are offline at any given time; the
   active fraction is what we budget for.
3. **Multi-zone, multi-player**. Up to 12 players, each in their
   own region OR sharing regions. Up to 12 regions simultaneously
   in the online tier (per [`multiplayer-alife-plan.md`](multiplayer-alife-plan.md)).
   The sim must handle this without falling below playable tick
   rate.
4. **Projectile combat, not hitscan**. Bullets travel over multiple
   ticks. Lag-compensation strategy differs from the classic
   hitscan "rewind targets" pattern; see §6.
5. Everything else — content, behavior depth, AI sophistication —
   is **secondary until 1-4 are stable.** Performance regressions
   from feature work go on the regression list before they ship.

---

## 2. Why this doc exists

Today (2026-05-11, post sim-playability commit) the sim runs on
Godot's main thread inside `SimHost::process`. We've spent a long
session getting per-tick cost from ~38 seconds down to ~15-25 ms,
which is enough to be playable in single-region testing — but it
hits an asymptote at "~30-55 FPS with 3,600 NPCs in one active
region", because:

- Sim tick is 15-25 ms. `MAX_TICKS_PER_FRAME = 4`. Worst case 60-
  100 ms per render frame just for sim.
- Render gets whatever's left.
- One core pegged; seven idle (`rayon` only helps inside
  `tick_npc_goals`).
- Adding more regions, more players, or more NPCs makes it worse
  proportionally.

There is no amount of micro-optimization that fixes this while sim
and render share a thread. The structural answer is the standard
MMO/sim pattern: **dedicated sim worker thread, published
snapshots, render-side interpolation**. Done correctly, it
guarantees:

- Render at any frame rate the GPU can hit, **independently** of
  sim cost.
- Sim at its own fixed rate (20 Hz now, possibly lower at extreme
  load), **independently** of render frame rate.
- Smooth visual motion at any frame rate via lerp between
  consecutive sim snapshots.
- A future dedicated-server binary becomes a near-trivial
  refactor — strip the main thread, keep the sim worker.

---

## 3. Architecture

```
┌──────────────────────────────────────┐         ┌───────────────────────────────────┐
│  Sim worker thread (target 20 Hz)    │         │  Godot main thread (60-144 FPS)   │
│                                      │         │                                   │
│   loop {                             │         │   _process(delta) {               │
│     drain inbound actions ────────────┐         │     read latest snapshot pair    │
│     Sim::tick() {                    │ │       │     alpha = time-into-tick frac  │
│       schedule.run(world);           │ │       │     for npc in snapshot {        │
│       publish snapshot ─────────────────────────┼──►    lerp prev,curr,alpha       │
│     }                                │ │       │       set Node3D position        │
│     sleep until next tick deadline   │ │       │     }                             │
│   }                                  │ │       │     submit render                 │
│                                      │ ▼       │     forward player input ─────────┼──► (back to sim inbound)
└──────────────────────────────────────┘         └───────────────────────────────────┘
       ▲                                                       │
       │                                                       │
       └───── action channel (bounded MPSC) ───────────────────┘
```

Two unidirectional channels:

- **Snapshot channel** (sim → main): publishes the latest world
  state on every tick. Main thread reads the freshest pair.
- **Action channel** (main → sim): player inputs, region change
  requests, debug commands, anything that mutates sim state.

No locks. No mutual blocking. Either side can be slow without
affecting the other's frame timing.

---

## 4. Snapshot model

### 4.1 Triple-buffered or bounded-channel?

Two viable approaches, both lock-free:

**Triple buffer.** Three preallocated snapshot slots. Sim writes
to "next", atomically swaps "next" and "ready", main reads
"current" which atomically swaps with "ready" on read. Bounded
memory, zero allocations per tick once warm. Most cache-friendly.

**Bounded channel of 2-3 snapshots.** Crossbeam or std MPSC.
Cheaper to implement at first; minor allocation overhead per tick.

**Decision:** start with bounded channel (`crossbeam_channel`,
capacity 2, sim sends "newest" semantics — drop older if main
hasn't picked them up). Migrate to triple buffer if profiling
shows the alloc cost matters. Either path keeps the contract the
same.

### 4.2 What goes in a snapshot

Snapshots are render-facing. They include only what the main
thread needs to draw / interpolate / build UI from. **Not** the
full ECS world.

```rust
pub struct SimSnapshot {
    pub tick: u64,
    pub published_at: std::time::Instant,

    // Per-online-region NPC summary. Offline-region NPCs are
    // omitted — they're not rendered.
    pub npcs: Vec<NpcSnapshot>,

    // In-flight projectiles for visual interp. See §6.
    pub projectiles: Vec<ProjectileSnapshot>,

    // Player positions (for self + peer rendering in coop).
    pub players: Vec<PlayerSnapshot>,

    // World state the HUD / shaders read every frame.
    pub world_time: WorldTime,
    pub weather: WeatherState,

    // Region delta channel: spawn / despawn / migrate events
    // since the last snapshot, so the renderer can spawn / free
    // pill nodes without polling the full list.
    pub deltas: Vec<RenderDelta>,
}

pub struct NpcSnapshot {
    pub id: NpcId,
    pub region: RegionId,
    pub pos: [f32; 3],
    pub yaw: f32,
    pub health: f32,
    // Body parts only for NPCs within the player's draw radius —
    // mirrors `npcs_near` filter. ~50 NPCs vs ~1000.
}

pub struct ProjectileSnapshot {
    pub id: ProjectileId,
    pub pos: [f32; 3],
    pub vel: [f32; 3],
    pub kind: ProjectileKind,  // bullet vs grenade vs etc.
}
```

The snapshot is **whatever the main thread needs and nothing
else**. If the inspector overlay wants a deeper view, it asks the
sim thread for a one-off query via the action channel ("give me
the full NpcView for NpcId(42)"), gets it back asynchronously, and
displays it. No hot-path coupling.

### 4.3 Snapshot publishing cadence

One snapshot per sim tick. At 20 Hz that's 50 ms between
snapshots. The renderer interpolates within that window.

If a sim tick takes >50 ms (the budget bust we're trying to
avoid), the sim falls behind, snapshots arrive later than 50 ms
apart, and the renderer **clamps `alpha` at 1.0** — it shows the
latest pose without extrapolation, freezing visually until the
next snapshot arrives. **Extrapolation is intentionally not
allowed** — it produces glitches when targets reverse direction.

---

## 5. Render-side interpolation

### 5.1 The lerp

```gdscript
# game_session.gd::_process(delta), once per frame
func _sync_npc_dummies() -> void:
    var (prev_snap, curr_snap) = SimHost.read_snapshot_pair()
    if prev_snap == null or curr_snap == null:
        return
    var span: float = (curr_snap.published_at - prev_snap.published_at).as_secs_f32()
    var since_curr: float = (Time.get_unix_time_from_system() - curr_snap.published_at).as_secs_f32()
    var alpha: float = clamp(since_curr / span, 0.0, 1.0)
    for npc_curr in curr_snap.npcs:
        var npc_prev = prev_snap.find_npc(npc_curr.id)
        var render_pos = lerp(npc_prev.pos, npc_curr.pos, alpha)
        var render_yaw = lerp_angle(npc_prev.yaw, npc_curr.yaw, alpha)
        dummy.global_position = render_pos
        dummy.rotation.y = render_yaw
```

Per-NPC lookup goes through a `HashMap<NpcId, NpcSnapshot>` built
once per snapshot pair. No O(N²) inside the per-frame loop.

### 5.2 NPCs that appear / disappear between snapshots

`RenderDelta::NpcSpawned` and `RenderDelta::NpcDespawned` in the
snapshot's `deltas` field tell the renderer to instantiate or free
dummy nodes. Position interpolation only applies to NPCs present
in both `prev_snap` and `curr_snap`.

### 5.3 Two transforms, never confused

**Render pose** = interpolated, on `Node3D.global_position`.
**Authoritative pose** = sim's latest published value, on
`NpcSnapshot.pos`. Read this for any gameplay logic, never the
Node3D.

This discipline is documented in the code path:

- `humanoid_dummy.gd::set_state(snapshot)` — visual lerp target.
- `Sim::npc_at(id) -> NpcView` — authoritative read.
- Any gameplay raycast / collision query from GDScript goes
  through a sim API, not Godot's `RayCast3D` against the Node3D
  layer.

If a future engineer adds `RayCast3D` for gameplay hit detection
against an NPC pill collider, the lerp-vs-authority drift bug
shows up at high latency. The plan is to **wrap such reads in a
sim-side API from day one** so the temptation doesn't exist.

---

## 6. Projectile combat in a threaded world

We are **projectile-based, not hitscan**. Bullets are entities
that travel through the world over multiple ticks. Travel time at
a typical rifle range is 100-300 ms — within the same order as
ping, which changes the lag-compensation story.

### 6.1 Authoritative projectile sim

On each sim tick, for each in-flight projectile:

1. Advance `pos += vel * dt` (with optional drag / gravity).
2. Test collision against authoritative NPC + player positions
   **at this tick**.
3. On hit: write a damage delta + spawn an `Impact` FX delta.
4. On miss + lifetime exceeded: despawn.

**No rewind is needed for the projectile-vs-target check** because
both projectile and targets advance at the same sim tick rate.
Authority sees a coherent timeline.

### 6.2 Lag compensation for the firing player

When a player presses fire:

1. **Client (immediate)**: spawn a *visual* projectile at the
   muzzle, locally, at the rendered camera direction. This is
   eye-candy only; no gameplay state.
2. **Client → sim**: queue
   `ActionKind::Shoot { origin, direction, fired_at_tick, projectile_kind }`.
   `fired_at_tick` is the sim tick the player believed it was
   when they fired — derived from the snapshot they were
   rendering.
3. **Sim (next tick after action arrives)**: rewind the
   *shooter's* position to `fired_at_tick`, spawn an authoritative
   projectile at that origin + direction. From there it advances
   normally. Targets are *not* rewound — they advance at their
   own sim rate.
4. **Client (when impact delta arrives)**: replace local visual
   projectile with the authoritative one, show impact FX.

Why this works for projectiles where it wouldn't for hitscan:

- Hitscan: shooter fires at T, target was at position P at T (as
  shooter saw), server processes at T+ping/2 with target now at
  position Q. Server must rewind to ask "where was target at T?"
- Projectile: shooter fires at T, server processes at T+ping/2 by
  spawning bullet at shooter's-position-at-T. From there bullet
  flight time (say 150 ms) is typically larger than ping (say 80
  ms), so the bullet's travel covers most of the timing
  discrepancy. Target moves during flight; bullet hits where it
  hits. **The shot feels honest because the bullet is a real
  thing in the world, not an instant verdict.**

### 6.3 Edge case: very close range

At point-blank (bullet travel <50 ms) projectile flight is
shorter than typical ping. Target rewind helps here. Approach:
keep a small per-NPC position ring buffer (last 4-8 ticks =
200-400 ms) on the sim side. For point-blank projectiles,
optionally test collision against the rewound target position at
spawn tick, in addition to the live position each subsequent tick.

Tunable threshold: if `bullet_travel_estimate < min_travel`, use
spawn-tick rewind; otherwise advance-normally. Constant deferred
to first impl pass.

### 6.4 Projectile interpolation on render

Same lerp as NPCs. `ProjectileSnapshot::pos` between consecutive
snapshots, interpolated by frame alpha. Muzzle-flash and impact
FX fire on `RenderDelta::ProjectileSpawned` / `ProjectileImpact`,
not on snapshot interpolation.

---

## 7. Multi-region + 12-player scaling

The 12-player target (from
[`multiplayer-alife-plan.md`](multiplayer-alife-plan.md)) implies
up to 12 simultaneously active (online) regions. At our current
~1000 NPCs per region, that's 12,000 online NPCs. The current
single-thread per-tick budget of ~25 ms does not absorb that.

### 7.1 The arithmetic

For 60 FPS render (16.67 ms budget), sim tick can be anything as
long as render isn't blocked. Sim tick budget is 50 ms (20 Hz). At
12,000 online NPCs the budget is **4 µs per NPC per tick** — fine
for trivial maintenance, brutal for anything per-NPC that touches
a hashmap or runs A*.

Options for closing the gap:

1. **Within-region distance LOD.** NPCs >~500 m from any player
   downgrade to cheaper per-tick work: skip combat, skip
   perception updates, run pathfinding on a slower cadence,
   freeze if no urgency. This is a separate plan (`distance-lod-plan.md`,
   to be written). Compatible with the threaded model — distance-
   tier is a per-NPC component the schedule reads.
2. **Per-region parallelism.** Each region's hot systems can run
   on its own thread. Cross-region dependencies are rare (portal
   transitions, world event bus events with global audiences) and
   can be processed sequentially after the per-region work
   completes. With 12 regions and 8 cores, ~1.5 regions per core
   = ~7 ms per-region budget at 50 ms total. Achievable for the
   per-NPC pass.
3. **Larger sim tick interval at peak load.** Drop from 20 Hz to
   15 Hz or 10 Hz when active-region count is high. Render
   interpolation masks the lower rate up to a point — players
   don't notice 15 Hz movement-only updates. Combat
   responsiveness suffers, so this is a graceful-degradation
   knob, not a default.

### 7.2 Recommended sequencing for this part

The threaded-sim PR itself does **not** need to ship per-region
parallelism; it should ship correct snapshot publishing + lerp at
the current single-core sim cost. Per-region parallelism is a
follow-up PR once the threading scaffold is in place. The plan
needs to **not paint itself into a corner** that prevents adding
parallelism later — see §10 open questions.

### 7.3 Offline tier on the same worker

The offline tier ([`offline-tier-plan.md`](offline-tier-plan.md))
runs alongside online tier on the same sim worker thread. It's
much cheaper per NPC (no per-tick A*, no per-tick perception, dice
resolution for combat). Whatever the threading model is, offline
NPCs ride along the same schedule with a different code path.

---

## 8. Data flow + ownership

### 8.1 Who owns `World`

The sim worker owns the `bevy_ecs::World`. Main thread never
touches it. All reads go through snapshots; all writes go through
the action channel.

This is the load-bearing simplification: no shared mutable state.

### 8.2 Action channel discipline

`ActionKind` is the existing enum (already used for net relay).
Extended with whatever the main thread needs to communicate.
Single producer (main thread), single consumer (sim worker), so a
SPSC channel is fine — `crossbeam::queue::ArrayQueue` or
`crossbeam_channel::bounded`.

```rust
pub enum ActionKind {
    // existing variants ...
    MovePlayer { steam_id: u64, pos: [f32;3], yaw: f32 },
    Shoot { steam_id: u64, origin: [f32;3], dir: [f32;3], fired_at_tick: u64, kind: ProjectileKind },
    ApplyBandage { steam_id: u64, part: BodyPart },
    // ...
    // New action for region change requests
    EnterRegion { steam_id: u64, region: RegionId },
    // Debug: one-off inspector query
    QueryNpcView { id: NpcId, reply: SyncReplyHandle },
}
```

Most actions are fire-and-forget; some (inspector / debug) need a
reply channel attached to the action.

### 8.3 Determinism

The action channel is FIFO. Sim drains all available actions at
the start of each tick, in order received. Actions from network
peers arrive on the same channel after `simn-net` processes them.

For network determinism (required for replay + replication), the
sim's tick processes actions in a deterministic order *within* a
tick — sort by `(action_arrival_tick, steam_id, action_seq)`
before applying. The existing `apply_action` machinery already
gives us this; the channel layer just delivers the actions.

---

## 9. Lifecycle

### 9.1 Startup

```rust
let (action_tx, action_rx) = crossbeam_channel::bounded(64);
let (snap_tx, snap_rx) = crossbeam_channel::bounded(2);
let sim_handle = std::thread::Builder::new()
    .name("simn-sim".into())
    .spawn(move || run_sim_loop(action_rx, snap_tx))
    .unwrap();
```

`run_sim_loop` is the fixed-timestep loop: drain inbound actions,
`sim.tick()`, publish snapshot, sleep until next deadline. Loop
exits when it receives a `Shutdown` action.

### 9.2 Shutdown

Main thread sends `ActionKind::Shutdown` when the player quits.
Sim worker finishes its current tick, runs `sim.shutdown()`
(saves snapshot + flushes journal), then exits. Main thread
joins the thread handle.

Joiner runs through Godot's normal `_exit_tree` lifecycle, so the
worker drains within a few hundred ms.

### 9.3 Mode switches

Solo → Coop-host: sim already running; `simn-net` starts publishing
deltas to peers. No sim restart.

Coop-host → Solo: stop net, sim keeps ticking.

Region change: just an action. Sim updates `ActiveRegions`; on next
snapshot the renderer sees the new region's NPCs / removes the
old's.

---

## 10. Open questions

1. **Snapshot allocation overhead.** Even with bounded channel +
   capacity 2, every snapshot allocates a `Vec<NpcSnapshot>`.
   Worst case 12,000 NPCs × 32 bytes × 20 Hz = ~7.5 MB/s churn.
   Triple-buffer with reused storage avoids this. Defer until
   profile shows it matters.

2. **Per-region parallelism interaction with global state.** The
   schedule has resources every system touches (`SquadObjectives`,
   `SquadBlackboards`, `PendingDeltas`, …). True per-region
   parallelism requires resources scoped to a region (per-region
   `SquadBlackboards`, etc.) or careful serialization at the
   global boundaries. Out of scope for the threaded-sim PR but
   the design must not block it.

3. **Joining clients and snapshot resync.** Today mirror clients
   apply external snapshots via `Sim::apply_external_snapshot`.
   That's a sim mutation, so it has to come in through the action
   channel. Design `ActionKind::ApplyExternalSnapshot(SnapshotBody)`
   — needs care to avoid blocking the action channel with a big
   payload.

4. **Inspector / debug overlay queries.** Need a sync reply
   mechanism. Either:
   - Small reply channels attached to specific actions (per-query
     one-off `crossbeam_channel::bounded(1)`).
   - A separate "control" channel for synchronous debugging
     operations.
   Pick one; the former is simpler.

5. **Tick rate degradation under load.** When sim falls behind
   (say, hits 12 active regions and per-tick cost climbs above
   50 ms), do we (a) drop to 15 Hz transparently, (b) skip ticks
   and apply double-time on the next, or (c) keep ticking at
   real-cost rate? Each has different observable behavior. Lean
   (a) — fixed-but-lower rate is the smoothest visually.

6. **Save / load locking.** `Sim::shutdown` writes a snapshot. If
   the main thread requests a save mid-session (e.g. user clicks
   "Save Now" in a future menu), how does that synchronize with
   the sim worker's ongoing ticks? Either: queue
   `ActionKind::SaveNow { reply: handle }` and have the sim
   handle the save inline at the start of its next tick. Avoids
   any shared-state coordination.

7. **Hot-reload / mod manager**. Some future systems will want to
   reload TOML data at runtime (factions, items, recipes). With
   threaded sim that's an action sent to the worker. Loaders
   that touch global state need careful boundaries.

---

## 11. Out of scope

- Cross-platform determinism (handled by `sim-hardening-plan.md` §2
  determinism harness — same-platform tested today; cross-platform
  is a separate problem).
- Implementing the offline tier itself (that's
  [`offline-tier-plan.md`](offline-tier-plan.md)).
- Distance-LOD within active regions (a future plan doc; this plan
  just makes sure the threading model doesn't preclude it).
- Per-region parallelism (this plan ships single-threaded sim
  worker; per-region parallelism is a follow-up PR).
- Dedicated server binary (already a separate plan,
  [`physics-backend-plan.md`](physics-backend-plan.md); becomes
  trivial once this lands).
- GPU compute for sim work (not currently needed; revisit if CPU
  budget tops out).

---

## 12. Dependencies

- **Blocks:** the 60 FPS goal at production population. Every
  further sim optimization is bounded by the single-thread limit
  without this.
- **Blocked by:** nothing concrete. Could land any time. Best
  done from a known-good single-thread baseline so regressions
  are easy to bisect.
- **Companions:**
  [`offline-tier-plan.md`](offline-tier-plan.md),
  [`multiplayer-alife-plan.md`](multiplayer-alife-plan.md),
  [`physical-combat-plan.md`](physical-combat-plan.md),
  [`tier-transition-plan.md`](tier-transition-plan.md).

---

## 13. Rollout plan (when implementation starts)

A future PR series, sketched:

1. **PR A — snapshot publishing scaffold**. Sim still runs on main
   thread; introduce `SimSnapshot`, publish from a hook in
   `Sim::tick`, expose `read_snapshot_pair()` from gdext. No
   behavior change yet; this just builds the data path.
2. **PR B — render-side lerp**. `_sync_npc_dummies` consumes the
   snapshot pair, lerps. Verify smooth visual motion at the
   current single-thread sim cost. NPCs render off the snapshot;
   `npcs_near` API stays but is no longer hot-path.
3. **PR C — move sim onto worker thread**. The cut-over. Action
   channel for inputs, sim loop on its own thread. Save / load
   pathway goes through action channel. Mirror sim follows the
   same model.
4. **PR D — projectile lerp + lag-compensated spawn**. Implement
   the §6 projectile model: client visual + authoritative spawn
   with shooter rewind.
5. **PR E — per-region parallelism (optional later)**. Once
   single-region-on-its-own-thread is stable, look at parallel
   per-region scheduling. Probably needs `SquadObjectives` /
   `SquadBlackboards` / etc. to become region-scoped.

Each PR is independently testable. Reverting any one of them does
not break the previous.
