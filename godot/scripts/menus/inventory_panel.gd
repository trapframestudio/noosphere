extends CanvasLayer
## In-game inventory + crafting panel — PR-3 of the Tarkov/STALKER
## inventory rewrite. Toggled with the `toggle_inventory_panel` action
## (default `I`). Two tabs:
##
## - **Inventory** — paper-doll equipment (left) + 2D grid renderer
##   for pockets and each equipped container (right). Click-to-pick-up /
##   click-to-place interaction; `R` rotates the held item; click a
##   paper-doll slot to equip the held item or unequip what's in it.
## - **Crafting** — recipe list, per-recipe detail, queue widget.
##   Unchanged from Slice B except it now reads `player_state.equipment`
##   for the shared kit-pool (already handled sim-side).
##
## Lives as a child of `session_root.tscn`. Polls `tick_completed` for
## refresh; input-only state (carried item, rotation) is client-side.

## Pixel size of one inventory grid cell. ~2× the previous 48 px so
## card text + icon strip have room to breathe; multi-cell items
## scale up correspondingly. The grid container stays a fixed
## shape (W × H cells); items occupy their footprint within it.
const _CELL: int = 96

## Pixel size of one paper-doll grid cell. Each slot multiplies
## this by its `size.w × size.h` footprint so wide/tall slots
## (rifles, armor vests) read as rectangles.
const _DOLL_CELL: int = 56

## Paper-doll grid extent. Sized to the new STALKER-style 8×7
## layout in `equipment_slots.toml`.
const _DOLL_COLS: int = 8
const _DOLL_ROWS: int = 7

## Phase 2A category → preferred-slot order. Used by the right-click
## "Equip" menu entry to pick a destination slot without dragging
## onto the doll. The first slot that's empty wins; if none are
## free we fall back to the first slot and let the sim's equip path
## decide whether to swap (it may reject). Mirrors
## `crates/simn-sim/data/equipment_slots.toml`.
## Phase 2B drag-and-drop script. Attached to every draggable card +
## drop-target cell so each one carries its own metadata + drop hook.
## See `inventory_drop_target.gd`.
const _DROP_TARGET_SCRIPT: Script = preload("res://scripts/menus/inventory_drop_target.gd")

const _CATEGORY_SLOT_PREFERENCE := {
	"weapon_primary": ["primary", "secondary"],
	"weapon_secondary": ["secondary", "primary"],
	"sidearm": ["sidearm"],
	"melee": ["melee"],
	"head_gear": ["head"],
	"eyes": ["eyes"],
	"armor_vest": ["armor_vest"],
	"chest_rig": ["rig"],
	"backpack": ["backpack"],
	"medical": ["belt_1", "belt_2", "belt_3", "belt_4"],
	"drug": ["belt_1", "belt_2", "belt_3", "belt_4"],
	"food": ["belt_1", "belt_2", "belt_3", "belt_4"],
	"drink": ["belt_1", "belt_2", "belt_3", "belt_4"],
}

var _root: Control
var _tabs: TabContainer
var _inv_weight_label: Label
var _paper_doll_box: Control
var _grids_column: VBoxContainer
var _carried_badge: Panel        # floating badge under mouse when carrying
var _carried_label: Label

# Crafting tab members — carried over from Slice B.
var _recipe_list: VBoxContainer
var _recipe_filter_buttons: Dictionary = {}
var _recipe_filter: String = "all"
var _craftable_only: bool = false
var _queue_strip: VBoxContainer
var _selected_recipe: String = ""
var _detail_slot: VBoxContainer
var _craft_count_spin: SpinBox
var _last_recipe_catalog: Array = []
var _last_slot_catalog: Array = []
## Phase 2C: id → catalog-dict lookup used by tooltips. Built from
## `SimHost.item_catalog()` on open + refreshed when the panel
## rebuilds. The drop-target script reads this via its `static var`
## so every card resolves weight / stack_size without per-hover
## bridge traffic.
var _item_catalog_by_id: Dictionary = {}

## Phase 2D: active category filter (`"all"`, `"weapons"`, `"ammo"`,
## `"medical"`, `"food"`, `"armor"`, `"parts"`) + free-text search
## query. Filter is preserved across panel rebuilds; cards that
## don't match get a dim modulate so the player still sees what
## they own without losing their grid positions (tarkov keeps
## positions stable while a filter is active — it's a highlight,
## not a re-layout).
var _active_filter: String = "all"
var _search_query: String = ""
## Filter chip buttons keyed by filter id — repainted on selection
## change to flip active styling.
var _filter_chip_buttons: Dictionary = {}
## Persistent search LineEdit so its focus + caret survive grid
## rebuilds.
var _search_input: LineEdit
## Category id (from `_TOOLTIP_CATEGORY_LABEL` etc.) → filter chip
## id. Used by `_card_passes_filter` to map an item's category to
## the currently selected chip group. Items whose category isn't
## in this map fall through to `"parts"` (tool / component / junk
## / misc).
const _FILTER_GROUPS := {
	"weapon_primary": "weapons",
	"weapon_secondary": "weapons",
	"sidearm": "weapons",
	"melee": "weapons",
	"magazine": "ammo",
	"ammo": "ammo",
	"medical": "medical",
	"drug": "medical",
	"food": "food",
	"drink": "food",
	"head_gear": "armor",
	"eyes": "armor",
	"armor_vest": "armor",
	"chest_rig": "armor",
	"backpack": "armor",
	"tool": "parts",
	"component": "parts",
	"junk": "parts",
	"misc": "parts",
}
## Ordered list of `(filter_id, short_label)` rendered as chips
## left-to-right. `"all"` is the always-on default.
const _FILTER_CHIPS: Array = [
	["all", "ALL"],
	["weapons", "WPN"],
	["ammo", "AMMO"],
	["medical", "MED"],
	["food", "FOOD"],
	["armor", "ARMOR"],
	["parts", "PARTS"],
]
## Alpha applied to cards that fail the active filter / search. Low
## enough to fade them visually while still leaving the item readable
## so the player can see what they have outside the current focus.
const _FILTER_DIM_ALPHA: float = 0.28

# Carry state — what the player has "picked up" for moving.
# `grid_ref` = "pockets" | "equipped:<slot_id>" | "container:<id>"
# `item_idx` = index into that grid's items array
# `rotation` = "0" | "90"
# `_carried` = null when nothing is being moved.
var _carried: Variant = null

# Phase 3E: id of the world container currently being looted, or
# `-1` when the player is just managing their inventory. Set via
# `open_for_container(id)` from the LootController on `F`; the
# right-side grid stack prepends the container's grid so the
# Phase 2 drag-and-drop / right-click / tooltip / filter
# affordances all work for looting too — no separate panel.
var _open_container_id: int = -1


func _ready() -> void:
	layer = 40
	visible = false
	_build()
	_connect_tick_signal()


func _connect_tick_signal() -> void:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim := session.get_node_or_null("SimHost")
	if sim == null:
		return
	# Phase 2G: subscribe to `view_updated` (fires every tick in solo
	# + host + client). The older `tick_completed` only fires when
	# networked — solo sessions never received it, so the inventory
	# stayed stale after drag-drop / equip / consume actions until
	# the panel was closed + reopened.
	if not sim.is_connected("view_updated", _on_view_updated):
		sim.connect("view_updated", _on_view_updated)


## Last sim tick we performed an `_refresh_all`. Used to throttle
## the view-updated cascade — without it, a 20 Hz sim tick rate
## triggers 20 full UI rebuilds per second, which queue_frees +
## reallocates hundreds of nodes per frame and tanks main-thread
## FPS. 4 Hz is the eye's perceptual limit for inventory changes
## and lets the worker breathe between rebuilds.
var _last_refresh_tick: int = -1
const _REFRESH_THROTTLE_TICKS: int = 5  # 20 Hz / 5 = 4 Hz refresh


func _on_view_updated(tick: int) -> void:
	if not visible:
		return
	if tick - _last_refresh_tick < _REFRESH_THROTTLE_TICKS:
		return
	_last_refresh_tick = tick
	_refresh_all()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inventory_panel"):
		var session := get_node_or_null("/root/GameSession")
		if visible:
			_close()
			get_viewport().set_input_as_handled()
			return
		if session != null and session.has_method("in_game") and session.in_game():
			_open()
			get_viewport().set_input_as_handled()
		return
	if visible and event.is_action_pressed("ui_cancel"):
		# Cancel what you're carrying first, then close.
		if _carried != null:
			_carried = null
			_update_carry_badge()
			get_viewport().set_input_as_handled()
			return
		_close()
		get_viewport().set_input_as_handled()
		return
	# R rotates the held item while carrying. Bind is set in project.godot
	# as `rotate_held_item` (default `R`). Only act while the panel is
	# open and something is carried.
	if visible and _carried != null and event.is_action_pressed("rotate_held_item"):
		var r: String = _carried.get("rotation", "0")
		_carried["rotation"] = "90" if r == "0" else "0"
		_update_carry_badge()
		_refresh_inventory_page()
		get_viewport().set_input_as_handled()
		return
	# X drops the held item to the ground when carrying. Sim's drop_slot
	# only takes a pockets index, so equipped-grid items must unequip
	# first; we log and bail in that case.
	if visible and _carried != null and event.is_action_pressed("drop_held_item"):
		_drop_carried()
		get_viewport().set_input_as_handled()


func _open() -> void:
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if _last_recipe_catalog.is_empty():
		_reload_recipe_catalog()
	if _last_slot_catalog.is_empty():
		_reload_slot_catalog()
	# Phase 2C: tooltip data-source. Reload on every open so a
	# mid-session catalog edit (mods, hot-reload) lands without a
	# restart.
	_reload_item_catalog()
	_refresh_all()


## Phase 3E: open the panel with a specific world container as
## the active loot surface. Called by `LootController` on `F`
## when the player is near a `WorldContainer`. The container's
## grid renders at the top of the right-side grids stack so the
## player sees it first; drag-and-drop into pockets / equipped
## containers routes through the existing
## `take_from_container` / `put_in_container` bridge methods.
##
## Closing the panel (Esc or `I`) clears `_open_container_id`,
## so the next open returns to "manage inventory" mode.
func open_for_container(container_id: int) -> void:
	if container_id < 0:
		return
	_open_container_id = container_id
	_open()


