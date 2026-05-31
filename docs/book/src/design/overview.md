# Design overview

This is the public design north star for Noosphere: what kind of game it is and
the systems it's built on. The detailed system docs live under
[architecture](../architecture/overview.md), [mechanics](../mechanics/inventory.md),
and the [planning](../planning/README.md) chapters. The full creative bible
(world canon, faction history, the setting's secrets) is kept internal.

## What it is

Noosphere is a co-op survival game in the S.T.A.L.K.E.R. lineage, set in an
affected stretch of the Columbia River Gorge a decade after a containment event
tore the area open. You don't raid and leave. You go into the Valley and you
live there, in your base, in forward micro-bases, in safe-houses you fortify and
lose and retake. You survive, or you don't.

Built in Godot 4 with a Rust core (the [SIMN](https://github.com/trapframestudio/simn)
engine) via gdext.

## Design pillars

1. **Valley-first simulation.** The world is the simulation, not a backdrop. AI,
   weather, hazards, factions, and economy run persistently on the server whether
   you're logged in or not.
2. **No character progression, ever.** No levels, skills, or perks. The only
   things that persist are your **gear** and your **base**. The progression that
   actually compounds is *player knowledge*: routes, hazard behavior, faction
   patterns, what the shards do. The world does not scale to you; you get better
   at reading it.
3. **Knowledge is the real loot.** Documents, radio chatter, NPC conversation,
   and environmental storytelling carry the game. A veteran's edge is that they
   know how the world behaves.
4. **Participatory horror.** The world reacts to how you behave in it. Loud,
   reckless play gets punished; quiet, careful play gets through. This is the
   spine of the game.
5. **PvE-first, always.** The Valley is the antagonist, not other players.
   Dedicated servers run up to 12 players; PvP is off by default and a per-server
   opt-in. The balance and narrative target is PvE.
6. **Roleplay-supportive.** Long-haul habitation, in-world voice radio on tunable
   frequencies, persistent bases and micro-bases, hub towns, and no stat sheets
   make a strong RP substrate. Server tooling (custom rules, admin roles,
   world-state backups, named crews) is first-class.
7. **Not an extraction shooter.** No safe-zone lobby, no raid timer, no
   extraction points, no "run" structure. You're in the Valley until your
   character dies. Shards are found, carried, used, stashed, and traded *inside*
   the Valley.
8. **Modding is first-class.** Data-driven config formats designed well from day
   one, with a documented SDK.

## The world's systems (the kept vocabulary)

The setting has its own terms, used throughout the code and docs:

- **The Valley** — the affected region you operate in.
- **Faults** — localized rift pockets; environmental hazard zones with distinct
  behaviors.
- **Squalls** — Valley-wide hazard pulses that periodically sweep the map.
- **Shards** — crystallized leakage; the valuable objects you find, carry, and
  trade.
- **Drifters** — the people who work the Valley (players and NPCs).
- **The Broadcast** — a persistent signal that shapes what's possible where.

Multiple factions contest the Valley, and none of them are the good guys. Faction
behavior, relations, and standing are data-driven through the engine's faction
registry.

## What's NOT here

No character classes, no skill trees, no extraction loop, no live-service grind,
no power fantasy. The player is small in the Valley and the Valley is rude about
it.
