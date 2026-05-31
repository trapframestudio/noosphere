extends CanvasLayer
## Top-left dev overlay. Toggle with backtick (`).
##
## Reads from the autoload GameSession (which holds SimHost +
## NetworkManager + the local player) and renders a compact text
## block: tick, in-world clock, region + faction control, FPS, local
## position. Updated every frame. Styled as a diegetic CRT readout
## (dark slate well, phosphor-green mono, hairline border) to match
## the menu/shell design system.

@onready var _panel: PanelContainer = $Panel
@onready var _margin: MarginContainer = $Panel/Margin
@onready var _label: Label = $Panel/Margin/Label

var _enabled: bool = true


func _ready() -> void:
	visible = _enabled
	_apply_theme()


func _apply_theme() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.BG_CRT
	sb.border_color = NSColors.VLF_PHOSPHOR_DIM
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_offset = Vector2(0, 2)
	_panel.add_theme_stylebox_override("panel", sb)

	_margin.add_theme_constant_override("margin_left", 14)
	_margin.add_theme_constant_override("margin_right", 14)
	_margin.add_theme_constant_override("margin_top", 12)
	_margin.add_theme_constant_override("margin_bottom", 12)

	_label.add_theme_font_override("font", NSFonts.MONO)
	_label.add_theme_font_size_override("font_size", 12)
	_label.add_theme_color_override("font_color", NSColors.VLF_PHOSPHOR)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		_enabled = not _enabled
		visible = _enabled
	elif event.is_action_pressed("wipe_sim"):
		var session := get_node_or_null("/root/GameSession")
		if session != null and session.has_method("wipe_and_reenter"):
			session.wipe_and_reenter()
	elif event.is_action_pressed("cycle_weather"):
		var session := get_node_or_null("/root/GameSession")
		var sim := session.get_node_or_null("SimHost") if session else null
		if sim != null and sim.has_method("cycle_weather"):
			var new_w: String = sim.cycle_weather()
			print("[weather] → %s" % new_w)
	elif event.is_action_pressed("advance_time"):
		var session := get_node_or_null("/root/GameSession")
		var sim := session.get_node_or_null("SimHost") if session else null
		if sim != null and sim.has_method("advance_time"):
			sim.advance_time(1.0)
			print("[time] advanced +1h")
	elif event.is_action_pressed("bandage_torso"):
		_apply_treatment("apply_bandage", "torso")
	elif event.is_action_pressed("tourniquet_torso"):
		_apply_treatment("apply_tourniquet", "torso")
	elif event.is_action_pressed("inventory_consume_first"):
		_consume_first_slot()
	elif event.is_action_pressed("toggle_near_campfire"):
		_toggle_near_campfire()
	elif event.is_action_pressed("cycle_near_workbench"):
		_cycle_near_workbench()


func _consume_first_slot() -> void:
	var session := get_node_or_null("/root/GameSession")
	var sim := session.get_node_or_null("SimHost") if session else null
	if sim == null or not sim.has_method("consume_slot"):
		return
	var sid: int = session.local_steam_id() if session.has_method("local_steam_id") else 0
	if sid == 0:
		return
	# Treatment items take a body part; default to torso for the debug key.
	var ok: bool = sim.consume_slot(sid, 0, "torso")
	if ok:
		print("[inv] consumed slot 0")
	else:
		print("[inv] consume slot 0 failed (empty or incompatible)")


func _toggle_near_campfire() -> void:
	var session := get_node_or_null("/root/GameSession")
	var sim := session.get_node_or_null("SimHost") if session else null
	if sim == null or not sim.has_method("set_near_campfire"):
		return
	var sid: int = session.local_steam_id() if session.has_method("local_steam_id") else 0
	if sid == 0:
		return
	var view: Dictionary = sim.player_state(sid)
	var cur: bool = view.get("near_campfire", false)
	sim.set_near_campfire(sid, not cur)
	print("[campfire] %s" % ("ON" if not cur else "OFF"))


# Cycle the debug NearWorkbench(tier) flag — none → basic → advanced
# → expert → none. Stand-in until scene-placed workbench entities +
# proximity drive this for real.
const _WORKBENCH_CYCLE: PackedStringArray = ["", "basic", "advanced", "expert"]


