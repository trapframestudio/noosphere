class_name MenuShell
extends Control
## Shell wrapper used by every top-level menu screen (main menu,
## server browser, character roster, settings). Provides the
## always-on classification strip at the top and the status bar at
## the bottom. The screen's own content fills the middle slot, which
## the screen populates by calling `set_body(node)` in its `_ready`.

const _CLASSIFICATION := "UNCLASSIFIED // FOR WANDERER USE // DO NOT DISCUSS ON OPEN FREQ"

var _body_slot: MarginContainer

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)
	add_child(v)

	var strip := ClassificationStrip.new()
	strip.text = _CLASSIFICATION
	v.add_child(strip)

	_body_slot = MarginContainer.new()
	_body_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_body_slot)

	var status := StatusBar.new()
	v.add_child(status)

## Install the screen's main content into the middle slot. Replaces
## anything that was there.
func set_body(node: Control) -> void:
	for c in _body_slot.get_children():
		c.queue_free()
	_body_slot.add_child(node)
