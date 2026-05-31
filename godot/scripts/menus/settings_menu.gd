extends Control
## Settings screen. Tabbed shell — Radio tab is implemented with the
## frequency input, transmit-mode segmented control, proximity range,
## input gain, background static, and broadcast-shadow glitch selector
## per the design. Other tabs (Audio / Video / Input / Server Rules /
## Accessibility) render the "not implemented in this kit" placeholder
## copy, matching the design export. All controls are cosmetic for
## now; hook them into the real audio/radio config in a later pass.

const PATH_MAIN_MENU := "res://scenes/menus/mainMenu.tscn"

const _TABS: Array[String] = ["AUDIO", "VIDEO", "RADIO", "INPUT", "SERVER RULES", "ACCESSIBILITY"]

var _active_tab: String = "RADIO"
var _content_slot: Control


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var shell := MenuShell.new()
	add_child(shell)
	shell.set_body(_build_body())
	_refresh_content()


func _build_body() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)

	v.add_child(_build_header())

	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 0)
	v.add_child(split)

	split.add_child(_build_tab_column())
	split.add_child(_build_content_column())
	return v


func _build_header() -> Control:
	var header := ScreenHeader.new()
	header.eyebrow_text = "◇ SETTINGS"
	header.title_text = "EQUIPMENT & SIGNAL"
	header.back_pressed.connect(_go_back)
	return header


func _build_tab_column() -> Control:
	var tabs := TabColumn.new()
	tabs.tabs = PackedStringArray(_TABS)
	tabs.initial_tab = _active_tab
	tabs.tab_selected.connect(func(name: String) -> void:
		_active_tab = name
		_refresh_content()
	)
	return tabs


# ---------------------------------------------------------------------
# Content column.
# ---------------------------------------------------------------------

func _build_content_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_content_slot = MarginContainer.new()
	_content_slot.add_theme_constant_override("margin_left", 48)
	_content_slot.add_theme_constant_override("margin_right", 48)
	_content_slot.add_theme_constant_override("margin_top", 24)
	_content_slot.add_theme_constant_override("margin_bottom", 24)
	_content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content_slot)

	return scroll


func _refresh_content() -> void:
	for c in _content_slot.get_children():
		c.queue_free()
	match _active_tab:
		"AUDIO":         _content_slot.add_child(_build_audio_tab())
		"VIDEO":         _content_slot.add_child(_build_video_tab())
		"RADIO":         _content_slot.add_child(_build_radio_tab())
		"INPUT":         _content_slot.add_child(_build_input_tab())
		"SERVER RULES":  _content_slot.add_child(_build_server_rules_tab())
		"ACCESSIBILITY": _content_slot.add_child(_build_accessibility_tab())
		_:               _content_slot.add_child(_build_stub_tab(_active_tab))


# ---------------------------------------------------------------------
# Audio tab — five volume sliders. Metadata-only for now; real wire-up
# to AudioServer buses waits on `default_bus_layout.tres` authoring.
# ---------------------------------------------------------------------

func _build_audio_tab() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var badges := HBoxContainer.new()
	badges.add_theme_constant_override("separation", 10)
	badges.add_child(NSWidgets.badge("OUTPUT · DEFAULT DEVICE", NSColors.VLF_PHOSPHOR))
	badges.add_child(NSWidgets.badge("BUS LAYOUT PENDING", NSColors.FOG))
	v.add_child(badges)
	v.add_child(_spacer(16))

	v.add_child(NSWidgets.form_row("Master", "global output level",
		_slider(int(SettingsStore.get_value("audio.master_volume")), "audio.master_volume")))
	v.add_child(NSWidgets.form_row("SFX", "gunfire, footsteps, faults",
		_slider(int(SettingsStore.get_value("audio.sfx_volume")), "audio.sfx_volume")))
	v.add_child(NSWidgets.form_row("Music", "campfire cues, title theme",
		_slider(int(SettingsStore.get_value("audio.music_volume")), "audio.music_volume")))
	v.add_child(NSWidgets.form_row("Voice", "in-world voice chat, radio",
		_slider(int(SettingsStore.get_value("audio.voice_volume")), "audio.voice_volume")))
	v.add_child(NSWidgets.form_row("Ambient", "wind, rain, broadcast carrier",
		_slider(int(SettingsStore.get_value("audio.ambient_volume")), "audio.ambient_volume")))

	return v


# ---------------------------------------------------------------------
# Video tab — window mode + vsync apply immediately; ui scale + view
# distance persist but only ui scale is wired (content_scale_factor).
# ---------------------------------------------------------------------

