extends CanvasLayer
## Developer control hub. Toggle with **F1**.
##
## Tabbed panel exposing every debug knob the bridge has surfaced.
## Tabs:
##   1. **Hotkeys** — read-only legend of every dev keybind.
##   2. **Player** — sliders + reset buttons for HP / stamina /
##      hunger / thirst / fatigue / radiation / toxicity / pain.
##   3. **Spawn** — NPC + container spawning at the player's
##      current position. NPC tab picks faction + count.
##   4. **Region** — fast-jump teleport to any region in the
##      sim's `all_regions()` list (replaces the cycle-by-M flow
##      for when you want to jump directly).
##   5. **Weather / Time** — set weather by name, advance time
##      in chunks, jump to a specific hour of day.
##   6. **World** — population density preset, behavior log
##      toggle, snapshot save / wipe.
##
## Reads from `/root/GameSession` for sim + local_steam_id. All
## mutations go through the existing `SimHost` `#[func]` surface
## so direct-mode + worker-mode share one code path.

@onready var _root: Panel = $Panel
@onready var _tabs: TabContainer = $Panel/Margin/TabContainer

var _enabled: bool = false


func _ready() -> void:
	layer = 60
	visible = false
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_dev_panel"):
		_enabled = not _enabled
		visible = _enabled
		if _enabled:
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			_refresh_current_tab()
		get_viewport().set_input_as_handled()
		return
	if not _enabled:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_enabled = false
		visible = false
		get_viewport().set_input_as_handled()


func _sim() -> Node:
	var session := get_node_or_null("/root/GameSession")
	return session.get_node_or_null("SimHost") if session else null


func _local_sid() -> int:
	var session := get_node_or_null("/root/GameSession")
	if session == null or not session.has_method("local_steam_id"):
		return 0
	return int(session.local_steam_id())


func _local_player_pos() -> Vector3:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return Vector3.ZERO
	var p: Node = session.get("_local_player") if "_local_player" in session else null
	if p == null:
		return Vector3.ZERO
	return (p as Node3D).global_position


func _current_region_id() -> String:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return ""
	if "_current_map_id" in session:
		return String(session.get("_current_map_id"))
	return ""


func _build() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_offset = Vector2(0, 4)
	_root.add_theme_stylebox_override("panel", sb)

	_tabs.add_child(_build_hotkeys_tab())
	_tabs.add_child(_build_player_tab())
	_tabs.add_child(_build_spawn_tab())
	_tabs.add_child(_build_region_tab())
	_tabs.add_child(_build_weather_time_tab())
	_tabs.add_child(_build_world_tab())
	_tabs.tab_changed.connect(_on_tab_changed)


func _on_tab_changed(_idx: int) -> void:
	_refresh_current_tab()


func _refresh_current_tab() -> void:
	# Refresh per-tab by name match. Each tab is a MarginContainer
	# child of the TabContainer; we look up which tab is current
	# and call the matching `_refresh_*` method on self. Keeps all
	# state + refresh logic colocated on this script rather than
	# scattering scripts across each tab's root node.
	var current: Control = _tabs.get_current_tab_control()
	if current == null:
		return
	match current.name:
		"Player":
			_refresh_player()
		"Spawn":
			_refresh_spawn()
		"Region":
			_refresh_region()
		"Weather/Time":
			_refresh_weather_time()
		"World":
			_refresh_world()
		# Hotkeys tab is static — no refresh needed.
		_:
			pass


# -------------------- Hotkeys tab --------------------

