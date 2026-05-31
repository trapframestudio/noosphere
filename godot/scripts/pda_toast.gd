extends CanvasLayer
## PDA toast overlay — surfaces offline-tier events from `SimHost`'s
## PDA event log as one-line notifications in the bottom-right
## corner. Each toast slides in, holds for `TOAST_HOLD_SECONDS`, then
## fades out. Multiple stacked toasts animate together via the
## parent VBox layout (newest at the bottom).
##
## Phase 1F of `sim-iteration-5-12-plan.md`. Polls `SimHost`'s
## `recent_pda_events_since(seq)` accessor on a fixed interval and
## tracks the last-seen seq locally — no replication needed since
## the log is server-authoritative and a coop client gets the same
## events via the snapshot stream.
##
## Lives as a child of `session_root.tscn` at layer 40, above the
## HUD (10) and below the PDA modal (50). Visible only while
## `GameSession.in_game()` returns true (no toasts on the launcher).

## How often (Hz) to poll `SimHost` for new PDA events. The sim
## emits at most a handful of events per offline tick (2 Hz), so
## anything ≥ 4 Hz captures everything with bounded latency.
const _POLL_HZ: float = 4.0

## How long each toast holds at full opacity before starting its
## fade-out, in seconds.
const TOAST_HOLD_SECONDS: float = 5.0

## Fade-out duration in seconds (linear).
const TOAST_FADE_SECONDS: float = 0.8

## Hard cap on simultaneously rendered toasts. Older ones get
## removed immediately when a burst exceeds this.
const TOAST_MAX_VISIBLE: int = 6

var _last_seq: int = 0
var _root: Control
var _vbox: VBoxContainer
var _ready_done: bool = false


func _ready() -> void:
	layer = 40
	_build()
	# Seed the bookmark to the current high-water so events that
	# landed before the player joined don't all toast at once.
	# Deferred so SimHost has time to come up (its `start()` is
	# called from `GameSession` after our `_ready`).
	call_deferred("_initial_bookmark")

	var tick := Timer.new()
	tick.wait_time = 1.0 / _POLL_HZ
	tick.autostart = true
	tick.timeout.connect(_poll)
	add_child(tick)


func _initial_bookmark() -> void:
	var sim: Node = _sim_host()
	if sim == null:
		# Sim not ready yet; we'll just toast everything from seq 0
		# once it comes up. That's fine for a fresh world (no events
		# yet); on snapshot-load we briefly flash a few toasts.
		_ready_done = true
		return
	if sim.has_method("pda_log_high_water"):
		_last_seq = int(sim.pda_log_high_water())
	_ready_done = true


func _sim_host() -> Node:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return null
	return session.get_node_or_null("SimHost")


func _build() -> void:
	_root = Control.new()
	_root.name = "ToastRoot"
	_root.anchor_left = 1.0
	_root.anchor_top = 1.0
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	# Anchor the bottom-right of the VBox to 24 px above + left of
	# the screen edge so toasts don't crash into the HUD weapon /
	# vitals row.
	_root.offset_left = -540.0
	_root.offset_top = -300.0
	_root.offset_right = -24.0
	_root.offset_bottom = -24.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_vbox = VBoxContainer.new()
	_vbox.name = "Stack"
	_vbox.size_flags_horizontal = Control.SIZE_FILL
	_vbox.size_flags_vertical = Control.SIZE_FILL | Control.SIZE_SHRINK_END
	_vbox.alignment = BoxContainer.ALIGNMENT_END
	_vbox.add_theme_constant_override("separation", 6)
	_root.add_child(_vbox)


func _poll() -> void:
	if not _ready_done:
		return
	var session := get_node_or_null("/root/GameSession")
	var in_game: bool = (
		session != null
		and session.has_method("in_game")
		and session.in_game()
	)
	if not in_game:
		return
	var sim: Node = _sim_host()
	if sim == null or not sim.has_method("recent_pda_events_since"):
		return
	var entries: Array = sim.recent_pda_events_since(_last_seq)
	for raw in entries:
		var entry: Dictionary = raw
		_last_seq = max(_last_seq, int(entry.get("seq", 0)))
		var text := _format_event(entry)
		if text.is_empty():
			continue
		_push_toast(text)


func _format_event(entry: Dictionary) -> String:
	var kind: String = String(entry.get("kind", ""))
	var region: String = String(entry.get("region", "")).replace("_", " ").capitalize()
	match kind:
		"OfflineCombatDeath":
			var killed: String = _faction_label(String(entry.get("killed_faction", "")))
			var killer: String = _faction_label(String(entry.get("killer_faction", "")))
			if region.is_empty():
				return "%s engaged %s in the field" % [killer, killed]
			return "%s engaged %s near %s" % [killer, killed, region]
		"OfflineGunfire":
			if region.is_empty():
				return "Gunfire reported in the distance"
			return "Gunfire reported near %s" % region
		"BaseFlip":
			var new_owner: String = _faction_label(String(entry.get("new_owner", "")))
			var old_owner_raw: String = String(entry.get("old_owner", ""))
			var old_owner: String = _faction_label(old_owner_raw)
			if old_owner.is_empty():
				if region.is_empty():
					return "%s took ground" % new_owner
				return "%s took ground near %s" % [new_owner, region]
			if region.is_empty():
				return "%s pushed %s back" % [new_owner, old_owner]
			return "%s pushed %s back near %s" % [new_owner, old_owner, region]
		_:
			return ""


## Capitalize a registry faction id ("pwa" → "PWA"; "revere_guard"
## → "Revere Guard"). Cheap heuristic; the proper display-name pass
## is on the faction-registry side.
func _faction_label(id: String) -> String:
	if id.is_empty():
		return ""
	if id.length() <= 4:
		return id.to_upper()
	return id.replace("_", " ").capitalize()


func _push_toast(text: String) -> void:
	# Trim stack first — keep newest TOAST_MAX_VISIBLE-1 plus the
	# new one we're about to add.
	while _vbox.get_child_count() >= TOAST_MAX_VISIBLE:
		var oldest := _vbox.get_child(0)
		oldest.queue_free()
		# `queue_free` defers, so manually detach so the next
		# loop iteration sees correct count.
		_vbox.remove_child(oldest)

	var panel := PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.06, 0.08, 0.78)
	bg.set_border_width_all(1)
	bg.border_color = Color(0.18, 0.42, 0.55, 0.85)
	bg.set_corner_radius_all(2)
	bg.content_margin_left = 12.0
	bg.content_margin_right = 12.0
	bg.content_margin_top = 6.0
	bg.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override("panel", bg)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate = Color(1, 1, 1, 0)

	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.85, 0.92, 0.95))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_font_size_override("font_size", 15)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	_vbox.add_child(panel)

	# Slide-in + fade-in.
	var t_in := create_tween()
	t_in.set_trans(Tween.TRANS_QUART)
	t_in.set_ease(Tween.EASE_OUT)
	t_in.tween_property(panel, "modulate:a", 1.0, 0.25)

	# Hold, then fade out + remove. Chained on a separate tween so
	# the in-animation completes cleanly.
	var t_out := create_tween()
	t_out.set_trans(Tween.TRANS_QUART)
	t_out.set_ease(Tween.EASE_IN)
	t_out.tween_interval(TOAST_HOLD_SECONDS)
	t_out.tween_property(panel, "modulate:a", 0.0, TOAST_FADE_SECONDS)
	t_out.tween_callback(Callable(panel, "queue_free"))