func _close() -> void:
	visible = false
	_carried = null
	# Phase 3E: dropping out of looting mode on close so the next
	# `I`-toggle opens a plain inventory view instead of
	# re-attaching to a now-stale container.
	_open_container_id = -1
	_update_carry_badge()
	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_method("in_game") and session.in_game():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# -------- Build --------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.45)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var chassis := PanelContainer.new()
	chassis.custom_minimum_size = Vector2(1180, 720)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(0, 0, 0, 0.8)
	sb.shadow_offset = Vector2(0, 4)
	chassis.add_theme_stylebox_override("panel", sb)
	center.add_child(chassis)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	chassis.add_child(body)

	body.add_child(_build_header())

	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_override("font", NSFonts.MONO)
	_tabs.add_theme_font_size_override("font_size", 12)
	body.add_child(_tabs)

	var inv_page := _build_inventory_page()
	inv_page.name = "INVENTORY"
	_tabs.add_child(inv_page)

	var craft_page := _build_crafting_page()
	craft_page.name = "CRAFTING"
	_tabs.add_child(craft_page)

	# Floating carry badge — sibling to the chassis, positioned via
	# _process so it tracks the mouse.
	_carried_badge = Panel.new()
	_carried_badge.visible = false
	_carried_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_carried_badge.custom_minimum_size = Vector2(280, 56)
	var badge_sb := StyleBoxFlat.new()
	badge_sb.bg_color = NSColors.BG_CRT
	badge_sb.border_color = NSColors.VLF_PHOSPHOR
	badge_sb.border_width_left = 2
	badge_sb.border_width_top = 2
	badge_sb.border_width_right = 2
	badge_sb.border_width_bottom = 2
	badge_sb.content_margin_left = 6
	badge_sb.content_margin_right = 6
	badge_sb.content_margin_top = 4
	badge_sb.content_margin_bottom = 4
	_carried_badge.add_theme_stylebox_override("panel", badge_sb)
	_carried_label = NSWidgets.label_mono("", 11, NSColors.VLF_PHOSPHOR)
	_carried_badge.add_child(_carried_label)
	_root.add_child(_carried_badge)


func _build_header() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BASALT_BLACK
	sb.border_color = NSColors.LICHEN
	sb.border_width_bottom = 1
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 16
	sb.content_margin_bottom = 12
	wrap.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	wrap.add_child(row)

	var brand := VBoxContainer.new()
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.add_theme_constant_override("separation", 4)
	brand.add_child(NSWidgets.eyebrow("◇ DRIFTER LOAD-OUT"))
	brand.add_child(NSWidgets.stencil("KIT", 22))
	row.add_child(brand)

	var hint := NSWidgets.label_mono(
		"[click] pick up · [click cell/slot] place · [click item] swap · [R] rotate · [X] drop · [Esc] cancel",
		11,
		NSColors.FG_3,
	)
	row.add_child(hint)

	var close := NSWidgets.button("Close [I]", NSWidgets.Variant.GHOST)
	close.pressed.connect(_close)
	row.add_child(close)

	return wrap


# -------- Inventory tab --------

func _build_inventory_page() -> Control:
	var page := MarginContainer.new()
	page.add_theme_constant_override("margin_left", 24)
	page.add_theme_constant_override("margin_right", 24)
	page.add_theme_constant_override("margin_top", 18)
	page.add_theme_constant_override("margin_bottom", 18)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	page.add_child(v)

	_inv_weight_label = NSWidgets.label_mono("weight: 0.0 / 50.0 kg", 12, NSColors.VLF_PHOSPHOR)
	v.add_child(_inv_weight_label)

	v.add_child(NSWidgets.hairline())

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 24)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(split)

	# Left column: paper doll. Width pinned to the doll grid +
	# horizontal padding so the right-side grid column can flex to
	# its own minimum size without stealing space from the doll.
	# Phase 2C polish: backdrop is now a Panel (not bare Control) so
	# the dark cells read against a slightly-lighter steel frame —
	# matches the tarkov-style cell treatment they sit inside.
	var doll_panel := Panel.new()
	var doll_sb := StyleBoxFlat.new()
	doll_sb.bg_color = Color(0.06, 0.07, 0.085, 1.0)
	doll_sb.border_color = Color(0.16, 0.19, 0.23, 1.0)
	doll_sb.set_border_width_all(1)
	doll_sb.set_corner_radius_all(3)
	doll_panel.add_theme_stylebox_override("panel", doll_sb)
	doll_panel.custom_minimum_size = Vector2(
		_DOLL_COLS * _DOLL_CELL + 24,
		_DOLL_ROWS * _DOLL_CELL + 24,
	)
	doll_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	split.add_child(doll_panel)

	_paper_doll_box = Control.new()
	_paper_doll_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_paper_doll_box.offset_left = 12
	_paper_doll_box.offset_right = -12
	_paper_doll_box.offset_top = 12
	_paper_doll_box.offset_bottom = -12
	_paper_doll_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	doll_panel.add_child(_paper_doll_box)

	# Right column: filter toolbar (Phase 2D) above a scroll container
	# holding the grids. Toolbar is OUTSIDE `_grids_column` so it
	# survives the per-tick rebuild and the search LineEdit doesn't
	# lose focus mid-typing.
	var right_col := VBoxContainer.new()
	right_col.add_theme_constant_override("separation", 8)
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right_col)

	right_col.add_child(_build_filter_toolbar())

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_col.add_child(scroll)

	_grids_column = VBoxContainer.new()
	_grids_column.add_theme_constant_override("separation", 16)
	_grids_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grids_column)

	return page


func _refresh_inventory_page() -> void:
	var view := _player_view()
	var weight: float = view.get("inventory_weight", 0.0)
	var cap: float = 50.0
	var over: bool = weight > cap
	_inv_weight_label.text = "weight: %.1f / %.1f kg%s" % [
		weight, cap, "  ⚠ OVER (regen ÷2)" if over else "",
	]
	_inv_weight_label.add_theme_color_override(
		"font_color",
		NSColors.STAMP_RED if over else NSColors.VLF_PHOSPHOR,
	)

	_rebuild_paper_doll(view)
	_rebuild_grids(view)


func _rebuild_paper_doll(view: Dictionary) -> void:
	for c in _paper_doll_box.get_children():
		c.queue_free()
	if _last_slot_catalog.is_empty():
		return
	var equipment: Dictionary = view.get("equipment", {})
	for slot_var in _last_slot_catalog:
		var slot: Dictionary = slot_var
		var slot_id: String = slot.get("id", "")
		if slot_id == "pockets":
			# Pockets is a virtual slot — rendered on the right as a
			# grid, not on the paper doll. Skip.
			continue
		var pos: Vector2i = slot.get("position", Vector2i.ZERO)
		# Phase 2 polish: slots carry a `size = {w, h}` footprint
		# (from `equipment_slots.toml`). Defaults to 1×1 for legacy
		# entries. Wider/taller slots get wider/taller cells so the
		# doll reads like a traditional inventory paper doll (rifles
		# are 4×1 horizontal, armor vest is 2×2, backpack is 1×4, etc).
		var size_v: Vector2i = slot.get("size", Vector2i(1, 1))
		var cell := _build_doll_cell(slot, equipment.get(slot_id, null))
		cell.position = Vector2(pos.x * _DOLL_CELL, pos.y * _DOLL_CELL)
		cell.size = Vector2(size_v.x * _DOLL_CELL, size_v.y * _DOLL_CELL)
		cell.custom_minimum_size = cell.size
		_paper_doll_box.add_child(cell)


## Doll-cell color tokens — Tarkov-inspired cold steel palette, kept
## inline rather than added to `NSColors` because they're scoped to
## this widget and intentionally diverge from the phosphor-green
## token vocabulary used elsewhere in the launcher shell.
const _DOLL_BG := Color(0.09, 0.10, 0.12, 1.0)
const _DOLL_BG_FULL := Color(0.10, 0.12, 0.14, 1.0)
const _DOLL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const _DOLL_BORDER_FULL := Color(0.30, 0.36, 0.42, 1.0)
const _DOLL_BORDER_ACCEPT := Color(0.72, 0.55, 0.28, 1.0)
const _DOLL_WATERMARK := Color(0.30, 0.36, 0.42, 0.45)
const _DOLL_SLOT_CHIP := Color(0.50, 0.58, 0.65, 0.85)
const _DOLL_ITEM_NAME := Color(0.93, 0.95, 0.97, 1.0)
const _DOLL_COUNT_FG := Color(0.95, 0.85, 0.55, 1.0)
const _DOLL_COUNT_BG := Color(0.05, 0.06, 0.08, 0.92)


func _build_doll_cell(slot: Dictionary, eq_item: Variant) -> Control:
	# Phase 2C polish: tarkov-style layered cell. Three layers
	# stacked via full-rect anchors:
	#  1. Watermark — faded slot-category tag, only meaningful when
	#     the slot is empty so the player can scan the doll without
	#     reading micro-labels.
	#  2. Slot chip — top-left abbreviated slot name in a small
	#     translucent badge. Always present so identification doesn't
	#     depend on hovering.
	#  3. Content — when populated: category icon strip mid-cell,
	#     item name beneath, count badge anchored bottom-right.
	var pc := PanelContainer.new()
	pc.set_script(_DROP_TARGET_SCRIPT)
	pc.kind = "doll_slot"
	pc.slot_id = String(slot.get("id", ""))
	pc.slot_label = String(slot.get("label", ""))
	pc.item_catalog = _item_catalog_by_id
	var slot_accepts: Array = slot.get("accepts", [])
	var accepts: PackedStringArray = PackedStringArray()
	for a in slot_accepts:
		accepts.push_back(String(a))
	pc.accepted_categories = accepts
	var has_item: bool = eq_item != null and eq_item is Dictionary
	pc.has_item = has_item
	if has_item:
		pc.item_data = eq_item
	pc.drop_received.connect(_on_drop_received)

	# Stylebox: dark steel bg + thin border. Color picks vary by
	# state — empty / has-item / accepting-drop — to telegraph
	# without shouting.
	var accepts_carried: bool = _slot_accepts_carried(slot)
	var sb := StyleBoxFlat.new()
	sb.bg_color = _DOLL_BG_FULL if has_item else _DOLL_BG
	var border := _DOLL_BORDER
	if accepts_carried:
		border = _DOLL_BORDER_ACCEPT
	elif has_item:
		border = _DOLL_BORDER_FULL
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	pc.add_theme_stylebox_override("panel", sb)

	# Outer MarginContainer eats the 3px inset so the chip / icon /
	# badge don't have to know about cell padding.
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 3)
	pad.add_theme_constant_override("margin_right", 3)
	pad.add_theme_constant_override("margin_top", 3)
	pad.add_theme_constant_override("margin_bottom", 3)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(pad)

	# Three stacked rows fill the cell. Watermark + content live in
	# the middle expand-row, anchored chips in the top + bottom rows.
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(rows)

	# Top row — slot-name chip on the left, expand spacer on the
	# right.
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 0)
	top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(top_row)
	var slot_label_text: String = _doll_slot_chip_text(slot)
	if not slot_label_text.is_empty():
		var chip := PanelContainer.new()
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var chip_sb := StyleBoxFlat.new()
		chip_sb.bg_color = Color(0.04, 0.05, 0.07, 0.78)
		chip_sb.set_corner_radius_all(2)
		chip_sb.content_margin_left = 4
		chip_sb.content_margin_right = 4
		chip_sb.content_margin_top = 1
		chip_sb.content_margin_bottom = 1
		chip.add_theme_stylebox_override("panel", chip_sb)
		var chip_label := Label.new()
		chip_label.text = slot_label_text
		chip_label.add_theme_color_override("font_color", _DOLL_SLOT_CHIP)
		chip_label.add_theme_font_size_override("font_size", 8)
		chip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(chip_label)
		top_row.add_child(chip)
	var top_spacer := Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(top_spacer)

	# Middle row — expand-fill. Holds either the watermark (empty)
	# or the icon + name stack (full). When full, the watermark is
	# still drawn behind via z-ordering so the slot identity stays
	# legible even with an item present.
	var middle := Control.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(middle)

	# Watermark — anchored full rect inside `middle`, centered text,
	# faded color.
	var watermark_cat: String = ""
	if not accepts.is_empty():
		watermark_cat = String(accepts[0])
	if not watermark_cat.is_empty():
		var wm := Label.new()
		wm.text = _category_watermark_text(watermark_cat)
		var wm_color: Color = _DOLL_WATERMARK
		if has_item:
			# Dim further when an item is overlaid so it reads as
			# texture rather than text.
			wm_color = Color(wm_color.r, wm_color.g, wm_color.b, 0.15)
		wm.add_theme_color_override("font_color", wm_color)
		wm.add_theme_font_size_override("font_size", 18)
		wm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		wm.set_anchors_preset(Control.PRESET_FULL_RECT)
		wm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		middle.add_child(wm)

	# Item content stack — icon + name, centered. Sits on top of the
	# watermark inside `middle`.
	if has_item:
		var item: Dictionary = eq_item
		var content := VBoxContainer.new()
		content.add_theme_constant_override("separation", 2)
		content.alignment = BoxContainer.ALIGNMENT_CENTER
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.set_anchors_preset(Control.PRESET_FULL_RECT)
		middle.add_child(content)

		var icon := _build_category_icon(String(item.get("category", "misc")))
		if icon != null:
			icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			content.add_child(icon)

		var name_label := Label.new()
		name_label.text = _short_name(item.get("name", "?"), 12)
		name_label.add_theme_color_override("font_color", _DOLL_ITEM_NAME)
		name_label.add_theme_font_size_override("font_size", 10)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(name_label)

	# Bottom row — spacer + count badge in the bottom-right.
	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", 0)
	bottom_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(bottom_row)
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_row.add_child(bottom_spacer)
	if has_item:
		var item: Dictionary = eq_item
		var count: int = int(item.get("count", 1))
		if count > 1:
			var badge := PanelContainer.new()
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var badge_sb := StyleBoxFlat.new()
			badge_sb.bg_color = _DOLL_COUNT_BG
			badge_sb.set_corner_radius_all(2)
			badge_sb.content_margin_left = 4
			badge_sb.content_margin_right = 4
			badge_sb.content_margin_top = 1
			badge_sb.content_margin_bottom = 1
			badge.add_theme_stylebox_override("panel", badge_sb)
			var badge_label := Label.new()
			badge_label.text = "×%d" % count
			badge_label.add_theme_color_override("font_color", _DOLL_COUNT_FG)
			badge_label.add_theme_font_size_override("font_size", 9)
			badge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			badge.add_child(badge_label)
			bottom_row.add_child(badge)

	# Phase 2B: doll slot is a drag-and-drop target/source via the
	# attached `inventory_drop_target.gd` script. Right-click on a
	# populated slot opens the context menu (Unequip / Examine).
	pc.context_menu_requested.connect(_on_doll_context_menu_requested.bind(slot))
	return pc


