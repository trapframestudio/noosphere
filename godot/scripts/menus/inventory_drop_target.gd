extends PanelContainer
## Drag-and-drop + right-click hook for inventory cards (Phase 2A/2B
## of
## `sim-iteration-5-12-plan.md`).
##
## Three kinds of card adopt this script:
## - `grid_card`: a populated cell in pockets / equipped container.
##   Draggable; also a drop target (drop here = move/swap).
## - `doll_slot`: a paper-doll equipment slot (may be empty or full).
##   Draggable only if `has_item`; always a drop target.
## - `empty_cell`: an unoccupied grid cell. Not draggable; drop target
##   (drop = move into this grid's first-fit, with the cell as hint).
##
## On a successful drop, the panel emits `drop_received(payload,
## target)` — both are Dictionaries. The owning `inventory_panel.gd`
## listens once at scene build and routes the drop into the right
## sim call (`equip` / `unequip` / `move_slot` / `move_between_grids`).
##
## The drag preview is a small Panel with the item name; Phase 2F
## upgrades it to a proper icon with rarity tint + count badge.

signal drop_received(payload: Dictionary, target: Dictionary)

## Phase 2C: id → catalog-dict lookup for tooltip enrichment.
## `inventory_panel.gd` resolves `sim.item_catalog()` once on open
## and passes the dict (by reference) to every card via this
## export so the tooltip path can resolve weight / stack_size /
## perishable status without making its own bridge call during a
## hover. Keys are item ids (`"ak_mag_30"` etc.) and values are
## the catalog dict.
@export var item_catalog: Dictionary = {}

## Card kind — drives both `_get_drag_data` (skip non-draggables)
## and `_can_drop_data` (target compatibility check). Set by the
## panel after `set_script()`.
@export var kind: String = ""

## For `grid_card`: which grid (`"pockets"` / `"equipped:<slot>"`)
## and which item index within that grid.
@export var grid_ref: String = ""
@export var item_idx: int = -1

## Phase 2A/2B: emitted on right-click so the panel can open the
## context menu without each card duplicating the popup logic.
signal context_menu_requested(grid_ref: String, item_idx: int, slot_id: String, item: Dictionary, screen_pos: Vector2)

## For `doll_slot`: the equipment slot id (`"primary"`, `"head"`, …)
## and whether it currently holds an item.
@export var slot_id: String = ""
@export var has_item: bool = false

## Phase 2C: human-readable slot label (`"Primary Weapon"`, `"Head"`)
## for empty-doll-slot tooltips. Populated slots derive their label
## from the item itself, so this is only read on empties.
@export var slot_label: String = ""

## For `doll_slot` *only*: the item categories this slot accepts.
## Used by `_can_drop_data` to reject mismatched drops (e.g. an
## armor vest dropped on the primary-weapon slot). Mirrors
## `crates/simn-sim/data/equipment_slots.toml`'s `accepts` array.
@export var accepted_categories: PackedStringArray

## For `empty_cell`: the grid this cell belongs to, plus its
## coordinates. Coordinates are advisory — the sim's first-fit
## placement may land the item somewhere else.
@export var cell_x: int = 0
@export var cell_y: int = 0

## Item dict (only for `grid_card` and populated `doll_slot`). Used
## by category-compat checks and the preview build.
@export var item_data: Dictionary = {}


## --- Input + drag-and-drop -----------------------------------------

func _ready() -> void:
	# Make sure the card catches mouse events for drag-init +
	# right-click context. Children that shouldn't intercept input
	# (labels, etc.) are set to IGNORE by the panel-build code.
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Phase 2C: setting `tooltip_text` to a non-empty placeholder is
	# what triggers Godot's tooltip pipeline — the actual contents
	# come from `_make_custom_tooltip` below. Empty cells don't get
	# a tooltip (nothing useful to surface).
	if kind != "empty_cell":
		tooltip_text = " "


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	var mb: InputEventMouseButton = event
	if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		# Empty cells have nothing to act on; doll slots with no
		# equipped item likewise.
		if kind == "empty_cell":
			return
		if kind == "doll_slot" and not has_item:
			return
		emit_signal(
			"context_menu_requested",
			grid_ref,
			item_idx,
			slot_id,
			item_data,
			mb.global_position,
		)
		# Mark as handled so it doesn't propagate to the panel
		# (which would re-fire as a generic input event).
		accept_event()


