extends CanvasLayer
## In-game overlay, misleadingly called a "pause menu" — the sim is
## always live (co-op survival; we don't get to stop the world), so
## this just paints a shell over the running game for housekeeping
## actions: save, disconnect, quit, settings. The Valley keeps running
## behind the scrim.
##
## Lives as a child of `session_root.tscn`, so it persists across
## map changes. Gated on `GameSession.in_game()` — ESC on the launcher
## does nothing; ESC in-game opens or closes this overlay. When open,
## the mouse is released so the overlay is clickable; on close, the
## mouse is re-captured so the FPS controller resumes.

const PATH_MAIN_MENU := "res://scenes/menus/mainMenu.tscn"

var _root: Control
var _status_label: Label


func _ready() -> void:
	layer = 80  # above HUD, below dev overlay (layer 90) and debug (100)
	visible = false
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	# ESC only acts in-game; launcher scenes handle their own ESC.
	if not visible and not session.in_game():
		return
	if visible:
		_close()
	else:
		_open()
	get_viewport().set_input_as_handled()


func _open() -> void:
	visible = true
	_set_status("")
	# Release mouse so the overlay is actually usable.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _close() -> void:
	visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# Scrim — dim the live game without hiding it.
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

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
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 28)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	margin.add_child(v)

	# Classification strip frames this as the same design vocabulary
	# as the launcher surfaces.
	var strip := ClassificationStrip.new()
	strip.text = "SYSTEM // ZONE REMAINS LIVE"
	v.add_child(strip)

	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	v.add_child(header)
	header.add_child(NSWidgets.eyebrow("◇ SYSTEM"))
	header.add_child(NSWidgets.stencil("PAUSED", 28))

	# Primary action column
	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	v.add_child(actions)

	actions.add_child(_action_row("Resume", NSWidgets.Variant.PRIMARY, _on_resume))
	actions.add_child(_action_row("Open PDA", NSWidgets.Variant.SECONDARY, _on_open_pda))
	actions.add_child(_action_row("View wanderer", NSWidgets.Variant.SECONDARY, _on_view_wanderer))
	actions.add_child(_action_row("Save now", NSWidgets.Variant.SECONDARY, _on_save))
	actions.add_child(_action_row("Disconnect to main menu", NSWidgets.Variant.GHOST, _on_disconnect))
	actions.add_child(_action_row("Quit to desktop", NSWidgets.Variant.DANGER, _on_quit))

	# Status line for confirmations ("world saved", errors, etc.)
	_status_label = NSWidgets.label_mono("", 11, NSColors.FG_3)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status_label)

	var footer := NSWidgets.label_mono(
		"[ ESC ] to resume   ·   [ ` ] dev readout   ·   [ Ctrl+S ] save   ·   [ Ctrl+Shift+R ] wipe",
		10,
		NSColors.FOG,
	)
	v.add_child(footer)


func _action_row(label: String, variant: int, handler: Callable) -> Button:
	var b := NSWidgets.button(label, variant)
	b.custom_minimum_size = Vector2(0, 40)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(handler)
	return b


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


# ---------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------

func _on_resume() -> void:
	_close()


func _on_open_pda() -> void:
	_close()
	var pda := get_node_or_null("/root/GameSession/PDA")
	if pda != null and pda.has_method("open_pda"):
		pda.open_pda()


func _on_view_wanderer() -> void:
	_close()
	get_tree().change_scene_to_file("res://scenes/menus/characterPicker.tscn")


func _on_save() -> void:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	session.force_save()
	_set_status("World saved · journal rotated.")


func _on_disconnect() -> void:
	visible = false
	var session := get_node_or_null("/root/GameSession")
	if session != null:
		session.leave_session_to_menu()


func _on_quit() -> void:
	get_tree().quit()
