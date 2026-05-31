extends Control
## Server Browser screen. Two-pane list/detail layout populated from a
## static mock array — real server discovery is a follow-up. Hosting
## your own lobby is a main-menu action (HOST COOP), not a row in
## this list. The "Join by Lobby ID" input at the bottom of the list
## column is the manual entry point for peers who received a lobby
## ID out of band (Steam overlay, Discord, etc).

const PATH_MAIN_MENU := "res://scenes/menus/mainMenu.tscn"

# Placeholder rows until real server discovery lands. No flavor content
# here on purpose; these just demonstrate the list/detail layout.
const _SERVERS: Array[Dictionary] = [
	{"name": "EXAMPLE SERVER 01", "host": "lan.local:27015", "pop": "4 / 12", "mode": "PURE PVE",  "ping": 38,  "up": "12d", "squall": "01:20",
	 "tags": ["PVE"], "motd": "> open lobby."},
	{"name": "EXAMPLE SERVER 02", "host": "lan.local:27016", "pop": "9 / 12", "mode": "CONTESTED", "ping": 64,  "up": "31d", "squall": "02:05",
	 "tags": ["PVE", "MODDED"], "motd": "> open lobby."},
	{"name": "EXAMPLE SERVER 03", "host": "lan.local:27017", "pop": "0 / 8",  "mode": "FULL PVP",  "ping": 110, "up": "3d",  "squall": "00:50",
	 "tags": ["PVP"], "motd": "> open lobby."},
]

var _rows: Array[Button] = []
var _selected: int = 0
var _detail_container: VBoxContainer
var _filter_input: LineEdit
var _lobby_id_input: LineEdit
var _manual_join_status: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var shell := MenuShell.new()
	add_child(shell)

	shell.set_body(_build_body())
	_refresh_detail()

	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_signal("session_failed"):
		session.session_failed.connect(func(source: String, message: String) -> void:
			if _manual_join_status != null:
				_manual_join_status.add_theme_color_override("font_color", NSColors.WARNING_RUST)
				_manual_join_status.text = "[%s] %s" % [source, message]
		)


func _build_body() -> Control:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)

	root.add_child(_build_header())

	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 0)
	root.add_child(split)

	var list_col := _build_list_column()
	list_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_col.size_flags_stretch_ratio = 1.6
	split.add_child(list_col)

	var detail_col := _build_detail_column()
	detail_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_col.size_flags_stretch_ratio = 1.0
	split.add_child(detail_col)

	return root


func _build_header() -> Control:
	var header := ScreenHeader.new()
	header.eyebrow_text = "◇ %d PUBLIC · 3 FRIENDS" % _SERVERS.size()
	header.title_text = "SERVER BROWSER"
	header.back_pressed.connect(_go_back)
	return header


func _build_list_column() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BASALT_BLACK
	sb.border_color = NSColors.LICHEN
	sb.border_width_right = 1
	wrap.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	wrap.add_child(v)

	# Filter row
	var filter_bar := MarginContainer.new()
	filter_bar.add_theme_constant_override("margin_left", 40)
	filter_bar.add_theme_constant_override("margin_right", 40)
	filter_bar.add_theme_constant_override("margin_top", 16)
	filter_bar.add_theme_constant_override("margin_bottom", 16)
	v.add_child(filter_bar)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 12)
	filter_bar.add_child(filter_row)

	_filter_input = LineEdit.new()
	_filter_input.placeholder_text = "filter…"
	_filter_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_input.text_changed.connect(func(_t: String) -> void: _rebuild_rows())
	filter_row.add_child(_filter_input)

	filter_row.add_child(NSWidgets.badge("FILTER", NSColors.FG_2))
	filter_row.add_child(NSWidgets.badge("PVE", NSColors.VLF_PHOSPHOR))
	filter_row.add_child(NSWidgets.badge("+ MODE", NSColors.FOG))
	filter_row.add_child(NSWidgets.badge("+ REGION", NSColors.FOG))

	# Column header
	v.add_child(_build_header_row())

	# List
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	var list := VBoxContainer.new()
	list.name = "List"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 0)
	scroll.add_child(list)

	_rebuild_rows_into(list)

	# Join-by-ID footer — for peers who received a lobby ID out of band.
	v.add_child(_build_join_by_id_row())
	return wrap


