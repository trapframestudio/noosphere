class_name ConnectingOverlay
extends CanvasLayer
## Phosphor modal that says "the system is trying." Heading + a body
## message + animated dots + optional cancel button. Reusable by any
## surface that kicks off an async operation that should block input
## while pending.
##
## Today this is not auto-wired anywhere — `GameSession.solo()` /
## `.host()` / `.join()` change scene synchronously, so the overlay
## has nothing to cover. Once those paths grow a "lobby_ready /
## sim_ready" gate (see TODO.md), a caller can:
##
##     var overlay := ConnectingOverlay.new()
##     overlay.heading = "◇ CONNECTING"
##     overlay.body = "reaching PNW-03…"
##     overlay.cancelable = true
##     overlay.cancelled.connect(_on_cancel)
##     add_child(overlay)
##
## …and remove/queue_free the overlay on success, or call
## `overlay.show_failure("RADIO SILENT. SERVER DID NOT ANSWER.")`
## and keep it up until dismissed.

signal cancelled

@export var heading: String = "◇ CONNECTING"
@export var body: String = "reaching…"
@export var cancelable: bool = true
@export var cancel_label: String = "Cancel"

var _body_label: Label
var _dots_label: Label
var _dots_timer: Timer
var _dot_tick: int = 0
var _failure: bool = false


func _ready() -> void:
	layer = 95  # above game menu, below debug
	_build()
	_dots_timer = Timer.new()
	_dots_timer.wait_time = 0.35
	_dots_timer.autostart = true
	_dots_timer.timeout.connect(_tick_dots)
	add_child(_dots_timer)


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.65)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(0, 0, 0, 0.8)
	sb.shadow_offset = Vector2(0, 4)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	margin.add_child(v)

	v.add_child(_phosphor(heading, 12, 0.8))

	var body_row := HBoxContainer.new()
	body_row.add_theme_constant_override("separation", 4)
	v.add_child(body_row)
	_body_label = _phosphor(body, 15, 1.0)
	_body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.add_child(_body_label)
	_dots_label = _phosphor("", 15, 1.0)
	body_row.add_child(_dots_label)

	if cancelable:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		v.add_child(spacer)
		var cancel := NSWidgets.button(cancel_label, NSWidgets.Variant.GHOST)
		cancel.size_flags_horizontal = Control.SIZE_SHRINK_END
		cancel.pressed.connect(func() -> void: cancelled.emit())
		v.add_child(cancel)


func _phosphor(text: String, size: int, alpha: float) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_override("font", NSFonts.MONO)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(NSColors.VLF_PHOSPHOR, alpha))
	return l


func _tick_dots() -> void:
	if _failure:
		return
	_dot_tick = (_dot_tick + 1) % 4
	_dots_label.text = ".".repeat(_dot_tick)


## Flip the overlay to a terminal error state — red border, static
## body, no dots. Caller remains responsible for `queue_free()` on
## dismiss.
func show_failure(message: String) -> void:
	_failure = true
	_dots_label.text = ""
	_body_label.text = message
	_body_label.add_theme_color_override("font_color", NSColors.WARNING_RUST)
	var panel: PanelContainer = get_node_or_null("Control/CenterContainer/PanelContainer")
	# The panel's in the tree but named by type; re-find via traversal.
	if panel == null:
		panel = _find_panel()
	if panel == null:
		return
	var sb := panel.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb = sb.duplicate() as StyleBoxFlat
		sb.border_color = NSColors.WARNING_RUST
		panel.add_theme_stylebox_override("panel", sb)


func _find_panel() -> PanelContainer:
	# Walk the tree; we built one PanelContainer so the first hit wins.
	var stack: Array = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is PanelContainer:
			return n
		for c in n.get_children():
			stack.append(c)
	return null
