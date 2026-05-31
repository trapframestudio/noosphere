# Networking - sim/net slice 1

> **Update (slice 1 shipped).** The walking-skeleton narrative below
> is preserved as historical context. Current architecture is
> **host-authoritative listen-server** - one peer runs the canonical
> sim and saves, others run mirror sims that consume snapshots +
> deltas. Action relay funnels client-initiated mutations to the
> host. See `../architecture/networking.md` for the
> slice-1 contract and `runs-and-saves.md` for the
> per-run save flow.
>
> What changed vs the walking-skeleton below:
>
> - `Msg` has four new variants beyond `State`: `Snapshot`, `Delta`,
>   `JoinRequest`, `Action`. Reliability class picked per
>   `Msg::reliability()`.
> - `NetSession` now has a `NetRole` field (`Solo` / `Host` /
>   `Client { host_steam_id }`) set by `host()` / `join()`.
> - `Sim::new_mirror(graph)` builds a sim without disk persistence
>   or NPC-mutating systems. `apply_external_snapshot` +
>   `apply_external_delta` let the host's state flow into the mirror.
> - `Sim::apply_action` dispatches client-sent `ActionKind` variants
>   to the corresponding mutation method (bandage, eat, consume,
>   craft, ...).
> - `SimHost` checks role on every mutation `#[func]`; client-side
>   calls encode an `ActionKind` and emit `action_requested` instead
>   of mutating locally. `GameSession` forwards via
>   `NetworkManager.send_action`.
> - Per-run saves: solo + coop-host runs each live in
>   `user://saves/<run_id>/`; `SavePaths::in_run_dir(root, run_id)`
>   is the helper. Joining clients don't save.

## Three layers

```
GDScript  →  NetworkManager (gdext)  →  NetSession (simn-net)  →  Steam
```

Left talks to right through a thin, intentional boundary. The pure-Rust
layer owns all Steam state; the gdext layer is a dumb signal bridge;
GDScript owns scene/player/UI.

## simn-net (engine-agnostic)