## Short text shown as the faded center watermark on an empty slot.
## Mirrors the category-icon tag vocabulary from
## `_build_category_icon` / drag preview, so the visual language is
## consistent across the inventory.
func _category_watermark_text(category: String) -> String:
	match category:
		"weapon_primary", "weapon_secondary":
			return "RIFLE"
		"sidearm":
			return "PSTL"
		"melee":
			return "BLADE"
		"magazine":
			return "MAG"
		"ammo":
			return "AMMO"
		"medical":
			return "MED+"
		"drug":
			return "RX"
		"food":
			return "FOOD"
		"drink":
			return "H2O"
		"head_gear":
			return "HEAD"
		"eyes":
			return "EYES"
		"armor_vest":
			return "VEST"
		"chest_rig":
			return "RIG"
		"backpack":
			return "BAG"
		"tool":
			return "TOOL"
		_:
			return ""


## Short corner-chip label for a doll slot. Belt slots get a digit
## (1..4), everything else uses an uppercase abbreviation of the
## slot's display label so 1×1 cells don't overflow.
func _doll_slot_chip_text(slot: Dictionary) -> String:
	var sid: String = String(slot.get("id", ""))
	if sid.begins_with("belt_"):
		return sid.substr(5, 1)
	var label_text: String = String(slot.get("label", sid))
	if label_text.is_empty():
		return ""
	# Keep it short — 4 chars is enough for HEAD / EYES / PRIM, and
	# fits in the corner chip without truncation art-effects.
	return label_text.substr(0, 4).to_upper()


# -------- Phase 2D: filter toolbar --------

func _build_filter_toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_filter_chip_buttons = {}
	for entry in _FILTER_CHIPS:
		var fid: String = String(entry[0])
		var label_text: String = String(entry[1])
		var btn := Button.new()
		btn.text = label_text
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_override("font", NSFonts.MONO_BOLD)
		btn.add_theme_font_size_override("font_size", 10)
		btn.add_theme_constant_override("h_separation", 0)
		btn.custom_minimum_size = Vector2(56, 22)
		btn.pressed.connect(_on_filter_chip_pressed.bind(fid))
		_filter_chip_buttons[fid] = btn
		bar.add_child(btn)

	# Push search input to the right edge.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_search_input = LineEdit.new()
	_search_input.placeholder_text = "search…"
	_search_input.custom_minimum_size = Vector2(200, 22)
	_search_input.add_theme_font_override("font", NSFonts.MONO)
	_search_input.add_theme_font_size_override("font_size", 11)
	_search_input.text_changed.connect(_on_search_text_changed)
	bar.add_child(_search_input)

	_paint_filter_chips()
	return bar


## Repaint chip styles so the active one stands out. Called on
## every selection change. Avoids re-creating the buttons (which
## would steal focus from the search input).
func _paint_filter_chips() -> void:
	for fid_var in _filter_chip_buttons.keys():
		var fid: String = String(fid_var)
		var btn: Button = _filter_chip_buttons[fid]
		var sb := StyleBoxFlat.new()
		var sb_hover := StyleBoxFlat.new()
		var sb_pressed := StyleBoxFlat.new()
		if fid == _active_filter:
			sb.bg_color = Color(0.72, 0.55, 0.28, 0.92)
			sb.border_color = Color(0.92, 0.78, 0.42, 0.95)
			sb.set_border_width_all(1)
			btn.add_theme_color_override("font_color", Color(0.06, 0.06, 0.08))
		else:
			sb.bg_color = Color(0.08, 0.10, 0.12, 0.95)
			sb.border_color = Color(0.22, 0.26, 0.30, 1.0)
			sb.set_border_width_all(1)
			btn.add_theme_color_override("font_color", Color(0.65, 0.72, 0.78))
		sb.set_corner_radius_all(2)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		# Hover + pressed clones — same border + corners, slightly
		# brighter bg for affordance.
		sb_hover.bg_color = sb.bg_color.lightened(0.08)
		sb_hover.border_color = sb.border_color
		sb_hover.set_border_width_all(1)
		sb_hover.set_corner_radius_all(2)
		sb_hover.content_margin_left = 8
		sb_hover.content_margin_right = 8
		sb_hover.content_margin_top = 2
		sb_hover.content_margin_bottom = 2
		sb_pressed.bg_color = sb.bg_color.darkened(0.08)
		sb_pressed.border_color = sb.border_color
		sb_pressed.set_border_width_all(1)
		sb_pressed.set_corner_radius_all(2)
		sb_pressed.content_margin_left = 8
		sb_pressed.content_margin_right = 8
		sb_pressed.content_margin_top = 2
		sb_pressed.content_margin_bottom = 2
		btn.add_theme_stylebox_override("normal", sb)
		btn.add_theme_stylebox_override("hover", sb_hover)
		btn.add_theme_stylebox_override("pressed", sb_pressed)
		btn.add_theme_stylebox_override("focus", sb)


func _on_filter_chip_pressed(filter_id: String) -> void:
	if _active_filter == filter_id:
		return
	_active_filter = filter_id
	_paint_filter_chips()
	_refresh_inventory_page()


func _on_search_text_changed(new_text: String) -> void:
	_search_query = new_text.strip_edges().to_lower()
	_refresh_inventory_page()


## True if `item` is visible under the current filter + search.
## Filter-only matches dim the card; the function returns the
## composite of both so the caller can apply a single modulate.
func _card_passes_filter(item: Dictionary) -> bool:
	if _active_filter != "all":
		var category: String = String(item.get("category", "misc"))
		var group: String = String(_FILTER_GROUPS.get(category, "parts"))
		if group != _active_filter:
			return false
	if not _search_query.is_empty():
		var hay: String = String(item.get("name", "")).to_lower()
		if not hay.contains(_search_query):
			# Also try the item id for cases where the in-world
			# label has been overridden / shortened (`ak_mag_30` for
			# example) so power users can search by stable id too.
			var id: String = String(item.get("id", "")).to_lower()
			if not id.contains(_search_query):
				return false
	return true


func _rebuild_grids(view: Dictionary) -> void:
	for c in _grids_column.get_children():
		c.queue_free()
	# Phase 3E: when the player is looting an active container,
	# render it FIRST so it's the most prominent grid on the right
	# side. The container's contents come from `container_view(id)`
	# via the bridge; the grid_ref `"container:<id>"` lets the
	# drop dispatcher route moves to `take_from_container` /
	# `put_in_container`. If the lookup fails (container despawned,
	# unknown id), skip silently — pockets / equipped still render.
	if _open_container_id >= 0:
		var sim := _sim()
		if sim != null:
			var container_grid_var = sim.container_view(_open_container_id)
			if container_grid_var is Dictionary:
				var container_grid: Dictionary = container_grid_var
				if int(container_grid.get("width", 0)) > 0:
					var grid_ref := "container:%d" % _open_container_id
					var title := "◇ LOOT — Container #%d" % _open_container_id
					_grids_column.add_child(_build_grid_widget(
						grid_ref, title, container_grid,
					))

	# Pockets.
	var pockets_grid: Dictionary = {
		"width": int(view.get("inventory_width", 4)),
		"height": int(view.get("inventory_height", 4)),
		"items": view.get("inventory", []),
	}
	_grids_column.add_child(_build_grid_widget("pockets", "POCKETS", pockets_grid))

	# Every equipped container contributes its inner_grid.
	var equipment: Dictionary = view.get("equipment", {})
	for slot_id_var in equipment.keys():
		var slot_id: String = slot_id_var
		var eq_item_var = equipment[slot_id]
		if not (eq_item_var is Dictionary):
			continue
		var eq_item: Dictionary = eq_item_var
		var inner_var = eq_item.get("inner_grid", null)
		if inner_var == null or not (inner_var is Dictionary):
			continue
		var title: String = "%s — %s" % [
			slot_id.to_upper(),
			eq_item.get("name", "container"),
		]
		_grids_column.add_child(_build_grid_widget(
			"equipped:" + slot_id,
			title,
			inner_var,
		))


