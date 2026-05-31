class_name GorgeBackdrop
extends TextureRect
## Distant Gorge backdrop — layered basalt ridges and fog, drawn as an
## SVG rasterised at import time. Full-bleed, mouse-transparent, fills
## the parent.

const _BACKDROP := preload("res://assets/backdrops/gorge.svg")

func _ready() -> void:
	texture = _BACKDROP
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
