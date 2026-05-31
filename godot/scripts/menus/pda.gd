extends CanvasLayer
## The drifter's in-pocket personal digital assistant. A CRT-flavored
## modal that overlays the live game — five pages under a left tab
## rail (Map, Dossiers, Chronicle, Radio Log, Settings). Every page
## is a scaffolded stub; the real content lands when the backing
## sim/document systems do.
##
## Lives as a child of `session_root.tscn`. Opens via the game menu's
## "Open PDA" action; closes with the `toggle_pda` input action
## (fallback ESC closes, same as game menu). The game keeps running
## beneath the scrim — the PDA is diegetically something the drifter
## is looking at on their belt, not a world-stop.

const _TABS: PackedStringArray = ["MAP", "DOSSIERS", "CHRONICLE", "RADIO LOG", "SETTINGS"]

var _root: Control
var _tab_column: TabColumn
var _content_slot: MarginContainer
var _active: String = "MAP"


func _ready() -> void:
	layer = 50  # above HUD (10), below game menu (80) and debug (100)
	visible = false
	_build()


func open_pda() -> void:
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func close_pda() -> void:
	visible = false
	# Only recapture if we're in a live game; otherwise leave mouse
	# state to the current scene.
	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_method("in_game") and session.in_game():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_pda"):
		var session := get_node_or_null("/root/GameSession")
		if visible:
			close_pda()
			get_viewport().set_input_as_handled()
			return
		if session != null and session.has_method("in_game") and session.in_game():
			open_pda()
			get_viewport().set_input_as_handled()
			return
	if visible and event.is_action_pressed("ui_cancel"):
		close_pda()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.45)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(scrim)

	# Centered PDA frame — fixed aspect, not full-bleed.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var chassis := PanelContainer.new()
	chassis.custom_minimum_size = Vector2(960, 620)
	var chassis_sb := StyleBoxFlat.new()
	chassis_sb.bg_color = NSColors.WET_SLATE
	chassis_sb.border_color = NSColors.LICHEN
	chassis_sb.border_width_left = 1
	chassis_sb.border_width_top = 1
	chassis_sb.border_width_right = 1
	chassis_sb.border_width_bottom = 1
	chassis_sb.shadow_color = Color(0, 0, 0, 0.8)
	chassis_sb.shadow_offset = Vector2(0, 4)
	chassis.add_theme_stylebox_override("panel", chassis_sb)
	center.add_child(chassis)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	chassis.add_child(body)

	# Top strip — branded header so it's clear this is in-fiction gear.
	body.add_child(_build_header_strip())

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 0)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(split)

	_tab_column = TabColumn.new()
	_tab_column.tabs = _TABS
	_tab_column.initial_tab = _active
	_tab_column.column_width = 180
	_tab_column.tab_selected.connect(func(name: String) -> void:
		_active = name
		_refresh_content()
	)
	split.add_child(_tab_column)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)

	_content_slot = MarginContainer.new()
	_content_slot.add_theme_constant_override("margin_left", 36)
	_content_slot.add_theme_constant_override("margin_right", 36)
	_content_slot.add_theme_constant_override("margin_top", 24)
	_content_slot.add_theme_constant_override("margin_bottom", 24)
	_content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content_slot)

	_refresh_content()


func _build_header_strip() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BASALT_BLACK
	sb.border_color = NSColors.LICHEN
	sb.border_width_bottom = 1
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 16
	sb.content_margin_bottom = 12
	wrap.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	wrap.add_child(row)

	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.add_theme_constant_override("separation", 4)
	brand.add_child(NSWidgets.eyebrow("◇ SURPLUS PDA · MODEL 7"))
	brand.add_child(NSWidgets.stencil("WANDERER", 22))
	row.add_child(brand)

	var stats := VBoxContainer.new()
	stats.add_theme_constant_override("separation", 4)
	stats.alignment = BoxContainer.ALIGNMENT_END
	stats.add_child(NSWidgets.label_mono("BATTERY — 84%", 11, NSColors.VLF_PHOSPHOR))
	stats.add_child(NSWidgets.label_mono("SIGNAL — 76 Hz · NOMINAL", 11, NSColors.FG_3))
	row.add_child(stats)

	var close := NSWidgets.button("Close", NSWidgets.Variant.GHOST)
	close.pressed.connect(close_pda)
	row.add_child(close)

	return wrap


func _refresh_content() -> void:
	for c in _content_slot.get_children():
		c.queue_free()
	match _active:
		"MAP":       _content_slot.add_child(_build_map_page())
		"DOSSIERS":  _content_slot.add_child(_build_dossiers_page())
		"CHRONICLE": _content_slot.add_child(_build_chronicle_page())
		"RADIO LOG": _content_slot.add_child(_build_radio_log_page())
		"SETTINGS":  _content_slot.add_child(_build_settings_page())
		_:           _content_slot.add_child(_stub("[ PAGE STUB ]"))


func _build_map_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.add_child(NSWidgets.eyebrow("◇ REGION MAP"))
	v.add_child(NSWidgets.stencil("WHERE YOU ARE", 22))
	v.add_child(_stub("— paper map scaffold. overlays wait on region graph + fog-of-exploration. —"))
	return v


func _build_dossiers_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.add_child(NSWidgets.eyebrow("◇ DOCUMENT TRAIL"))
	v.add_child(NSWidgets.stencil("RECOVERED — 0", 22))
	v.add_child(_stub("— found-documents reader scaffold. wait for sim-side documents system. —"))
	return v


func _build_chronicle_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.add_child(NSWidgets.eyebrow("◇ RUN CHRONICLE"))
	v.add_child(NSWidgets.stencil("WHAT HAPPENED", 22))
	v.add_child(_stub("— event log scaffold. backed by `sim.chronicle_summary()` once per-run history is indexed. —"))
	return v


func _build_radio_log_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.add_child(NSWidgets.eyebrow("◇ RADIO LOG"))
	v.add_child(NSWidgets.stencil("76 Hz · 146.520 · …", 22))
	v.add_child(_stub("— transcript scaffold. depends on voice subsystem + broadcast shadow. —"))
	return v


func _build_settings_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.add_child(NSWidgets.eyebrow("◇ PDA SETTINGS"))
	v.add_child(NSWidgets.stencil("LOCAL PREFERENCES", 22))
	v.add_child(_stub("— for things the PDA owns itself: backlight, beep volume, map annotation style. —"))
	return v


func _stub(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_override("font", NSFonts.MONO)
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	p.add_child(l)
	return p