func _get_drag_data(_at_position: Vector2):
	# Empty cells and empty doll slots are not drag sources.
	if kind == "empty_cell":
		return null
	if kind == "doll_slot" and not has_item:
		return null
	# Build the payload. Recipients use `kind` to route the action.
	var payload := {
		"source_kind": kind,
		"grid_ref": grid_ref,
		"item_idx": item_idx,
		"slot_id": slot_id,
		"item": item_data,
	}
	set_drag_preview(_build_preview())
	return payload


func _can_drop_data(_at_position: Vector2, data) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var payload: Dictionary = data
	# Same-cell drop is a no-op; reject so the cursor shows the
	# "no" affordance and the drop callback doesn't fire.
	if payload.get("source_kind", "") == "grid_card" and kind == "grid_card":
		if String(payload.get("grid_ref", "")) == grid_ref and int(payload.get("item_idx", -1)) == item_idx:
			return false
	# Doll slot must accept the source item's category.
	if kind == "doll_slot":
		if has_item:
			# Swap-into-doll is sim-supported (equip swaps); accept.
			return _doll_accepts_payload(payload)
		return _doll_accepts_payload(payload)
	# Dragging back from a doll slot onto a grid card / empty cell:
	# always allowed (it's an unequip into the destination grid).
	if payload.get("source_kind", "") == "doll_slot":
		return kind == "grid_card" or kind == "empty_cell"
	# Grid → grid is always allowed (move / swap).
	return true


func _drop_data(_at_position: Vector2, data) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var payload: Dictionary = data
	var target := {
		"target_kind": kind,
		"grid_ref": grid_ref,
		"item_idx": item_idx,
		"slot_id": slot_id,
		"cell_x": cell_x,
		"cell_y": cell_y,
	}
	emit_signal("drop_received", payload, target)


## --- Helpers --------------------------------------------------------

func _doll_accepts_payload(payload: Dictionary) -> bool:
	# `accepted_categories` lives on the slot script. The payload
	# carries the item dict which has `category` (set by
	# `inventory_to_array` server-side).
	if accepted_categories.is_empty():
		return true
	var item: Dictionary = payload.get("item", {})
	var category: String = String(item.get("category", ""))
	for accept in accepted_categories:
		if String(accept) == category:
			return true
	return false


func _build_preview() -> Control:
	# Drag preview mirrors the visual treatment of the source card:
	# same border style, same category icon strip, same name + count
	# stacked vertically. Sized to the item's grid footprint
	# (`w × h` cells × `_CELL` px) so the player sees exactly how
	# much grid space they're holding under the cursor.
	#
	# The card is rendered at 70 % opacity so it doesn't fully
	# occlude potential drop targets underneath.
	const CELL: int = 96  # mirrors inventory_panel._CELL
	var w: int = int(item_data.get("w", 1))
	var h: int = int(item_data.get("h", 1))
	var pc := PanelContainer.new()
	pc.modulate = Color(1, 1, 1, 0.7)
	pc.custom_minimum_size = Vector2(CELL * w + 2 * (w - 1), CELL * h + 2 * (h - 1))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.9)
	sb.border_color = Color(0.55, 0.78, 0.95, 0.95)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	pc.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(v)

	# Category icon strip — same palette as `inventory_panel`'s
	# `_build_category_icon` (kept inline here to avoid a circular
	# import; if the table drifts, both should be updated).
	var category: String = String(item_data.get("category", "misc"))
	var icon := _build_preview_icon(category)
	if icon != null:
		v.add_child(icon)

	var name_label := Label.new()
	name_label.text = String(item_data.get("name", "?"))
	name_label.add_theme_color_override("font_color", Color(0.92, 0.96, 0.98))
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_label)
	var count: int = int(item_data.get("count", 1))
	if count > 1:
		var count_label := Label.new()
		count_label.text = "×%d" % count
		count_label.add_theme_color_override("font_color", Color(0.55, 0.78, 0.95))
		count_label.add_theme_font_size_override("font_size", 10)
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(count_label)
	# Magazine loadout readout (mirrors the card so the player sees
	# what they're moving).
	var mag_cap: int = int(item_data.get("magazine_capacity", 0))
	if mag_cap > 0:
		var loaded: int = int(item_data.get("loaded_rounds", 0))
		var mag_label := Label.new()
		mag_label.text = "%d/%d" % [loaded, mag_cap]
		mag_label.add_theme_color_override("font_color", Color(0.40, 0.78, 0.78))
		mag_label.add_theme_font_size_override("font_size", 10)
		mag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(mag_label)
	return pc