func _build_hotkeys_tab() -> Control:
	var page := MarginContainer.new()
	page.name = "Hotkeys"
	page.add_theme_constant_override("margin_left", 16)
	page.add_theme_constant_override("margin_right", 16)
	page.add_theme_constant_override("margin_top", 12)
	page.add_theme_constant_override("margin_bottom", 12)

	var scroll := ScrollContainer.new()
	scroll.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	scroll.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	page.add_child(scroll)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	scroll.add_child(col)

	var sections: Array = [
		["Dev panel & overlays", [
			["F1", "Toggle this dev panel"],
			["`", "Toggle debug stats overlay"],
			["Tab", "Toggle NPC labels (faction / HP / goal)"],
			["F9", "Toggle NPC behavior tracing log"],
		]],
		["Map & world", [
			["M", "Cycle to next region"],
			["F10", "Cycle population density preset"],
			["F11", "Cycle weather"],
			["F12", "Advance time +1 hour"],
			["F2", "Cycle near-workbench tier (debug)"],
			["F4", "Toggle near-campfire flag (debug)"],
			["Ctrl+S", "Save snapshot now"],
			["Ctrl+Shift+R", "Wipe save + restart sim"],
		]],
		["Inventory & crafting", [
			["I", "Toggle inventory + crafting panel"],
			["G", "Toggle debug item-grant panel"],
			["P", "Toggle PDA"],
			["1-4", "Hotbar slot consume"],
			["H", "Consume first inventory slot"],
			["R (held)", "Rotate held item"],
			["X (held)", "Drop held item"],
		]],
		["Combat & survival", [
			["F", "Interact / pick up"],
			["B", "Bandage torso (debug shortcut)"],
			["T", "Tourniquet torso (debug shortcut)"],
			["R (weapon)", "Reload current weapon"],
			["E / Q", "Cycle weapon next / previous"],
		]],
		["Movement", [
			["W / A / S / D", "Walk forward / strafe"],
			["Mouse", "Look"],
			["\\", "Toggle noclip (when in-game)"],
		]],
	]

	for section_var in sections:
		var section: Array = section_var
		var header := Label.new()
		header.text = String(section[0])
		header.add_theme_font_override("font", NSFonts.MONO_BOLD)
		header.add_theme_font_size_override("font_size", 13)
		header.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
		col.add_child(header)
		var rows: Array = section[1]
		for row_var in rows:
			var row: Array = row_var
			var line := HBoxContainer.new()
			line.add_theme_constant_override("separation", 14)
			var key := Label.new()
			key.text = String(row[0])
			key.add_theme_font_override("font", NSFonts.MONO)
			key.add_theme_font_size_override("font_size", 12)
			key.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
			key.custom_minimum_size = Vector2(140, 0)
			line.add_child(key)
			var desc := Label.new()
			desc.text = String(row[1])
			desc.add_theme_font_override("font", NSFonts.MONO)
			desc.add_theme_font_size_override("font_size", 12)
			desc.add_theme_color_override("font_color", NSColors.FG_2)
			line.add_child(desc)
			col.add_child(line)
		col.add_child(_spacer(10))

	return page


# -------------------- Player tab --------------------

var _player_label: Label

func _build_player_tab() -> Control:
	var page := MarginContainer.new()
	page.name = "Player"
	page.add_theme_constant_override("margin_left", 16)
	page.add_theme_constant_override("margin_right", 16)
	page.add_theme_constant_override("margin_top", 12)
	page.add_theme_constant_override("margin_bottom", 12)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	page.add_child(col)

	_player_label = Label.new()
	_player_label.add_theme_font_override("font", NSFonts.MONO)
	_player_label.add_theme_font_size_override("font_size", 12)
	_player_label.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	col.add_child(_player_label)

	col.add_child(_hr())

	col.add_child(_row_two_btns(
		"HP", "heal full", _action_heal_full, "kill", _action_kill,
	))
	col.add_child(_row_two_btns(
		"Stamina", "max", _action_stam_full, "drain", _action_stam_drain,
	))
	col.add_child(_row_set_stat("Hunger", "hunger"))
	col.add_child(_row_set_stat("Thirst", "thirst"))
	col.add_child(_row_set_stat("Fatigue", "fatigue"))
	col.add_child(_row_two_btns(
		"Radiation", "clear", _action_rad_clear, "+25", _action_rad_bump,
	))
	col.add_child(_row_two_btns(
		"Toxicity", "clear", _action_tox_clear, "+25", _action_tox_bump,
	))
	col.add_child(_row_two_btns(
		"Wounds", "clear all", _action_clear_wounds, "infect torso", _action_infect_torso,
	))

	return page


