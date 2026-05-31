extends Control
## Post-connect character picker. Placed in the flow after a session
## resolves — players pick or create a wanderer for the run they just
## loaded. This is a scaffold: the character model is still owned by
## the sim (per-run character rosters need per-run save isolation,
## which is a `simn-sim` follow-up), so the list is empty and the
## Create action is a stub.
##
## Today the scene is only reachable from the game menu's "View
## wanderer" action so devs can preview the surface. Production wiring
## routes through `GameSession.session_ready` (to be added) once the
## session lifecycle gates its scene changes.

const PATH_MAIN_MENU := "res://scenes/menus/mainMenu.tscn"

var _name_input: LineEdit


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var shell := MenuShell.new()
	add_child(shell)
	shell.set_body(_build_body())


func _build_body() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)

	var header := ScreenHeader.new()
	header.eyebrow_text = "◇ POST-CONNECT"
	header.title_text = "WANDERER"
	header.back_pressed.connect(_go_back)
	v.add_child(header)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 40)
	pad.add_theme_constant_override("margin_right", 40)
	pad.add_theme_constant_override("margin_top", 24)
	pad.add_theme_constant_override("margin_bottom", 40)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(pad)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 32)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.add_child(split)

	split.add_child(_build_roster_column())
	split.add_child(_build_create_column())
	return v


func _build_roster_column() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.2
	col.add_theme_constant_override("separation", 14)

	col.add_child(NSWidgets.eyebrow("◇ ROSTER"))
	col.add_child(NSWidgets.typewriter(
		"wanderers carry forward across reconnects. a dead wanderer is not a reloaded wanderer. choose with intention.",
		13,
		NSColors.FG_3,
	))

	var empty := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 24
	sb.content_margin_bottom = 24
	empty.add_theme_stylebox_override("panel", sb)
	empty.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)
	empty.add_child(inner)
	inner.add_child(NSWidgets.label_mono("— no wanderers registered on this server yet —", 12, NSColors.FG_3))
	inner.add_child(NSWidgets.label_mono("per-run rosters land once `simn-sim` keys saves by run id.", 10, NSColors.FOG))
	col.add_child(empty)

	return col


func _build_create_column() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 1.0
	col.add_theme_constant_override("separation", 18)

	col.add_child(NSWidgets.eyebrow("◇ NEW WANDERER"))
	col.add_child(NSWidgets.stencil("CHOOSE A CALLSIGN", 22))

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "callsign…"
	col.add_child(_name_input)

	col.add_child(NSWidgets.form_row(
		"Starting kit",
		"what you carry in with — irreversible",
		_stub_segmented(["LIGHT", "STANDARD", "LOADED"], "STANDARD"),
	))
	col.add_child(NSWidgets.form_row(
		"Faction lean",
		"soft preference — factions judge on actions, not intake",
		_stub_segmented(["WANDERER", "PWA", "RG", "COMPACT"], "WANDERER"),
	))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	var create_btn := NSWidgets.button("Enter the Valley", NSWidgets.Variant.PRIMARY)
	create_btn.disabled = true
	create_btn.tooltip_text = "Character creation is scaffolded; sim-side storage lands with per-run save isolation."
	actions.add_child(create_btn)
	var skip := NSWidgets.button("Skip for now", NSWidgets.Variant.GHOST)
	skip.pressed.connect(_go_back)
	actions.add_child(skip)
	col.add_child(actions)

	return col


## Returns a segmented control that doesn't persist — used for the
## scaffolded create form, since there's nowhere yet to save a
## character definition.
func _stub_segmented(options: Array, selected: String) -> Control:
	var wrap := HBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)
	for i in range(options.size()):
		var opt: String = options[i]
		var b := Button.new()
		b.text = opt
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_override("font", NSFonts.MONO_BOLD)
		b.add_theme_font_size_override("font_size", 11)
		var sb := StyleBoxFlat.new()
		var is_active := opt == selected
		sb.bg_color = NSColors.VLF_PHOSPHOR_DIM if is_active else Color(0, 0, 0, 0)
		sb.border_color = NSColors.LICHEN
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_width_left = 1
		if i == options.size() - 1:
			sb.border_width_right = 1
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		b.add_theme_stylebox_override("normal",  sb)
		b.add_theme_stylebox_override("hover",   sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.add_theme_stylebox_override("focus",   sb)
		b.add_theme_color_override("font_color", NSColors.BG_CRT if is_active else NSColors.MIST)
		wrap.add_child(b)
	return wrap


func _go_back() -> void:
	# If we're overlaying a live game (reached via game menu), close back
	# to main menu. Parent picker flow will eventually route elsewhere.
	get_tree().change_scene_to_file(PATH_MAIN_MENU)
