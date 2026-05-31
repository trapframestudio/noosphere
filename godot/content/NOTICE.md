# Noosphere Content Overlay

This is Noosphere's content set. `SimHost.set_content_root("res://content")`
(wired in `game_session.gd`) tells the sim to load these files as a
`ContentSource::Overlay` over SIMN's embedded generic example pack. Files
here win; anything not here falls back to the engine's embedded defaults.

The game owns its full content set here, so it doesn't depend on SIMN's
example data at runtime. The folders mirror the engine's concern layout:
`factions/`, `names/`, `ai/`, `items/`, `loot/`, `crafting/`, `combat/`,
`poi/`, `world/`.

## Two kinds of files in here

**Proprietary creative IP** (covered by [LICENSE-ASSETS.md](../../LICENSE-ASSETS.md),
not the code license) - the identity layer:

* `factions/factions.toml` - the real faction names, relations, lore, identity.
* `ai/chatter_lines.toml` - in-world dialogue and voice flavor.
* `names/` - the curated Noosphere name pools.

**Mechanics, seeded from the open engine pack** - `items/`, `loot/`,
`crafting/`, `combat/`, `poi/`, `world/`, and `ai/{behavior,activity_types,npc_loadouts}.toml`
started as copies of SIMN's permissive example pack (MIT/Apache) so the game
owns and tunes them directly instead of inheriting volatile examples. The
faction-keyed files (`ai/npc_loadouts.toml`, `loot/loot_pools.toml`) are
re-keyed to the real roster so every faction resolves. As these get tuned
into real game balance they become game-specific; until then they're a
working starting point, not finished design.

If you build a different game on SIMN, swap this whole overlay for your own.
