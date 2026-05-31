extends CanvasLayer
## Bottom-center hotbar HUD. 4 belt slots driven by the
## `equipment_slot_catalog()` registry — any slot flagged
## `is_hotbar = true` shows up here in `hotbar_index` order. Polls the
## sim's `tick_completed` signal to refresh contents.
##
## Number keys 1..N (bound as `hotbar_1` .. `hotbar_N` in the
## InputMap) trigger `consume_hotbar(idx, body_part)` for that slot.
## Today every belt slot consumes torso-targeted items by default
## (matches the existing `H` debug key) — once the inventory panel
## offers a body-part picker for treatments, this can route through
## that.

const _SLOT_SIZE: int = 60
const _DEFAULT_BODY_PART: String = "torso"

var _row: HBoxContainer
var _slots_by_index: Dictionary = {}   # int hotbar_index -> Panel
var _slot_labels_by_index: Dictionary = {}  # int -> { name: Label, count: Label }
var _last_slot_catalog: Array = []


func _ready() -> void:
	layer = 12  # above HUD (10), below PDA / inventory (40+)
	_build()
	_refresh_visibility()
	# Pull catalog once; refresh contents each tick.
	_reload_catalog()
	_refresh_contents()
	var sim := _sim()
	if sim != null and not sim.is_connected("tick_completed", _on_tick_completed):
		sim.connect("tick_completed", _on_tick_completed)
	# Visibility tick.
	var t := Timer.new()
	t.wait_time = 0.25
	t.autostart = true
	t.timeout.connect(_refresh_visibility)
	add_child(t)


func _on_tick_completed(_tick: int, _payload: PackedByteArray) -> void:
	if visible:
		_refresh_contents()


func _refresh_visibility() -> void:
	var session := get_node_or_null("/root/GameSession")
	visible = session != null and session.has_method("in_game") and session.in_game()
	# If the sim came online late, the catalog might still be empty.
	if visible and _last_slot_catalog.is_empty():
		_reload_catalog()
		_rebuild_slot_widgets()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Walk every known hotbar slot and check the matching action.
	for idx_var in _slots_by_index.keys():
		var idx: int = idx_var
		var action: String = "hotbar_%d" % idx
		if InputMap.has_action(action) and event.is_action_pressed(action):
			_fire_hotbar(idx)
			get_viewport().set_input_as_handled()
			return


# -------- Build --------

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Anchor the hotbar at the bottom-center, ~120 px up from the bottom
	# edge so it sits above the existing HUD's bottom-center "prompt"
	# slot without colliding.
	var anchor := Control.new()
	anchor.anchor_left = 0.5
	anchor.anchor_right = 0.5
	anchor.anchor_top = 1.0
	anchor.anchor_bottom = 1.0
	anchor.offset_left = -200
	anchor.offset_right = 200
	anchor.offset_top = -100
	anchor.offset_bottom = -40
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(anchor)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(_row)


func _rebuild_slot_widgets() -> void:
	for c in _row.get_children():
		c.queue_free()
	_slots_by_index.clear()
	_slot_labels_by_index.clear()
	# Sort hotbar slots by index.
	var hotbar_slots: Array = []
	for s_var in _last_slot_catalog:
		var s: Dictionary = s_var
		if bool(s.get("is_hotbar", false)):
			hotbar_slots.append(s)
	hotbar_slots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("hotbar_index", 0)) < int(b.get("hotbar_index", 0))
	)
	for s_var in hotbar_slots:
		var s: Dictionary = s_var
		var idx: int = int(s.get("hotbar_index", 0))
		var widget := _build_slot_widget(idx)
		_row.add_child(widget)
		_slots_by_index[idx] = widget


func _build_slot_widget(idx: int) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(_SLOT_SIZE, _SLOT_SIZE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)

	var key_label := NSWidgets.label_mono("[%d]" % idx, 9, NSColors.FG_3)
	v.add_child(key_label)

	var name_label := NSWidgets.label_mono("—", 11, NSColors.PAGE_WHITE)
	name_label.clip_text = true
	v.add_child(name_label)

	var count_label := NSWidgets.label_mono("", 10, NSColors.VLF_PHOSPHOR)
	v.add_child(count_label)

	_slot_labels_by_index[idx] = {"name": name_label, "count": count_label}
	return p


# -------- Refresh --------

func _refresh_contents() -> void:
	if _slots_by_index.is_empty():
		_rebuild_slot_widgets()
	var view := _player_view()
	var equipment: Dictionary = view.get("equipment", {})
	# Walk the cached catalog so we know which slot id maps to which idx.
	for s_var in _last_slot_catalog:
		var s: Dictionary = s_var
		if not bool(s.get("is_hotbar", false)):
			continue
		var idx: int = int(s.get("hotbar_index", 0))
		var slot_id: String = s.get("id", "")
		var labels = _slot_labels_by_index.get(idx, null)
		if labels == null:
			continue
		var item_var = equipment.get(slot_id, null)
		if item_var is Dictionary:
			var item: Dictionary = item_var
			labels["name"].text = String(item.get("name", "?"))
			var count: int = int(item.get("count", 1))
			labels["count"].text = ("×%d" % count) if count > 1 else ""
		else:
			labels["name"].text = "—"
			labels["count"].text = ""


# -------- Action --------

func _fire_hotbar(idx: int) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	# Default body-part for hotbar items today is torso. The
	# inventory panel can offer a picker later for limb-specific
	# treatments; for the common case (food, drink, drug, generic
	# bandage) torso is fine.
	var ok: bool = sim.consume_hotbar(sid, idx, _DEFAULT_BODY_PART)
	if not ok:
		print("[hotbar] %d failed (empty / wrong action / no wound)" % idx)


# -------- Util --------

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


func _player_view() -> Dictionary:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return {}
	return sim.player_state(sid)


func _reload_catalog() -> void:
	var sim := _sim()
	if sim == null:
		_last_slot_catalog = []
		return
	_last_slot_catalog = sim.equipment_slot_catalog()
