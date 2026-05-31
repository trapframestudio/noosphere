# Noosphere

**An openly-developed co-op survival game built in Godot 4 and Rust, made by trapframe. Open-source code (MIT/Apache), original IP, sold on Steam to fund development.**

Noosphere is set in an affected stretch of the Columbia River Gorge, a decade after a
containment event tore the area open and never let it close. The locals call it **the
Valley**. Several factions contest it, reaching into the wound for what it leaks, and
none of them are the good guys.

The mood owes a debt to Roadside Picnic and the survival games that followed it:
patient, quiet, and indifferent to whether you live. The world, the factions, and the
story are original. Noosphere is not a port, a remake, or a reimplementation of
anything.

The engine is Godot 4 with a Rust simulation core through gdext. Dedicated servers
hold up to **12 players** and the host sets the cap (small private crews of 2 to 4, on
up to the full 12). The game is **PvE-first**. PvP is an opt-in server toggle. It is
**not an extraction shooter**, and it runs natively on Linux, Windows, and macOS.

## What we're going for

- **PvE-first co-op** on dedicated servers (up to 12 players, host-configurable, PvP
  opt-in). The Valley is the antagonist, not a backdrop. There is no extraction loop.
  You live in the Valley until you die.
- **No character progression, ever.** Only your gear and your base persist. The one
  thing that compounds is what you know: routes, how the faults behave, faction
  patterns, what each shard does to you.
- **A Valley that runs on its own clock.** The simulation keeps going on the server
  whether anyone is logged in or not, and it does not scale up or down with party size.
- **Participatory horror.** Belief has weight in the Valley: how you behave shifts what
  the world does. Loud, confident players get punished. Quiet, careful ones get through.
- **Modding as a first-class feature**, through documented data formats, scripting
  surfaces, and an SDK from day one.
- **Cross-platform**: Linux, Windows, macOS, Steam Deck.
- **Open-source code**, dual-licensed under MIT or Apache 2.0. Use it for anything,
  commercial or not. The creative IP stays original to trapframe.
- **Openly funded.** A paid, one-time purchase on Steam funds development, and
  contributors share in the revenue (see [Funding Model](project/funding-model.md)).

## Tech stack

| Layer | Technology |
|-------|-----------|
| Engine | Godot 4.6 (rendering, physics, audio, scene system) |
| Rust bindings | gdext (godot-rust) for engine integration |
| UI / scenes | GDScript, hot-reloadable, fast iteration |
| Simulation | Rust crates (`simn-sim`, `simn-common`), engine-agnostic |
| Networking | `simn-net` crate, listen-server P2P over Steam (walking skeleton). Server-authoritative replication is still ahead. |
| Scripting | TBD, weighing GDScript-only against GDScript plus embedded Lua |
| Language | Rust and GDScript |

## Where we are right now

Early development. The Godot 4 and gdext scaffold is up, the workspace is laid out
around the engine-agnostic rule, CI hooks and pre-commit gates are wired up, and the
documentation pipeline builds cleanly.

The vision and design principles live in the [design overview](design/overview.md). Engineering
context and the current architecture live under
[Architecture](architecture/overview.md) and the
[Crate Guide](architecture/crate-guide.md). Narrative deep-dives are in
[Walkthroughs](walkthroughs/README.md). Forward-looking designs are in
[Planning](planning/README.md).
