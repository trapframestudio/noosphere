extends Control
## Noosphere main menu.
##
## Four primary capabilities match the GDD's "what the shell is for":
## pick a solo run, pick / host a coop run, join a dedicated session
## via the server browser, and change settings. Characters belong to
## individual servers and are picked after the session connects, so
## there is no launcher-level character picker. The world-wipe dev
## action stays available via the Ctrl+Shift+R input binding
## registered in project.godot; deliberately not on the shell.
##
## Solo and Coop open dedicated runs screens (scripts/menus/runs_screen.gd)
## — players can maintain as many named runs as they want per mode.

const PATH_SOLO_RUNS      := "res://scenes/menus/soloRunsScreen.tscn"
const PATH_COOP_RUNS      := "res://scenes/menus/coopRunsScreen.tscn"
const PATH_SERVER_BROWSER := "res://scenes/menus/serverBrowser.tscn"
const PATH_SETTINGS       := "res://scenes/menus/settingsMenu.tscn"

const DEV_OVERLAY_SCENE: PackedScene = preload("res://scenes/menus/devOverlay.tscn")

var _status_label: Label
var _dev_overlay: CanvasLayer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_persisted_video_settings()

	var shell := MenuShell.new()
	add_child(shell)

	var body := _build_body()
	shell.set_body(body)

	var session := _get_session()
	if session != null and session.has_signal("lobby_id_changed"):
		session.lobby_id_changed.connect(_on_lobby_id_changed)


## Apply video settings that were persisted in a previous run. Same
## logic as Settings' Video tab — kept here as a pre-body step so
## first-paint uses the right window mode + UI scale.
func _apply_persisted_video_settings() -> void:
	var window_mode: String = str(SettingsStore.get_value("video.window_mode"))
	match window_mode:
		"WINDOWED":   DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		"FULLSCREEN": DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"BORDERLESS": DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	var vsync: String = str(SettingsStore.get_value("video.vsync"))
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync == "ON" else DisplayServer.VSYNC_DISABLED
	)
	var ui_scale: int = int(SettingsStore.get_value("video.ui_scale"))
	var w := get_window()
	if w != null:
		w.content_scale_factor = float(ui_scale) / 100.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		_toggle_dev_overlay()
		get_viewport().set_input_as_handled()


func _toggle_dev_overlay() -> void:
	if _dev_overlay != null and is_instance_valid(_dev_overlay):
		_dev_overlay.queue_free()
		_dev_overlay = null
		return
	_dev_overlay = DEV_OVERLAY_SCENE.instantiate()
	add_child(_dev_overlay)
	_dev_overlay.close_requested.connect(_toggle_dev_overlay)


func _build_body() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	root.add_child(GorgeBackdrop.new())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 72)
	margin.add_theme_constant_override("margin_right", 72)
	margin.add_theme_constant_override("margin_top", 64)
	margin.add_theme_constant_override("margin_bottom", 72)
	root.add_child(margin)

	var grid := HBoxContainer.new()
	grid.add_theme_constant_override("separation", 48)
	margin.add_child(grid)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	left.add_theme_constant_override("separation", 0)
	grid.add_child(left)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.1
	right.size_flags_vertical = Control.SIZE_SHRINK_END
	right.add_theme_constant_override("separation", 18)
	grid.add_child(right)

	_build_left_column(left)
	_build_right_column(right)

	return root


# ---------------------------------------------------------------------
# Left column: brand + ledger.
# ---------------------------------------------------------------------

func _build_left_column(col: VBoxContainer) -> void:
	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", 10)
	brand.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(brand)

	brand.add_child(NSWidgets.stencil("NOOSPHERE", 80))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brand.add_child(spacer)

	_status_label = NSWidgets.label_mono("", 11, NSColors.FG_3)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status_label)

	var dev_hint := NSWidgets.label_mono("[ ` ]  dev panel — raw lobby actions", 10, NSColors.FOG)
	col.add_child(dev_hint)

	var resume_card := _build_resume_card()
	if resume_card != null:
		col.add_child(resume_card)

	col.add_child(NSWidgets.hairline(NSColors.LICHEN, 1))
	col.add_child(_build_ledger())


## Build a "CONTINUE <name>" card for the most-recently-played run,
## or return null if there are no runs yet. Inserted just above the
## ledger divider so returning players land on it first without
## demoting SOLO / HOST COOP for fresh installs.
func _build_resume_card() -> Control:
	var recent: Variant = RunsStore.most_recent()
	if recent == null:
		return null
	var run: Dictionary = recent

	var card := Button.new()
	card.flat = true
	card.focus_mode = Control.FOCUS_ALL
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.custom_minimum_size = Vector2(0, 72)
	card.add_theme_stylebox_override("normal",  _resume_box(false))
	card.add_theme_stylebox_override("hover",   _resume_box(true))
	card.add_theme_stylebox_override("pressed", _resume_box(true))
	card.add_theme_stylebox_override("focus",   _resume_box(true))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)

	info.add_child(NSWidgets.eyebrow("◇ CONTINUE", NSColors.VLF_PHOSPHOR))
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(name_row)
	name_row.add_child(NSWidgets.stencil(run.get("name", "?"), 22, NSColors.PAGE_WHITE, 600))
	name_row.add_child(NSWidgets.badge(str(run.get("mode", "")).to_upper(), NSColors.VLF_PHOSPHOR))

	var meta: String = "LAST PLAYED %s" % _format_relative(int(run.get("last_played_unix", run.get("created_unix", 0))))
	var meta_l := NSWidgets.label_mono(meta, 10, NSColors.FG_3)
	info.add_child(meta_l)

	var arrow := NSWidgets.label_mono("→", 22, NSColors.VLF_PHOSPHOR)
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(arrow)

	card.pressed.connect(_on_resume_pressed.bind(run))
	return card