func _refresh_player() -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		_player_label.text = "(no player)"
		return
	var view: Dictionary = sim.player_state(sid)
	if view.is_empty():
		_player_label.text = "(player not yet in view)"
		return
	var hp: float = view.get("health", 0.0)
	var max_hp: float = view.get("max_health", 1.0)
	var st: float = view.get("stamina", 0.0)
	var max_st: float = view.get("max_stamina", 1.0)
	var s: Dictionary = view.get("survival", {})
	_player_label.text = "HP %d/%d  Stam %d/%d  Hunger %d  Thirst %d  Fatigue %d  Rad %d  Tox %d  Pain %d" % [
		int(hp), int(max_hp), int(st), int(max_st),
		int(s.get("hunger", 0)), int(s.get("thirst", 0)), int(s.get("fatigue", 0)),
		int(view.get("radiation", 0.0)),
		int(view.get("toxicity", 0.0)),
		int(view.get("pain", 0.0)),
	]


func _action_heal_full() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("heal_player"):
		sim.heal_player(_local_sid(), 9999.0)


func _action_kill() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("damage_player"):
		sim.damage_player(_local_sid(), 9999.0)


func _action_stam_full() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_player_stamina"):
		sim.set_player_stamina(_local_sid(), 100.0)


func _action_stam_drain() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_player_stamina"):
		sim.set_player_stamina(_local_sid(), 0.0)


func _action_rad_clear() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_radiation"):
		sim.set_radiation(_local_sid(), 0.0)


func _action_rad_bump() -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	var view: Dictionary = sim.player_state(sid)
	var cur: float = view.get("radiation", 0.0)
	if sim.has_method("set_radiation"):
		sim.set_radiation(sid, min(100.0, cur + 25.0))


func _action_tox_clear() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_toxicity"):
		sim.set_toxicity(_local_sid(), 0.0)


func _action_tox_bump() -> void:
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	var view: Dictionary = sim.player_state(sid)
	var cur: float = view.get("toxicity", 0.0)
	if sim.has_method("set_toxicity"):
		sim.set_toxicity(sid, min(100.0, cur + 25.0))


func _action_clear_wounds() -> void:
	# No bulk-clear bridge call yet — apply each treatment in turn.
	var sim := _sim()
	var sid := _local_sid()
	if sim == null or sid == 0:
		return
	for part in ["head", "torso", "left_arm", "right_arm", "left_leg", "right_leg"]:
		if sim.has_method("apply_stitch"):
			sim.apply_stitch(sid, part)
		if sim.has_method("apply_antibiotics"):
			sim.apply_antibiotics(sid)


func _action_infect_torso() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("damage_part"):
		# Damage forces a wound; with no antibiotic the natural
		# tick path infects it. Quick way to get to the "infected
		# wound" state for triage testing.
		sim.damage_part(_local_sid(), "torso", 25.0)


# -------------------- Spawn tab --------------------

var _spawn_faction_dropdown: OptionButton
var _spawn_count_spin: SpinBox
var _spawn_status_label: Label

