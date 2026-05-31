# API Reference

The GDScript-facing surface exported by `simn-godot` (the only crate
that depends on `godot`). Four `GodotClass` types live here, each
documented in its own chapter:

| Class | Purpose |
|---|---|
| [`SimHost`](sim-host.md) | Owns the `simn_sim::Sim`, ticks it each frame, exposes the full simulation surface to GDScript (players, combat, wounds, drugs, inventory, world state, NPCs, chronicle, replication). |
| [`NetworkManager`](network-manager.md) | Steam P2P session manager. Hosts / joins lobbies, broadcasts snapshots + deltas + actions for host-authoritative replication (slice 1). |
| [`TerrainNode`](terrain-node.md) | `StaticBody3D` subclass that loads a canonical `.r16` heightmap and materializes it as an `ArrayMesh` + `HeightMapShape3D`. |
| [`PhysicsSetup`](physics-setup.md) | Runtime trimesh collision builder for static props. Caches shapes per-mesh. |

## Conventions

These conventions hold across every class in this reference. Read
them once so each method page can stay terse.

### Steam IDs

All `steam_id` parameters are declared `int` (Godot's `i64`) but
Steam IDs are inherently unsigned `u64` on the Rust side. Internally
`SimHost` / `NetworkManager` cast with `i64 as u64`. Don't pass
negative values - Steam IDs are always positive. The solo-mode
synthetic ID is `0xDEADBEEF`.

### String enums

Many methods take a `String` that must match a known enum variant.
Casing is always `snake_case`. Every enum listed below has a
discovery method on `SimHost` that returns the valid strings:

| Domain | Enum | Discovery |
|---|---|---|
| Weather | `"clear"` / `"partly_cloudy"` / … | `all_weather_types()` |
| Faction | `"pwa"` / `"linemen"` / … | `all_factions()` |
| Region | `"map_a"` / `"map_b"` / … | `all_regions()` |
| Body part | `"head"` / `"torso"` / `"left_arm"` / `"right_arm"` / `"left_leg"` / `"right_leg"` | *(enumerated in this doc)* |
| Drug | `"painkiller"` / `"morphine"` / `"adrenaline"` / `"stim_cocktail"` / `"anti_rad"` / `"anti_tox"` (aliases: `"stim"`, `"antirad"`, `"antitox"`) | *(enumerated)* |
| Food | `"preserved_ration"` / `"fresh_food"` / `"raw_meat"` / `"cooked_meat"` / `"contaminated_food"` / `"field_ration"` / `"energy_bar"` | *(enumerated)* |
| Water | `"dirty_water"` / `"clean_water"` / `"energy_drink"` / `"vodka"` | *(enumerated)* |
| Survival stat | `"hunger"` / `"thirst"` / `"fatigue"` | *(enumerated)* |

Passing an unrecognized string to a mutation method is a no-op + logs
a `godot_error!`; passing one to a query method returns an empty
dictionary / array.

### Error handling

Slice-1 has two patterns:

- **`bool` return**: `grant_item`, `drop_slot`, `move_slot`,
  `consume_slot`, `salvage_slot`, `craft_recipe`, `set_near_campfire`,
  `apply_drug`. Return value is `true` on success, `false` on failure
  (item not found, slot out of range, tolerance too high, etc.). The
  underlying error is also logged to `godot_error!` - the return value
  is your primary signal.
- **Void return**: most others. Errors go to `godot_error!` only;
  the caller can't observe success/failure from the return. Treat these
  as fire-and-forget. If you need to check outcomes, read
  `player_state()` before/after.
- **`sim_error(message)` signal**: fatal sim errors (schedule crash,
  journal write failure). Emitted once, ends the current session.

Unifying these is a post-slice-1 cleanup (see `TODO.md`). The
reference documents current behavior as-shipped.

### Replication role gating

Every mutation method on `SimHost` checks `NetworkManager.role()`
before touching the sim:

- **Solo / Host**: mutates the local authoritative sim directly.
- **Client**: encodes the call as a `Msg::Action` and forwards to
  the host. The host dispatches, broadcasts the resulting delta,
  and the client's mirror sim applies it. Local state changes
  with one RTT of lag.

The contract for GDScript callers is identical in all three roles -
you call `sim.apply_bandage(sid, "torso")` the same way regardless.
`SimHost` + `NetworkManager` handle the routing.

### Per-run save isolation

`SimHost.start(save_dir)` takes an absolute path. The Godot shell's
`GameSession.solo(run_id)` / `host(run_id)` construct
`user://saves/<run_id>/` and pass it through; joining clients call
`SimHost.start_mirror()` instead (no disk). See
[Runs & saves walkthrough](../../../../walkthrough/runs-and-saves.md).

## Related

- `docs/book/src/architecture/crate-guide.md` - architectural
  overview of each crate, with the relationships between `simn-sim`,
  `simn-net`, `simn-godot`.
- `docs/book/src/architecture/networking.md` - slice-1 replication
  contract (role model, wire protocol, snapshot handshake, action
  relay).
- `docs/walkthrough/sim.md` - how the sim's data model +
  persistence + tick loop fit together. The *reason* for the API
  surface documented here.
