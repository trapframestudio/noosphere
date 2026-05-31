class_name ClassificationStrip
extends PanelContainer
## Top-of-screen classification strip. Always-visible diegetic header
## — fog-grey tracked mono centered between hairline rules over a
## faintly-dark wash.

@export var text: String = "UNCLASSIFIED // FOR WANDERER USE // DO NOT DISCUSS ON OPEN FREQ"

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.3)
	sb.border_color = NSColors.RULE_1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	add_theme_stylebox_override("panel", sb)

	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", NSFonts.MONO_BOLD)
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", NSColors.FG_3)
	add_child(l)
