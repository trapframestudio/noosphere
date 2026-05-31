extends CanvasLayer
# Looting panel — opens on E when standing near a `WorldContainer`
# (ground drop, scene-placed crate, NPC corpse). Side-by-side layout:
# the player's pockets on the left, the open container on the right.
# Click an item on either side to "carry" it; click an empty cell on
# the opposite side to drop it there. The Sim API enforces fit / room.
#
# Cross-grid moves use the existing `take_from_container` /
# `put_in_container` `#[func]`s; equipped containers (rig, backpack)
# aren't surfaced here yet — pockets only for v1. The looting flow
# is meant to feel fast: walk up, E, click, click, ESC.

const _CELL: int = 48

var _root: PanelContainer
var _grids_row: HBoxContainer
var _hint_label: Label

var _open_container_id: int = -1
# `_carried` mirrors inventory_panel's shape:
# `{ side: "pockets" | "container", item_idx: int }`. null when empty.
var _carried: Variant = null


func _ready() -> void:
	_build()
	_connect_tick_signal()


func _connect_tick_signal() -> void:
	var sim := _sim()
	if sim == null:
		return
	if sim.has_signal("tick_completed") and not sim.tick_completed.is_connected(_on_tick_completed):
		sim.tick_completed.connect(_on_tick_completed)


func _on_tick_completed(_tick: int, _payload: PackedByteArray) -> void:
	if visible:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


# Public API ----------------------------------------------------------

func open_for(container_id: int) -> void:
	if container_id < 0:
		return
	_open_container_id = container_id
	_carried = null
	visible = true
	_refresh()


func close() -> void:
	visible = false
	_open_container_id = -1
	_carried = null


# Build ---------------------------------------------------------------

func _build() -> void:
	# Full-screen dim backdrop so click-outside still registers as a
	# meaningful "this panel owns the focus" affordance.
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.45)
	backdrop.anchor_left = 0.0
	backdrop.anchor_top = 0.0
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_top = 0.5
	_root.anchor_right = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -360
	_root.offset_top = -260
	_root.offset_right = 360
	_root.offset_bottom = 260
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 18
	sb.content_margin_top = 14
	sb.content_margin_right = 18
	sb.content_margin_bottom = 14
	_root.add_theme_stylebox_override("panel", sb)
	add_child(_root)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_root.add_child(v)

	v.add_child(NSWidgets.stencil("LOOT", 24))
	v.add_child(NSWidgets.hairline())

	_grids_row = HBoxContainer.new()
	_grids_row.add_theme_constant_override("separation", 24)
	v.add_child(_grids_row)

	v.add_child(NSWidgets.hairline())
	_hint_label = NSWidgets.label_mono(
		"Click an item to carry  •  click opposite empty cell to deposit  •  [ESC] close",
		11,
		NSColors.FG_3,
	)
	v.add_child(_hint_label)


# Refresh -------------------------------------------------------------

func _refresh() -> void:
	if _grids_row == null:
		return
	for c in _grids_row.get_children():
		c.queue_free()
	if _open_container_id < 0:
		return
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return

	# Player pockets (left).
	var view: Dictionary = sim.player_state(sid)
	var pockets_grid: Dictionary = {
		"width": int(view.get("inventory_width", 4)),
		"height": int(view.get("inventory_height", 4)),
		"items": view.get("inventory", []),
	}
	_grids_row.add_child(_build_grid_widget("pockets", "POCKETS", pockets_grid))

	# Container (right).
	var container_grid: Dictionary = sim.container_view(_open_container_id)
	if int(container_grid.get("width", 0)) == 0:
		# Container vanished mid-loot (e.g. host despawned it). Close.
		close()
		return
	_grids_row.add_child(_build_grid_widget("container", "CONTAINER", container_grid))


