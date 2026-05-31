# Networking

> **Status:** Slice 1 of host-authoritative replication is live. One
> peer is the `Host` (runs the authoritative sim, owns the save),
> others are `Client`s running a mirror sim that consumes host
> snapshots + deltas. Action relay wires client-initiated mutations
> (bandage, consume item, craft, ...) to the host. 4-player cap stays
> until slice 2 bumps it after profiling.

## Architecture

The networking core lives in `simn-net` (pure Rust, no `godot` dep).
The Godot integration is a `NetworkManager` node exported by
`simn-godot` and wired to `GameSession` via signals.

```
GDScript (game_session.gd)
        │  solo(run_id) / host(run_id) / join(lobby_id)
        ▼
NetworkManager  ──┐           SimHost  (simn-godot)
   (simn-godot)   │              │
        │         │  attach_network()  (role queries + broadcast)
        ▼         ▼              ▼
NetSession    (simn-net)       Sim  (simn-sim)
        │                        │
        ▼                        ▼
Steam P2P / lobby            journal + snapshot
```

### Role model

`NetRole` (in `simn-net`) is one of:

- **`Solo`** - no lobby; the local sim is trivially authoritative.
- **`Host`** - created the lobby; this peer's sim is the canonical
  state for everyone. Saves to `user://saves/<run_id>/`.
- **`Client { host_steam_id }`** - joined someone else's lobby;
  runs a **mirror** sim (no disk, no NPC-mutating systems) that
  consumes snapshots + deltas from the host.

Role is exposed to GDScript via `NetworkManager.role()` (returns
`"solo" | "host" | "client"`) and to SimHost via
`NetworkManager::current_role()` (Rust-side, type-safe).

### Wire protocol

All messages `bincode`-encoded. Reliability class per
`Msg::reliability()`:

| Variant | Direction | Reliability | Payload |
|---|---|---|---|
| `State { map_id, pos, yaw }` | any → any | unreliable 20Hz | legacy pill-lerp path |
| `Snapshot { tick, payload }` | host → client | reliable | bincoded `SnapshotBody` |
| `Delta { tick, payload }` | host → clients | reliable ordered | bincoded `Vec<WorldDelta>` |
| `JoinRequest` | client → host | reliable | (empty) |
| `Action { steam_id, payload }` | client → host | reliable | bincoded `ActionKind` |

`Snapshot` / `Delta` / `Action` payloads are opaque `Vec<u8>` at the
network layer - `simn-net` stays ignorant of sim types. Serialization
happens in `simn-sim` (see `serialize_snapshot_body`, `drain_tick_deltas`,
`action::encode_action` / `decode_action`).

### Snapshot handshake

1. Client joins lobby → Steam lobby ready fires.
2. Client sees its role is `Client` → sends `Msg::JoinRequest`.
3. Host receives `JoinRequest` → serializes current sim state
   (`Sim::serialize_snapshot_body`) → sends `Msg::Snapshot` directly
   to that peer (not broadcast).
4. Client applies snapshot (`Sim::apply_external_snapshot`) →
   `snapshot_applied` signal fires on `SimHost` → `GameSession`
   loads the region scene for the local player's position.
5. All subsequent deltas from host apply normally.

### Tick broadcast loop

Each host frame:

1. `Sim::tick()` runs the schedule and journals mutations via
   `record_delta` (which both appends to disk and buffers in
   `last_tick_deltas`).
2. `SimHost::process` drains the buffer at the end of the frame and
   emits the `tick_completed(tick, payload)` signal.
3. `GameSession._on_sim_tick_completed` → `NetworkManager.broadcast_delta`
   → reliable Steam send to every lobby peer.

Clients receive → `NetworkManager` emits `delta_received(tick, payload)`
→ `GameSession._on_delta_received` → `SimHost.apply_network_delta_batch`
→ the existing `apply_delta` free function is called per delta and
the mirror's clock is anchored to the host's tick.

### Action relay

Client-initiated mutations (bandage, eat, consume slot, craft, drop,
move, salvage, set-campfire, drug, movement, region-change) go
through the same `#[func]` methods on `SimHost` they would in solo
play, but the method body checks the role first. On `Client` role,
it encodes an `ActionKind` and emits `action_requested(steam_id, payload)`;
`GameSession` forwards via `NetworkManager.send_action` → `Msg::Action`
to the host.