func _resume_box(hovered: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.498, 0.698, 0.416, 0.06) if hovered else Color(0.498, 0.698, 0.416, 0.03)
	sb.border_color = NSColors.VLF_PHOSPHOR if hovered else NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	return sb


static func _format_relative(unix: int) -> String:
	if unix <= 0:
		return "never"
	var delta := int(Time.get_unix_time_from_system()) - unix
	if delta < 60:    return "just now"
	if delta < 3600:  return "%d m ago" % (delta / 60)
	if delta < 86400: return "%d h ago" % (delta / 3600)
	if delta < 86400 * 30: return "%d d ago" % (delta / 86400)
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]


func _on_resume_pressed(run: Dictionary) -> void:
	var run_id: String = run.get("id", "")
	if run_id.is_empty():
		push_error("MainMenu: run has no id")
		return
	RunsStore.touch(run_id)
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	match run.get("mode", ""):
		RunsStore.MODE_COOP: session.host(run_id)
		_:                    session.solo(run_id)


func _build_ledger() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)

	var items := [
		{"id": "solo",     "label": "SOLO",           "sub": "Start or load a single-player run"},
		{"id": "coop",     "label": "HOST COOP",      "sub": "Start or load a hosted coop run"},
		{"id": "browser",  "label": "SERVER BROWSER", "sub": "Join a dedicated session"},
		{"id": "settings", "label": "SETTINGS",       "sub": "Audio · video · radio · keybinds"},
		{"id": "quit",     "label": "QUIT",           "sub": "Leave the Valley"},
	]

	for entry in items:
		v.add_child(_build_ledger_row(entry))

	return v


func _build_ledger_row(entry: Dictionary) -> Control:
	var row := Button.new()
	row.flat = true
	row.focus_mode = Control.FOCUS_ALL
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.add_theme_stylebox_override("normal", _ledger_box(false))
	row.add_theme_stylebox_override("hover",  _ledger_box(true))
	row.add_theme_stylebox_override("pressed", _ledger_box(true))
	row.add_theme_stylebox_override("focus",  _ledger_box(true))

	var row_layout := HBoxContainer.new()
	row_layout.add_theme_constant_override("separation", 16)
	row_layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	row_layout.offset_left = 14
	row_layout.offset_right = -14
	row.add_child(row_layout)

	var bullet := NSWidgets.label_mono("·", 13, NSColors.FG_3)
	bullet.custom_minimum_size = Vector2(24, 0)
	row_layout.add_child(bullet)

	var label := NSWidgets.stencil(entry["label"], 22, NSColors.MIST, 600)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_layout.add_child(label)

	var sub := NSWidgets.label_mono(entry["sub"], 10, NSColors.FOG)
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row_layout.add_child(sub)

	row.custom_minimum_size = Vector2(0, 44)
	row.pressed.connect(_on_ledger_pressed.bind(entry["id"]))
	row.mouse_entered.connect(func() -> void:
		bullet.text = "→"
		bullet.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
		label.add_theme_color_override("font_color", NSColors.PAGE_WHITE)
	)
	row.mouse_exited.connect(func() -> void:
		bullet.text = "·"
		bullet.add_theme_color_override("font_color", NSColors.FG_3)
		label.add_theme_color_override("font_color", NSColors.MIST)
	)
	return row


func _ledger_box(hovered: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if hovered:
		sb.bg_color = Color(0.498, 0.698, 0.416, 0.04)
		sb.border_width_left = 3
		sb.border_color = NSColors.VLF_PHOSPHOR
	else:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_width_left = 3
		sb.border_color = Color(0, 0, 0, 0)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	return sb


# ---------------------------------------------------------------------
# Right column: intentionally empty for now. The decorative advisory +
# broadcast panels were placeholder flavor and were stripped; real
# status content can be added here when it's backed by actual data.
# ---------------------------------------------------------------------

func _build_right_column(_col: VBoxContainer) -> void:
	pass


# ---------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------

func _on_ledger_pressed(id: String) -> void:
	match id:
		"solo":
			get_tree().change_scene_to_file(PATH_SOLO_RUNS)
		"coop":
			get_tree().change_scene_to_file(PATH_COOP_RUNS)
		"browser":
			get_tree().change_scene_to_file(PATH_SERVER_BROWSER)
		"settings":
			get_tree().change_scene_to_file(PATH_SETTINGS)
		"quit":
			get_tree().quit()


func _on_lobby_id_changed(lobby_id: int) -> void:
	var link := "steam://joinlobby/480/%d/%d" % [lobby_id, _get_session().local_steam_id()]
	_status("Lobby ID: %d\nShare link: %s" % [lobby_id, link])
	DisplayServer.clipboard_set(str(lobby_id))


func _status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _get_session() -> Node:
	return get_node("/root/GameSession")
