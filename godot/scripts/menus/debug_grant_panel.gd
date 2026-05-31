extends CanvasLayer
## Dev-only spawn-by-category panel. Replaces the old `G`-cycle in
## `debug_overlay.gd` which was limited to a hardcoded 8-item list.
##
## Toggle: `G` (the `inventory_grant_test` action).
## Reads the full item catalog via `SimHost.item_catalog()`, groups
## by category bucket, and offers per-row `+1` / `+10` / `+stack`
## quick-grants. Search field filters by name substring.
##
## Lives as a child of `session_root.tscn` parallel to `InventoryPanel`.
## Closing the panel restores mouse-capture identically to inventory.
##
## **Strictly debug** — slice 3 ships proper crafting + loot economy,
## at which point this panel goes behind a `--dev` flag.

const _PANEL_WIDTH: int = 720
const _PANEL_HEIGHT: int = 640

# Display order + grouping. Maps the sim's `ItemCategory` strings to
# broader player-facing buckets so the panel doesn't show 12
# top-level sections.
const _CATEGORY_BUCKETS: Array = [
	{"label": "WEAPONS", "cats": ["weapon_primary", "weapon_secondary", "sidearm", "melee"]},
	{"label": "MAGAZINES & AMMO", "cats": ["magazine", "ammo"]},
	{"label": "ARMOR & GEAR", "cats": ["armor_vest", "head_gear", "eyes", "chest_rig", "backpack"]},
	{"label": "MEDICAL & DRUGS", "cats": ["medical", "drug"]},
	{"label": "FOOD & WATER", "cats": ["food", "drink"]},
	{"label": "TOOLS & COMPONENTS", "cats": ["tool", "component"]},
	{"label": "MISC", "cats": ["misc", "junk"]},
]

var _root: Control
var _search_box: LineEdit
var _list_box: VBoxContainer
var _last_catalog: Array = []
var _filter_text: String = ""


func _ready() -> void:
	layer = 50
	visible = false
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory_grant_test"):
		var session := get_node_or_null("/root/GameSession")
		if visible:
			_close()
			get_viewport().set_input_as_handled()
			return
		if session != null and session.has_method("in_game") and session.in_game():
			_open()
			get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	# Esc closes when open.
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()


func _open() -> void:
	visible = true
	_refresh_catalog()
	_render()
	# Release mouse so the search field + buttons can receive clicks.
	# Closes via Esc / G restore the capture state in `_close`.
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_search_box.grab_focus()