The host receives → `NetworkManager` emits `action_received` →
`GameSession` calls `SimHost.dispatch_network_action` →
`Sim::apply_action` → matches the enum variant and calls the matching
existing mutation method. Deltas produced by the method broadcast
back to everyone via the normal tick path.

This means **clients are first-class gameplay participants** - they
can bandage their own wounds, eat food, craft, etc. - without running
local mutations that would diverge from the host. One round-trip of
latency per action is the trade-off; slice 2 adds client-side
prediction for movement and treatment actions.

### NPC position sync

NPC movement systems (`tick_npc_goals`, `npc_migrate`, `squad_planner`,
etc.) use per-tick RNG seeds that mix in `Entity::to_bits()`. Because
bevy_ecs entity ids aren't stable across sim instances, running those
systems on the client mirror would produce different NPC targets /
objectives than the host. So the mirror schedule **omits all
NPC-mutating systems**, and the host's authoritative schedule includes
`broadcast_npc_positions` - a system that emits one
`WorldDelta::NpcPositionBatch` per tick carrying every live NPC's
`(id, pos, yaw)`. The client's `apply_delta` updates ECS positions
in place.

Bandwidth: at 20Hz × 50 NPCs × ~32 bytes per entry ≈ 32 KB/s per
client in slice 1. Slice 2 layers per-region subscription so
clients only receive batches for the region they're in.

### Per-run save isolation

Solo + coop-host runs each have a named entry in `RunsStore`
(`user://runs.json`). Each run keys to a save directory:

```
user://saves/<run_id>/world.save
user://saves/<run_id>/world.journal
```

`GameSession.solo(run_id)` and `host(run_id)` thread the id through
to `SimHost.start(save_dir)`. Deleting a run from the runs screen
nukes both the metadata entry and the save directory (via
`RunsStore.remove(id)` → `_remove_recursive`).

Joining clients **don't use any local save** - their mirror sim has
no disk path and runs `Sim::new_mirror(graph)` which omits the
journal writer entirely. The test `mirror_sim_no_disk_writes` in
`crates/simn-sim/tests/network_replay.rs` guards against this
accidentally reverting.

## Test maps

`scenes/test/test_map_1.tscn` (map_a) through `test_map_4.tscn`
(map_d). Each has a `PlayerSpawn` marker and transition cubes
(`scripts/transition_cube.gd`) that call `GameSession.request_map_change`.
With the slice-1 role model, a client calling `request_map_change`
emits an `ActionKind::ChangeRegion` to the host; the host's sim
updates, the `ChangePlayerRegion` delta broadcasts, and the client
loads the scene after receiving the delta.

## Out of scope - deferred to slice 2+

- **Client-side prediction + reconciliation.** Movement feels laggy
  by one RTT today. Slice 2 adds local-echo prediction with
  host-correction rollback for the local player's own transform.
- **Per-region delta subscription.** Every client currently receives
  every delta, even from regions they can't see. Slice 2 filters
  `NpcPositionBatch` and player-move deltas by the recipient's
  region.
- **12-player cap.** Slice 1 stays at 4. Slice 2 bumps `MAX_LOBBY_MEMBERS`
  after we profile delta volume + bandwidth under load.
- **Input validation + anti-cheat.** Slice 3. Host currently trusts
  every `ActionKind` from every peer.
- **Host migration.** If the host quits, clients are kicked. Handing
  authority to another peer mid-session is later polish.
- **Reconnect / resume mid-session.** Disconnected clients rejoin
  and get a fresh snapshot; their character state is whatever the
  host's sim has kept.
- **Dedicated server binary.** `simn-sim` is engine-agnostic so a
  headless `main.rs` that runs the authoritative sim without Godot
  is possible - slice 2 adds the entry point if we need it. See the
  planned `simn-server` crate in `../planning/physics-backend-plan.md`.
- **Reactive physics replication.** Tier 2 physics bodies (debris,
  flung props, gib chunks from destruction) use a priority-based
  per-peer replication budget so the world stays reactive across a
  range of connections. Designed in `../planning/physics-tiering-plan.md`.
  Lands alongside the destruction systems (`../planning/destruction-plan.md`).

## Runtime requirements

- Steam must be running for `NetSession::init` to succeed (Solo
  mode bypasses Steam entirely).
- `libsteam_api.so` must be resolvable next to `libsimn_godot.so` on
  Linux. The `simn-godot` build script copies it from the
  `steamworks-sys` output directory into `target/<profile>/`.
- A `steam_appid.txt` file in the process working directory
  identifies the Steam app. Dev uses Valve's public test appid 480
  (Spacewar).