func _build_join_by_id_row() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_top = 1
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	wrap.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	wrap.add_child(v)

	v.add_child(NSWidgets.eyebrow("◇ JOIN BY LOBBY ID"))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)

	_lobby_id_input = LineEdit.new()
	_lobby_id_input.placeholder_text = "paste lobby id…"
	_lobby_id_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_lobby_id_input)

	var btn := NSWidgets.button("Join", NSWidgets.Variant.PRIMARY)
	btn.pressed.connect(_on_manual_join_pressed)
	row.add_child(btn)

	_manual_join_status = NSWidgets.label_mono("", 10, NSColors.FG_3)
	v.add_child(_manual_join_status)

	return wrap


func _build_header_row() -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", 40)
	wrap.add_theme_constant_override("margin_right", 40)
	wrap.add_theme_constant_override("margin_top", 14)
	wrap.add_theme_constant_override("margin_bottom", 14)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = NSColors.RULE_1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", sb)
	wrap.add_child(panel)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 12)
	panel.add_child(grid)
	for col in ["NAME", "MODE", "POP.", "PING", "BLOW."]:
		var l := NSWidgets.eyebrow(col)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
	return wrap


func _rebuild_rows() -> void:
	var list := get_tree().root.find_child("List", true, false)
	if list == null:
		return
	_rebuild_rows_into(list)


func _rebuild_rows_into(list: VBoxContainer) -> void:
	for c in list.get_children():
		c.queue_free()
	_rows.clear()
	var needle := ""
	if _filter_input != null:
		needle = _filter_input.text.to_lower()
	for i in range(_SERVERS.size()):
		var s: Dictionary = _SERVERS[i]
		var hay := ("%s %s" % [s["name"], s["host"]]).to_lower()
		if needle != "" and not hay.contains(needle):
			continue
		var row := _build_row(i, s)
		list.add_child(row)
		_rows.append(row)


func _build_row(index: int, server: Dictionary) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_stylebox_override("normal",  _row_box(index == _selected))
	b.add_theme_stylebox_override("hover",   _row_box(true))
	b.add_theme_stylebox_override("pressed", _row_box(true))
	b.add_theme_stylebox_override("focus",   _row_box(true))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(margin)

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 12)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(grid)

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := NSWidgets.label_mono(server["name"], 12, NSColors.PAGE_WHITE)
	name_col.add_child(name_l)
	var host_l := NSWidgets.label_mono(server["host"], 10, NSColors.FG_3)
	name_col.add_child(host_l)
	grid.add_child(name_col)

	grid.add_child(NSWidgets.label_mono(server["mode"], 12, _mode_color(server["mode"])))
	grid.add_child(NSWidgets.label_mono(server["pop"], 12, NSColors.PAGE_WHITE))
	grid.add_child(NSWidgets.label_mono(str(server["ping"]), 12, _ping_color(server["ping"])))
	grid.add_child(NSWidgets.label_mono(server["squall"], 12, NSColors.MIST))

	b.pressed.connect(func() -> void:
		_selected = index
		_refresh_row_styles()
		_refresh_detail()
	)
	return b


