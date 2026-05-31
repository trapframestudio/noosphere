class_name NSWidgets
extends RefCounted
## Factory helpers for Noosphere's shared UI atoms. Each method returns
## a fully-configured Godot Control ready to be added to a tree. Keep
## the visual vocabulary here narrow — styled buttons, badges, stamps,
## typography shorthands. Larger compound panels (advisory, CRT,
## dossier) live in their own scripts.

const _MONO_TRACKING_CHROME := 0.18 ## em-equivalent tracking for button labels
const _MONO_TRACKING_LABEL  := 0.20

# -------------------------------------------------------------------
# Buttons — four variants, taken from the design's Chrome.jsx.
# -------------------------------------------------------------------

enum Variant { PRIMARY, SECONDARY, GHOST, DANGER }

static func button(label: String, variant: int = Variant.SECONDARY) -> Button:
	var b := Button.new()
	b.text = label.to_upper()
	b.custom_minimum_size = Vector2(0, 0)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", NSFonts.MONO_BOLD)
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_constant_override("outline_size", 0)
	# letter_spacing isn't a theme prop; approximate by padding the text
	# with zero-width space is ugly — we accept native spacing.
	var fg: Color
	var bg: Color
	var border: Color
	match variant:
		Variant.PRIMARY:
			bg = NSColors.VLF_PHOSPHOR_DIM
			fg = NSColors.BG_CRT
			border = NSColors.VLF_PHOSPHOR
		Variant.SECONDARY:
			bg = NSColors.WET_SLATE
			fg = NSColors.PAGE_WHITE
			border = NSColors.LICHEN
		Variant.GHOST:
			bg = Color(0, 0, 0, 0)
			fg = NSColors.MIST
			border = NSColors.FOG
		Variant.DANGER:
			bg = Color(0, 0, 0, 0)
			fg = NSColors.WARNING_RUST
			border = NSColors.WARNING_RUST
		_:
			bg = NSColors.WET_SLATE
			fg = NSColors.PAGE_WHITE
			border = NSColors.LICHEN
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg.lightened(0.15))
	b.add_theme_color_override("font_pressed_color", fg.darkened(0.15))
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_stylebox_override("normal", _button_box(bg, border, false))
	b.add_theme_stylebox_override("hover",  _button_box(bg.lightened(0.05), border.lightened(0.1), false))
	b.add_theme_stylebox_override("pressed", _button_box(bg.darkened(0.2), border, true))
	b.add_theme_stylebox_override("focus",   _button_box(bg, border.lightened(0.3), false))
	b.add_theme_stylebox_override("disabled", _button_box(bg.darkened(0.4), border.darkened(0.3), false))
	return b

static func _button_box(bg: Color, border: Color, pressed: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_right = 0
	sb.corner_radius_bottom_left = 0
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 11 if not pressed else 12
	sb.content_margin_bottom = 11 if not pressed else 10
	return sb

# -------------------------------------------------------------------
# Typography shorthands.
# -------------------------------------------------------------------

static func stencil(text: String, size: int = 36, color: Color = NSColors.PAGE_WHITE, weight: int = 700) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", NSFonts.stencil(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

static func label_mono(text: String, size: int = 13, color: Color = NSColors.PAGE_WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", NSFonts.MONO)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

## Uppercase wide-tracked caption label (the "eyebrow" in the design).
static func eyebrow(text: String, color: Color = NSColors.FG_3) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", NSFonts.MONO)
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", color)
	return l

## Typewriter body (for dossier / tagline).
static func typewriter(text: String, size: int = 15, color: Color = NSColors.FG_2) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_override("font", NSFonts.TYPEWRITER)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

# -------------------------------------------------------------------
# Badge — bordered uppercase tag.
# -------------------------------------------------------------------

static func badge(text: String, color: Color = NSColors.MIST) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = color
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", NSFonts.MONO_BOLD)
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", color)
	p.add_child(l)
	return p

# -------------------------------------------------------------------
# Stamp — rotated double-border classification mark.
# -------------------------------------------------------------------

static func stamp(text: String, color: Color = NSColors.STAMP_RED, rotation_deg: float = -1.5) -> Control:
	# Use a Control wrapper so the rotation doesn't skew layout.
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(0, 0)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	# Godot has no "double border" style; fake it with a thick border +
	# inner spacing that reads as stamped.
	sb.border_color = color
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_offset = Vector2(1, 1)
	sb.shadow_size = 0
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_font_override("font", NSFonts.MONO_BOLD)
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", color)
	p.add_child(l)
	p.rotation = deg_to_rad(rotation_deg)
	p.pivot_offset = Vector2(30, 12)
	wrap.add_child(p)
	return wrap

# -------------------------------------------------------------------
# Form row — settings-tab pattern of
#   [fixed-width label + optional hint] | [control that fills]
# Wrapped in a panel with a bottom hairline separator.
# -------------------------------------------------------------------

static func form_row(label: String, hint: String, control: Control, label_width: int = 240) -> PanelContainer:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = NSColors.RULE_1
	sb.border_width_bottom = 1
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	wrap.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	wrap.add_child(row)

	var label_col := VBoxContainer.new()
	label_col.custom_minimum_size = Vector2(label_width, 0)
	label_col.add_theme_constant_override("separation", 3)

	var l := Label.new()
	l.text = label.to_upper()
	l.add_theme_font_override("font", NSFonts.MONO_BOLD)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", NSColors.PAGE_WHITE)
	label_col.add_child(l)

	if hint != "":
		var h := Label.new()
		h.text = hint
		h.add_theme_font_override("font", NSFonts.MONO)
		h.add_theme_font_size_override("font_size", 10)
		h.add_theme_color_override("font_color", NSColors.FG_3)
		label_col.add_child(h)
	row.add_child(label_col)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return wrap


# -------------------------------------------------------------------
# Hairline divider.
# -------------------------------------------------------------------

static func hairline(color: Color = NSColors.LICHEN, height: int = 1) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.custom_minimum_size = Vector2(0, height)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return r
