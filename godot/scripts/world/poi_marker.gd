@tool
class_name PoiMarker3D
extends Node3D

## A single point of interest in the world — faction base, NPC nav
## anchor, or generic landmark. Hand-placed by level authors before
## any procedural systems run.
##
## **Authoring discoverability.** Drop one in via Add Node → search
## "PoiMarker", set `kind` + `poi_id` in the inspector. The debug
## marker (color-coded gizmo + optional Label3D) makes the placement
## visible at a glance in the 3D viewport without running the game.
##
## **Consumed by:**
## - The (future) offline-graph bake tool, which walks
##   `get_tree().get_nodes_in_group("poi_markers")` and emits a record
##   per node with `poi_id`, `kind`, `faction`, `tags`, and the world
##   transform.
## - The (future) NPC materialization shim — `ANCHOR_*` kinds become
##   spawn-point candidates per `npc-traversal-plan.md` §7.
## - Sim-side `BaseKind` registration: `BASE_*` kinds with a non-NONE
##   faction map directly to `simn-sim::BaseKind` + `Faction` records
##   in the world seed.
##
## **Faction enum drift.** The Faction enum below mirrors
## `crates/simn-sim/src/faction.rs` `Faction::ALL` in declaration
## order. Drift is caught at build time by
## `crates/simn-godot/tests/faction_enum_sync.rs` — that test will
## fail with a "this variant is missing / extra" message if the two
## sides drift.

## Faction-claimable bases (mirrors `simn-sim::BaseKind`), NPC nav
## anchors (per `npc-traversal-plan.md` §4), and generic landmarks
## (placement first, sim semantics later).
enum Kind {
	# BASE_* — faction-claimable bases. Mirror simn-sim BaseKind.
	BASE_CHECKPOINT,
	BASE_OUTPOST,
	BASE_SAFEHOUSE,
	BASE_HEADQUARTERS,
	BASE_RESEARCH_POST,
	BASE_CAMP_SITE,
	# ANCHOR_* — NPC behaviour hints (spawn / loop / rest points).
	ANCHOR_SPAWN,
	ANCHOR_PATROL,
	ANCHOR_SLEEP,
	# Generic landmarks — placement now, sim mechanic later.
	LANDMARK,
	CACHE,            # hand-placed unique loot stash (story / quest items)
	RUIN,
	TRADER,
	DOOR,             # interior portal pivot (in-scene; not cross-scene — see MapTransition3D)
	LOOT_CONTAINER,   # procedural loot spawn point (distinct from CACHE)
	QUEST_HOOK,       # NPC / object that starts a quest
	VEHICLE_SPAWN,    # vehicle spawn / parking marker
	# (FAULT removed 2026-05-04 — graduated to volumetric FaultZone3D
	# since hazard zone + shard spawn ring are inherently volumetric.)
}

## NONE = unowned / neutral (sim-side: stored with `Faction::Wanderers`
## as the neutral placeholder per `simn-sim::world_seed.rs`). The
## remaining 10 mirror `simn-sim::Faction::ALL` in declaration order.
## Drift caught by `faction_enum_sync` test.
enum Faction {
	NONE,
	PWA,
	LINEMEN,
	REVERE_GUARD,
	FEDERAL,
	GULF_COMPACT,
	MERGED,
	NOOSPHERE_WORSHIPPERS,
	LOOTERS,
	CORPORATE_RESEARCH,
	WANDERERS,
}

## Stable identifier; becomes the offline-graph poi key. Convention:
## snake_case, prefixed by map (`cascade_locks_outpost_east`).
@export var poi_id: String = ""

## What kind of POI this is. Drives downstream sim registration: the
## bake tool routes BASE_* into the faction-base layer, ANCHOR_* into
## the nav-anchor layer, and the rest into a generic POI table.
@export var kind: Kind = Kind.LANDMARK: set = _set_kind

## Faction owner. Only meaningful for `BASE_*` kinds — sets warning
## when set on non-bases. Default NONE = unowned / neutral.
@export var faction: Faction = Faction.NONE: set = _set_faction

## Free-form metadata passed through to the offline graph artifact.
## Use for things like trader_inventory_table=..., cache_loot_pool=...,
## ruin_tier=2, fault_kind=gravity, etc.
@export var tags: Dictionary = {}

