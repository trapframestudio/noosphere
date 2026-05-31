class_name FactionColors
extends RefCounted
## Per-faction debug color cache.
##
## The canonical palette lives in `crates/simn-sim/src/factions.toml`
## under each faction's `debug_color` field. At session start
## `refresh_from_sim(sim_host)` walks the registry once and populates
## this cache; per-frame callers (`base_marker`, `faction_materials`,
## `humanoid_dummy`) hit the cache via `of(name)` without round-
## tripping into the gdext bridge for every lookup.
##
## Calling `of()` before `refresh_from_sim()` returns
## [`UNKNOWN`] (magenta) so a missing wiring is visually obvious in
## dev rather than silently dropping NPCs to a default color.

const UNKNOWN: Color = Color(1.0, 0.0, 1.0)  # magenta — debug "not yet primed"

static var _cache: Dictionary = {}


## Populate the cache from `SimHost` (which exposes
## `faction_debug_color(name)` per the faction registry). Call once
## per session — typically from `GameSession._ready()` after
## `SimHost.start()` has loaded the registry. Idempotent.
static func refresh_from_sim(sim_host: Node) -> void:
	_cache.clear()
	if sim_host == null:
		push_warning("FactionColors.refresh_from_sim: sim_host is null")
		return
	if not sim_host.has_method("all_factions"):
		push_warning("FactionColors.refresh_from_sim: sim_host has no all_factions(); was SimHost.start() called?")
		return
	var names: Array = sim_host.all_factions()
	for name_v in names:
		var name: String = String(name_v)
		var color: Color = sim_host.faction_debug_color(name)
		_cache[name] = color


static func of(faction_str: String) -> Color:
	if _cache.has(faction_str):
		return _cache[faction_str]
	return UNKNOWN


## Stable color for an arbitrary identifier (Steam ID, etc.). Used to
## color remote-player pills so multiple peers are distinguishable.
## Hashed into a fixed palette so two clients agree on each peer's
## color. Independent of the faction registry.
static func for_id(id: int) -> Color:
	const COLORS: Array = [
		Color8(0x4a, 0xa3, 0xff),  # cyan-blue
		Color8(0xff, 0x80, 0x40),  # orange
		Color8(0x60, 0xd0, 0x60),  # green
		Color8(0xe0, 0x60, 0xc0),  # magenta
		Color8(0xf0, 0xd0, 0x40),  # gold
		Color8(0xb0, 0xa0, 0xff),  # lavender
		Color8(0xff, 0xa0, 0xa0),  # pink
		Color8(0x80, 0xe0, 0xc0),  # mint
	]
	return COLORS[hash(id) % COLORS.size()]