func _cycle_near_workbench() -> void:
	var session := get_node_or_null("/root/GameSession")
	var sim := session.get_node_or_null("SimHost") if session else null
	if sim == null or not sim.has_method("set_near_workbench"):
		return
	var sid: int = session.local_steam_id() if session.has_method("local_steam_id") else 0
	if sid == 0:
		return
	var view: Dictionary = sim.player_state(sid)
	var cur: String = view.get("near_workbench", "")
	var idx: int = _WORKBENCH_CYCLE.find(cur)
	if idx < 0:
		idx = 0
	var next: String = _WORKBENCH_CYCLE[(idx + 1) % _WORKBENCH_CYCLE.size()]
	sim.set_near_workbench(sid, next)
	print("[workbench] %s" % ("none" if next == "" else next))


func _apply_treatment(method: String, part: String) -> void:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim := session.get_node_or_null("SimHost")
	if sim == null or not sim.has_method(method):
		return
	var sid: int = session.local_steam_id() if session.has_method("local_steam_id") else 0
	if sid == 0:
		return
	sim.call(method, sid, part)
	print("[wound] %s on %s" % [method, part])


## Throttle the debug overlay rebuild rate. The full text build calls
## `sim.player_state(sid)` which marshals the entire inventory +
## equipment + wounds + effects into a Godot Dictionary (hundreds of
## `Variant` allocations per call). Running that at render-frame rate
## (120+ Hz) cost ~3-5 ms / frame just on Variant churn. Refreshing
## the overlay at 4 Hz is well below human perception for a debug
## readout and brings the cost down to ~1 % of what it was.
const _OVERLAY_REFRESH_HZ: float = 4.0
var _overlay_refresh_accum: float = 0.0


func _process(delta: float) -> void:
	if not _enabled:
		return
	_overlay_refresh_accum += delta
	var min_interval: float = 1.0 / _OVERLAY_REFRESH_HZ
	if _overlay_refresh_accum < min_interval:
		return
	_overlay_refresh_accum = 0.0
	_label.text = _build_text()