func _build_video_tab() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var mode_control := _segmented(
		["WINDOWED", "FULLSCREEN", "BORDERLESS"],
		str(SettingsStore.get_value("video.window_mode")),
		"video.window_mode",
		func(new_value: String) -> void: _apply_window_mode(new_value),
	)
	v.add_child(NSWidgets.form_row("Window mode", "applied on the spot",
		mode_control))

	var vsync_control := _segmented(
		["ON", "OFF"],
		str(SettingsStore.get_value("video.vsync")),
		"video.vsync",
		func(new_value: String) -> void: _apply_vsync(new_value),
	)
	v.add_child(NSWidgets.form_row("VSync", "cap frames to display refresh",
		vsync_control))

	var scale_control := _slider(
		int(SettingsStore.get_value("video.ui_scale")),
		"video.ui_scale",
		75, 150,
		func(val: int) -> void: _apply_ui_scale(val),
	)
	v.add_child(NSWidgets.form_row("UI scale", "percent · affects all HUD + menu chrome",
		scale_control))

	v.add_child(NSWidgets.form_row("View distance", "meters · higher hurts framerate in dense cuts",
		_slider(int(SettingsStore.get_value("video.view_distance")), "video.view_distance", 200, 2000)))

	return v


func _apply_window_mode(mode: String) -> void:
	var display_mode: int
	match mode:
		"WINDOWED":   display_mode = DisplayServer.WINDOW_MODE_WINDOWED
		"FULLSCREEN": display_mode = DisplayServer.WINDOW_MODE_FULLSCREEN
		"BORDERLESS": display_mode = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
		_:            return
	DisplayServer.window_set_mode(display_mode)


func _apply_vsync(value: String) -> void:
	var mode: int = DisplayServer.VSYNC_ENABLED if value == "ON" else DisplayServer.VSYNC_DISABLED
	DisplayServer.window_set_vsync_mode(mode)


func _apply_ui_scale(percent: int) -> void:
	var w := get_window()
	if w != null:
		w.content_scale_factor = float(percent) / 100.0


# ---------------------------------------------------------------------
# Input tab — read-only binding list with per-action rebind stubs.
# Real rebinding waits on a modal capture flow.
# ---------------------------------------------------------------------

const _REBINDABLE_ACTIONS: Array = [
	["move_forward",        "Move forward"],
	["move_back",           "Move back"],
	["move_left",           "Strafe left"],
	["move_right",          "Strafe right"],
	["save_now",            "Force save"],
	["ui_cancel",           "Open system menu"],
	["toggle_debug",        "Toggle debug readout"],
	["toggle_npc_labels",   "Toggle NPC labels (dev)"],
	["cycle_map",           "Cycle map (dev)"],
	["advance_time",        "Advance time +1h (dev)"],
]


func _build_input_tab() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var note := HBoxContainer.new()
	note.add_theme_constant_override("separation", 10)
	note.add_child(NSWidgets.badge("VIEW ONLY", NSColors.FOG))
	note.add_child(NSWidgets.badge("REBINDING — SOON", NSColors.WARNING_RUST))
	v.add_child(note)
	v.add_child(_spacer(16))

	for entry in _REBINDABLE_ACTIONS:
		var action_name: String = entry[0]
		var display: String = entry[1]
		var current: String = _action_binding_string(action_name)

		var control := HBoxContainer.new()
		control.add_theme_constant_override("separation", 8)
		var key_l := NSWidgets.label_mono(current, 12, NSColors.VLF_PHOSPHOR)
		key_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		control.add_child(key_l)
		var rebind := NSWidgets.button("Rebind", NSWidgets.Variant.GHOST)
		rebind.disabled = true
		rebind.tooltip_text = "Rebinding is not implemented yet."
		control.add_child(rebind)

		v.add_child(NSWidgets.form_row(display, "", control))
	return v


static func _action_binding_string(action: String) -> String:
	if not InputMap.has_action(action):
		return "—"
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "—"
	var parts: Array[String] = []
	for ev in events:
		parts.append(ev.as_text())
	return " · ".join(parts)


# ---------------------------------------------------------------------
# Accessibility — ui scale wired; remaining toggles metadata-only
# until the relevant subsystems honor them.
# ---------------------------------------------------------------------

func _build_accessibility_tab() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var scale_control := _slider(
		int(SettingsStore.get_value("video.ui_scale")),
		"video.ui_scale",
		75, 150,
		func(val: int) -> void: _apply_ui_scale(val),
	)
	v.add_child(NSWidgets.form_row("UI scale", "shared with Video tab",
		scale_control))

	v.add_child(NSWidgets.form_row("Color-blind mode", "palette remap for icons + faction tokens",
		_segmented(
			["NONE", "PROTANOPIA", "DEUTERANOPIA", "TRITANOPIA"],
			str(SettingsStore.get_value("accessibility.color_blind")),
			"accessibility.color_blind",
		)))

	v.add_child(NSWidgets.form_row("Subtitles", "for radio, broadcast, NPC chatter",
		_toggle("accessibility.subtitles")))
	v.add_child(NSWidgets.form_row("Reduced motion", "disable camera drift, CRT scanlines",
		_toggle("accessibility.reduced_motion")))
	v.add_child(NSWidgets.form_row("Screen shake", "on for impacts, explosions, squalls",
		_toggle("accessibility.screen_shake")))

	return v


