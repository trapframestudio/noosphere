@tool
class_name InteractionAreaMarker3D
extends Node3D

## A scene-authored interaction area: a designer-placed spot where
## NPCs can be told to "do X here" via a flexible string descriptor.
## Drop one in via **Add Node → search "InteractionAreaMarker3D"**,
## set `interaction_kind` (e.g. `"rest"`, `"work"`, `"socialize"`),
## set `extents` to the area's footprint, optionally pin `faction`
## and `capacity`, and the in-editor gizmo updates immediately.
##
## **Phase D of `sim-iteration-5-13`** (the nav-pipeline + interaction-
## areas iteration). Complements:
## - `NavObstacleMarker3D` (Phase B) — same authoring pattern, but
##   for nav-blocking AABBs.
## - `LootContainerMarker3D` (Phase 3D) — same pattern, different
##   gameplay surface.
## - `PoiMarker3D` — generic level landmarks; this node is
##   intentionally separate so PoiMarker's 18-value Kind enum
##   doesn't grow into a catch-all.
##
## **Free-form `interaction_kind`.** The sim recognizes a canonical
## set (`"rest"`, `"work"`, `"socialize"`, `"scavenge"`,
## `"guard_post"`, `"patrol_node"`, `"campfire"`, `"workbench"`);
## unknown kinds resolve to a generic "visit" with low utility.
## Designers and modders can invent new kinds without code changes;
## the bridge just ships the string.
##
## **Capacity.** Default 1 (one NPC per spot at a time). The sim's
## occupancy tracker rejects further `reserve_interaction_area`
## calls past the cap; NPCs waiting for a freed slot pick a
## different target.
##
## **Faction.** Empty string = any. When set to a faction name (must
## match `factions.toml` ids), `Sim::reserve_interaction_area`
## rejects requests from NPCs of other factions. Useful for "this
## is a Federal campsite" or "this is an Aegis workbench" markers
## that the Looters shouldn't use.
##
## **Persistence is transient.** The sim's `InteractionAreas`
## resource is rebuilt from the scene on every region attach — same
## contract as `NavQueries`. Deleting a marker removes the area on
## the next attach.

## Per-spot designer descriptor. Free-form string so modders can
## extend the vocabulary without touching Rust.
##
## Canonical kinds the sim recognizes (Phase D3 will wire these to
## squad-objective utility scoring):
## - `"rest"` — squads can pick this as a `Rest` objective target.
## - `"work"` — generic "do a thing here" slot (campfire, prep,
##   busywork). Phase D3 v1 doesn't add a `Work` objective kind;
##   reserved for follow-up.
## - `"socialize"` — chat / morale spot. Follow-up.
## - `"scavenge"` — pick-up spot for a future scavenger AI.
## - `"guard_post"` — alternative to procedural Guard objectives;
##   pins a squad to a specific spot.
## - `"patrol_node"` — explicit patrol waypoint a Patrol objective
##   can chain through.
## - `"campfire"` — special-case `rest` for evening / weather
##   behavior (TBD).
## - `"workbench"` — special-case `work` for crafting (TBD).
##
## Unknown values are not an error — the sim treats them as a
## generic "visit" with low utility.
@export var interaction_kind: String = "rest": set = _set_interaction_kind

## XZ footprint half-size in meters. Sim consumes only X and Z;
## Y on the gizmo is for editor readability (the box height).
@export var extents: Vector3 = Vector3(1.5, 1.0, 1.5): set = _set_extents

## Max NPCs that can use this area simultaneously. Default 1 (one
## per spot). The sim's occupancy tracker rejects reservations
## past the cap.
@export var capacity: int = 1: set = _set_capacity

## Faction restriction. Empty string = any. When set, must match
## a faction id in `crates/simn-sim/data/factions.toml` (`pwa`,
## `looters`, `federal`, etc.). The sim's reserve call rejects
## NPCs from other factions when this is set.
@export var faction: String = "": set = _set_faction

## Stable identifier — used as the sim-side primary key for the
## interaction area. Empty string = auto-derive from the marker's
## scene path + node name at enumeration time. Production maps
## should set a stable snake_case id (map-prefixed) so saves /
## replication can reference specific areas without scene-path
## fragility.
@export var area_id: String = ""

## Free-form metadata. Mirrors `PoiMarker3D.tags`. The sim passes
## these through as a `HashMap<String, String>` on the
## `InteractionArea` record; downstream consumers (future Work /
## Socialize objective kinds, mod scripts) can read them.
@export var tags: Dictionary = {}

@export_group("Debug visual")
## Toggle the wireframe gizmo + label in the editor. Off in
## builds; the sim consumes the data, not the gizmo.
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"interaction_area_markers"
const _DEBUG_ALPHA: float = 0.55