@export_group("Contestation")
## When true, this base participates in the rotating-ownership
## contestation system: factions can take, hold, and lose control of
## the POI through attacks. The marker's `faction` field is the
## starting / canonical owner; runtime ownership flips as attacks
## resolve. Only meaningful for `BASE_*` kinds (configuration
## warning fires otherwise).
##
## **TODO(sim):** wire into simn-sim. The contestation tick needs:
## a system that scans `poi_markers` group → filters `contested =
## true` BASE_* nodes → maintains a `ContestedBase { current_owner,
## last_flip_tick, attack_cadence }` component. Per-tick: chance of
## attack scales with `contest_tier`; on resolution, swap owner if
## attacker wins, refresh garrison. Unblocked once faction-AI
## planner exists; tracking via `npc-traversal-plan.md` consumers.
@export var contested: bool = false: set = _set_contested

## Strategic importance of this contested POI, 1 (minor) to 4 (major).
## Drives attack cadence, garrison size, and faction priority once
## the sim wires this in. Only meaningful when `contested = true` on
## a `BASE_*` kind. Default 1 — minor checkpoint / camp.
##
## **TODO(sim):** consumed alongside `contested` by the contestation
## tick. Higher tier = more frequent attacks, larger defending
## garrison, higher reward for capture. Numbers tuned at sim impl
## time.
@export_range(1, 4, 1) var contest_tier: int = 1: set = _set_contest_tier

@export_group("Debug visual")
## Show a colored sphere + Label3D billboard at this node's position
## while in the editor. Off in builds.
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"poi_markers"
const _DEBUG_RADIUS_M: float = 0.6
const _DEBUG_LABEL_HEIGHT_M: float = 1.5
const _DEBUG_ALPHA: float = 0.8

var _debug_marker: MeshInstance3D = null
var _debug_label: Label3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


func _set_kind(v: Kind) -> void:
	kind = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_faction(v: Faction) -> void:
	faction = v
	update_configuration_warnings()


func _set_contested(v: bool) -> void:
	contested = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_contest_tier(v: int) -> void:
	contest_tier = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if poi_id.strip_edges().is_empty():
		warnings.append(
			"poi_id is empty — set a stable identifier so the offline "
			+ "graph has a key to reference this POI by.")
	if faction != Faction.NONE and not _kind_is_base(kind):
		warnings.append(
			"faction is set but kind is not a BASE_* — non-base POIs "
			+ "don't have an owner. Either set kind to a BASE_* or "
			+ "set faction back to NONE.")
	if _kind_is_base(kind) and faction == Faction.NONE:
		warnings.append(
			"BASE_* kind with faction=NONE will register as neutral / "
			+ "unowned. That's valid (CampSite for Wanderers etc.), "
			+ "but unintentional for an outpost / safehouse / hq.")
	if contested and not _kind_is_base(kind):
		warnings.append(
			"contested=true but kind is not a BASE_* — only bases "
			+ "participate in the rotating-ownership system. Either "
			+ "set kind to a BASE_* or clear contested.")
	if contest_tier > 1 and not contested:
		warnings.append(
			"contest_tier > 1 but contested=false — tier is only "
			+ "consumed by the contestation system. Reset tier to 1 "
			+ "if this base isn't contested.")
	return warnings


# --- Debug visualization -----------------------------------------

func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return
	_debug_marker = MeshInstance3D.new()
	_debug_marker.name = "_PoiDebugMarker"
	var sphere := SphereMesh.new()
	sphere.radius = _DEBUG_RADIUS_M
	sphere.height = _DEBUG_RADIUS_M * 2.0
	_debug_marker.mesh = sphere
	add_child(_debug_marker, false, Node.INTERNAL_MODE_BACK)

	_debug_label = Label3D.new()
	_debug_label.name = "_PoiDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	# Match NPC `StateLabel`'s world-scaling sizing
	# (`humanoid_dummy.tscn`): `fixed_size = false` + a small
	# `pixel_size` makes the label a world-space size that scales
	# down naturally with camera distance. The old `fixed_size =
	# true` rendered at constant screen size so distant markers
	# stamped huge text across the viewport.
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, _DEBUG_LABEL_HEIGHT_M, 0.0)
	_debug_label.font_size = 24
	_debug_label.outline_size = 4
	_debug_label.modulate = Color(1.0, 1.0, 1.0, _DEBUG_ALPHA)
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)
	_apply_debug_appearance()