# ---------------------------------------------------------------------
# Server rules — host-time defaults the host can override per lobby
# once the session-creation flow lands. Displayed here so the host
# has a single place to pick their usual defaults.
# ---------------------------------------------------------------------

func _build_server_rules_tab() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var note := HBoxContainer.new()
	note.add_theme_constant_override("separation", 10)
	note.add_child(NSWidgets.badge("HOST DEFAULTS", NSColors.VLF_PHOSPHOR))
	note.add_child(NSWidgets.badge("PER-LOBBY OVERRIDE — SOON", NSColors.FOG))
	v.add_child(note)
	v.add_child(_spacer(16))

	v.add_child(NSWidgets.form_row("PvP mode", "what harm is permitted between drifters",
		_segmented(
			["PVE", "MIXED", "PVP"],
			str(SettingsStore.get_value("server.pvp_mode")),
			"server.pvp_mode",
		)))

	v.add_child(NSWidgets.form_row("Friendly fire", "teammates can damage each other",
		_toggle("server.friendly_fire")))
	v.add_child(NSWidgets.form_row("Hardcore start", "no map markers, no compass, no carry between runs",
		_toggle("server.hardcore")))
	v.add_child(NSWidgets.form_row("Peace-bond at hubs", "weapons sealed inside hub perimeters",
		_toggle("server.peace_bond_hubs")))

	return v


# ---------------------------------------------------------------------
# Small helpers — spacer + bool toggle.
# ---------------------------------------------------------------------

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _toggle(store_key: String) -> Control:
	var current: bool = bool(SettingsStore.get_value(store_key))
	var current_str: String = "ON" if current else "OFF"
	return _segmented(
		["ON", "OFF"],
		current_str,
		"",
		func(new_value: String) -> void:
			SettingsStore.set_value(store_key, new_value == "ON"),
	)


func _build_radio_tab() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)

	var badges := HBoxContainer.new()
	badges.add_theme_constant_override("separation", 10)
	badges.add_child(NSWidgets.badge("VOICE RADIO · IN-WORLD", NSColors.VLF_PHOSPHOR))
	badges.add_child(NSWidgets.badge("NO GLOBAL TEXT", NSColors.FOG))
	v.add_child(badges)

	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 16)
	v.add_child(pad)

	var freq := _phosphor_line_edit(str(SettingsStore.get_value("radio.primary_frequency")), 140)
	freq.text_changed.connect(func(t: String) -> void:
		SettingsStore.set_value("radio.primary_frequency", t)
	)
	v.add_child(NSWidgets.form_row(
		"Primary frequency",
		"your character's default, saved to PDA",
		freq,
	))

	v.add_child(NSWidgets.form_row(
		"Transmit mode",
		"",
		_segmented(
			["PUSH-TO-TALK", "OPEN MIC", "MORSE"],
			str(SettingsStore.get_value("radio.transmit_mode")),
			"radio.transmit_mode",
		),
	))
	v.add_child(NSWidgets.form_row(
		"Proximity range",
		"meters · falls off with basalt and fog",
		_slider(int(SettingsStore.get_value("radio.proximity_range")), "radio.proximity_range"),
	))
	v.add_child(NSWidgets.form_row(
		"Input gain",
		"",
		_slider(int(SettingsStore.get_value("radio.input_gain")), "radio.input_gain"),
	))
	v.add_child(NSWidgets.form_row(
		"Background static",
		"louder radios draw more attention",
		_slider(int(SettingsStore.get_value("radio.background_static")), "radio.background_static"),
	))
	v.add_child(NSWidgets.form_row(
		"Broadcast-shadow glitch",
		"enable diegetic corruption of text in the shadow",
		_segmented(
			["OFF", "LIGHT", "FULL"],
			str(SettingsStore.get_value("radio.broadcast_shadow_glitch")),
			"radio.broadcast_shadow_glitch",
		),
	))
	return v


func _phosphor_line_edit(initial: String, min_width: int) -> LineEdit:
	var le := LineEdit.new()
	le.text = initial
	le.custom_minimum_size = Vector2(min_width, 0)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = NSColors.BG_CRT
	sb_n.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb_n.border_width_left = 1
	sb_n.border_width_top = 1
	sb_n.border_width_right = 1
	sb_n.border_width_bottom = 1
	sb_n.content_margin_left = 12
	sb_n.content_margin_right = 12
	sb_n.content_margin_top = 9
	sb_n.content_margin_bottom = 9
	var sb_f := sb_n.duplicate() as StyleBoxFlat
	sb_f.border_color = NSColors.VLF_PHOSPHOR
	le.add_theme_stylebox_override("normal", sb_n)
	le.add_theme_stylebox_override("focus",  sb_f)
	le.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	le.add_theme_color_override("caret_color", NSColors.VLF_PHOSPHOR)
	le.add_theme_color_override("selection_color", Color(0.306, 0.435, 0.259, 0.6))
	return le


