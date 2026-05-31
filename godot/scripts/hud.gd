extends CanvasLayer
## In-game HUD scaffold. Five labeled slots, each holding a placeholder
## so the layout and visual grammar are set — the actual widgets land
## in a dedicated HUD pass.
##
## Slot layout (mirrors the GDD's diegetic inclinations):
##
##   top-left      compass / heading              top-right     time + squall + weather
##   ┌─────────────────────────────────────────────────────────────┐
##   │                                                             │
##   │                      (live game visible)                    │
##   │                                                             │
##   └─────────────────────────────────────────────────────────────┘
##   bottom-left   vitals (HP / stam / stress)    bottom-right   radio frequency + log
##                       bottom-center   prompt / interact hint
##
## Visible only while `GameSession.in_game()` — on the launcher the
## scrim/backdrop would conflict with the main menu chrome.

const _REFRESH_HZ: float = 4.0

var _slot_top_left: Control
var _slot_top_right: Control
var _slot_bottom_left: Control
var _slot_bottom_right: Control
var _slot_bottom_center: Control
## Inner label of the bottom-right slot — the weapon readout.
## Set by `_build()`; refreshed on Player's `weapon_changed` /
## `weapon_fired` signals.
var _weapon_label: Label
## Tracks the Player node we're connected to so we can reconnect
## on respawn without leaking duplicate signal subscriptions.
var _connected_player: Node = null


func _ready() -> void:
	layer = 10  # above game world, below PDA (50) and game menu (80)
	_build()
	_refresh_visibility()

	var tick := Timer.new()
	tick.wait_time = 1.0 / _REFRESH_HZ
	tick.autostart = true
	tick.timeout.connect(_refresh_visibility)
	add_child(tick)


func _refresh_visibility() -> void:
	var session := get_node_or_null("/root/GameSession")
	var in_game: bool = session != null and session.has_method("in_game") and session.in_game()
	visible = in_game
	if in_game:
		_ensure_player_hook()


## Find the local-player node (the first CharacterBody3D in the
## `local_player` group) and connect to its weapon signals so the
## HUD refreshes when the weapon changes or fires. Idempotent: if
## we're already connected to the same node, this is a no-op.
func _ensure_player_hook() -> void:
	var players := get_tree().get_nodes_in_group("local_player")
	var player: Node = players[0] if not players.is_empty() else null
	if player == _connected_player:
		return
	_connected_player = player
	if player == null:
		return
	if player.has_signal("weapon_changed"):
		player.weapon_changed.connect(_refresh_weapon_label)
	if player.has_signal("weapon_fired"):
		player.weapon_fired.connect(_refresh_weapon_label)
	_refresh_weapon_label()


func _refresh_weapon_label() -> void:
	if _weapon_label == null or _connected_player == null:
		return
	if not _connected_player.has_method("active_weapon_slot"):
		return
	var slot_id: String = String(_connected_player.active_weapon_slot())
	var entry := _active_weapon_entry(slot_id)
	if entry.is_empty():
		_weapon_label.text = "[ NO WEAPON IN %s ]" % slot_id.to_upper()
		return
	var display_name: String = String(entry.get("name", "?"))
	if bool(entry.get("has_magazine", false)):
		var loaded: int = int(entry.get("loaded_rounds", 0))
		var cap: int = int(entry.get("magazine_capacity", 0))
		# Short-form variant tag from the loaded round id. e.g.
		# `round_5_45x39_ap` → `AP`; `round_5_45x39` (phase-2 FMJ
		# canonical) → `FMJ`; empty / unknown → no tag.
		var variant_tag: String = _short_variant_tag(String(entry.get("loaded_variant", "")))
		if variant_tag.is_empty():
			_weapon_label.text = "%s  %d/%d" % [display_name, loaded, cap]
		else:
			_weapon_label.text = "%s  %s %d/%d" % [display_name, variant_tag, loaded, cap]
	else:
		_weapon_label.text = "%s  -/-" % display_name


## Map a round ItemId to a short display tag. Hidden in this
## file because the vocabulary is specific to the items.toml
## layout (HP / AP / FMJ / slug / …) and we don't want to widen
## it into a bridge contract.
func _short_variant_tag(round_id: String) -> String:
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
	# Phase-1 canonical ids (round_9x18, round_5_45x39) are FMJ.
	if round_id.begins_with("round_"):
		return "FMJ"
	return ""


## Fetch the per-slot weapon entry out of the sim's `player_state`.
## Returns `{}` (via `is_empty()`) if the slot is empty, the item
## isn't a weapon, or the sim/session isn't available yet.
func _active_weapon_entry(slot_id: String) -> Dictionary:
	var session := get_node_or_null("/root/GameSession")
	if session == null or not session.has_method("local_steam_id"):
		return {}
	var sim := session.get_node_or_null("SimHost")
	if sim == null:
		return {}
	var sid: int = int(session.local_steam_id())
	if sid <= 0:
		return {}
	var state: Dictionary = sim.player_state(sid)
	var weapons: Variant = state.get("equipped_weapons", null)
	if typeof(weapons) != TYPE_DICTIONARY:
		return {}
	var entry: Variant = (weapons as Dictionary).get(slot_id, null)
	if typeof(entry) != TYPE_DICTIONARY:
		return {}
	return entry as Dictionary


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var pad := 24

	_slot_top_left = _make_slot("[ COMPASS ]")
	_slot_top_left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_slot_top_left.position = Vector2(pad, pad)
	root.add_child(_slot_top_left)

	_slot_top_right = _make_slot("[ CLOCK · SQUALL · WEATHER ]")
	_slot_top_right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_slot_top_right.position = Vector2(-pad - 260, pad)
	_slot_top_right.custom_minimum_size = Vector2(260, 0)
	root.add_child(_slot_top_right)

	_slot_bottom_left = _make_slot("[ HP · STAM · STRESS ]")
	_slot_bottom_left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_slot_bottom_left.position = Vector2(pad, -pad - 36)
	root.add_child(_slot_bottom_left)

	# Bottom-right: weapon readout (name + damage + range). The
	# "radio" placeholder moves to a later HUD pass. Wiring the
	# weapon readout here keeps the slot count at five.
	_slot_bottom_right = _make_slot("[ NO WEAPON ]")
	_slot_bottom_right.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_slot_bottom_right.position = Vector2(-pad - 260, -pad - 36)
	_slot_bottom_right.custom_minimum_size = Vector2(260, 0)
	root.add_child(_slot_bottom_right)
	# Remember the inner label so `_refresh_weapon_label` can update it.
	_weapon_label = _slot_bottom_right.get_child(0) as Label

	_slot_bottom_center = _make_slot("", Color(0.839, 0.804, 0.706, 0.9))
	_slot_bottom_center.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_slot_bottom_center.position = Vector2(-130, -pad - 80)
	_slot_bottom_center.custom_minimum_size = Vector2(260, 0)
	root.add_child(_slot_bottom_center)


## Slot = a fixed-width bordered panel with a mono caption. When the
## real HUD lands, each slot becomes a named child the widget scripts
## fill in via `get_node("HUD/Slot…")`.
func _make_slot(caption: String, text_color: Color = NSColors.FG_2) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.102, 0.125, 0.114, 0.6)
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", sb)

	var l := Label.new()
	l.text = caption
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", NSFonts.MONO_BOLD)
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", text_color)
	p.add_child(l)
	return p
