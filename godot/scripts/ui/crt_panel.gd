class_name CRTPanel
extends PanelContainer
## Diegetic CRT well: dark slate background, phosphor-green body text,
## faint horizontal scanlines, subtle inner shadow. Used for the
## broadcast advisory on the main menu and the MOTD block on the
## server browser detail pane.
##
## The scanline pattern is drawn as a child ColorRect with a shader so
## it scales with the panel; no texture asset required.

@export var heading_left: String = "◇ BROADCAST · 76 Hz"
@export var heading_right: String = "SHADOW 6.3 km"
@export_multiline var body_text: String = "> signal nominal. antenna well responding. do not linger."

const _SCANLINE_SHADER := "
shader_type canvas_item;
void fragment() {
	float y = FRAGCOORD.y;
	float line = step(0.5, mod(y, 3.0));
	COLOR = vec4(0.498, 0.698, 0.416, 0.07) * line;
}
"

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_offset = Vector2(0, 2)
	add_theme_stylebox_override("panel", sb)

	clip_contents = true

	# Scanline overlay — set mouse_filter to ignore so it doesn't eat
	# hover on child content.
	var scan := ColorRect.new()
	scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scan.color = Color(1, 1, 1, 1)
	var shader := Shader.new()
	shader.code = _SCANLINE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	scan.material = mat
	scan.z_index = 1

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	add_child(scan)

	var header := HBoxContainer.new()
	var l := _phosphor_label(heading_left, 12)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.modulate.a = 0.8
	var r := _phosphor_label(heading_right, 12)
	r.modulate.a = 0.8
	header.add_child(l)
	header.add_child(r)
	v.add_child(header)

	var body := _phosphor_label(body_text, 15)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(body)

func _phosphor_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", NSFonts.MONO)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	l.add_theme_color_override("font_outline_color", NSColors.VLF_PHOSPHOR)
	l.add_theme_constant_override("outline_size", 0)
	return l
