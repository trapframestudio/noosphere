class_name AdvisoryPanel
extends PanelContainer
## Wet-slate advisory card. Header row (eyebrow label + timestamp), body
## paragraph, trailing badge row. Generic status card; callers set the
## text. (Currently unused after the main-menu strip; kept for reuse.)

@export var eyebrow_text: String = "◇ ADVISORY"
@export var timestamp: String = "—"
@export_multiline var body_text: String = ""
@export var badges: Array[Dictionary] = [] ## [{"text": "...", "color": Color}, ...]

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_offset = Vector2(0, 2)
	sb.shadow_size = 0
	add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	add_child(v)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	var l_eyebrow := NSWidgets.eyebrow(eyebrow_text, NSColors.FG_2)
	l_eyebrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(l_eyebrow)
	header.add_child(NSWidgets.eyebrow(timestamp, NSColors.FG_3))
	v.add_child(header)

	if body_text != "":
		var body := Label.new()
		body.text = body_text
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_theme_font_override("font", NSFonts.MONO)
		body.add_theme_font_size_override("font_size", 13)
		body.add_theme_color_override("font_color", NSColors.PAGE_WHITE)
		v.add_child(body)

	if not badges.is_empty():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		for entry in badges:
			var color: Color = entry.get("color", NSColors.MIST)
			var text: String = entry.get("text", "")
			row.add_child(NSWidgets.badge(text, color))
		v.add_child(row)
