@tool
class_name RegionMarker3D
extends Area3D

## Coarse named region for the offline NPC-traversal graph. One per
## map (e.g. `region_id = "cascade_locks"`) until interior buildings
## arrive and finer subdivision becomes necessary; then drop more
## per interior, transition zone, etc.
##
## Drop a `CollisionShape3D` child to define the footprint. Godot
## renders the collision shape as a wireframe in the editor, so no
## separate debug mesh is needed — pick the shape that matches the
## real footprint (BoxShape3D for rectangular maps, ConvexPolygonShape3D
## for irregular boundaries).
##
## The offline-graph bake tool (per `npc-traversal-plan.md` §6) walks
## `get_tree().get_nodes_in_group("region_markers")` to enumerate all
## regions in a scene; the `region_id` becomes the offline `RegionId`
## key. `region_kind` and `tags` are passed through into the baked
## artifact's tag dictionary.

## Stable region identifier — used as the `RegionId` key in the
## offline graph. Convention: snake_case map id for the coarse per-
## map region (`"cascade_locks"`), suffixed for interior subdivisions
## (`"cascade_locks_outpost_west"`, `"the_dalles_interior_a"`).
@export var region_id: String = ""

## What kind of space this is — drives offline-tier behaviour hints
## (e.g. NPCs prefer interior regions for sleep, exterior for
## patrol).
@export_enum("exterior", "interior", "transition") var region_kind: int = 0

## Free-form metadata. Bake tool serializes this verbatim into the
## region record's `tags` map. Useful keys today: `poi=<poi_id>`
## (binds this region to a POI), `faction=<name>` (default occupant),
## `weather_pref=<key>`. Bake-tool validator will warn on typos
## (tag values not seen elsewhere in the world).
@export var tags: Dictionary = {}

const _GROUP: StringName = &"region_markers"


func _enter_tree() -> void:
	add_to_group(_GROUP)


func _exit_tree() -> void:
	remove_from_group(_GROUP)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if region_id.strip_edges().is_empty():
		warnings.append(
			"region_id is empty — set a stable identifier so the offline "
			+ "graph has a key to reference this region by.")
	var has_shape := false
	for child in get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			has_shape = true
			break
	if not has_shape:
		warnings.append(
			"No CollisionShape3D child with a Shape — the region has no "
			+ "footprint. Add a CollisionShape3D and pick a BoxShape3D / "
			+ "ConvexPolygonShape3D / etc.")
	# Sibling-id collision check. Bake tool also enforces this, but
	# surfacing it in the inspector catches it before commit.
	var parent := get_parent()
	if parent != null and not region_id.is_empty():
		for sibling in parent.get_children():
			if sibling == self or not (sibling is RegionMarker3D):
				continue
			if (sibling as RegionMarker3D).region_id == region_id:
				warnings.append(
					"region_id collides with sibling `%s` — IDs must be "
					% sibling.name + "unique within a scene.")
				break
	return warnings
