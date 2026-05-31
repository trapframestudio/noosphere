extends CanvasLayer
## Dev overlay for the launcher. Exposes the raw Steam-lobby actions
## (solo / host / join-by-ID / wipe-world) that the redesigned main
## menu doesn't surface directly. Toggled by `toggle_debug` (backtick).
## Styled to match the shell: wet-slate panel, 1px lichen border,
## classification strip labeling it DEV // PRIVILEGED.
##
## This exists because the polished main menu routes solo and coop
## through the named-runs screens — useful for players, but slower
## for devs who just want to smoke-test a lobby. Keep this honest:
## it is a shortcut, not a secondary flow that needs polish.

signal close_requested

var _status_label: Label
var _lobby_input: LineEdit


func _ready() -> void:
	layer = 90  ## Above main menu body, below modal dialogs if any.
	_build()
	var session := get_node_or_null("/root/GameSession")
	if session != null:
		if session.has_signal("lobby_id_changed"):
			session.lobby_id_changed.connect(_on_lobby_id_changed)
		if session.has_signal("session_failed"):
			session.session_failed.connect(func(source: String, message: String) -> void:
				_status("[%s] %s" % [source, message])
				_status_label.add_theme_color_override("font_color", NSColors.WARNING_RUST)
			)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug") or (event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE and event.pressed):
		close_requested.emit()
		get_viewport().set_input_as_handled()


func _build() -> void:
	# Dim scrim so the main menu reads as pushed back.
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			close_requested.emit()
	)
	add_child(scrim)

	# Centered dev panel.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_offset = Vector2(0, 4)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	margin.add_child(v)

	# Classification
	var strip := ClassificationStrip.new()
	strip.text = "DEV // PRIVILEGED // NOT FOR RELEASE BUILD"
	v.add_child(strip)

	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	v.add_child(header)
	header.add_child(NSWidgets.eyebrow("◇ DEV PANEL"))
	header.add_child(NSWidgets.stencil("STEAM LOBBY", 28))
	header.add_child(NSWidgets.typewriter(
		"raw actions — bypass the named-runs shell. wipe world leaves no save.",
		13,
		NSColors.FG_3,
	))

	# Primary action row
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	v.add_child(actions)

	var solo := NSWidgets.button("Resume solo", NSWidgets.Variant.SECONDARY)
	solo.pressed.connect(_on_solo_pressed)
	actions.add_child(solo)

	var host := NSWidgets.button("Host lobby", NSWidgets.Variant.SECONDARY)
	host.pressed.connect(_on_host_pressed)
	actions.add_child(host)

	var wipe := NSWidgets.button("Wipe world", NSWidgets.Variant.DANGER)
	wipe.pressed.connect(_on_wipe_pressed)
	actions.add_child(wipe)

	# Join-by-ID row
	var join_row := VBoxContainer.new()
	join_row.add_theme_constant_override("separation", 6)
	v.add_child(join_row)

	join_row.add_child(NSWidgets.eyebrow("◇ JOIN BY LOBBY ID"))
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 8)
	join_row.add_child(input_row)

	_lobby_input = LineEdit.new()
	_lobby_input.placeholder_text = "paste lobby id…"
	_lobby_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_input.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	input_row.add_child(_lobby_input)

	var join_btn := NSWidgets.button("Join", NSWidgets.Variant.PRIMARY)
	join_btn.pressed.connect(_on_join_pressed)
	input_row.add_child(join_btn)

	# Status + close
	_status_label = NSWidgets.label_mono("", 11, NSColors.FG_3)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status_label)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	v.add_child(footer)

	var hint := NSWidgets.label_mono("toggle with ` · ESC to close", 10, NSColors.FOG)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.add_child(hint)

	var close := NSWidgets.button("Close", NSWidgets.Variant.GHOST)
	close.pressed.connect(func() -> void: close_requested.emit())
	footer.add_child(close)


# ---------------------------------------------------------------------
# Actions — mirrors of the pre-redesign main_menu.gd.
# ---------------------------------------------------------------------

func _on_solo_pressed() -> void:
	_status("Solo…")
	var run_id := _ensure_dev_run(RunsStore.MODE_SOLO)
	if run_id.is_empty():
		_status("Couldn't create dev solo run.")
		return
	_get_session().solo(run_id)


func _on_host_pressed() -> void:
	_status("Hosting…")
	var run_id := _ensure_dev_run(RunsStore.MODE_COOP)
	if run_id.is_empty():
		_status("Couldn't create dev coop run.")
		return
	_get_session().host(run_id)


# Dev overlay is a fast path for smoke-testing lobbies without going
# through the named-runs shell. Grabs the most-recent run in the given
# mode, creating a synthetic one if no runs exist yet. `solo` /
# `host` on `GameSession` require a run_id as of slice 1's per-run
# save isolation.
func _ensure_dev_run(mode: String) -> String:
	var existing := RunsStore.list_for_mode(mode)
	if not existing.is_empty():
		var run: Dictionary = existing[0]
		var id: String = run.get("id", "")
		if not id.is_empty():
			RunsStore.touch(id)
			return id
	var display_name: String = "Dev Solo" if mode == RunsStore.MODE_SOLO else "Dev Coop"
	var created: Variant = RunsStore.create(display_name, mode)
	if created == null:
		return ""
	return (created as Dictionary).get("id", "")


func _on_join_pressed() -> void:
	var text: String = _lobby_input.text.strip_edges()
	if text.is_empty():
		_status("Paste a lobby ID first.")
		return
	if not text.is_valid_int():
		_status("Lobby ID must be a number.")
		return
	_status("Joining %s…" % text)
	_get_session().join(text.to_int())


func _on_wipe_pressed() -> void:
	var removed: bool = _get_session().wipe_world()
	_status("World wiped — fresh seed loaded." if removed else "No save files to wipe; sim re-seeded.")


func _on_lobby_id_changed(lobby_id: int) -> void:
	var link := "steam://joinlobby/480/%d/%d" % [lobby_id, _get_session().local_steam_id()]
	_status("Lobby ID: %d\nShare link: %s" % [lobby_id, link])
	DisplayServer.clipboard_set(str(lobby_id))


func _status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _get_session() -> Node:
	return get_node("/root/GameSession")