func _build_spawn_tab() -> Control:
	var page := MarginContainer.new()
	page.name = "Spawn"
	page.add_theme_constant_override("margin_left", 16)
	page.add_theme_constant_override("margin_right", 16)
	page.add_theme_constant_override("margin_top", 12)
	page.add_theme_constant_override("margin_bottom", 12)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	page.add_child(col)

	var note := Label.new()
	note.text = "Spawn at player position; effects show up next tick (≤ 50 ms)."
	note.add_theme_font_override("font", NSFonts.MONO)
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", NSColors.FG_3)
	col.add_child(note)

	col.add_child(_hr())

	# NPC spawn row.
	var npc_row := HBoxContainer.new()
	npc_row.add_theme_constant_override("separation", 8)
	npc_row.add_child(_label_mono("NPC faction:"))
	_spawn_faction_dropdown = OptionButton.new()
	_spawn_faction_dropdown.custom_minimum_size = Vector2(160, 0)
	npc_row.add_child(_spawn_faction_dropdown)
	npc_row.add_child(_label_mono("count:"))
	_spawn_count_spin = SpinBox.new()
	_spawn_count_spin.min_value = 1
	_spawn_count_spin.max_value = 32
	_spawn_count_spin.value = 4
	npc_row.add_child(_spawn_count_spin)
	var spawn_btn := Button.new()
	spawn_btn.text = "Bump pop"
	spawn_btn.add_theme_font_override("font", NSFonts.MONO)
	spawn_btn.pressed.connect(_on_spawn_npc_pressed)
	npc_row.add_child(spawn_btn)
	col.add_child(npc_row)

	# Container row.
	var cont_row := HBoxContainer.new()
	cont_row.add_theme_constant_override("separation", 8)
	cont_row.add_child(_label_mono("Container:"))
	var cont_pub := Button.new()
	cont_pub.text = "Spawn 4×4 public crate"
	cont_pub.add_theme_font_override("font", NSFonts.MONO)
	cont_pub.pressed.connect(_on_spawn_container_pressed.bind(true))
	cont_row.add_child(cont_pub)
	var cont_pri := Button.new()
	cont_pri.text = "Spawn 4×4 private"
	cont_pri.add_theme_font_override("font", NSFonts.MONO)
	cont_pri.pressed.connect(_on_spawn_container_pressed.bind(false))
	cont_row.add_child(cont_pri)
	col.add_child(cont_row)

	_spawn_status_label = Label.new()
	_spawn_status_label.add_theme_font_override("font", NSFonts.MONO)
	_spawn_status_label.add_theme_font_size_override("font_size", 11)
	_spawn_status_label.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR_DIM)
	col.add_child(_spawn_status_label)

	return page


func _refresh_spawn() -> void:
	# Populate faction dropdown lazily — depends on sim being up.
	if _spawn_faction_dropdown == null or _spawn_faction_dropdown.item_count > 0:
		return
	# Hardcoded set matching `factions.toml`. The bridge has no
	# `all_factions()` #[func] today; using a fixed list keeps the
	# dropdown stable across runs.
	var factions: Array = [
		"pwa", "linemen", "revere_guard", "federal", "ghost_teams",
		"gulf_compact", "registry", "aegis_pacific", "recovery_division",
		"attuned", "choir", "merged",
		"bandits", "looters", "cartel",
		"wanderers",
	]
	for f in factions:
		_spawn_faction_dropdown.add_item(String(f))


func _on_spawn_npc_pressed() -> void:
	var sim := _sim()
	var region: String = _current_region_id()
	if sim == null or region.is_empty():
		_spawn_status_label.text = "(no region)"
		return
	var faction: String = _spawn_faction_dropdown.get_item_text(_spawn_faction_dropdown.selected)
	var count: int = int(_spawn_count_spin.value)
	# Bump the population target for the chosen faction in the
	# current region. The spawn system reaches the new target over
	# the next few ticks via its normal squad-pacing path; this is
	# preferable to a direct "force-spawn here" because it respects
	# every spawn invariant (squad cohesion, faction ownership, etc).
	if sim.has_method("set_population_target"):
		# Read current target via `population_state_for_region` if it
		# exists; otherwise just set the absolute count.
		sim.set_population_target(region, faction, count)
		_spawn_status_label.text = "set %s pop target → %d in %s" % [faction, count, region]