func _build_grid_widget(grid_ref: String, title: String, grid: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.add_child(NSWidgets.eyebrow("◇ " + title))

	var width: int = int(grid.get("width", 0))
	var height: int = int(grid.get("height", 0))
	var items: Array = grid.get("items", [])

	# Build a sparse 2D occupancy map: anchors at (x, y) carry the
	# item dict; covered cells point back to their anchor so the
	# empty-cell pass skips them.
	var anchors: Dictionary = {}
	var covered: Dictionary = {}
	for i in range(items.size()):
		var item: Dictionary = items[i]
		var ix: int = int(item.get("x", 0))
		var iy: int = int(item.get("y", 0))
		var w: int = int(item.get("w", 1))
		var h: int = int(item.get("h", 1))
		var a := Vector2i(ix, iy)
		var decorated: Dictionary = item.duplicate()
		decorated["_sim_idx"] = i
		anchors[a] = decorated
		for dy in range(h):
			for dx in range(w):
				covered[Vector2i(ix + dx, iy + dy)] = a

	# Phase 2 perf fix: use absolute positioning instead of
	# `GridContainer`. GridContainer propagates each cell's min-width
	# to the entire column — so a 4-wide rifle in column 0 stretched
	# column 0 to 4×CELL px for every row, ballooning the grid to
	# ~1500 px wide. With absolute positioning each cell sits at
	# `(x * CELL, y * CELL)` regardless of neighbors and the grid
	# stays a fixed `width × height × CELL` square.
	var canvas := Control.new()
	canvas.custom_minimum_size = Vector2(
		width * _CELL + (width - 1) * 2,
		height * _CELL + (height - 1) * 2,
	)
	canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(canvas)

	for y in range(height):
		for x in range(width):
			var coord := Vector2i(x, y)
			if covered.has(coord) and not anchors.has(coord):
				# Non-anchor covered cell — visually hidden but the
				# anchor card covers this area.
				continue
			var cell: Control
			if anchors.has(coord):
				var item: Dictionary = anchors[coord]
				cell = _build_grid_item_card(grid_ref, item)
			else:
				cell = _build_grid_empty_cell(grid_ref, x, y)
			canvas.add_child(cell)
			cell.position = Vector2(x * (_CELL + 2), y * (_CELL + 2))
			# Anchor cards self-size from their footprint; empty cells
			# pin to a single cell.
			if not anchors.has(coord):
				cell.size = Vector2(_CELL, _CELL)
				cell.custom_minimum_size = Vector2(_CELL, _CELL)

	return v


func _build_grid_empty_cell(grid_ref: String, cell_x: int, cell_y: int) -> Control:
	# Phase 2B: empty cell is drop-only — drop into here lands the
	# item via the sim's first-fit placement within the grid (the
	# cell coordinates are advisory). Not a drag source.
	var pc := PanelContainer.new()
	pc.set_script(_DROP_TARGET_SCRIPT)
	pc.kind = "empty_cell"
	pc.grid_ref = grid_ref
	pc.cell_x = cell_x
	pc.cell_y = cell_y
	pc.drop_received.connect(_on_drop_received)
	pc.custom_minimum_size = Vector2(_CELL, _CELL)
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = (
		NSColors.VLF_PHOSPHOR if _carried != null else NSColors.VLF_PHOSPHOR_DIM
	)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	pc.add_theme_stylebox_override("panel", sb)

	# Phase 2B: empty cells are pure drop targets; the attached
	# script handles `_can_drop_data` / `_drop_data`. No background
	# Button — clicks on empty cells do nothing now (the carry flow
	# is gone in favor of drag-and-drop).
	return pc


func _build_grid_item_card(grid_ref: String, item: Dictionary) -> Control:
	var w: int = int(item.get("w", 1))
	var h: int = int(item.get("h", 1))
	# Phase 2B: every grid card is a drag source + drop target.
	# Left-press starts a drag (via the attached script); right-click
	# still opens the 2A context menu via `gui_input` on the
	# background button below.
	var pc := PanelContainer.new()
	pc.set_script(_DROP_TARGET_SCRIPT)
	pc.kind = "grid_card"
	pc.grid_ref = grid_ref
	pc.item_idx = int(item.get("_sim_idx", 0))
	pc.item_data = item
	# Phase 2C: shared-by-reference catalog so the tooltip override
	# can resolve weight / stack_size without a per-hover bridge call.
	pc.item_catalog = _item_catalog_by_id
	pc.drop_received.connect(_on_drop_received)
	pc.context_menu_requested.connect(_on_card_context_menu_requested)
	# Phase 2D: dim cards that fail the filter / search so the
	# matches read at a glance without losing the grid layout. Cards
	# keep their drop-target / drag-source behavior — the dim is
	# purely visual.
	if not _card_passes_filter(item):
		pc.modulate = Color(1.0, 1.0, 1.0, _FILTER_DIM_ALPHA)
	pc.custom_minimum_size = Vector2(_CELL * w + 2 * (w - 1), _CELL * h + 2 * (h - 1))
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	pc.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	# Container + every Label inside it must have
	# `MOUSE_FILTER_IGNORE` so left-press still reaches the panel's
	# drag-init code path. Labels default to `MOUSE_FILTER_STOP` —
	# they were silently eating every item-card press pre-Phase 2B.
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(v)

	# Phase 2B: placeholder category icon. A small tinted panel +
	# category tag (e.g., "RIFLE", "MED", "FOOD") so the player can
	# tell a stack of bandages from a stack of ammo at a glance
	# without reading the name. Real icons land alongside the
	# Phase 2F rarity-tier visual pass.
	var category: String = String(item.get("category", "misc"))
	var icon_strip := _build_category_icon(category)
	if icon_strip != null:
		v.add_child(icon_strip)

	var name_label := NSWidgets.label_mono(
		_short_name(item.get("name", "?"), 14),
		11,
		NSColors.PAGE_WHITE,
	)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(name_label)
	var count: int = int(item.get("count", 1))
	if count > 1:
		var count_label := NSWidgets.label_mono("×%d" % count, 10, NSColors.VLF_PHOSPHOR)
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(count_label)
	var rot: String = item.get("rotation", "0")
	if rot != "0":
		var rot_label := NSWidgets.label_mono("↻", 10, NSColors.FG_3)
		rot_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(rot_label)
	# Magazine overlay: show variant tag + loaded/capacity and, if
	# there's matching-caliber ammo in pockets with room to load,
	# add a "LOAD" action link. The pockets grid is the source for
	# variant detection, so this shortcut is only shown for mags in
	# `pockets` (equipped-in-weapon mags reload via `R`).
	var magazine_capacity: int = int(item.get("magazine_capacity", 0))
	if magazine_capacity > 0:
		var loaded: int = int(item.get("loaded_rounds", 0))
		var variant: String = String(item.get("loaded_variant", ""))
		var tag: String = _short_variant_tag(variant)
		var text: String
		if tag.is_empty():
			text = "%d/%d" % [loaded, magazine_capacity]
		else:
			text = "%s %d/%d" % [tag, loaded, magazine_capacity]
		var mag_label := NSWidgets.label_mono(text, 9, NSColors.VLF_PHOSPHOR)
		mag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(mag_label)
		if grid_ref == "pockets" and loaded < magazine_capacity:
			var caliber: String = String(item.get("caliber", ""))
			if not caliber.is_empty():
				var next_ammo := _pocket_ammo_for_load(caliber, variant)
				if not next_ammo.is_empty():
					var load_btn := Button.new()
					load_btn.text = "▲ LOAD"
					load_btn.add_theme_font_override("font", NSFonts.MONO_BOLD)
					load_btn.add_theme_font_size_override("font_size", 11)
					load_btn.focus_mode = Control.FOCUS_NONE
					load_btn.flat = false
					# Phase 2B fix: the parent PanelContainer is a
					# drag source. To stop a press on LOAD from
					# being interpreted as the start of a card-drag,
					# stop input here AND clear the parent's drag
					# state by accepting the input event directly.
					# `mouse_filter = STOP` (default) is already
					# correct; visible non-flat styling helps the
					# player hit it. We also bump font size +
					# expand the button horizontally so the click
					# target is larger.
					load_btn.size_flags_horizontal = (
						Control.SIZE_EXPAND_FILL
					)
					load_btn.custom_minimum_size = Vector2(0, 22)
					var load_sb := StyleBoxFlat.new()
					load_sb.bg_color = Color(0.13, 0.30, 0.46, 0.92)
					load_sb.border_color = Color(0.35, 0.75, 1.0, 0.95)
					load_sb.set_border_width_all(1)
					load_sb.set_corner_radius_all(2)
					load_sb.content_margin_top = 3.0
					load_sb.content_margin_bottom = 3.0
					load_btn.add_theme_stylebox_override("normal", load_sb)
					load_btn.add_theme_color_override(
						"font_color", Color(0.95, 0.98, 1.0)
					)
					load_btn.pressed.connect(
						_on_load_mag_pressed.bind(
							int(item.get("_sim_idx", 0)),
							next_ammo,
						)
					)
					v.add_child(load_btn)
	# The card spans multiple GridContainer columns visually via
	# custom_minimum_size. GridContainer doesn't support col-span so we
	# paint the non-anchor covered cells as invisible spacers and rely
	# on the anchor card sitting on top. Fine for ≤4×4 items.
	#
	# Phase 2B: drag-and-drop replaces the click-carry flow. Input
	# now goes directly to the `PanelContainer` (via the attached
	# `inventory_drop_target.gd` script) — no background `Button`.
	# Left-press + move starts a drag; right-click opens the context
	# menu. The LOAD overlay (added above for magazines) is still a
	# nested Button and intercepts its own clicks before the panel
	# sees them.
	return pc


# -------- Interaction --------

func _on_empty_cell_pressed(grid_ref: String, cell_x: int, cell_y: int) -> void:
	# Empty cell: only meaningful while carrying.
	# For PR-3 v1 we use "first-fit placement" semantics — the sim's
	# `equip` / `move` / `grant` paths all pick a position themselves.
	# A later slice can teach the bridge to accept (x, y) from the UI.
	# Until then: click-on-empty is "place somewhere in this grid".
	var _x := cell_x
	var _y := cell_y
	if _carried == null:
		return
	_try_place_carried_into_grid(grid_ref)


func _on_item_card_pressed(grid_ref: String, idx: int) -> void:
	print("[inv-click] card grid=%s idx=%d carried=%s" % [
		grid_ref, idx, "yes" if _carried != null else "no",
	])
	if _carried == null:
		# Pick up.
		var rotation := _read_item_rotation(grid_ref, idx)
		_carried = {
			"grid_ref": grid_ref,
			"item_idx": idx,
			"rotation": rotation,
		}
		print("[inv-click] picked up: grid=%s idx=%d rot=%s" % [grid_ref, idx, rotation])
		_update_carry_badge()
		_refresh_inventory_page()
		return
	# Carrying → click on an item card.
	var src = _carried
	var src_grid: String = src.get("grid_ref", "")
	var src_idx: int = int(src.get("item_idx", -1))
	# Same cell: cancel carry.
	if src_grid == grid_ref and src_idx == idx:
		_carried = null
		_update_carry_badge()
		_refresh_inventory_page()
		return
	# Same-pockets swap: bridge supports `move_slot(from, to)`.
	if src_grid == "pockets" and grid_ref == "pockets":
		var sim := _sim()
		var sid := _local_sid()
		if sim != null and sid != 0:
			var ok: bool = sim.move_slot(sid, src_idx, idx)
			if not ok:
				print("[inv] swap %d↔%d failed" % [src_idx, idx])
		_carried = null
		_update_carry_badge()
		_refresh_inventory_page()
		return
	# Cross-grid: move into the dest grid's first-fit. Sim's
	# `move_between_grids` is one-way — true swap stays deferred since
	# the dest cell may not have room for the source item, so we move
	# rather than try to atomically exchange.
	var sim := _sim()
	var sid := _local_sid()
	if sim != null and sid != 0:
		var ok: bool = sim.move_between_grids(sid, src_grid, src_idx, grid_ref)
		if not ok:
			print("[inv] move %s[%d] → %s failed" % [src_grid, src_idx, grid_ref])
	_carried = null
	_update_carry_badge()
	_refresh_inventory_page()


func _drop_carried() -> void:
	var src = _carried
	var src_grid: String = src.get("grid_ref", "")
	var src_idx: int = int(src.get("item_idx", -1))
	if src_grid != "pockets":
		print("[inv] drop only supported for pocket items — unequip first")
		return
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0 or src_idx < 0:
		return
	var ok: bool = sim.drop_slot(sid, src_idx)
	if ok:
		print("[inv] dropped slot %d" % src_idx)
	else:
		print("[inv] drop slot %d failed" % src_idx)
	_carried = null
	_update_carry_badge()
	_refresh_inventory_page()


func _on_doll_slot_pressed(slot: Dictionary) -> void:
	var slot_id: String = slot.get("id", "")
	print("[doll-click] slot=%s carried=%s" % [slot_id, "yes" if _carried != null else "no"])
	if slot_id == "" or slot_id == "pockets":
		return
	if _carried != null:
		# Equip into the slot.
		var src = _carried
		var src_grid: String = src.get("grid_ref", "")
		var src_idx: int = int(src.get("item_idx", -1))
		print("[equip] try slot=%s from grid=%s idx=%d" % [slot_id, src_grid, src_idx])
		if src_grid == "" or src_idx < 0:
			print("[equip] aborted — invalid src grid/idx")
			return
		var sim := _sim()
		var sid := _local_sid()
		if sim == null or sid == 0:
			print("[equip] aborted — sim=%s sid=%d" % [str(sim != null), sid])
			return
		var ok: bool = sim.equip(sid, slot_id, src_grid, src_idx)
		print("[equip] sim.equip returned %s" % str(ok))
		if not ok:
			print("[equip] failed — slot %s rejects this item" % slot_id)
		_carried = null
		_update_carry_badge()
		_refresh_all()
	else:
		# Unequip into pockets. If pockets is full, the sim returns
		# false and we log it.
		var sim := _sim()
		var sid := _local_sid()
		if sim == null or sid == 0:
			return
		var ok: bool = sim.unequip(sid, slot_id, "pockets")
		if not ok:
			print("[unequip] %s failed — pockets full or slot empty" % slot_id)
		_refresh_all()


func _try_place_carried_into_grid(dest_grid: String) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0 or _carried == null:
		return
	var src = _carried
	var src_grid: String = src.get("grid_ref", "")
	var src_idx: int = int(src.get("item_idx", -1))
	if src_grid == "" or src_idx < 0:
		return
	# Same-grid empty-cell click: bridge has no cell-precise placement
	# (`grant_or_merge` first-fits), so a within-grid empty-cell drop is
	# a no-op cancel — the item stays where it is.
	if src_grid == dest_grid:
		_carried = null
		_update_carry_badge()
		_refresh_inventory_page()
		return
	# Cross-grid move: pockets ↔ equipped inner grid, or two inner
	# grids. First-fit on dest; sim restores to source on failure.
	var ok: bool = sim.move_between_grids(sid, src_grid, src_idx, dest_grid)
	if not ok:
		print("[inv] move %s[%d] → %s failed" % [src_grid, src_idx, dest_grid])
	_carried = null
	_update_carry_badge()
	_refresh_inventory_page()


func _read_item_rotation(grid_ref: String, idx: int) -> String:
	var view := _player_view()
	if grid_ref == "pockets":
		var items: Array = view.get("inventory", [])
		if idx >= 0 and idx < items.size():
			var it: Dictionary = items[idx]
			return it.get("rotation", "0")
	elif grid_ref.begins_with("equipped:"):
		var slot_id := grid_ref.substr(9)
		var eq: Dictionary = view.get("equipment", {})
		var ei_var = eq.get(slot_id, null)
		if ei_var is Dictionary:
			var ig_var = ei_var.get("inner_grid", null)
			if ig_var is Dictionary:
				var inner_items: Array = ig_var.get("items", [])
				if idx >= 0 and idx < inner_items.size():
					var it: Dictionary = inner_items[idx]
					return it.get("rotation", "0")
	return "0"


func _slot_accepts_carried(slot: Dictionary) -> bool:
	if _carried == null:
		return false
	var accepts: Array = slot.get("accepts", [])
	# Look up the carried item's category.
	var view := _player_view()
	var category: String = ""
	var src_grid: String = _carried.get("grid_ref", "")
	var src_idx: int = int(_carried.get("item_idx", -1))
	if src_grid == "pockets":
		var items: Array = view.get("inventory", [])
		if src_idx >= 0 and src_idx < items.size():
			category = items[src_idx].get("category", "")
	elif src_grid.begins_with("equipped:"):
		var slot_id := src_grid.substr(9)
		var eq: Dictionary = view.get("equipment", {})
		var ei = eq.get(slot_id, null)
		if ei is Dictionary:
			var ig = ei.get("inner_grid", null)
			if ig is Dictionary:
				var inner_items: Array = ig.get("items", [])
				if src_idx >= 0 and src_idx < inner_items.size():
					category = inner_items[src_idx].get("category", "")
	return category != "" and accepts.has(category)


func _update_carry_badge() -> void:
	if _carried == null:
		_carried_badge.visible = false
		return
	# Build label from carried item name + rotation indicator.
	var view := _player_view()
	var name: String = "?"
	var src_grid: String = _carried.get("grid_ref", "")
	var src_idx: int = int(_carried.get("item_idx", -1))
	if src_grid == "pockets":
		var items: Array = view.get("inventory", [])
		if src_idx >= 0 and src_idx < items.size():
			name = items[src_idx].get("name", "?")
	elif src_grid.begins_with("equipped:"):
		var slot_id := src_grid.substr(9)
		var eq: Dictionary = view.get("equipment", {})
		var ei = eq.get(slot_id, null)
		if ei is Dictionary:
			var ig = ei.get("inner_grid", null)
			if ig is Dictionary:
				var inner_items: Array = ig.get("items", [])
				if src_idx >= 0 and src_idx < inner_items.size():
					name = inner_items[src_idx].get("name", "?")
	var rot: String = _carried.get("rotation", "0")
	_carried_label.text = "◊ %s%s\n[X] drop  [R] rotate  [Esc] cancel" % [
		name, "  ↻" if rot == "90" else "",
	]
	_carried_badge.visible = true


func _process(_dt: float) -> void:
	if _carried_badge.visible:
		var mp := _root.get_local_mouse_position()
		_carried_badge.position = mp + Vector2(18, 18)
	# (Removed tick-driven auto-refresh. The constant rebuild of
	# grid children was interfering with click input: buttons would
	# be `queue_free`'d and recreated between frames at the same
	# screen position the user was clicking on, and the carry-flow
	# clicks weren't firing reliably. Worker-mode mutations have a
	# ~50 ms latency before the next `SimView` shows the change —
	# we accept that lag and trigger refreshes explicitly from
	# each mutation site instead. A follow-up commit will hook a
	# `SimHost::view_updated` signal that the panel can subscribe
	# to for one-shot refresh after each tick, which gives the
	# same behavior without the per-frame teardown.)


# -------- Crafting tab (Slice B, minimal changes) --------

func _build_crafting_page() -> Control:
	var page := MarginContainer.new()
	page.add_theme_constant_override("margin_left", 24)
	page.add_theme_constant_override("margin_right", 24)
	page.add_theme_constant_override("margin_top", 18)
	page.add_theme_constant_override("margin_bottom", 18)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	page.add_child(v)

	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 6)
	v.add_child(filters)
	var spec_tags: PackedStringArray = [
		"all", "general", "gunsmith", "armor_repair", "weapon_repair", "drug_making", "shards",
	]
	var spec_labels: Dictionary = {
		"all": "ALL",
		"general": "GENERAL",
		"gunsmith": "GUNSMITH",
		"armor_repair": "ARMOR",
		"weapon_repair": "WEAPON RPR",
		"drug_making": "DRUG",
		"shards": "SHARD",
	}
	for tag in spec_tags:
		var btn := NSWidgets.button(spec_labels[tag], NSWidgets.Variant.GHOST)
		btn.pressed.connect(_set_recipe_filter.bind(tag))
		filters.add_child(btn)
		_recipe_filter_buttons[tag] = btn
	_paint_recipe_filter_buttons()

	var craftable_btn := NSWidgets.button("CRAFTABLE NOW", NSWidgets.Variant.GHOST)
	craftable_btn.toggle_mode = true
	craftable_btn.toggled.connect(func(on: bool) -> void:
		_craftable_only = on
		_refresh_recipes()
	)
	filters.add_child(craftable_btn)

	v.add_child(NSWidgets.hairline())

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 18)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(split)

	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(440, 0)
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(list_scroll)

	_recipe_list = VBoxContainer.new()
	_recipe_list.add_theme_constant_override("separation", 4)
	_recipe_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_recipe_list)

	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(detail_scroll)

	_detail_slot = VBoxContainer.new()
	_detail_slot.add_theme_constant_override("separation", 12)
	_detail_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(_detail_slot)

	v.add_child(NSWidgets.hairline())
	var queue_label := NSWidgets.eyebrow("◇ ACTIVE QUEUE")
	v.add_child(queue_label)
	_queue_strip = VBoxContainer.new()
	_queue_strip.add_theme_constant_override("separation", 4)
	v.add_child(_queue_strip)

	return page