func _close() -> void:
	visible = false
	# Re-capture mouse for the FPS controller. `player.gd` re-captures
	# on next LMB anyway, but doing it here avoids a one-frame visible
	# cursor flash.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# Dim background.
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	# Centered panel.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(_PANEL_WIDTH, _PANEL_HEIGHT)
	panel.position = Vector2(-_PANEL_WIDTH / 2.0, -_PANEL_HEIGHT / 2.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	# Header row: title + close button.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	var title := NSWidgets.label_mono("DEBUG SPAWN", 16, NSColors.VLF_PHOSPHOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.add_theme_font_override("font", NSFonts.MONO_BOLD)
	close_btn.add_theme_font_size_override("font_size", 14)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(_close)
	header.add_child(close_btn)
	v.add_child(header)

	# Hint line.
	var hint := NSWidgets.label_mono(
		"G or Esc to close · click +1 / +10 / +stack to grant",
		10,
		NSColors.FG_3,
	)
	v.add_child(hint)

	# Search box.
	_search_box = LineEdit.new()
	_search_box.placeholder_text = "filter by name or id…"
	_search_box.add_theme_font_override("font", NSFonts.MONO)
	_search_box.add_theme_font_size_override("font_size", 12)
	_search_box.text_changed.connect(_on_search_changed)
	v.add_child(_search_box)

	# Scrollable list.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 4)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)


func _refresh_catalog() -> void:
	var sim := _sim()
	if sim == null or not sim.has_method("item_catalog"):
		_last_catalog = []
		return
	var raw: Variant = sim.item_catalog()
	if typeof(raw) == TYPE_ARRAY:
		_last_catalog = raw as Array
	else:
		_last_catalog = []


func _on_search_changed(new_text: String) -> void:
	_filter_text = new_text.strip_edges().to_lower()
	_render()


func _render() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	if _last_catalog.is_empty():
		_list_box.add_child(NSWidgets.label_mono(
			"sim not started or item catalog empty",
			11,
			NSColors.FG_3,
		))
		return

	# Bucket items by category.
	var by_cat: Dictionary = {}
	for it_var in _last_catalog:
		if typeof(it_var) != TYPE_DICTIONARY:
			continue
		var it := it_var as Dictionary
		var cat: String = String(it.get("category", "misc"))
		if not _matches_filter(it):
			continue
		if not by_cat.has(cat):
			by_cat[cat] = []
		(by_cat[cat] as Array).append(it)

	var rendered_count := 0
	for bucket in _CATEGORY_BUCKETS:
		var bucket_items: Array = []
		for cat in bucket["cats"]:
			if by_cat.has(cat):
				for it in (by_cat[cat] as Array):
					bucket_items.append(it)
		if bucket_items.is_empty():
			continue
		bucket_items.sort_custom(_sort_by_name)
		_list_box.add_child(_build_section_header(bucket["label"], bucket_items.size()))
		for it_var in bucket_items:
			_list_box.add_child(_build_item_row(it_var as Dictionary))
			rendered_count += 1

	if rendered_count == 0:
		_list_box.add_child(NSWidgets.label_mono(
			"no matches for '%s'" % _filter_text,
			11,
			NSColors.FG_3,
		))


func _matches_filter(it: Dictionary) -> bool:
	if _filter_text.is_empty():
		return true
	var name: String = String(it.get("name", "")).to_lower()
	var id: String = String(it.get("id", "")).to_lower()
	return name.contains(_filter_text) or id.contains(_filter_text)


func _sort_by_name(a: Variant, b: Variant) -> bool:
	var an: String = String((a as Dictionary).get("name", ""))
	var bn: String = String((b as Dictionary).get("name", ""))
	return an.naturalnocasecmp_to(bn) < 0


func _build_section_header(label: String, count: int) -> Control:
	var h := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.LICHEN
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	h.add_theme_stylebox_override("panel", sb)
	var l := NSWidgets.label_mono(
		"%s  (%d)" % [label, count],
		11,
		NSColors.PAGE_WHITE,
	)
	h.add_child(l)
	return h


func _build_item_row(it: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name: String = String(it.get("name", "?"))
	var id: String = String(it.get("id", ""))
	var stack_size: int = int(it.get("stack_size", 1))
	var weight: float = float(it.get("weight", 0.0))

	# Name + id (greyed) + weight.
	var info_v := VBoxContainer.new()
	info_v.add_theme_constant_override("separation", 0)
	info_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_v.add_child(NSWidgets.label_mono(name, 12, NSColors.PAGE_WHITE))
	var meta := "%s · %.2f kg" % [id, weight]
	if stack_size > 1:
		meta += " · stack %d" % stack_size
	info_v.add_child(NSWidgets.label_mono(meta, 9, NSColors.FG_3))
	row.add_child(info_v)

	# Quick-grant buttons.
	row.add_child(_build_grant_button("+1", id, 1))
	row.add_child(_build_grant_button("+10", id, 10))
	if stack_size > 1:
		row.add_child(_build_grant_button("+%d" % stack_size, id, stack_size))

	return row


func _build_grant_button(label: String, id: String, count: int) -> Button:
	var b := Button.new()
	b.text = label
	b.add_theme_font_override("font", NSFonts.MONO_BOLD)
	b.add_theme_font_size_override("font_size", 11)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(54, 0)
	b.pressed.connect(_on_grant_pressed.bind(id, count))
	return b


func _on_grant_pressed(item_id: String, count: int) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0 or not sim.has_method("grant_item"):
		return
	var ok: bool = sim.grant_item(sid, item_id, count)
	if ok:
		print("[grant] +%d %s" % [count, item_id])
	else:
		print("[grant] failed +%d %s" % [count, item_id])


func _sim() -> Node:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return null
	return session.get_node_or_null("SimHost")


func _local_sid() -> int:
	var session := get_node_or_null("/root/GameSession")
	if session == null or not session.has_method("local_steam_id"):
		return 0
	return int(session.local_steam_id())