## Local copy of `inventory_panel._build_category_icon` — kept
## inline so the drag preview script doesn't need to reach into
## the panel during a drag operation.
func _build_preview_icon(category: String) -> Control:
	const ICONS := {
		"weapon_primary": {"tag": "RIFLE", "color": Color(0.78, 0.55, 0.30)},
		"weapon_secondary": {"tag": "RIFLE", "color": Color(0.78, 0.55, 0.30)},
		"sidearm": {"tag": "PSTL", "color": Color(0.78, 0.55, 0.30)},
		"melee": {"tag": "BLADE", "color": Color(0.65, 0.55, 0.45)},
		"magazine": {"tag": "MAG", "color": Color(0.30, 0.65, 0.65)},
		"ammo": {"tag": "AMMO", "color": Color(0.30, 0.65, 0.65)},
		"medical": {"tag": "MED+", "color": Color(0.78, 0.30, 0.30)},
		"drug": {"tag": "RX", "color": Color(0.65, 0.40, 0.78)},
		"food": {"tag": "FOOD", "color": Color(0.50, 0.70, 0.30)},
		"drink": {"tag": "H2O", "color": Color(0.30, 0.55, 0.78)},
		"head_gear": {"tag": "HEAD", "color": Color(0.55, 0.55, 0.40)},
		"eyes": {"tag": "EYES", "color": Color(0.55, 0.55, 0.40)},
		"armor_vest": {"tag": "VEST", "color": Color(0.55, 0.55, 0.65)},
		"chest_rig": {"tag": "RIG", "color": Color(0.55, 0.55, 0.45)},
		"backpack": {"tag": "BAG", "color": Color(0.55, 0.40, 0.30)},
		"tool": {"tag": "TOOL", "color": Color(0.55, 0.55, 0.55)},
		"component": {"tag": "PART", "color": Color(0.45, 0.45, 0.55)},
		"junk": {"tag": "JUNK", "color": Color(0.40, 0.40, 0.40)},
		"misc": {"tag": "ITEM", "color": Color(0.45, 0.45, 0.45)},
	}
	var visual: Dictionary = ICONS.get(category, ICONS["misc"])
	var color: Color = visual.get("color", Color(0.45, 0.45, 0.45))
	var tag: String = String(visual.get("tag", "ITEM"))
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 0.85)
	sb.border_color = color
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = tag
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(0.95, 0.97, 0.98))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	return panel


## --- Tooltips (Phase 2C) -------------------------------------------

const _TOOLTIP_CATEGORY_LABEL := {
	"weapon_primary": "Primary",
	"weapon_secondary": "Secondary",
	"sidearm": "Sidearm",
	"melee": "Melee",
	"magazine": "Magazine",
	"ammo": "Ammo",
	"medical": "Medical",
	"drug": "Drug",
	"food": "Food",
	"drink": "Drink",
	"head_gear": "Headgear",
	"eyes": "Eyewear",
	"armor_vest": "Armor",
	"chest_rig": "Rig",
	"backpack": "Backpack",
	"tool": "Tool",
	"component": "Component",
	"junk": "Junk",
	"misc": "Item",
}


## Build the floating tooltip shown after a hover delay.
##
## Called by Godot once per tooltip surface; we return a fresh
## Control each time and Godot manages its lifecycle. The
## `_for_text` argument is the literal `tooltip_text` string
## (just a placeholder space — content is built from `kind` +
## `item_data` + `slot_label` here).
func _make_custom_tooltip(_for_text: String) -> Control:
	if kind == "empty_cell":
		return null
	if kind == "doll_slot" and not has_item:
		return _build_empty_slot_tooltip()
	return _build_item_tooltip(item_data)