func _row_box(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if selected:
		sb.bg_color = Color(0.498, 0.698, 0.416, 0.05)
		sb.border_color = NSColors.VLF_PHOSPHOR
		sb.border_width_left = 3
	else:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = Color(0, 0, 0, 0)
		sb.border_width_left = 3
	sb.border_color = sb.border_color if selected else Color(0, 0, 0, 0)
	# hairline divider between rows
	sb.border_color = sb.border_color
	sb.border_width_bottom = 1
	sb.border_color = NSColors.RULE_1 if not selected else NSColors.VLF_PHOSPHOR
	return sb


func _mode_color(mode: String) -> Color:
	match mode:
		"PURE PVE":  return NSColors.VLF_PHOSPHOR
		"CONTESTED": return NSColors.FAC_PWA
		_: return NSColors.WARNING_RUST


func _ping_color(ping: int) -> Color:
	if ping < 60:   return NSColors.VLF_PHOSPHOR
	if ping < 100:  return NSColors.PAGE_WHITE
	return NSColors.WARNING_RUST


func _refresh_row_styles() -> void:
	for i in range(_rows.size()):
		var b: Button = _rows[i]
		b.add_theme_stylebox_override("normal", _row_box(i == _selected))


# ---------------------------------------------------------------------
# Detail column.
# ---------------------------------------------------------------------

func _build_detail_column() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 28
	sb.content_margin_bottom = 28
	wrap.add_theme_stylebox_override("panel", sb)

	_detail_container = VBoxContainer.new()
	_detail_container.add_theme_constant_override("separation", 20)
	wrap.add_child(_detail_container)

	return wrap


func _refresh_detail() -> void:
	if _detail_container == null:
		return
	for c in _detail_container.get_children():
		c.queue_free()
	if _selected < 0 or _selected >= _SERVERS.size():
		return
	var s: Dictionary = _SERVERS[_selected]

	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.add_child(NSWidgets.eyebrow("◇ SELECTED"))
	header.add_child(NSWidgets.stencil(s["name"], 26))
	_detail_container.add_child(header)

	var fields := GridContainer.new()
	fields.columns = 2
	fields.add_theme_constant_override("h_separation", 14)
	fields.add_theme_constant_override("v_separation", 14)
	for entry in [
		["HOST",         s["host"]],
		["MODE",         s["mode"]],
		["POP.",         s["pop"]],
		["UPTIME",       s["up"]],
		["PING",         "%d ms" % s["ping"]],
		["NEXT SQUALL", s["squall"]],
	]:
		fields.add_child(_detail_field(entry[0], entry[1]))
	_detail_container.add_child(fields)

	var tags_v := VBoxContainer.new()
	tags_v.add_theme_constant_override("separation", 8)
	tags_v.add_child(NSWidgets.eyebrow("TAGS"))
	var tags_row := HBoxContainer.new()
	tags_row.add_theme_constant_override("separation", 8)
	for tag in s["tags"]:
		tags_row.add_child(NSWidgets.badge(tag, NSColors.FOG))
	tags_v.add_child(tags_row)
	_detail_container.add_child(tags_v)

	var motd := CRTPanel.new()
	motd.heading_left = "◇ MOTD"
	motd.heading_right = s["host"]
	motd.body_text = s["motd"]
	_detail_container.add_child(motd)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_container.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	var connect_btn := NSWidgets.button("Connect", NSWidgets.Variant.PRIMARY)
	connect_btn.pressed.connect(_on_connect_pressed.bind(s))
	actions.add_child(connect_btn)
	actions.add_child(NSWidgets.button("Bookmark", NSWidgets.Variant.SECONDARY))
	actions.add_child(NSWidgets.button("Details", NSWidgets.Variant.GHOST))
	_detail_container.add_child(actions)


func _detail_field(key: String, value: String) -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.content_margin_left = 10
	wrap.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	wrap.add_child(v)
	v.add_child(NSWidgets.eyebrow(key))
	v.add_child(NSWidgets.label_mono(value, 13, NSColors.PAGE_WHITE))
	return wrap


# ---------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------

func _on_connect_pressed(_server: Dictionary) -> void:
	# These rows are mock data until real server discovery is wired.
	# Surface that clearly in the MOTD slot; use HOST COOP from the
	# main menu or the Join-by-ID row below to connect for real.
	for c in _detail_container.get_children():
		if c is CRTPanel:
			(c as CRTPanel).body_text = "> mock entry. host your own via main menu ›  HOST COOP, or paste a lobby ID below."


func _on_manual_join_pressed() -> void:
	var text: String = _lobby_id_input.text.strip_edges()
	if text.is_empty():
		_manual_join_status.text = "Paste a lobby ID first."
		return
	if not text.is_valid_int():
		_manual_join_status.text = "Lobby ID must be a number."
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	_manual_join_status.text = "Joining %s…" % text
	session.join(text.to_int())


func _go_back() -> void:
	get_tree().change_scene_to_file(PATH_MAIN_MENU)
