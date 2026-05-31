class_name ScreenHeader
extends PanelContainer
## Shared header strip used by every sub-screen (runs, server browser,
## settings). Renders an eyebrow label, a stencil title, and an
## optional back button. Emits `back_pressed` when the back button is
## clicked. Instantiate, set the `@export` fields, connect the signal,
## add to the scene.

signal back_pressed

@export var eyebrow_text: String = ""
@export var title_text: String = ""
@export var show_back: bool = true
@export var back_label: String = "← Back"


func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BASALT_BLACK
	sb.border_color = NSColors.LICHEN
	sb.border_width_bottom = 1
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 28
	sb.content_margin_bottom = 20
	add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	add_child(row)

	var title_col := VBoxContainer.new()
	title_col.add_theme_constant_override("separation", 8)
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title_col)

	if eyebrow_text != "":
		title_col.add_child(NSWidgets.eyebrow(eyebrow_text))
	title_col.add_child(NSWidgets.stencil(title_text, 36))

	if show_back:
		var back := NSWidgets.button(back_label, NSWidgets.Variant.GHOST)
		back.pressed.connect(func() -> void: back_pressed.emit())
		back.size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(back)
