@tool
class_name MapTransition3D
extends Area3D

## Player-trigger volume that swaps to another map scene. Drop one
## at the edge of a map (or at a doorway / portal), set the target
## scene + the spawn marker name in the target, and any node in
## `trigger_groups` that enters the volume triggers the transition.
##
## Drop a `CollisionShape3D` child to define the trigger footprint —
## a BoxShape3D for a doorway, a wider box for a "drive across the
## map edge" style transition. Godot renders the shape as a wireframe
## in the editor.
##
## **Spawn placement.** After the new scene loads, the script in
## `game_session.gd` (or its successor) looks up a node by
## `target_spawn_node_name` and places the player at its global
## transform. Use a `RegionMarker3D`, `PoiMarker3D` (kind =
## `ANCHOR_SPAWN`), or plain `Marker3D` as the target.

## The scene to load. Resolved at trigger time via
## `get_tree().change_scene_to_file(target_scene)`.
@export_file("*.tscn") var target_scene: String = ""

## Name of a node in the target scene to spawn the player at.
## Resolved by `target_root.find_child(target_spawn_node_name, true,
## false)` after scene-load. Empty falls back to whatever default
## spawn the target scene's session script picks (current behaviour).
@export var target_spawn_node_name: String = ""

## Fade-out time before the scene swap. 0 = instant snap (debug /
## playtesting); ~0.6 s = the production-feel fade.
@export_range(0.0, 2.0, 0.05) var fade_seconds: float = 0.6

## Bodies in any of these groups can trigger the transition. Default
## "player" prevents debug pills / dummy NPCs from auto-triggering.
@export var trigger_groups: PackedStringArray = ["player"]

const _GROUP: StringName = &"map_transitions"

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
	if _fired:
		return
	if target_scene.is_empty():
		push_error("MapTransition3D %s: target_scene is empty; ignoring trigger."
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
	# Stash the desired spawn target on a session-level autoload-style
	# group so the destination scene's session script can read it on
	# _ready. Using a group avoids a hard dependency on a specific
	# autoload name.
	if not target_spawn_node_name.is_empty():
		Engine.set_meta(&"map_transition_spawn_target", target_spawn_node_name)
	else:
		Engine.remove_meta(&"map_transition_spawn_target")
	# Defer to next frame so the body_entered handler completes before
	# the scene tree changes underneath us.
	call_deferred("_perform_transition")


func _perform_transition() -> void:
	# fade_seconds is honored by `game_session.gd`'s fade overlay if
	# present; if not, change_scene_to_file is instant. Wiring the
	# fade up is owned by the session script, not this node.
	if fade_seconds > 0.0:
		Engine.set_meta(&"map_transition_fade_seconds", fade_seconds)
	else:
		Engine.remove_meta(&"map_transition_fade_seconds")
	get_tree().change_scene_to_file(target_scene)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if target_scene.strip_edges().is_empty():
		warnings.append(
			"target_scene is empty — transition is a no-op until set.")
	elif not FileAccess.file_exists(target_scene):
		warnings.append(
			"target_scene `%s` does not exist on disk — was the scene "
			% target_scene + "renamed or moved?")
	var has_shape := false
	for child in get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			has_shape = true
			break
	if not has_shape:
		warnings.append(
			"No CollisionShape3D child with a Shape — the transition has "
			+ "no trigger footprint and will never fire. Add a "
			+ "CollisionShape3D and pick a BoxShape3D / etc.")
	if trigger_groups.is_empty():
		warnings.append(
			"trigger_groups is empty — nothing will ever trigger this "
			+ "transition. Set at least one group (typically `player`).")
	return warnings