func _segmented(options: Array, selected: String, store_key: String = "", on_change: Callable = Callable()) -> Control:
	var wrap := HBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)
	var buttons: Array[Button] = []
	for i in range(options.size()):
		var opt: String = options[i]
		var b := Button.new()
		b.text = opt
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.add_theme_font_override("font", NSFonts.MONO_BOLD)
		b.add_theme_font_size_override("font_size", 11)
		_apply_segmented_style(b, opt == selected, i == options.size() - 1)
		b.pressed.connect(func() -> void:
			selected = opt
			for j in range(buttons.size()):
				_apply_segmented_style(buttons[j], options[j] == selected, j == options.size() - 1)
			if store_key != "":
				SettingsStore.set_value(store_key, selected)
			if on_change.is_valid():
				on_change.call(selected)
		)
		buttons.append(b)
		wrap.add_child(b)
	return wrap


func _apply_segmented_style(b: Button, is_active: bool, is_last: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.VLF_PHOSPHOR_DIM if is_active else Color(0, 0, 0, 0)
	sb.border_color = NSColors.LICHEN
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	if is_last:
		sb.border_width_right = 1
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("focus",   sb)
	var active_color: Color = NSColors.BG_CRT if is_active else NSColors.MIST
	b.add_theme_color_override("font_color", active_color)
	b.add_theme_color_override("font_hover_color", active_color if is_active else NSColors.PAGE_WHITE)
	b.add_theme_color_override("font_pressed_color", active_color)
	b.add_theme_color_override("font_focus_color", active_color)


func _slider(value: int, store_key: String = "", min_v: int = 0, max_v: int = 100, on_change: Callable = Callable()) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = 1
	slider.value = clampi(value, min_v, max_v)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0, 14)

	# Track (slider stylebox) — slate well, 1px lichen border.
	var track := StyleBoxFlat.new()
	track.bg_color = NSColors.MOSS_SHADOW
	track.border_color = NSColors.LICHEN
	track.border_width_left = 1
	track.border_width_top = 1
	track.border_width_right = 1
	track.border_width_bottom = 1
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	slider.add_theme_stylebox_override("slider", track)

	# Fill (grabber_area_highlight) — phosphor-dim.
	var fill := StyleBoxFlat.new()
	fill.bg_color = NSColors.VLF_PHOSPHOR_DIM
	fill.border_color = NSColors.VLF_PHOSPHOR_DIM
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)

	# Grabber — small phosphor rectangle.
	var grabber_tex := _make_grabber_texture()
	slider.add_theme_icon_override("grabber", grabber_tex)
	slider.add_theme_icon_override("grabber_highlight", grabber_tex)
	slider.add_theme_icon_override("grabber_disabled", grabber_tex)

	row.add_child(slider)

	var readout := Label.new()
	readout.text = str(int(slider.value))
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.custom_minimum_size = Vector2(44, 0)
	readout.add_theme_font_override("font", NSFonts.MONO_BOLD)
	readout.add_theme_font_size_override("font_size", 12)
	readout.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	row.add_child(readout)

	slider.value_changed.connect(func(v: float) -> void:
		readout.text = str(int(v))
		if store_key != "":
			SettingsStore.set_value(store_key, int(v))
		if on_change.is_valid():
			on_change.call(int(v))
	)
	return row


## Small phosphor-colored grabber nub, drawn procedurally so no asset
## is needed. Returned as an ImageTexture that Godot composites onto
## the slider track.
func _make_grabber_texture() -> Texture2D:
	var img := Image.create(6, 14, false, Image.FORMAT_RGBA8)
	var fg := NSColors.VLF_PHOSPHOR
	var edge := NSColors.VLF_PHOSPHOR.darkened(0.25)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var color: Color = edge if (x == 0 or x == img.get_width() - 1) else fg
			img.set_pixel(x, y, color)
	return ImageTexture.create_from_image(img)


func _build_stub_tab(tab: String) -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_top", 40)
	wrap.add_theme_constant_override("margin_bottom", 40)
	var l := NSWidgets.label_mono("— %s PANEL NOT IMPLEMENTED IN THIS BUILD —" % tab, 12, NSColors.FG_3)
	wrap.add_child(l)
	return wrap


func _go_back() -> void:
	get_tree().change_scene_to_file(PATH_MAIN_MENU)