func _set_recipe_filter(tag: String) -> void:
	_recipe_filter = tag
	_paint_recipe_filter_buttons()
	_refresh_recipes()


func _paint_recipe_filter_buttons() -> void:
	for tag in _recipe_filter_buttons.keys():
		var btn: Button = _recipe_filter_buttons[tag]
		btn.disabled = (tag == _recipe_filter)


func _reload_recipe_catalog() -> void:
	var sim := _sim()
	if sim == null:
		_last_recipe_catalog = []
		return
	_last_recipe_catalog = sim.recipe_catalog()


func _reload_slot_catalog() -> void:
	var sim := _sim()
	if sim == null:
		_last_slot_catalog = []
		return
	_last_slot_catalog = sim.equipment_slot_catalog()


## Phase 2C: cache `SimHost.item_catalog()` keyed by id so tooltips
## resolve weight / stack_size in O(1). The catalog is stable for
## the session (TOML-driven, loaded once at sim init) so we can
## fetch it once on open and reuse the rest of the session. The
## dict is shared by reference into every drop-target card via
## that script's `item_catalog` export at construction time.
func _reload_item_catalog() -> void:
	var sim := _sim()
	if sim == null:
		_item_catalog_by_id = {}
		return
	var catalog: Array = sim.item_catalog()
	var by_id: Dictionary = {}
	for def in catalog:
		if def is Dictionary:
			by_id[String(def.get("id", ""))] = def
	_item_catalog_by_id = by_id


