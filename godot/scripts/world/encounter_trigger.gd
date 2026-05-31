@tool
class_name EncounterTrigger3D
extends Area3D

## Volumetric trigger that fires an encounter (combat / ambush /
## scripted event / dialog / cutscene) when a body in `trigger_groups`
## enters. Authoring-side only for now — the encounter dispatcher
## that consumes the `encounter_triggered` signal lands with the
## sim-driven encounter system; this node is the placement contract
## that will feed it.
##
## Volumetric (not a `PoiMarker3D` Kind) because encounters cover
## space — a clearing, a building, an ambush kill-zone — not a single
## point. Drop a `CollisionShape3D` child to define the trigger
## footprint.
##
## **TODO(sim):** wire the `encounter_triggered` signal into the
## encounter dispatcher when it lands. Per-trigger behaviour
## (combat encounter table, scripted event id, ambush composition)
## lives in `tags` until the dispatcher's data model exists; once
## it does, fold into typed exports.

signal encounter_triggered(encounter_id: String, encounter_kind: int, body: Node)

## Stable identifier the encounter dispatcher routes on. Convention:
## snake_case, prefixed by map (`cascade_locks_pwa_ambush_west`).
@export var encounter_id: String = ""

## Categorical hint for the dispatcher. The actual behaviour is
## downstream of this enum + `tags`; this just narrows what kind of
## encounter to expect when authoring.
enum EncounterKind {
	COMBAT,            # standing-fight encounter
	AMBUSH,            # surprise attack on the player
	SCRIPTED_EVENT,    # one-shot scripted moment
	DIALOG,            # NPC interaction trigger
	CUTSCENE,          # camera-takeover scripted scene
}
@export var encounter_kind: EncounterKind = EncounterKind.COMBAT

## Bodies in any of these groups can fire the trigger. Default
## "player" matches the convention used by `MapTransition3D`.
@export var trigger_groups: PackedStringArray = ["player"]

## When true, only fires the first time a qualifying body enters —
## subsequent entries are silent. Useful for one-shot scripted
## events / cutscenes that shouldn't replay. False = fires on every
## enter (recurring ambushes, repeating dialogues).
@export var fires_once: bool = true

## Free-form metadata for the dispatcher. Until the typed encounter
## data model lands, use keys like `combat_table=pwa_outpost_west`,
## `ambush_squad=looter_3`, `scripted_event=dalles_intro`,
## `dialog_id=trader_intro`, etc.
@export var tags: Dictionary = {}

const _GROUP: StringName = &"encounter_triggers"

var _fired: bool = false


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if not Engine.is_editor_hint():
		body_entered.connect(_on_body_entered)


func _exit_tree() -> void:
	remove_from_group(_GROUP)
	if not Engine.is_editor_hint() and body_entered.is_connected(_on_body_entered):
		body_entered.disconnect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if fires_once and _fired:
		return
	if encounter_id.is_empty():
		push_error("EncounterTrigger3D %s: encounter_id is empty; ignoring trigger."
			% get_path())
		return
	# Body must be in at least one of the trigger groups.
	var ok := false
	for g in trigger_groups:
		if body.is_in_group(g):
			ok = true
			break
	if not ok:
		return
	_fired = true
	encounter_triggered.emit(encounter_id, int(encounter_kind), body)


## Editor / debug helper — manually mark the trigger as un-fired so a
## fires_once trigger can be re-tested without reloading the scene.
func reset_fired_flag() -> void:
	_fired = false


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if encounter_id.strip_edges().is_empty():
		warnings.append(
			"encounter_id is empty — set a stable identifier so the "
			+ "encounter dispatcher has a key to route on.")
	var has_shape := false
	for child in get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			has_shape = true
			break
	if not has_shape:
		warnings.append(
			"No CollisionShape3D child with a Shape — the trigger has "
			+ "no footprint and will never fire. Add a CollisionShape3D "
			+ "and pick a BoxShape3D / etc.")
	if trigger_groups.is_empty():
		warnings.append(
			"trigger_groups is empty — nothing will ever fire this "
			+ "encounter. Set at least one group (typically `player`).")
	return warnings
