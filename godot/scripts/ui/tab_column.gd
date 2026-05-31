class_name TabColumn
extends PanelContainer
## Vertical tab rail: a fixed-width left column of text buttons with a
## phosphor left-edge accent on the active tab. Emits `tab_selected`
## when the user clicks a tab. The owner script decides what to
## render in its content slot; this component only handles selection.
##
## Used by the settings screen today. Any future tabbed screen
## (character creation, inventory categories, mod manager) can reuse
## the same component.

signal tab_selected(name: String)

@export var tabs: PackedStringArray = PackedStringArray()
@export var initial_tab: String = ""
@export var column_width: int = 220

var _buttons: Dictionary = {}
var _active: String = ""


func _ready() -> void:
	custom_minimum_size = Vector2(column_width, 0)

	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BASALT_BLACK
	sb.border_color = NSColors.LICHEN
	sb.border_width_right = 1
	sb.content_margin_top = 24
	sb.content_margin_bottom = 24
	add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	add_child(v)

	_active = initial_tab if initial_tab != "" and initial_tab in tabs else (
		tabs[0] if tabs.size() > 0 else ""
	)

	for t in tabs:
		var b := _build_tab_button(t)
		_buttons[t] = b
		v.add_child(b)


func select(name: String) -> void:
	if name == _active or not (name in tabs):
		return
	_active = name
	for t in _buttons.keys():
		_apply_style(_buttons[t], t == _active)
	tab_selected.emit(name)


func active_tab() -> String:
	return _active


func _build_tab_button(tab: String) -> Button:
	var b := Button.new()
	b.text = tab
	b.flat = true
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 44)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", NSFonts.MONO_BOLD)
	b.add_theme_font_size_override("font_size", 12)
	_apply_style(b, tab == _active)
	b.pressed.connect(func() -> void: select(tab))
	return b


func _apply_style(b: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.border_width_left = 3
	if active:
		sb.bg_color = Color(0.498, 0.698, 0.416, 0.04)
		sb.border_color = NSColors.VLF_PHOSPHOR
	else:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = Color(0, 0, 0, 0)
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_stylebox_override("focus",   sb)
	b.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR if active else NSColors.MIST)
	b.add_theme_color_override("font_hover_color", NSColors.PAGE_WHITE if not active else NSColors.VLF_PHOSPHOR)
