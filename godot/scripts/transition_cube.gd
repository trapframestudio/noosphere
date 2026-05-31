extends Area3D
## Map transition trigger. When the local player enters, asks the
## `GameSession` autoload to swap to `target_map`.
##
## `target_map` is the logical map id (e.g. "map_a", "map_b"), which
## `GameSession` knows how to resolve to a scene path.

@export var target_map: String = ""


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	# Only respond to the local player, not remote-pill nodes (which live
	# in a different group).
	if not body.is_in_group("local_player"):
		return
	if target_map.is_empty():
		push_warning("TransitionCube: target_map is not set")
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		push_error("TransitionCube: /root/GameSession autoload is missing")
		return
	session.request_map_change(target_map)