func _on_spawn_container_pressed(is_public: bool) -> void:
	var sim := _sim()
	var region: String = _current_region_id()
	if sim == null or region.is_empty():
		_spawn_status_label.text = "(no region)"
		return
	# Place 2 m in front of the player so it's not on top of them.
	var session := get_node_or_null("/root/GameSession")
	var p: Node3D = session.get("_local_player") if session != null and "_local_player" in session else null
	if p == null:
		_spawn_status_label.text = "(no player)"
		return
	var origin: Vector3 = p.global_position
	var fwd: Vector3 = -p.global_transform.basis.z
	var spawn_pos: Vector3 = origin + fwd * 2.0
	if sim.has_method("spawn_world_container"):
		var cid: int = sim.spawn_world_container(region, spawn_pos, 4, 4, is_public)
		_spawn_status_label.text = "container id=%d (%s)" % [
			cid, "public" if is_public else "private",
		]


# -------------------- Region tab --------------------

var _region_list: VBoxContainer

func _build_region_tab() -> Control:
	var page := MarginContainer.new()
	page.name = "Region"
	page.add_theme_constant_override("margin_left", 16)
	page.add_theme_constant_override("margin_right", 16)
	page.add_theme_constant_override("margin_top", 12)
	page.add_theme_constant_override("margin_bottom", 12)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	page.add_child(col)

	col.add_child(_label_mono("Jump to region:"))

	var scroll := ScrollContainer.new()
	scroll.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	scroll.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	col.add_child(scroll)

	_region_list = VBoxContainer.new()
	_region_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_region_list)

	return page


func _refresh_region() -> void:
	for c in _region_list.get_children():
		c.queue_free()
	var sim := _sim()
	if sim == null or not sim.has_method("all_regions"):
		_region_list.add_child(_label_mono("(sim not started)"))
		return
	var regions: Array = sim.all_regions()
	if regions.is_empty():
		_region_list.add_child(_label_mono("(no regions)"))
		return
	var cur := _current_region_id()
	for r_var in regions:
		var r: String = String(r_var)
		var row := HBoxContainer.new()
		var marker := Label.new()
		marker.text = "▶" if r == cur else " "
		marker.add_theme_font_override("font", NSFonts.MONO)
		marker.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
		marker.custom_minimum_size = Vector2(20, 0)
		row.add_child(marker)
		var btn := Button.new()
		btn.text = r
		btn.add_theme_font_override("font", NSFonts.MONO)
		btn.disabled = (r == cur)
		btn.pressed.connect(_on_region_jump.bind(r))
		row.add_child(btn)
		_region_list.add_child(row)


func _on_region_jump(region_name: String) -> void:
	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_method("request_map_change"):
		session.request_map_change(region_name)


# -------------------- Weather / Time tab --------------------

var _wt_status: Label
var _weather_dropdown: OptionButton

func _build_weather_time_tab() -> Control:
	var page := MarginContainer.new()
	page.name = "Weather/Time"
	page.add_theme_constant_override("margin_left", 16)
	page.add_theme_constant_override("margin_right", 16)
	page.add_theme_constant_override("margin_top", 12)
	page.add_theme_constant_override("margin_bottom", 12)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	page.add_child(col)

	_wt_status = Label.new()
	_wt_status.add_theme_font_override("font", NSFonts.MONO)
	_wt_status.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	col.add_child(_wt_status)

	col.add_child(_hr())

	var weather_row := HBoxContainer.new()
	weather_row.add_theme_constant_override("separation", 8)
	weather_row.add_child(_label_mono("Weather:"))
	_weather_dropdown = OptionButton.new()
	_weather_dropdown.custom_minimum_size = Vector2(180, 0)
	weather_row.add_child(_weather_dropdown)
	var set_btn := Button.new()
	set_btn.text = "Set"
	set_btn.add_theme_font_override("font", NSFonts.MONO)
	set_btn.pressed.connect(_on_set_weather_pressed)
	weather_row.add_child(set_btn)
	var cycle_btn := Button.new()
	cycle_btn.text = "Cycle"
	cycle_btn.add_theme_font_override("font", NSFonts.MONO)
	cycle_btn.pressed.connect(_on_cycle_weather_pressed)
	weather_row.add_child(cycle_btn)
	col.add_child(weather_row)

	col.add_child(_hr())

	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 8)
	time_row.add_child(_label_mono("Time:"))
	for hour in [0, 6, 9, 12, 15, 18, 21]:
		var b := Button.new()
		b.text = "%02d:00" % hour
		b.add_theme_font_override("font", NSFonts.MONO)
		b.pressed.connect(_on_set_time_pressed.bind(hour))
		time_row.add_child(b)
	col.add_child(time_row)

	var adv_row := HBoxContainer.new()
	adv_row.add_theme_constant_override("separation", 8)
	adv_row.add_child(_label_mono("Advance:"))
	for hours in [1, 3, 6, 12]:
		var b := Button.new()
		b.text = "+%dh" % hours
		b.add_theme_font_override("font", NSFonts.MONO)
		b.pressed.connect(_on_advance_pressed.bind(float(hours)))
		adv_row.add_child(b)
	col.add_child(adv_row)

	return page


