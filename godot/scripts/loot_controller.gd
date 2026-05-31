extends Node
# Tracks the nearest interactable WorldContainer and dispatches the
# F-key (interact action) into the looting panel. Lives as a child of
# GameSession so it has direct sibling access to SimHost + LootPanel
# + HUD without scene-tree spelunking.
#
# Polling cadence is once per sim tick (via SimHost.tick_completed,
# 20Hz) — way cheaper than per-frame and matches the rate at which
# container positions can change anyway. The HUD prompt is shown when
# any container is in `LOOT_RANGE_M` of the player; F opens the
# nearest one's grid in the LootPanel.

const LOOT_RANGE_M: float = 2.5

var _nearest_id: int = -1
var _prompt: Label
var _prompt_layer: CanvasLayer


func _ready() -> void:
	_build_hud_prompt()
	# Defer signal hookup one frame so SimHost / GameSession finish
	# `_ready` first.
	call_deferred("_connect_tick_signal")


func _connect_tick_signal() -> void:
	var sim := _sim()
	if sim == null:
		return
	if sim.has_signal("tick_completed") and not sim.tick_completed.is_connected(_on_tick_completed):
		sim.tick_completed.connect(_on_tick_completed)


func _on_tick_completed(_tick: int, _payload: PackedByteArray) -> void:
	_refresh_nearest()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return
	if _nearest_id < 0:
		return
	# Don't interact while a modal panel already owns input.
	var inv := _inventory_panel()
	if inv != null and inv.visible:
		return
	# Phase 3E: looting routes through the unified inventory
	# panel — the container's grid renders alongside pockets +
	# equipped containers, and the Phase 2 drag-and-drop /
	# right-click / tooltip / filter affordances all apply. The
	# old standalone `LootPanel` is no longer in the loop.
	if inv != null and inv.has_method("open_for_container"):
		inv.open_for_container(_nearest_id)
		get_viewport().set_input_as_handled()


func _refresh_nearest() -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		_set_prompt_visible(false)
		_nearest_id = -1
		return
	# The Sim sees containers in the same region — host filters by
	# region+radius, so just ask for everything within range.
	var hits: Array = sim.containers_in_range(sid, LOOT_RANGE_M)
	if hits.is_empty():
		_set_prompt_visible(false)
		_nearest_id = -1
		return
	# Closest first (sim returns in arbitrary order — sort here so the
	# F-key always opens the obvious one).
	var player_pos := _player_world_pos()
	var best_id: int = -1
	var best_d2: float = INF
	for hit_var in hits:
		var hit: Dictionary = hit_var
		var pos: Vector3 = hit.get("pos", Vector3.ZERO)
		var d2: float = (pos - player_pos).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best_id = int(hit.get("id", -1))
	_nearest_id = best_id
	_set_prompt_visible(_nearest_id >= 0)


func _player_world_pos() -> Vector3:
	# The Player node is parented under whatever map scene is current;
	# walk the tree by group lookup.
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return Vector3.ZERO
	var node: Node = players[0]
	if node is Node3D:
		return (node as Node3D).global_position
	return Vector3.ZERO


# HUD -----------------------------------------------------------------

func _build_hud_prompt() -> void:
	_prompt_layer = CanvasLayer.new()
	_prompt_layer.layer = 11   # between HUD (10) and Hotbar (12)
	add_child(_prompt_layer)
	var anchor := Control.new()
	anchor.anchor_left = 0.5
	anchor.anchor_top = 1.0
	anchor.anchor_right = 0.5
	anchor.anchor_bottom = 1.0
	anchor.offset_top = -180
	anchor.offset_bottom = -160
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_layer.add_child(anchor)
	_prompt = Label.new()
	_prompt.text = "[F] LOOT"
	_prompt.add_theme_font_size_override("font_size", 16)
	_prompt.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.anchor_left = 0.0
	_prompt.anchor_top = 0.0
	_prompt.anchor_right = 1.0
	_prompt.anchor_bottom = 1.0
	_prompt.offset_left = -100
	_prompt.offset_right = 100
	anchor.add_child(_prompt)
	_prompt.visible = false


func _set_prompt_visible(v: bool) -> void:
	if _prompt != null:
		_prompt.visible = v


# Sibling lookups -----------------------------------------------------

func _sim() -> Node:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return null
	return session.get_node_or_null("SimHost")


func _local_sid() -> int:
	var session := get_node_or_null("/root/GameSession")
	if session == null or not session.has_method("local_steam_id"):
		return 0
	return session.local_steam_id()


func _loot_panel() -> Node:
	return get_node_or_null("/root/GameSession/LootPanel")


func _inventory_panel() -> Node:
	return get_node_or_null("/root/GameSession/InventoryPanel")