func _build_item_tooltip(item: Dictionary) -> Control:
	var id: String = String(item.get("id", ""))
	var def: Dictionary = item_catalog.get(id, {})

	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.96)
	sb.border_color = Color(0.55, 0.78, 0.95, 0.95)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(240, 0)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	pc.add_child(v)

	# Header: name + category tag.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	v.add_child(header)

	var name_label := Label.new()
	name_label.text = String(item.get("name", "?"))
	name_label.add_theme_color_override("font_color", Color(0.95, 0.97, 0.98))
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	var category: String = String(item.get("category", "misc"))
	var cat_label := Label.new()
	cat_label.text = _TOOLTIP_CATEGORY_LABEL.get(category, "Item")
	cat_label.add_theme_color_override("font_color", Color(0.55, 0.78, 0.95))
	cat_label.add_theme_font_size_override("font_size", 10)
	header.add_child(cat_label)

	# Hairline divider.
	var hair := ColorRect.new()
	hair.color = Color(0.30, 0.40, 0.50, 0.60)
	hair.custom_minimum_size = Vector2(0, 1)
	v.add_child(hair)

	# Weight (unit × stack = total). The catalog dict is authoritative
	# for the per-unit weight; the grid card dict carries the stack
	# count. We show both lines so the player sees "this stack is
	# 7.2 kg" without doing the math.
	var count: int = int(item.get("count", 1))
	var unit_w: float = float(def.get("weight", 0.0))
	if unit_w > 0.0:
		var weight_str: String
		if count > 1:
			var total: float = unit_w * float(count)
			weight_str = "%.2f kg × %d = %.2f kg" % [unit_w, count, total]
		else:
			weight_str = "%.2f kg" % unit_w
		_append_kv(v, "Weight", weight_str)

	var stack_max: int = int(def.get("stack_size", 1))
	if stack_max > 1:
		_append_kv(v, "Stack", "%d / %d" % [count, stack_max])

	# Magazine-specific block.
	var mag_cap: int = int(item.get("magazine_capacity", 0))
	if mag_cap > 0:
		var loaded: int = int(item.get("loaded_rounds", 0))
		var variant: String = String(item.get("loaded_variant", ""))
		var caliber: String = String(item.get("caliber", ""))
		var load_str: String
		if variant.is_empty():
			load_str = "%d / %d" % [loaded, mag_cap]
		else:
			load_str = "%d / %d (%s)" % [loaded, mag_cap, variant]
		_append_kv(v, "Loaded", load_str)
		if not caliber.is_empty():
			_append_kv(v, "Caliber", caliber)
	elif category == "ammo":
		# Ammo without magazine_capacity but with a caliber surfaced
		# on the card dict (some ammo defs expose caliber straight
		# through `inventory_to_array`).
		var caliber: String = String(item.get("caliber", ""))
		if not caliber.is_empty():
			_append_kv(v, "Caliber", caliber)

	# Perishable hint — show only if the item is flagged
	# perishable. `perishable_ticks > 0` in the catalog dict.
	var perish: int = int(def.get("perishable_ticks", 0))
	if perish > 0:
		# Ticks @ 20 Hz → seconds → minutes. Round to nearest minute.
		var minutes: int = max(1, int(round(perish / 20.0 / 60.0)))
		_append_kv(v, "Spoils in", "%d min (fresh)" % minutes)

	# Rotation indicator — kept low-key, just a subtle line so the
	# player understands footprint matches what's drawn.
	var rot: String = String(item.get("rotation", "0"))
	if rot != "0":
		_append_kv(v, "Rotated", "90°")

	return pc


func _build_empty_slot_tooltip() -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.96)
	sb.border_color = Color(0.40, 0.55, 0.65, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(200, 0)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	pc.add_child(v)

	var title := Label.new()
	var label_text: String = slot_label if not slot_label.is_empty() else slot_id.capitalize()
	title.text = label_text
	title.add_theme_color_override("font_color", Color(0.85, 0.90, 0.95))
	title.add_theme_font_size_override("font_size", 12)
	v.add_child(title)

	var hair := ColorRect.new()
	hair.color = Color(0.30, 0.40, 0.50, 0.50)
	hair.custom_minimum_size = Vector2(0, 1)
	v.add_child(hair)

	# Accepted categories — rendered as a comma-joined list using
	# the same human-readable labels as item tooltips.
	if accepted_categories.size() > 0:
		var labels: Array[String] = []
		for cat in accepted_categories:
			var s: String = String(cat)
			labels.push_back(_TOOLTIP_CATEGORY_LABEL.get(s, s.capitalize()))
		_append_kv(v, "Accepts", ", ".join(labels))
	else:
		_append_kv(v, "Accepts", "any")
	return pc


func _append_kv(parent: VBoxContainer, key: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var k := Label.new()
	k.text = key
	k.add_theme_color_override("font_color", Color(0.55, 0.68, 0.78))
	k.add_theme_font_size_override("font_size", 10)
	k.custom_minimum_size = Vector2(70, 0)
	row.add_child(k)

	var w := Label.new()
	w.text = value
	w.add_theme_color_override("font_color", Color(0.92, 0.96, 0.98))
	w.add_theme_font_size_override("font_size", 10)
	w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(w)