func _refresh_recipes() -> void:
	for c in _recipe_list.get_children():
		c.queue_free()
	if _last_recipe_catalog.is_empty():
		return
	var sid := _local_sid()
	# Bulk craftability check via `can_craft_many` — one bridge call
	# returns reports for every visible recipe instead of N per-recipe
	# calls. The per-recipe path goes through `worker.inspect` in
	# worker mode (one tick of latency each); batching collapses the
	# whole refresh into a single inspect round-trip, which is the
	# difference between ~15 FPS and the renderer's native frame rate
	# when the recipe browser is open.
	var ids := PackedStringArray()
	var visible_recipes: Array = []
	for recipe_var in _last_recipe_catalog:
		var recipe: Dictionary = recipe_var
		if not _recipe_passes_filter(recipe):
			continue
		visible_recipes.append(recipe)
		ids.push_back(String(recipe.get("id", "")))
	var reports: Dictionary = {}
	if sid != 0 and not ids.is_empty():
		var sim := _sim()
		if sim != null and sim.has_method("can_craft_many"):
			reports = sim.can_craft_many(sid, ids)
		else:
			# Fall back to per-recipe calls if running against an old
			# bridge build that doesn't have `can_craft_many` yet.
			for r in visible_recipes:
				reports[r.get("id", "")] = _can_craft(r.get("id", ""))
	for recipe in visible_recipes:
		var report: Dictionary = reports.get(recipe.get("id", ""), {})
		if _craftable_only and not bool(report.get("ok", false)):
			continue
		_recipe_list.add_child(_build_recipe_row(recipe, report))
	_refresh_detail()


func _recipe_passes_filter(recipe: Dictionary) -> bool:
	if _recipe_filter == "all":
		return true
	var kit_var = recipe.get("required_kit", null)
	if kit_var == null or not (kit_var is Dictionary):
		return false
	var kit: Dictionary = kit_var
	return kit.get("specialty", "") == _recipe_filter


func _build_recipe_row(recipe: Dictionary, report: Dictionary) -> Control:
	var ok: bool = bool(report.get("ok", false))
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR if ok else NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	pc.add_child(v)
	v.add_child(NSWidgets.label_mono(recipe.get("name", "?"), 13, NSColors.PAGE_WHITE))
	v.add_child(NSWidgets.label_mono(
		"%s · %ds" % [recipe.get("id", ""), int(recipe.get("time_ticks", 0)) / 20],
		10,
		NSColors.FG_3,
	))
	v.add_child(NSWidgets.label_mono(
		_requires_line(recipe, report),
		11,
		NSColors.VLF_PHOSPHOR if ok else NSColors.STAMP_RED,
	))

	var btn := Button.new()
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(func() -> void:
		_selected_recipe = recipe.get("id", "")
		_refresh_detail()
	)
	pc.add_child(btn)
	return pc


func _requires_line(recipe: Dictionary, report: Dictionary) -> String:
	if report.is_empty():
		return "select character first"
	if bool(report.get("ok", false)):
		return "READY"
	var bits: Array = []
	for input_var in report.get("inputs", []):
		var input: Dictionary = input_var
		var have: int = int(input.get("have", 0))
		var need: int = int(input.get("need", 0))
		if have < need:
			bits.append("%s %d/%d" % [input.get("id", "?"), have, need])
	var missing_tool: String = report.get("missing_tool", "")
	if missing_tool != "":
		bits.append("tool: %s" % missing_tool)
	var missing_kit_var = report.get("missing_kit", null)
	if missing_kit_var != null and missing_kit_var is Dictionary:
		var kit: Dictionary = missing_kit_var
		bits.append("kit: %s+ %s" % [kit.get("min_tier", "?"), kit.get("specialty", "?")])
	var wrong_station: String = report.get("wrong_station", "")
	if wrong_station != "":
		bits.append("at: %s" % wrong_station)
	if bits.is_empty():
		return "?"
	return "needs " + ", ".join(bits)


func _refresh_detail() -> void:
	for c in _detail_slot.get_children():
		c.queue_free()
	if _selected_recipe == "":
		_detail_slot.add_child(NSWidgets.label_mono(
			"select a recipe", 12, NSColors.FG_3,
		))
		return
	var recipe: Dictionary = _find_recipe(_selected_recipe)
	if recipe.is_empty():
		_selected_recipe = ""
		return
	_detail_slot.add_child(NSWidgets.stencil(recipe.get("name", "?"), 18))

	var report: Dictionary = _can_craft(_selected_recipe)
	_detail_slot.add_child(NSWidgets.label_mono(
		_requires_line(recipe, report),
		12,
		NSColors.VLF_PHOSPHOR if bool(report.get("ok", false)) else NSColors.STAMP_RED,
	))

	var inputs: Array = recipe.get("inputs", [])
	if not inputs.is_empty():
		_detail_slot.add_child(NSWidgets.eyebrow("◇ INPUTS"))
		for stack_var in inputs:
			var stack: Dictionary = stack_var
			_detail_slot.add_child(NSWidgets.label_mono(
				"  %s × %d" % [stack.get("id", "?"), int(stack.get("count", 0))],
				12,
				NSColors.PAGE_WHITE,
			))
	var outputs: Array = recipe.get("outputs", [])
	if not outputs.is_empty():
		_detail_slot.add_child(NSWidgets.eyebrow("◇ OUTPUTS"))
		for stack_var in outputs:
			var stack: Dictionary = stack_var
			_detail_slot.add_child(NSWidgets.label_mono(
				"  %s × %d" % [stack.get("id", "?"), int(stack.get("count", 0))],
				12,
				NSColors.PAGE_WHITE,
			))
	_detail_slot.add_child(NSWidgets.label_mono(
		"time: %ds per unit" % (int(recipe.get("time_ticks", 0)) / 20),
		11,
		NSColors.FG_3,
	))

	var ctl_row := HBoxContainer.new()
	ctl_row.add_theme_constant_override("separation", 8)
	_detail_slot.add_child(ctl_row)
	ctl_row.add_child(NSWidgets.label_mono("queue ×", 12, NSColors.FG_2))
	_craft_count_spin = SpinBox.new()
	_craft_count_spin.min_value = 1
	_craft_count_spin.max_value = 99
	_craft_count_spin.value = 1
	_craft_count_spin.custom_minimum_size = Vector2(80, 0)
	ctl_row.add_child(_craft_count_spin)
	var queue_btn := NSWidgets.button(
		"Queue Craft",
		NSWidgets.Variant.PRIMARY if bool(report.get("ok", false)) else NSWidgets.Variant.GHOST,
	)
	queue_btn.disabled = not bool(report.get("ok", false))
	queue_btn.pressed.connect(_on_queue_pressed)
	ctl_row.add_child(queue_btn)


func _on_queue_pressed() -> void:
	var sim := _sim()
	if sim == null or _selected_recipe == "":
		return
	var sid := _local_sid()
	if sid == 0:
		return
	var count: int = int(_craft_count_spin.value)
	var job_id: int = sim.queue_craft(sid, _selected_recipe, count)
	if job_id < 0:
		print("[craft] queue_craft failed for %s ×%d" % [_selected_recipe, count])
	else:
		print("[craft] queued job=%d %s ×%d" % [job_id, _selected_recipe, count])
	_refresh_all()


func _refresh_queue() -> void:
	for c in _queue_strip.get_children():
		c.queue_free()
	var view := _player_view()
	var queue: Array = view.get("crafting_queue", [])
	if queue.is_empty():
		_queue_strip.add_child(NSWidgets.label_mono(
			"  (no jobs)", 11, NSColors.FG_3,
		))
		return
	var sim := _sim()
	var now: int = 0
	if sim != null:
		now = sim.current_tick()
	for job_var in queue:
		var job: Dictionary = job_var
		_queue_strip.add_child(_build_queue_row(job, now))


func _build_queue_row(job: Dictionary, _now: int) -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	pc.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	pc.add_child(row)

	var recipe_id: String = job.get("recipe_id", "?")
	var recipe: Dictionary = _find_recipe(recipe_id)
	var name: String = recipe.get("name", recipe_id)
	row.add_child(NSWidgets.label_mono(name, 12, NSColors.PAGE_WHITE))
	var count_remaining: int = int(job.get("count_remaining", 0))
	row.add_child(NSWidgets.label_mono("×%d left" % count_remaining, 11, NSColors.FG_2))
	var time_total: int = int(recipe.get("time_ticks", 1))
	var ticks_remaining: int = int(job.get("ticks_remaining", 0))
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = float(max(time_total, 1))
	bar.value = float(max(time_total - ticks_remaining, 0))
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(220, 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(bar)
	row.add_child(NSWidgets.label_mono(
		"%.1fs" % (float(ticks_remaining) / 20.0), 11, NSColors.VLF_PHOSPHOR,
	))
	var cancel := NSWidgets.button("Cancel", NSWidgets.Variant.GHOST)
	cancel.pressed.connect(_on_cancel_pressed.bind(int(job.get("id", -1))))
	row.add_child(cancel)
	return pc


func _on_cancel_pressed(job_id: int) -> void:
	if job_id < 0:
		return
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	if sim.cancel_craft(sid, job_id):
		print("[craft] cancelled job=%d" % job_id)
	_refresh_all()


# -------- Refresh helpers --------

func _refresh_all() -> void:
	_refresh_inventory_page()
	_refresh_recipes()
	_refresh_queue()


# -------- Util --------

func _sim() -> Node:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return null
	return session.get_node_or_null("SimHost")


func _local_sid() -> int:
	var session := get_node_or_null("/root/GameSession")
	if session == null or not session.has_method("local_steam_id"):
		return 0
	return session.local_steam_id()


func _player_view() -> Dictionary:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return {}
	return sim.player_state(sid)


## Look up the item dict at `(grid_ref, idx)` in the latest player
## view. Returns an empty Dictionary if the grid or index doesn't
## exist. Used by drag-and-drop to inspect the target before
## dispatching (e.g. is the drop target a magazine?).
func _grid_item_at(grid_ref: String, idx: int) -> Dictionary:
	var view: Dictionary = _player_view()
	var items: Array
	if grid_ref == "pockets":
		items = view.get("inventory", [])
	else:
		# `equipped:<slot>` — peek at the corresponding container.
		var slot_id := grid_ref.trim_prefix("equipped:")
		var equipment: Dictionary = view.get("equipment", {})
		var eq_item = equipment.get(slot_id)
		if eq_item == null or not (eq_item is Dictionary):
			return {}
		var inner: Dictionary = eq_item.get("inner_grid", {})
		items = inner.get("items", [])
	# `_sim_idx` is the array index assigned during card decoration
	# (see `_build_grid_widget`'s `decorated["_sim_idx"] = i`). Raw
	# view items don't carry it, so look up by position directly.
	if idx >= 0 and idx < items.size():
		var entry = items[idx]
		if entry is Dictionary:
			return entry
	return {}


func _can_craft(recipe_id: String) -> Dictionary:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0 or recipe_id == "":
		return {}
	return sim.can_craft(sid, recipe_id)


func _find_recipe(recipe_id: String) -> Dictionary:
	for r_var in _last_recipe_catalog:
		var r: Dictionary = r_var
		if r.get("id", "") == recipe_id:
			return r
	return {}


func _short_name(s: String, max_len: int) -> String:
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len - 1) + "…"