func _refresh_weather_time() -> void:
	var sim := _sim()
	if sim == null:
		_wt_status.text = "(no sim)"
		return
	var wt: Dictionary = sim.world_time()
	var weather: Dictionary = sim.weather_state()
	var day: int = wt.get("day", 0)
	var sec: float = wt.get("seconds_of_day", 0.0)
	var day_len: float = wt.get("day_length_seconds", 1440.0)
	var ratio: float = 86400.0 / day_len
	var in_world_seconds: float = sec * ratio
	var hours: int = int(in_world_seconds / 3600.0) % 24
	var minutes: int = int(in_world_seconds / 60.0) % 60
	_wt_status.text = "Day %d, %02d:%02d   weather: %s → %s" % [
		day, hours, minutes,
		weather.get("current", "?"),
		weather.get("next", "?"),
	]
	if _weather_dropdown != null and _weather_dropdown.item_count == 0:
		if sim.has_method("all_weather_types"):
			for w_var in sim.all_weather_types():
				_weather_dropdown.add_item(String(w_var))


func _on_set_weather_pressed() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_weather"):
		var idx := _weather_dropdown.selected
		if idx < 0:
			return
		var name: String = _weather_dropdown.get_item_text(idx)
		sim.set_weather(name)


func _on_cycle_weather_pressed() -> void:
	var sim := _sim()
	if sim != null and sim.has_method("cycle_weather"):
		sim.cycle_weather()


func _on_set_time_pressed(hour: int) -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_time_of_day"):
		sim.set_time_of_day(hour, 0)


func _on_advance_pressed(hours: float) -> void:
	var sim := _sim()
	if sim != null and sim.has_method("advance_time"):
		sim.advance_time(hours)


# -------------------- World tab --------------------

var _world_status: Label