`NetSession::init()` calls `steamworks::Client::init()`, which reads
`steam_appid.txt` (contains `480`, Valve's public Spacewar test app)
from CWD and authenticates against the running Steam client. You get
back a `Client` handle and a `SingleClient` - the latter exists because
Steam's callback pump isn't thread-safe and must be driven from a
single thread.

`init()` also registers three callbacks and keeps the `CallbackHandle`s
alive in the session (Steam's API drops callbacks if the handle is
freed):

- **`LobbyChatUpdate`** - member joined/left bitflags decoded into
  `PeerJoined` / `PeerLeft` events.
- **`P2PSessionRequest`** - auto-accepted. Lobby membership is our
  access-control boundary; if you're in the lobby, you can talk to us.
- **`GameLobbyJoinRequested`** - fires when Steam hands us a lobby ID
  via the overlay or a `steam://joinlobby/...` link. Converts to a
  `JoinRequested` event.

Events are pushed into an `Arc<Mutex<Vec<NetEvent>>>` and drained by
`tick()` every frame.

`host()` calls `matchmaking().create_lobby(FriendsOnly, 4, cb)`. The
Steam async call-result goes to `cb`, which pushes a
`LobbyReady { lobby_id }` event. `join()` does the same with
`join_lobby`.

Every `tick()`:

1. `single.run_callbacks()` - pumps Steam's callback queue.
2. Drain incoming packets: `is_p2p_packet_available()` →
   `read_p2p_packet()` → `bincode::deserialize` into a
   `Msg::State { map_id, pos, yaw }` → push a `PeerState` event.
   Self-packets are filtered.
3. Refresh peer list from `lobby_members()`.
4. If ≥50ms since last broadcast and local state is dirty, serialize
   our own `Msg::State` and `send_p2p_packet(peer, Unreliable, bytes)`
   to everyone in the lobby. 20Hz rate, unreliable - fine for
   transforms, state converges on the next tick anyway.
5. Return accumulated events as a `Vec<NetEvent>`.

## simn-godot (the bridge)

`NetworkManager` is a `GodotClass` with `base=Node`. Its `process()`
impl calls `session.tick()` and translates each `NetEvent` into a Godot
signal via `base_mut().emit_signal(...)`. `#[func]` methods
(`host_session`, `join_session`, `publish_state`, `open_invite_overlay`)
are panic-free: they wrap the underlying call and emit `network_error`
on failure.

`ensure_session()` does lazy Steam init on first host/join - so
launching the game without clicking anything doesn't require Steam to
be up.

The `build.rs` does one load-bearing thing: it walks up from `OUT_DIR`
to `target/<profile>/build/`, finds `steamworks-sys-*/out/libsteam_api.so`,
and copies it next to `libsimn_godot.so`. Combined with
`rustc-link-arg=-Wl,-rpath,$ORIGIN` on the cdylib, the runtime loader
finds `libsteam_api.so` by looking next to the library that needed it.
Without this, Godot fails to load the extension on startup.

## GDScript orchestration

`GameSession` is an autoload (`/root/GameSession`) with a
`NetworkManager` child, wired via `project.godot`'s `[autoload]`
section. It owns the current map scene, the local player, and a dict
of remote pills keyed by Steam ID.

**Key idea: the session doesn't know about scenes, and the scene
hierarchy doesn't know about the session.** Decoupled via the `map_id`
string.

`_physics_process` reads the local player's `global_position` and
`rotation.y` every frame and calls
`NetworkManager.publish_state(current_map_id, pos, yaw)`. `simn-net`
rate-limits that internally.

On `peer_state(steam_id, map_id, pos, yaw)`:

- If `map_id == _current_map_id`: spawn a `remote_pill.tscn` at that
  position, or update its target if it's already spawned.
- Else: free the remote-pill node if present, but keep the peer's
  last-known state in `_peer_last_state` so we can resurrect the pill
  if the local player transitions to their map.

The `remote_pill.gd` script smooths the 20Hz updates with a `lerp`
against the target at 12 units/sec, so pills glide instead of
teleporting.

`transition_cube.gd` is an `Area3D` with `body_entered` →
`GameSession.request_map_change(target_map)`. Bodies tagged
`local_player` only (remote pills can't trigger transitions).
`request_map_change` frees the current map node (which cascades all
remote pills as children), loads the new `.tscn`, reparents to `/root`,
spawns the local player at the `PlayerSpawn` marker, and walks
`_peer_last_state` to re-instantiate any pills for peers who were
already on that map.

## Invite flow (two paths)

**Overlay path** (only works when Steam launched the game):
`host_session()` → Steam creates lobby → `LobbyReady` → GDScript calls
`open_invite_overlay()` → Steam renders the friends list overlay on top
of Godot's window → friend clicks Invite → Steam routes
`GameLobbyJoinRequested` to their game → `JoinRequested` event →
`GameSession.join(lobby_id)`.

**Lobby-ID fallback** (dev runs): `LobbyReady` → `GameSession` emits
`lobby_id_changed` → the main menu's status line shows the ID and the
`steam://joinlobby/480/<id>/<host>` link, and
`DisplayServer.clipboard_set()` puts the ID on the clipboard. The
other player pastes it into either the server browser's **Join by
Lobby ID** input or the launcher dev panel's (`` ` ``) join field
and clicks Join. Bypasses the overlay entirely.

## Cross-platform builds

Linux is native Cargo. Windows is `cargo-xwin`: it targets
`x86_64-pc-windows-msvc` and uses a cached MSVC CRT from
`~/.cache/cargo-xwin/` instead of needing MSVC installed. This works
because `steamworks-sys` ships `steam_api64.lib` in MSVC format, which
the `-msvc` Rust target links against directly. (MinGW wouldn't work -
COFF vs ELF/DWARF mismatch on the Steam import library.)

`scripts/package-release.sh` does: cargo build → copy `simn_godot.{so,dll}`
\+ `{libsteam_api.so,steam_api64.dll}` into `godot/bin/{linux,windows}/`
→ `godot --headless --export-release` for each preset → bundle with
`steam_appid.txt` → zip.

The `.gdextension` has different paths for dev vs release:
`res://../target/debug/...` for local dev (library lives in the cargo
target dir), `res://bin/<platform>/...` for exported builds (library
gets packaged inside the .pck). The `[dependencies]` section tells
Godot to also bundle `libsteam_api.so` / `steam_api64.dll` into the
export, so the user only has to deal with one folder.

## What's deferred past slice 1

The slice-1 header at the top of this file is the current contract:
host-authoritative sim, snapshot + delta replication, action relay,
per-run saves. Remaining deferrals:

- **No client-side prediction / reconciliation.** Own-transform
  movement feels laggy by one RTT today because every client move
  goes through the host. Slice 2 adds local-echo prediction +
  host-correction rollback. `remote_pill.gd` still does lerp
  smoothing for peers - that's fine at slice-1 fidelity.
- **No per-region delta subscription.** Clients receive every delta
  the host broadcasts, even NPC position batches from regions they
  can't see. Slice 2 filters by recipient's region - required
  before bumping the lobby cap.
- **4-player cap.** `simn_net::MAX_LOBBY_MEMBERS = 4`. Slice 2
  raises to 12 after profiling slice-1 bandwidth under load.
- **No input validation.** The host trusts every `ActionKind` from
  every peer (any peer could claim to be moving any player).
  Slice 3.
- **No host migration.** If the host quits, clients are kicked.
  Handing authority to another peer mid-session is later polish.
- **No dedicated server.** `simn-net` + `simn-sim` are
  engine-agnostic so a headless entry point is possible, but no
  binary yet.
- **AppID 480.** Using Spacewar means anyone else using 480 shows
  up in public lobby searches. We're on `FriendsOnly` so it's fine
  for dev, but a real appid is required before shipping.