## Short display tag for an ammo round id. Mirrors the table in
## `hud.gd::_short_variant_tag` so inventory badges + HUD stay
## consistent (AKS-74 AP 24/30 on the HUD, and `AP 24/30` on the
## mag sitting in pockets).
func _short_variant_tag(round_id: String) -> String:
	if round_id.is_empty():
		return ""
	if round_id.ends_with("_hp"):
		return "HP"
	if round_id.ends_with("_ap"):
		return "AP"
	if round_id.ends_with("_slug"):
		return "SLG"
	if round_id.ends_with("_flechette"):
		return "FLCH"
	if round_id.ends_with("_buckshot"):
		return "BCK"
	if round_id.begins_with("round_"):
		return "FMJ"
	return ""


## Pick the ammo id to feed into `SimHost.load_rounds_into_pocket`
## for a mag with the given `caliber` and currently-loaded `variant`
## (`""` if the mag is empty). Preference order:
##
## 1. If the mag already holds a variant, load more of the same —
##    partial-mag variant flip is rejected sim-side.
## 2. Otherwise, pick the pocket ammo stack with the most rounds
##    (so the action feels like "load whatever I've got most of").
## 3. Returns `""` if no matching-caliber ammo exists in pockets.
##
## Reads `player_state.inventory` live so it's in sync with whatever
## the grid render just drew.
func _pocket_ammo_for_load(caliber: String, current_variant: String) -> String:
	var view := _player_view()
	var items_variant: Variant = view.get("inventory", [])
	if typeof(items_variant) != TYPE_ARRAY:
		return ""
	var items := items_variant as Array
	# If the mag holds a variant already, only that round_id can
	# load (partial-variant-flip rejection sim-side). Confirm the
	# variant is actually present in pockets.
	if not current_variant.is_empty():
		for it in items:
			if typeof(it) != TYPE_DICTIONARY:
				continue
			var d := it as Dictionary
			if String(d.get("category", "")) != "ammo":
				continue
			if String(d.get("id", "")) == current_variant:
				return current_variant
		return ""
	# Empty mag: pick the matching-caliber ammo with the most rounds
	# in pockets. The ammo dict doesn't carry a caliber field (that's
	# a magazine_config property), so we match by the caliber tag
	# embedded in the round id — the `items.toml` naming convention
	# is `round_<caliber_sans_dots>[_<variant>]`.
	var best_id: String = ""
	var best_count: int = -1
	for it in items:
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var d := it as Dictionary
		if String(d.get("category", "")) != "ammo":
			continue
		var round_id: String = String(d.get("id", ""))
		if not _round_matches_caliber(round_id, caliber):
			continue
		var c: int = int(d.get("count", 0))
		if c > best_count:
			best_count = c
			best_id = round_id
	return best_id


## Does the ammo `round_id` (e.g. "round_5_45x39_ap") match the
## magazine's `caliber` tag (e.g. "5.45x39")? The naming convention
## in `items.toml` is `round_<caliber>[_<variant>]`, so we check
## whether the id contains the caliber as a segment. Paranoid — if
## the caliber string is empty, bail.
func _round_matches_caliber(round_id: String, caliber: String) -> bool:
	if caliber.is_empty():
		return false
	# Replace dots with underscores to match the id form
	# ("5.45x39" → "5_45x39" in the id).
	var cal_key := caliber.replace(".", "_")
	return round_id.find("_" + cal_key) != -1 or round_id.find(cal_key) != -1


## Load-button handler: call the bridge + refresh.
func _on_load_mag_pressed(pocket_idx: int, round_id: String) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	if not sim.has_method("load_rounds_into_pocket"):
		print("[inv] load_rounds_into_pocket bridge not present")
		return
	var loaded: int = int(sim.load_rounds_into_pocket(sid, pocket_idx, round_id))
	if loaded < 0:
		print("[inv] load_rounds failed for mag @%d with %s" % [pocket_idx, round_id])
	elif loaded == 0:
		print("[inv] no rounds loaded (mag full or pockets empty)")
	else:
		print("[inv] loaded %d %s into mag @%d" % [loaded, round_id, pocket_idx])
	_refresh_all()


# -------- Phase 2B: drag-and-drop routing --------

## One handler routes every drop event from
## `inventory_drop_target.gd`. The `payload` is the source data the
## drag started with; `target` is the destination metadata. We
## branch on `(source_kind, target_kind)` and call the right sim
## bridge:
##
## - grid_card → doll_slot: `equip(sid, slot_id, src_grid, src_idx)`
## - doll_slot → grid_card / empty_cell: `unequip(sid, slot_id, dest_grid)`
## - grid_card → grid_card (same pockets): `move_slot(sid, from, to)`
## - grid_card → grid_card (different grids): `move_between_grids(...)`
## - grid_card → empty_cell: route to the right move call based on
##   whether grids match.
##
## All paths refresh the UI after — the next sim view picks up the
## new state.
## Phase 3E: container-aware drop routing.
##
## - **container → pockets / equipped / doll**: route through
##   `take_from_container` (lands in pockets). Equipped /
##   doll-slot targets are not directly supported by the bridge;
##   the user can chain: container → pockets, then pockets →
##   equipped / doll as separate drags.
## - **pockets / equipped → container**: route through
##   `put_in_container`. Doll-slot → container is similarly a
##   two-step (unequip first); rejected here so the user
##   isn't confused by a silent no-op.
## - **container → container**: only one container is open at a
##   time today, so this only fires when dragging within the
##   open container's own grid. The bridge doesn't expose a
##   reorder primitive for world-container grids yet, so we just
##   return `true` (handled) without action — the user can
##   re-arrange by chaining a take then a put.
##
## Returns `true` if the drop was a container-involved move
## (handled here, caller short-circuits). `false` lets the
## existing handlers run for plain inventory ↔ doll moves.
func _handle_container_drop(
	sim: Object,
	sid: int,
	src_kind: String,
	src_grid: String,
	src_idx: int,
	tgt_kind: String,
	tgt_grid: String,
	tgt_slot: String,
) -> bool:
	var src_is_container: bool = src_grid.begins_with("container:")
	var tgt_is_container: bool = tgt_grid.begins_with("container:")
	if not src_is_container and not tgt_is_container:
		return false

	# Source = container.
	if src_is_container:
		var cid := _container_id_from_grid_ref(src_grid)
		if cid < 0:
			return true
		# container → container (only when same id; one open at a time).
		if tgt_is_container:
			# Same-container reorder isn't a sim-supported op yet
			# — bridge has no primitive. Silent no-op so the drop
			# doesn't appear to succeed.
			return true
		# container → doll: bridge only takes into pockets; chain.
		if tgt_kind == "doll_slot":
			print("[inv-drop] container → doll: two-step via pockets — drag to pockets first, then equip")
			return true
		# container → pockets / equipped: bridge only delivers to
		# pockets. If target is an equipped inner grid, prompt the
		# user to chain via pockets.
		if tgt_grid != "pockets":
			print("[inv-drop] container → %s: two-step — drag to pockets, then move from pockets to %s" % [tgt_grid, tgt_grid])
			return true
		if not sim.has_method("take_from_container"):
			return true
		var ok: bool = sim.take_from_container(sid, cid, src_idx)
		if not ok:
			print("[inv-drop] take_from_container c=%d idx=%d failed (pockets full?)" % [cid, src_idx])
		return true

	# Target = container. (src is not a container if we get here.)
	if tgt_is_container:
		var cid := _container_id_from_grid_ref(tgt_grid)
		if cid < 0:
			return true
		if src_kind == "doll_slot":
			print("[inv-drop] doll → container: unequip into pockets first, then drag to container")
			return true
		# Source must be a grid (pockets or equipped:<slot>) — the
		# bridge's `put_in_container` accepts both.
		if not sim.has_method("put_in_container"):
			return true
		var ok: bool = sim.put_in_container(sid, cid, src_grid, src_idx)
		if not ok:
			print("[inv-drop] put_in_container c=%d src=%s[%d] failed (container full?)" % [cid, src_grid, src_idx])
		return true

	return false


func _container_id_from_grid_ref(grid_ref: String) -> int:
	if not grid_ref.begins_with("container:"):
		return -1
	var suffix: String = grid_ref.substr("container:".length())
	if not suffix.is_valid_int():
		return -1
	return suffix.to_int()