func _build_world_tab() -> Control:
	var page := MarginContainer.new()
	page.name = "World"
	page.add_theme_constant_override("margin_left", 16)
	page.add_theme_constant_override("margin_right", 16)
	page.add_theme_constant_override("margin_top", 12)
	page.add_theme_constant_override("margin_bottom", 12)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	page.add_child(col)

	_world_status = Label.new()
	_world_status.add_theme_font_override("font", NSFonts.MONO)
	_world_status.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)
	col.add_child(_world_status)

	col.add_child(_hr())

	var pop_row := HBoxContainer.new()
	pop_row.add_theme_constant_override("separation", 8)
	pop_row.add_child(_label_mono("Population density:"))
	for label_factor in [["0×", 0.0], ["0.25×", 0.25], ["0.5×", 0.5], ["1×", 1.0], ["2×", 2.0]]:
		var b := Button.new()
		b.text = String(label_factor[0])
		b.add_theme_font_override("font", NSFonts.MONO)
		b.pressed.connect(_on_scale_pop_pressed.bind(float(label_factor[1])))
		pop_row.add_child(b)
	col.add_child(pop_row)

	var log_row := HBoxContainer.new()
	log_row.add_theme_constant_override("separation", 8)
	log_row.add_child(_label_mono("Behavior log:"))
	var on_btn := Button.new()
	on_btn.text = "ON"
	on_btn.add_theme_font_override("font", NSFonts.MONO)
	on_btn.pressed.connect(_on_behavior_log_pressed.bind(true))
	log_row.add_child(on_btn)
	var off_btn := Button.new()
	off_btn.text = "OFF"
	off_btn.add_theme_font_override("font", NSFonts.MONO)
	off_btn.pressed.connect(_on_behavior_log_pressed.bind(false))
	log_row.add_child(off_btn)
	col.add_child(log_row)

	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 8)
	save_row.add_child(_label_mono("Save:"))
	var save_now_btn := Button.new()
	save_now_btn.text = "Save now (Ctrl+S)"
	save_now_btn.add_theme_font_override("font", NSFonts.MONO)
	save_now_btn.pressed.connect(_on_save_now_pressed)
	save_row.add_child(save_now_btn)
	var wipe_btn := Button.new()
	wipe_btn.text = "Wipe + restart"
	wipe_btn.add_theme_font_override("font", NSFonts.MONO)
	wipe_btn.pressed.connect(_on_wipe_pressed)
	save_row.add_child(wipe_btn)
	col.add_child(save_row)

	return page


func _refresh_world() -> void:
	var sim := _sim()
	if sim == null:
		_world_status.text = "(no sim)"
		return
	var chron: Dictionary = sim.chronicle_summary()
	var log_on := false
	if sim.has_method("behavior_log_enabled"):
		log_on = sim.behavior_log_enabled()
	_world_status.text = "tick: %d   chronicle: ever=%d alive=%d   behavior log: %s" % [
		int(sim.current_tick()),
		int(chron.get("total_ever_spawned", 0)),
		int(chron.get("currently_alive", 0)),
		"ON" if log_on else "OFF",
	]


func _on_scale_pop_pressed(factor: float) -> void:
	var sim := _sim()
	if sim != null and sim.has_method("scale_population"):
		sim.scale_population(factor)


func _on_behavior_log_pressed(enabled: bool) -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_behavior_log"):
		sim.set_behavior_log(enabled)


func _on_save_now_pressed() -> void:
	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_method("force_save"):
		session.force_save()


func _on_wipe_pressed() -> void:
	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_method("wipe_and_reenter"):
		session.wipe_and_reenter()


# -------------------- Helpers --------------------

func _row_set_stat(label: String, stat_key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label_mono("%s:" % label))
	for v in [0, 25, 50, 75, 100]:
		var b := Button.new()
		b.text = "%d" % v
		b.add_theme_font_override("font", NSFonts.MONO)
		b.pressed.connect(_on_set_survival.bind(stat_key, float(v)))
		row.add_child(b)
	return row


func _on_set_survival(stat: String, value: float) -> void:
	var sim := _sim()
	if sim != null and sim.has_method("set_survival_stat"):
		sim.set_survival_stat(_local_sid(), stat, value)


func _row_two_btns(
	label: String,
	a_text: String, a_cb: Callable,
	b_text: String, b_cb: Callable,
) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label_mono("%s:" % label))
	var a := Button.new()
	a.text = a_text
	a.add_theme_font_override("font", NSFonts.MONO)
	a.pressed.connect(a_cb)
	row.add_child(a)
	var b := Button.new()
	b.text = b_text
	b.add_theme_font_override("font", NSFonts.MONO)
	b.pressed.connect(b_cb)
	row.add_child(b)
	return row


func _label_mono(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", NSFonts.MONO)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", NSColors.FG_2)
	return l


func _hr() -> Control:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 1)
	return sep


func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s
