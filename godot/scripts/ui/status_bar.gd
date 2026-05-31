class_name StatusBar
extends PanelContainer
## Bottom-of-screen status row. Build identifier on the left, radio
## frequency / local time / squall countdown on the right. Time
## ticks live (once per second) so the bar feels like equipment rather
## than a printed label.

@export var freq_text: String = "146.520"
@export var squall_text: String = "00:41:11"

var _time_label: Label

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_top = 1
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	add_child(row)

	var build_version: String = str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	var left := _mono_label("◇ NOOSPHERE · v%s" % build_version, NSColors.FG_2)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)

	row.add_child(_mono_label("FREQ %s" % freq_text, NSColors.FG_2))
	_time_label = _mono_label("LOCAL %s" % _now(), NSColors.FG_2)
	row.add_child(_time_label)
	row.add_child(_mono_label("SQUALL · %s" % squall_text, NSColors.WARNING_RUST))

	var tick := Timer.new()
	tick.wait_time = 1.0
	tick.autostart = true
	tick.timeout.connect(_refresh_time)
	add_child(tick)

func _refresh_time() -> void:
	if _time_label != null:
		_time_label.text = "LOCAL %s" % _now()

static func _now() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d" % [t["hour"], t["minute"]]

func _mono_label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", NSFonts.MONO_BOLD)
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", color)
	return l