func _on_drop_received(payload: Dictionary, target: Dictionary) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	var src_kind: String = String(payload.get("source_kind", ""))
	var tgt_kind: String = String(target.get("target_kind", ""))
	var src_grid: String = String(payload.get("grid_ref", ""))
	var src_idx: int = int(payload.get("item_idx", -1))
	var src_slot: String = String(payload.get("slot_id", ""))
	var tgt_grid: String = String(target.get("grid_ref", ""))
	var tgt_idx: int = int(target.get("item_idx", -1))
	var tgt_slot: String = String(target.get("slot_id", ""))

	# Cancel out same-cell drops (defensive — the can_drop check
	# rejects these, but Godot can race on tap+drop with no movement).
	if src_kind == "grid_card" and tgt_kind == "grid_card" \
		and src_grid == tgt_grid and src_idx == tgt_idx:
		return

	# Phase 3E: route container-involved moves through the
	# `take_from_container` / `put_in_container` bridge methods
	# before the generic grid/doll handlers below, since the
	# move_between_grids primitive doesn't know about world
	# containers.
	if _handle_container_drop(sim, sid, src_kind, src_grid, src_idx, tgt_kind, tgt_grid, tgt_slot):
		_refresh_all()
		return

	if src_kind == "grid_card" and tgt_kind == "doll_slot":
		if not sim.has_method("equip"):
			return
		var ok: bool = sim.equip(sid, tgt_slot, src_grid, src_idx)
		if not ok:
			print("[inv-drop] equip %s → %s failed" % [
				payload.get("item", {}).get("name", "?"), tgt_slot,
			])
	elif src_kind == "doll_slot" and (tgt_kind == "grid_card" or tgt_kind == "empty_cell"):
		if not sim.has_method("unequip"):
			return
		# `unequip` always lands in pockets today. If the target is
		# an equipped-container grid, we'd need a two-step move; for
		# Phase 2B we route to pockets and let the user move it from
		# there. The Phase 3 loot-and-economy work will revisit the
		# multi-grid transfer story.
		var ok: bool = sim.unequip(sid, src_slot, "pockets")
		if not ok:
			print("[inv-drop] unequip %s failed (pockets full?)" % src_slot)
	elif src_kind == "grid_card" and tgt_kind == "grid_card":
		# Special case: dragging an ammo stack onto a magazine in
		# pockets routes through `load_rounds_into_pocket` instead
		# of swapping positions. The visible affordance matches what
		# the LOAD-link button does — drag-onto is the discoverable
		# alternative.
		var src_item: Dictionary = payload.get("item", {})
		var tgt_item_view: Dictionary = _grid_item_at(tgt_grid, tgt_idx)
		var src_is_ammo: bool = String(src_item.get("category", "")) == "ammo"
		var tgt_is_mag: bool = int(tgt_item_view.get("magazine_capacity", 0)) > 0
		if src_is_ammo and tgt_is_mag and src_grid == "pockets" and tgt_grid == "pockets":
			if sim.has_method("load_rounds_into_pocket"):
				var round_id: String = String(src_item.get("id", ""))
				if round_id.is_empty():
					# Source dict didn't carry the round id (older
					# view shape). Fall through to a generic swap.
					pass
				else:
					var loaded: int = int(sim.load_rounds_into_pocket(sid, tgt_idx, round_id))
					if loaded <= 0:
						print("[inv-drop] load ammo → mag: %d loaded" % loaded)
					_refresh_all()
					return
		if src_grid == tgt_grid and src_grid == "pockets":
			if not sim.has_method("move_slot"):
				return
			var ok: bool = sim.move_slot(sid, src_idx, tgt_idx)
			if not ok:
				print("[inv-drop] swap %d↔%d failed" % [src_idx, tgt_idx])
		else:
			if not sim.has_method("move_between_grids"):
				return
			var ok: bool = sim.move_between_grids(sid, src_grid, src_idx, tgt_grid)
			if not ok:
				print("[inv-drop] move %s[%d] → %s failed" % [src_grid, src_idx, tgt_grid])
	elif src_kind == "grid_card" and tgt_kind == "empty_cell":
		if src_grid == tgt_grid:
			# Reordering within the same grid: sim's `move_slot`
			# expects two occupied indices; the empty-cell coord
			# isn't directly addressable. Punt: skip and let the
			# user drop on an existing card to swap. Phase 2F
			# polish can teach the bridge to accept an empty
			# (x, y) target.
			return
		if not sim.has_method("move_between_grids"):
			return
		var ok: bool = sim.move_between_grids(sid, src_grid, src_idx, tgt_grid)
		if not ok:
			print("[inv-drop] move %s[%d] → %s failed" % [src_grid, src_idx, tgt_grid])
	_refresh_all()


## Routes the `context_menu_requested` signal off a grid card
## (emitted by `inventory_drop_target.gd` on right-click) into the
## existing Phase 2A popup builder.
func _on_card_context_menu_requested(
	grid_ref: String, idx: int, _slot_id: String, item: Dictionary, screen_pos: Vector2
) -> void:
	_show_item_context_menu(grid_ref, idx, item, screen_pos)


## Same as above but for doll-slot cards. Needs the original `slot`
## dict (passed via `bind` from `_build_doll_cell`) since the
## context-menu builder reads slot metadata.
func _on_doll_context_menu_requested(
	_grid_ref: String, _idx: int, _slot_id: String, item: Dictionary, screen_pos: Vector2, slot: Dictionary
) -> void:
	_show_doll_slot_context_menu(slot, item, screen_pos)


# -------- Phase 2A: right-click context menu --------

## Menu action ids. PopupMenu wants stable integers for `id_pressed`;
## these centralize the assignment so the handler can dispatch
## cleanly. Values are arbitrary but stable across this script.
const _CTX_USE: int = 100
const _CTX_EQUIP: int = 101
const _CTX_UNEQUIP: int = 102
const _CTX_DROP: int = 103
const _CTX_EXAMINE: int = 104


## Build + popup a context menu for a regular grid item card.
## `screen_pos` is where the click landed (we offset slightly so
## the cursor doesn't cover the first entry). Menu entries depend
## on the item's category — consumables get Use, gear gets Equip,
## everyone gets Drop / Examine.
func _show_item_context_menu(
	grid_ref: String, idx: int, item: Dictionary, screen_pos: Vector2
) -> void:
	var menu := PopupMenu.new()
	menu.add_theme_font_override("font", NSFonts.MONO)
	menu.add_theme_font_size_override("font_size", 13)
	var category: String = String(item.get("category", "misc"))
	var name: String = String(item.get("name", "?"))
	# Title row — a disabled item so the player can read what
	# they're acting on without an extra hover step.
	menu.add_item(name)
	menu.set_item_disabled(0, true)
	menu.add_separator()
	if _is_consumable(category):
		menu.add_item("Use", _CTX_USE)
	if _is_equippable(category):
		menu.add_item("Equip", _CTX_EQUIP)
	# Drop only meaningful for pocket items (equipped items must
	# unequip into pockets first); the existing sim path mirrors
	# this constraint.
	if grid_ref == "pockets":
		menu.add_item("Drop", _CTX_DROP)
	menu.add_separator()
	menu.add_item("Examine", _CTX_EXAMINE)
	menu.id_pressed.connect(
		_on_item_context_menu_pressed.bind(grid_ref, idx, item)
	)
	# Free when dismissed so we don't leak PopupMenus across refreshes.
	menu.close_requested.connect(menu.queue_free)
	add_child(menu)
	menu.popup(Rect2i(int(screen_pos.x), int(screen_pos.y), 1, 1))


## Build + popup a context menu for an equipped (doll-slot) item.
## Limited to Unequip / Examine; carrying the equipped item into
## pockets is the equip path's opposite, and the existing sim
## `unequip` covers it.
func _show_doll_slot_context_menu(
	slot: Dictionary, item: Dictionary, screen_pos: Vector2
) -> void:
	var menu := PopupMenu.new()
	menu.add_theme_font_override("font", NSFonts.MONO)
	menu.add_theme_font_size_override("font_size", 13)
	var name: String = String(item.get("name", "?"))
	menu.add_item(name)
	menu.set_item_disabled(0, true)
	menu.add_separator()
	menu.add_item("Unequip", _CTX_UNEQUIP)
	menu.add_separator()
	menu.add_item("Examine", _CTX_EXAMINE)
	menu.id_pressed.connect(
		_on_doll_slot_context_menu_pressed.bind(slot, item)
	)
	menu.close_requested.connect(menu.queue_free)
	add_child(menu)
	menu.popup(Rect2i(int(screen_pos.x), int(screen_pos.y), 1, 1))


func _on_item_context_menu_pressed(
	id: int, grid_ref: String, idx: int, item: Dictionary
) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	match id:
		_CTX_USE:
			# Empty body part — sim picks default for non-wound
			# consumables. Wound treatment (bandage / tourniquet)
			# still needs a body-part picker; that lands with the
			# full healing-flow rework.
			if not sim.has_method("consume_slot"):
				print("[inv-ctx] consume_slot unavailable")
				return
			if grid_ref != "pockets":
				print("[inv-ctx] Use: only pocket items can be consumed via context menu")
				return
			var ok: bool = sim.consume_slot(sid, idx, "")
			if not ok:
				print("[inv-ctx] consume failed for slot %d" % idx)
			_refresh_all()
		_CTX_EQUIP:
			if grid_ref != "pockets":
				print("[inv-ctx] Equip from non-pockets grids not supported yet")
				return
			var slot_id := _first_free_slot_for_category(String(item.get("category", "")))
			if slot_id.is_empty():
				print("[inv-ctx] no compatible slot for %s" % item.get("name", "?"))
				return
			if not sim.has_method("equip"):
				return
			var ok: bool = sim.equip(sid, slot_id, "pockets", idx)
			if not ok:
				print("[inv-ctx] equip %s → %s failed" % [item.get("name", "?"), slot_id])
			_refresh_all()
		_CTX_DROP:
			if grid_ref != "pockets":
				return
			if not sim.has_method("drop_slot"):
				return
			var ok: bool = sim.drop_slot(sid, idx)
			if not ok:
				print("[inv-ctx] drop failed for slot %d" % idx)
			_refresh_all()
		_CTX_EXAMINE:
			# Placeholder until Phase 2C tooltips land — print to
			# console so the menu is functional end-to-end while
			# the proper detail panel is queued.
			print("[inv-ctx] examine: %s" % _format_item_examine(item))


func _on_doll_slot_context_menu_pressed(
	id: int, slot: Dictionary, item: Dictionary
) -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	match id:
		_CTX_UNEQUIP:
			if not sim.has_method("unequip"):
				return
			var slot_id: String = String(slot.get("id", ""))
			if slot_id.is_empty():
				return
			var ok: bool = sim.unequip(sid, slot_id, "pockets")
			if not ok:
				print("[inv-ctx] unequip %s failed (pockets full?)" % slot_id)
			_refresh_all()
		_CTX_EXAMINE:
			print("[inv-ctx] examine: %s" % _format_item_examine(item))


## Inspect the live equipment view and return the first
## category-compatible slot that's currently empty. Empty string if
## no compatible slot is open. Mirrors the slot-acceptance
## semantics in `equipment_slots.toml`.
func _first_free_slot_for_category(category: String) -> String:
	if not _CATEGORY_SLOT_PREFERENCE.has(category):
		return ""
	var pref: Array = _CATEGORY_SLOT_PREFERENCE[category]
	var view: Dictionary = _player_view()
	var equipment: Dictionary = view.get("equipment", {})
	for slot_id_v in pref:
		var slot_id := String(slot_id_v)
		if not equipment.has(slot_id) or equipment[slot_id] == null:
			return slot_id
	# All compatible slots full — return the first preference; sim
	# `equip` will reject if it can't displace.
	return String(pref[0])


func _is_consumable(category: String) -> bool:
	return category == "food" or category == "drink" \
		or category == "medical" or category == "drug"


func _is_equippable(category: String) -> bool:
	return _CATEGORY_SLOT_PREFERENCE.has(category)


## Cheap one-line description for the placeholder "Examine"
## action. The proper version lands with Phase 2C tooltips.
func _format_item_examine(item: Dictionary) -> String:
	var parts: Array = []
	parts.append(String(item.get("name", "?")))
	parts.append("(%s)" % String(item.get("category", "?")))
	var count: int = int(item.get("count", 1))
	if count > 1:
		parts.append("×%d" % count)
	var cap: int = int(item.get("magazine_capacity", 0))
	if cap > 0:
		parts.append("[%d/%d]" % [int(item.get("loaded_rounds", 0)), cap])
	return " ".join(parts)


# -------- Phase 2B: placeholder category icons ----------------------

## Per-category icon palette. Color is a tinted background panel,
## tag is a 3-4 char ASCII label rendered in mono. Together they
## give the player a heads-up read of the item without reading the
## name — a stack of bandages and a stack of ammo would otherwise
## look identical until Phase 2F's real-icon pass lands.
const _CATEGORY_VISUAL := {
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


func _build_category_icon(category: String) -> Control:
	var visual: Dictionary = _CATEGORY_VISUAL.get(category, _CATEGORY_VISUAL["misc"])
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
	label.add_theme_font_override("font", NSFonts.MONO_BOLD)
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(0.95, 0.97, 0.98))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	return panel
