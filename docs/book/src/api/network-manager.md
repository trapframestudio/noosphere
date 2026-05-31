# NetworkManager

`class NetworkManager extends Node`

Steam P2P session manager. Owns the lobby, the peer table, and the
send/receive surface for slice-1 replication. Pumps Steam
callbacks each frame in `process()` and translates `simn_net::NetEvent`
values into Godot signals.

Typical usage: one `NetworkManager` autoload node (`scenes/session_root.tscn`).
Lazy-initializes Steam on the first `host_session` / `join_session`
call.

**Source:** `crates/simn-godot/src/network.rs`

---

## Signals

### `peer_joined(steam_id: int)`

A remote peer joined the lobby.

### `peer_left(steam_id: int)`

A remote peer disconnected.

### `peer_state(steam_id: int, map_id: String, pos: Vector3, yaw: float)`

Remote peer's pill transform update (legacy unreliable 20Hz path).

### `lobby_ready(lobby_id: int)`

Lobby created (host) or joined (client).

### `join_requested(lobby_id: int)`

Steam overlay triggered a join request - friend clicked an invite
link. `GameSession` calls `join_session(lobby_id)` in response.

### `network_error(message: String)`

Non-fatal network error (Steam init failure, lobby create failure,
etc.).

### `snapshot_requested(peer_steam_id: int)`

Host-side: a peer sent `Msg::JoinRequest`. GDScript handler should
call `SimHost.serialize_snapshot_payload()` + `send_snapshot(peer, tick, payload)`.

### `snapshot_received(tick: int, payload: PackedByteArray)`

Client-side: host sent a snapshot. `payload` is bincoded
`SnapshotBody`. Forward to `SimHost.apply_network_snapshot`.

### `delta_received(tick: int, payload: PackedByteArray)`

Client-side: host broadcast a per-tick delta batch. Forward to
`SimHost.apply_network_delta_batch`.

### `action_received(peer_steam_id: int, steam_id: int, payload: PackedByteArray)`

Host-side: a peer sent an action. `peer_steam_id` is the sender;
`steam_id` is the acting player (same in slice 1). Forward to
`SimHost.dispatch_network_action(steam_id, payload)`.

---

## Session

### `func host_session() -> void`

Create a Steam lobby, become host. Emits `lobby_ready(lobby_id)`
when ready. Flips role to `"host"` immediately.

Fails with `network_error` if Steam isn't running.

### `func join_session(lobby_id: int) -> void`

Join an existing lobby by id. Flips role to `"client"` after the
lobby membership resolves.

### `func open_invite_overlay() -> void`

Open the Steam friends overlay invite dialog. No-op if no lobby is
active or the game wasn't launched through Steam.

### `func publish_state(map_id: String, pos: Vector3, yaw: float) -> void`

Publish the local player's legacy transform (unreliable, 20Hz rate
limit applied session-side). Used by the pill-lerp path.

### `func local_steam_id() -> int`

The local user's Steam ID. Returns `0` if Steam isn't initialized
(e.g., solo mode).

---

## Role (slice 1)

### `func role() -> String`

Local role. Returns `"solo"`, `"host"`, or `"client"`. Defaults
to `"solo"` before any `host_session` / `join_session` call.

### `func host_steam_id() -> int`

The host's Steam ID when in `"client"` role; `0` otherwise.

### `func is_authoritative() -> bool`

`true` when the local sim is authoritative (solo or host).

---

## Replication send surface (slice 1)

All of the following use Steam's reliable ordered channel (via
`Msg::reliability()`).

### `func broadcast_snapshot(tick: int, payload: PackedByteArray) -> void`

Host-side: send a snapshot to every peer in the lobby. Rare -
typically only after a state-altering debug command.

### `func broadcast_delta(tick: int, payload: PackedByteArray) -> void`

Host-side: send a per-tick delta batch to every peer. Called every
frame by `GameSession._on_sim_tick_completed`.

### `func send_snapshot(peer_steam_id: int, tick: int, payload: PackedByteArray) -> void`

Host-side direct send to a single peer. Used in response to
`snapshot_requested` - reply to the peer who asked rather than
broadcasting to everyone.

### `func send_action(acting_steam_id: int, payload: PackedByteArray) -> void`

Client-side: send an encoded `ActionKind` to the host. `payload` is
the bincoded action. No-op on non-client roles.

### `func send_join_request() -> bool`

Client-side: send `Msg::JoinRequest` to the host. Called after
`lobby_ready` when the local role is `"client"`. Returns `false`
on non-client roles.
