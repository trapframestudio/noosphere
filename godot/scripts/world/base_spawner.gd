extends Node
## Iteration 5-14 Phase E — runtime walker that turns scene-authored
## `PoiMarker3D` nodes with `BASE_*` kind into real `Base` ECS entities
## in the sim. Mirrors `loot_container_spawner.gd` for the
## `&"loot_container_markers"` group.
##
## Call [`spawn_authored_bases(region_name, terrain_node)`] from a
## map scene's `_ready` (after terrain is loaded so Y-snapping
## works). The walker iterates the `&"poi_markers"` group and, for
## each `BASE_*` kind marker, calls
## `SimHost.register_authored_base(region_name, pos, kind, faction)`.
##
## Designer flow:
## 1. POI baker (`poi_baker.gd`) creates `PoiMarker3D` children
##    under a `BakedPOIs` node — one per scattered base.
## 2. Scene loads, `test_map.gd::_on_terrain_ready` calls into
##    this script.
## 3. Each marker becomes a sim-side `Base` entity at the marker's
##    Y-snapped position with the right `BaseKind` + faction.
##
## ANCHOR_* and generic landmark kinds are skipped here — those
## map to other downstream consumers (NPC spawn anchors, generic
## landmark layer).
##
## Static — call as `BaseSpawner.spawn_authored_bases(...)`.
## Idempotent within a load: re-running just re-registers, and
## the sim accepts duplicate spawns at the same position (the
## squad planner uses distance, not identity).

const _GROUP: StringName = &"poi_markers"

## Map from `PoiMarker3D::Kind` integer to the `BaseKind` PascalCase
## string the sim bridge accepts. Indices match the enum order in
## `godot/scripts/world/poi_marker.gd`.
##
## - 0 BASE_CHECKPOINT → "Checkpoint"
## - 1 BASE_OUTPOST    → "Outpost"
## - 2 BASE_SAFEHOUSE  → "Safehouse"
## - 3 BASE_HEADQUARTERS → "Headquarters"
## - 4 BASE_RESEARCH_POST → "ResearchPost"
## - 5 BASE_CAMP_SITE  → "CampSite"
const _KIND_NAMES: Array[String] = [
	"Checkpoint",
	"Outpost",
	"Safehouse",
	"Headquarters",
	"ResearchPost",
	"CampSite",
]

## Map from `PoiMarker3D::Faction` integer to the `factions.toml` id.
## Indices match the enum order in `poi_marker.gd`.
##
## - 0 NONE                  → "wanderers" (neutral placeholder)
## - 1 PWA                   → "pwa"
## - 2 LINEMEN               → "linemen"
## - 3 REVERE_GUARD          → "revere_guard"
## - 4 FEDERAL               → "federal"
## - 5 GULF_COMPACT          → "gulf_compact"
## - 6 MERGED                → "merged"
## - 7 NOOSPHERE_WORSHIPPERS → "noosphere_worshippers"
## - 8 LOOTERS               → "looters"
## - 9 CORPORATE_RESEARCH    → "corporate_research"
## - 10 WANDERERS            → "wanderers"
const _FACTION_NAMES: Array[String] = [
	"wanderers",
	"pwa",
	"linemen",
	"revere_guard",
	"federal",
	"gulf_compact",
	"merged",
	"noosphere_worshippers",
	"looters",
	"corporate_research",
	"wanderers",
]


## Walk every `poi_markers` node in the active scene tree, filter
## down to `BASE_*` kinds, and register each with the sim.
##
## - `tree`: the active `SceneTree`.
## - `region_name`: the map id (`"map_a"`, `"corbett"`, etc.).
## Returns the number of bases successfully registered. Y-snapping
## is handled by the sim's register_authored_base (uses TerrainMaps
## fed from Terrain3D).
static func spawn_authored_bases(
	tree: SceneTree,
	region_name: String,
) -> int:
	if tree == null:
		return 0
	var session := tree.root.get_node_or_null("GameSession")
	if session == null:
		return 0
	var sim: Node = session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method("register_authored_base"):
		return 0
	var markers: Array[Node] = tree.get_nodes_in_group(_GROUP)
	if markers.is_empty():
		return 0

	var registered := 0
	for node in markers:
		if not (node is Node3D):
			continue
		var marker: Node3D = node
		# Resolve enum fields via the `get` indirection so this
		# spawner doesn't depend on a hard `PoiMarker3D` class
		# import (mirrors the loot_container_spawner pattern).
		var kind_int: int = -1
		if "kind" in marker:
			kind_int = int(marker.kind)
		if kind_int < 0 or kind_int >= _KIND_NAMES.size():
			# ANCHOR_*, LANDMARK, etc. — not a base, skip silently.
			continue
		var faction_int: int = 0
		if "faction" in marker:
			faction_int = int(marker.faction)
		var pos: Vector3 = marker.global_position
		var kind_str: String = _KIND_NAMES[kind_int]
		# CampSite uses the neutral "wanderers" pool regardless of
		# the marker's authored faction (test maps may default
		# `NONE` on campsite markers; the sim treats them as
		# neutral regardless).
		var faction_str: String
		if kind_str == "CampSite":
			faction_str = "wanderers"
		elif faction_int < 0 or faction_int >= _FACTION_NAMES.size():
			faction_str = "wanderers"
		else:
			faction_str = _FACTION_NAMES[faction_int]
		if sim.register_authored_base(region_name, pos, kind_str, faction_str):
			registered += 1
	return registered