func _build_text() -> String:
	var lines := PackedStringArray()
	lines.append("FPS: %d" % Engine.get_frames_per_second())

	var session := get_node_or_null("/root/GameSession")
	var sim := session.get_node_or_null("SimHost") if session else null

	if sim != null:
		var tick: int = sim.current_tick()
		lines.append("tick: %d" % tick)
		var wt: Dictionary = sim.world_time()
		if not wt.is_empty():
			var day: int = wt.get("day", 0)
			var sec: float = wt.get("seconds_of_day", 0.0)
			var day_len: float = wt.get("day_length_seconds", 1440.0)
			# Map compressed dt back to in-world 24h for display.
			var ratio: float = 86400.0 / day_len
			var in_world_seconds: float = sec * ratio
			var hours: int = int(in_world_seconds / 3600.0) % 24
			var minutes: int = int(in_world_seconds / 60.0) % 60
			lines.append("time: Day %d, %02d:%02d" % [day, hours, minutes])
			var moon_name: String = wt.get("moon_phase_name", "")
			var moon_illum: float = wt.get("moon_illumination", 0.0)
			if moon_name != "":
				lines.append("moon: %s (%.0f%%)" % [moon_name, moon_illum * 100.0])
		var weather: Dictionary = sim.weather_state()
		if not weather.is_empty():
			var cur: String = weather.get("current", "?")
			var nxt: String = weather.get("next", "?")
			if cur == nxt:
				lines.append("weather: %s" % cur)
			else:
				lines.append("weather: %s → %s" % [cur, nxt])
		var chron: Dictionary = sim.chronicle_summary()
		if not chron.is_empty():
			lines.append(
				"chronicle: ever=%d alive=%d" % [
					chron.get("total_ever_spawned", 0),
					chron.get("currently_alive", 0),
				]
			)
	var gs := get_node_or_null("/root/GameSession")
	if gs != null and "POP_DENSITY_LABELS" in gs and "_pop_density_idx" in gs:
		var labels: Array = gs.POP_DENSITY_LABELS
		var idx: int = gs._pop_density_idx
		var factors: Array = gs.POP_DENSITY_FACTORS
		lines.append("density: %s (×%.2f)" % [labels[idx], factors[idx]])
	else:
		lines.append("sim: not started")

	if session != null:
		var current_map: String = session.get("_current_map_id") if "_current_map_id" in session else ""
		if current_map != "":
			lines.append("region: %s" % current_map)
			if sim != null:
				var control: Dictionary = sim.region_control(current_map)
				if not control.is_empty():
					var primary: String = control.get("primary", "?")
					var contested: Array = control.get("contested_by", [])
					var tension: float = control.get("tension", 0.0)
					lines.append("primary: %s" % primary)
					if contested.size() > 0:
						lines.append("contested by: %s" % ", ".join(contested))
					lines.append("tension: %.2f" % tension)
		var local_player: Node = session.get("_local_player") if "_local_player" in session else null
		if local_player != null:
			var p: Vector3 = local_player.global_position
			lines.append("pos: (%.0f, %.0f, %.0f)" % [p.x, p.y, p.z])

		# Triage view — wounds + meds layer per survival plan §4 + GAMMA
		# §6 depth. Polished triage scene lands with crafting UI in
		# Step 5+.
		if sim != null and session.has_method("local_steam_id"):
			var sid: int = session.local_steam_id()
			if sid != 0:
				var view: Dictionary = sim.player_state(sid)
				if not view.is_empty():
					var pain: float = view.get("pain", 0.0)
					var rad: float = view.get("radiation", 0.0)
					var tox: float = view.get("toxicity", 0.0)
					if pain > 0.0 or rad > 0.0 or tox > 0.0:
						lines.append("vitals: pain=%.0f rad=%.0f tox=%.0f" % [pain, rad, tox])
					var wounds: Array = view.get("wounds", [])
					if wounds.size() > 0:
						lines.append("")
						lines.append("wounds:")
						for w in wounds:
							var wd: Dictionary = w
							var part: String = wd.get("body_part", "?")
							var sev: int = wd.get("severity", 0)
							var treat: String = wd.get("treatment", "?")
							var infected: bool = wd.get("infected", false)
							var bleed_rate: float = 0.0
							if treat == "untreated" and wd.get("kind", "") == "bleed":
								bleed_rate = float(sev) * 0.5
							var line := "  %s  bleed sev=%d %s" % [part, sev, treat]
							if infected:
								line += " INFECTED"
							if bleed_rate > 0.0:
								line += "  [%.1f hp/s]" % bleed_rate
							lines.append(line)
					var effects: Array = view.get("active_effects", [])
					if effects.size() > 0:
						lines.append("")
						lines.append("effects:")
						for e in effects:
							var ed: Dictionary = e
							var kind: String = ed.get("kind", "?")
							var applied: int = ed.get("applied_tick", 0)
							var dur: int = ed.get("duration_ticks", 0)
							var t_now: int = sim.current_tick()
							var remaining: int = max(0, applied + dur - t_now)
							lines.append("  %s  %ds left" % [kind, int(remaining / 20)])
					var tol: Dictionary = view.get("drug_tolerance", {})
					var tol_keys: Array = tol.keys()
					if tol_keys.size() > 0:
						var tol_parts: Array = []
						for key in tol_keys:
							var v: float = tol[key]
							if v > 0.5:
								tol_parts.append("%s=%.0f" % [key, v])
						if tol_parts.size() > 0:
							lines.append("tolerance: %s" % ", ".join(tol_parts))
					var inventory: Array = view.get("inventory", [])
					var inv_weight: float = view.get("inventory_weight", 0.0)
					var near_fire: bool = view.get("near_campfire", false)
					var near_wb: String = view.get("near_workbench", "")
					var wb_tag: String = "off" if near_wb == "" else near_wb
					lines.append("")
					if inventory.is_empty():
						lines.append("inventory: (empty)  wt=%.1f  campfire=%s  bench=%s" % [
							inv_weight, "ON" if near_fire else "off", wb_tag,
						])
					else:
						lines.append("inventory: wt=%.1f  campfire=%s  bench=%s" % [
							inv_weight, "ON" if near_fire else "off", wb_tag,
						])
						for i in range(inventory.size()):
							var stack: Dictionary = inventory[i]
							lines.append("  [%d] %s ×%d (%s)" % [
								i,
								stack.get("name", "?"),
								stack.get("count", 0),
								stack.get("category", "?"),
							])
					var queue: Array = view.get("crafting_queue", [])
					if not queue.is_empty():
						lines.append("queue:")
						for job in queue:
							var jd: Dictionary = job
							lines.append("  job=%d %s ×%d (%.1fs left)" % [
								int(jd.get("id", 0)),
								jd.get("recipe_id", "?"),
								int(jd.get("count_remaining", 0)),
								float(int(jd.get("ticks_remaining", 0))) / 20.0,
							])

	lines.append("")
	lines.append("[F1] dev panel  [`] toggle this overlay")
	return "\n".join(lines)