func _build_grid_widget(side: String, title: String, grid: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	var header_text := "◇ " + title
	if _carried != null and _carried.get("side", "") == side:
		header_text += "  (carrying)"
	v.add_child(NSWidgets.eyebrow(header_text))

	var width: int = max(int(grid.get("width", 0)), 1)
	var height: int = max(int(grid.get("height", 0)), 1)
	var items: Array = grid.get("items", [])

	var anchors: Dictionary = {}
	var covered: Dictionary = {}
	for i in range(items.size()):
		var item: Dictionary = items[i]
		var ix: int = int(item.get("x", 0))
		var iy: int = int(item.get("y", 0))
		var w: int = int(item.get("w", 1))
		var h: int = int(item.get("h", 1))
		var a := Vector2i(ix, iy)
		var decorated: Dictionary = item.duplicate()
		decorated["_sim_idx"] = i
		anchors[a] = decorated
		for dy in range(h):
			for dx in range(w):
				covered[Vector2i(ix + dx, iy + dy)] = a

	var gc := GridContainer.new()
	gc.columns = width
	gc.add_theme_constant_override("h_separation", 2)
	gc.add_theme_constant_override("v_separation", 2)
	v.add_child(gc)

	for y in range(height):
		for x in range(width):
			var coord := Vector2i(x, y)
			var cell: Control
			if anchors.has(coord):
				cell = _build_item_card(side, anchors[coord])
			elif covered.has(coord):
				cell = Control.new()
				cell.custom_minimum_size = Vector2(_CELL, _CELL)
				cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
			else:
				cell = _build_empty_cell(side)
			gc.add_child(cell)

	return v


func _build_item_card(side: String, item: Dictionary) -> Control:
	var w: int = int(item.get("w", 1))
	var h: int = int(item.get("h", 1))
	var idx: int = int(item.get("_sim_idx", -1))
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(_CELL * w + 2 * (w - 1), _CELL * h + 2 * (h - 1))
	btn.text = "%s\n×%d" % [_short(item.get("name", "?"), 14), int(item.get("count", 1))]
	btn.add_theme_font_size_override("font_size", 10)
	btn.flat = false
	# Highlight if it's the carried stack so the player can see what
	# they picked up (and click again to cancel the carry).
	var is_carried: bool = (
		_carried != null
		and _carried.get("side", "") == side
		and int(_carried.get("item_idx", -1)) == idx
	)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.LICHEN if is_carried else NSColors.BG_CRT
	sb.border_color = NSColors.STAMP_RED if is_carried else NSColors.VLF_PHOSPHOR
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	btn.pressed.connect(_on_item_pressed.bind(side, idx))
	return btn


func _build_empty_cell(side: String) -> Control:
	# When carrying from the OPPOSITE side, an empty cell on this side
	# becomes the "deposit here" target. Otherwise it's inert visually.
	var clickable: bool = false
	if _carried != null and String(_carried.get("side", "")) != side:
		clickable = true
	if clickable:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(_CELL, _CELL)
		btn.flat = false
		var sb := StyleBoxFlat.new()
		sb.bg_color = NSColors.BG_CRT
		sb.border_color = NSColors.VLF_PHOSPHOR
		sb.border_width_left = 1
		sb.border_width_top = 1
		sb.border_width_right = 1
		sb.border_width_bottom = 1
		btn.add_theme_stylebox_override("normal", sb)
		btn.pressed.connect(_on_empty_pressed.bind(side))
		return btn
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(_CELL, _CELL)
	var sb_dim := StyleBoxFlat.new()
	sb_dim.bg_color = NSColors.BG_CRT
	sb_dim.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb_dim.border_width_left = 1
	sb_dim.border_width_top = 1
	sb_dim.border_width_right = 1
	sb_dim.border_width_bottom = 1
	pc.add_theme_stylebox_override("panel", sb_dim)
	return pc


# Click handlers ------------------------------------------------------

func _on_item_pressed(side: String, idx: int) -> void:
	if _carried == null:
		_carried = { "side": side, "item_idx": idx }
		_refresh()
		return
	var carried_side: String = _carried.get("side", "")
	var carried_idx: int = int(_carried.get("item_idx", -1))
	# Click on the same item we're carrying: cancel.
	if carried_side == side and carried_idx == idx:
		_carried = null
		_refresh()
		return
	# Click on a different item on the same side: re-carry the new one.
	if carried_side == side:
		_carried = { "side": side, "item_idx": idx }
		_refresh()
		return
	# Click on an item on the opposite side while carrying: treat
	# as "place into that side" — the destination grid's free-fit
	# scan picks the actual cell. The clicked item itself is not
	# affected; this is just a shortcut over having to click an
	# empty cell on the opposite side.
	_perform_transfer(carried_side)


func _on_empty_pressed(dest_side: String) -> void:
	if _carried == null:
		return
	if _carried.get("side", "") == dest_side:
		return
	_perform_transfer(_carried.get("side", ""))


func _perform_transfer(source_side: String) -> void:
	# `source_side` is where the carried item lives; the destination
	# is the other side. Routes to take_from_container or put_in_container.
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0 or _carried == null or _open_container_id < 0:
		_carried = null
		_refresh()
		return
	var idx: int = int(_carried.get("item_idx", -1))
	var ok := false
	if source_side == "container":
		ok = sim.take_from_container(sid, _open_container_id, idx)
	elif source_side == "pockets":
		ok = sim.put_in_container(sid, _open_container_id, "pockets", idx)
	if not ok:
		print("[loot] transfer failed (full or invalid)")
	_carried = null
	# Refresh happens via tick_completed; force one in case the next
	# tick is far off and the user wants immediate feedback.
	_refresh()


# Helpers -------------------------------------------------------------

func _short(s_var: Variant, max_len: int) -> String:
	var s: String = str(s_var)
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len - 1) + "…"


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