# Color tints per canonical kind so a glance at the editor view
# tells you the spot's role. Unknown kinds get the neutral
# `_COLOR_GENERIC` so designers can still see them.
const _COLOR_REST: Color = Color(0.45, 0.85, 0.50, _DEBUG_ALPHA)        # green
const _COLOR_WORK: Color = Color(0.30, 0.65, 0.95, _DEBUG_ALPHA)        # blue
const _COLOR_SOCIALIZE: Color = Color(0.95, 0.75, 0.30, _DEBUG_ALPHA)   # warm yellow
const _COLOR_SCAVENGE: Color = Color(0.85, 0.55, 0.30, _DEBUG_ALPHA)    # orange-brown
const _COLOR_GUARD: Color = Color(0.85, 0.30, 0.30, _DEBUG_ALPHA)       # red
const _COLOR_PATROL: Color = Color(0.55, 0.35, 0.85, _DEBUG_ALPHA)      # purple
const _COLOR_CAMPFIRE: Color = Color(0.95, 0.55, 0.25, _DEBUG_ALPHA)    # campfire-orange
const _COLOR_WORKBENCH: Color = Color(0.55, 0.55, 0.70, _DEBUG_ALPHA)   # steel-grey-blue
const _COLOR_GENERIC: Color = Color(0.70, 0.70, 0.75, _DEBUG_ALPHA)     # neutral grey

var _debug_box: MeshInstance3D = null
var _debug_label: Label3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


# --- Setters ----------------------------------------------------

func _set_interaction_kind(v: String) -> void:
	interaction_kind = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_extents(v: Vector3) -> void:
	# Clamp to a sane minimum so the gizmo never collapses to a
	# zero-volume box.
	extents = Vector3(maxf(v.x, 0.1), maxf(v.y, 0.1), maxf(v.z, 0.1))
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()


func _set_capacity(v: int) -> void:
	capacity = maxi(v, 1)
	update_configuration_warnings()


func _set_faction(v: String) -> void:
	faction = v
	update_configuration_warnings()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


# --- Configuration warnings -------------------------------------

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if interaction_kind.strip_edges().is_empty():
		warnings.append(
			"interaction_kind is empty — the sim will treat this as a "
				+ "generic visit with low utility. Set a canonical kind "
				+ "(rest / work / socialize / scavenge / guard_post / "
				+ "patrol_node / campfire / workbench) or a domain string."
		)
	if capacity < 1:
		warnings.append("capacity must be at least 1.")
	if area_id.strip_edges().is_empty():
		warnings.append(
			"area_id is empty — the bridge will auto-derive an id from "
				+ "the scene path + node name. Production maps should "
				+ "set a stable snake_case id (map-prefixed) so saves / "
				+ "replication can reference this area unambiguously."
		)
	return warnings


# --- Debug visual -----------------------------------------------

func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return
	_debug_box = MeshInstance3D.new()
	_debug_box.name = "_InteractionAreaDebugBox"
	var box := BoxMesh.new()
	box.size = extents * 2.0
	_debug_box.mesh = box
	add_child(_debug_box, false, Node.INTERNAL_MODE_BACK)

	_debug_label = Label3D.new()
	_debug_label.name = "_InteractionAreaDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	# Match NPC `StateLabel`'s world-scaling sizing — `fixed_size =
	# true` rendered the label at constant screen size so distant
	# markers stamped huge text across the viewport.
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(0.0, extents.y + 0.5, 0.0)
	_debug_label.font_size = 22
	_debug_label.outline_size = 4
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)

	_apply_debug_appearance()


func _clear_debug_visual() -> void:
	if _debug_box != null:
		_debug_box.queue_free()
		_debug_box = null
	if _debug_label != null:
		_debug_label.queue_free()
		_debug_label = null


func _apply_debug_appearance() -> void:
	if _debug_box == null and _debug_label == null:
		return
	var tint := _color_for_kind(interaction_kind)
	if _debug_box != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.emission_enabled = true
		mat.emission = tint
		mat.emission_energy_multiplier = 0.30
		_debug_box.material_override = mat
	if _debug_label != null:
		_debug_label.text = interaction_kind.to_upper() if not interaction_kind.is_empty() else "VISIT"
		_debug_label.modulate = Color(tint.r, tint.g, tint.b, 1.0)


static func _color_for_kind(kind: String) -> Color:
	match kind:
		"rest":
			return _COLOR_REST
		"work":
			return _COLOR_WORK
		"socialize":
			return _COLOR_SOCIALIZE
		"scavenge":
			return _COLOR_SCAVENGE
		"guard_post":
			return _COLOR_GUARD
		"patrol_node":
			return _COLOR_PATROL
		"campfire":
			return _COLOR_CAMPFIRE
		"workbench":
			return _COLOR_WORKBENCH
		_:
			return _COLOR_GENERIC