func _clear_debug_visual() -> void:
	if _debug_marker != null and is_instance_valid(_debug_marker):
		_debug_marker.queue_free()
	_debug_marker = null
	if _debug_label != null and is_instance_valid(_debug_label):
		_debug_label.queue_free()
	_debug_label = null


# Update debug marker color + label text without rebuilding meshes.
func _apply_debug_appearance() -> void:
	if _debug_marker != null and is_instance_valid(_debug_marker):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _color_for_kind(kind)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.render_priority = 10
		_debug_marker.material_override = mat
	if _debug_label != null and is_instance_valid(_debug_label):
		_debug_label.text = _label_text()


# Color per kind family: amber for bases, green for anchors, white-
# ish for landmarks. Subtle hue variation within a family helps
# distinguish at a glance without a legend.
static func _color_for_kind(k: Kind) -> Color:
	match k:
		Kind.BASE_CHECKPOINT: return Color(1.00, 0.70, 0.20, _DEBUG_ALPHA)
		Kind.BASE_OUTPOST: return Color(1.00, 0.55, 0.10, _DEBUG_ALPHA)
		Kind.BASE_SAFEHOUSE: return Color(0.95, 0.40, 0.10, _DEBUG_ALPHA)
		Kind.BASE_HEADQUARTERS: return Color(0.85, 0.20, 0.10, _DEBUG_ALPHA)
		Kind.BASE_RESEARCH_POST: return Color(0.80, 0.25, 0.50, _DEBUG_ALPHA)
		Kind.BASE_CAMP_SITE: return Color(1.00, 0.85, 0.35, _DEBUG_ALPHA)
		Kind.ANCHOR_SPAWN: return Color(0.20, 0.90, 0.30, _DEBUG_ALPHA)
		Kind.ANCHOR_PATROL: return Color(0.30, 0.80, 0.55, _DEBUG_ALPHA)
		Kind.ANCHOR_SLEEP: return Color(0.40, 0.65, 0.85, _DEBUG_ALPHA)
		Kind.LANDMARK: return Color(0.85, 0.85, 0.85, _DEBUG_ALPHA)
		Kind.CACHE: return Color(0.55, 0.85, 0.20, _DEBUG_ALPHA)
		Kind.RUIN: return Color(0.45, 0.45, 0.45, _DEBUG_ALPHA)
		Kind.TRADER: return Color(0.95, 0.95, 0.40, _DEBUG_ALPHA)
		Kind.DOOR: return Color(0.70, 0.55, 0.30, _DEBUG_ALPHA)
		Kind.LOOT_CONTAINER: return Color(0.30, 0.70, 0.30, _DEBUG_ALPHA)
		Kind.QUEST_HOOK: return Color(0.20, 0.55, 0.95, _DEBUG_ALPHA)
		Kind.VEHICLE_SPAWN: return Color(0.65, 0.40, 0.20, _DEBUG_ALPHA)
		_: return Color(0.50, 0.50, 0.50, _DEBUG_ALPHA)


func _label_text() -> String:
	var kind_str := Kind.keys()[kind] as String
	var prefix := "" if poi_id.is_empty() else (poi_id + "\n")
	var contest_suffix := ""
	if contested and _kind_is_base(kind):
		contest_suffix = "\n[contested T%d]" % contest_tier
	if faction != Faction.NONE and _kind_is_base(kind):
		return prefix + "%s\n%s%s" % [kind_str, Faction.keys()[faction], contest_suffix]
	return prefix + kind_str + contest_suffix


static func _kind_is_base(k: Kind) -> bool:
	return k == Kind.BASE_CHECKPOINT \
		or k == Kind.BASE_OUTPOST \
		or k == Kind.BASE_SAFEHOUSE \
		or k == Kind.BASE_HEADQUARTERS \
		or k == Kind.BASE_RESEARCH_POST \
		or k == Kind.BASE_CAMP_SITE
