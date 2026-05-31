extends Control
## Runs roster screen. Lists saved runs for the configured `mode`
## (solo or coop), with an inline "+ New Run" action that prompts for
## a name and starts the session. Used by both `soloRunsScreen.tscn`
## and `coopRunsScreen.tscn` — the two scenes differ only in the
## `mode` @export and the displayed title.
##
## When a row is loaded, the sim's existing `solo()` / `host()` on
## `GameSession` is called. The run name is currently metadata; see
## the gap note in `scripts/ui/runs_store.gd` for why per-run save
## isolation is a follow-up.

const PATH_MAIN_MENU := "res://scenes/menus/mainMenu.tscn"

@export var mode: String = RunsStore.MODE_SOLO  ## "solo" | "coop"

var _list_container: VBoxContainer
var _new_run_row: Control
var _new_run_input: LineEdit
var _new_run_status: Label
var _empty_label: Label
var _session_status: Label
var _editing_id: String = ""    ## Id of the row currently in rename mode, "" if none.
var _edit_error: String = ""    ## Last rename validation error, cleared on rebuild.


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var shell := MenuShell.new()
	add_child(shell)
	shell.set_body(_build_body())
	_rebuild_rows()

	var session := get_node_or_null("/root/GameSession")
	if session != null and session.has_signal("session_failed"):
		session.session_failed.connect(_on_session_failed)


func _build_body() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)

	v.add_child(_build_header())
	v.add_child(_build_new_run_bar())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 40)
	pad.add_theme_constant_override("margin_right", 40)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 40)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)

	_list_container = VBoxContainer.new()
	_list_container.add_theme_constant_override("separation", 8)
	pad.add_child(_list_container)

	_session_status = NSWidgets.label_mono("", 11, NSColors.WARNING_RUST)
	_session_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_session_status.visible = false
	pad.add_child(_session_status)

	return v


func _on_session_failed(source: String, message: String) -> void:
	if _session_status == null:
		return
	_session_status.visible = true
	_session_status.text = "[%s] %s" % [source, message]


func _build_header() -> Control:
	var header := ScreenHeader.new()
	header.eyebrow_text = "◇ RUNS · %s" % mode.to_upper()
	header.title_text = _title_for_mode()
	header.back_pressed.connect(_go_back)
	return header


func _title_for_mode() -> String:
	match mode:
		RunsStore.MODE_COOP: return "COOP RUNS"
		_:                   return "SOLO RUNS"


func _build_new_run_bar() -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_bottom = 1
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	wrap.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	wrap.add_child(v)

	var trigger_row := HBoxContainer.new()
	trigger_row.add_theme_constant_override("separation", 10)
	v.add_child(trigger_row)

	var start_btn := NSWidgets.button("+ New Run", NSWidgets.Variant.PRIMARY)
	start_btn.pressed.connect(_on_show_new_run)
	trigger_row.add_child(start_btn)

	var hint := NSWidgets.label_mono(
		"as many saves as you want · name each one",
		11,
		NSColors.FG_3,
	)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trigger_row.add_child(hint)

	# Hidden name-entry row.
	_new_run_row = HBoxContainer.new()
	_new_run_row.visible = false
	(_new_run_row as HBoxContainer).add_theme_constant_override("separation", 8)
	v.add_child(_new_run_row)

	_new_run_input = LineEdit.new()
	_new_run_input.placeholder_text = "name this run…"
	_new_run_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_run_input.text_submitted.connect(func(_t: String) -> void: _on_confirm_new_run())
	_new_run_row.add_child(_new_run_input)

	var confirm := NSWidgets.button("Create & Load", NSWidgets.Variant.PRIMARY)
	confirm.pressed.connect(_on_confirm_new_run)
	_new_run_row.add_child(confirm)

	var cancel := NSWidgets.button("Cancel", NSWidgets.Variant.GHOST)
	cancel.pressed.connect(_on_cancel_new_run)
	_new_run_row.add_child(cancel)

	_new_run_status = NSWidgets.label_mono("", 10, NSColors.WARNING_RUST)
	v.add_child(_new_run_status)
	return wrap


# ---------------------------------------------------------------------
# Row list.
# ---------------------------------------------------------------------

func _rebuild_rows() -> void:
	if _list_container == null:
		return
	for c in _list_container.get_children():
		c.queue_free()
	_empty_label = null

	var runs := RunsStore.list_for_mode(mode)
	if runs.is_empty():
		_empty_label = NSWidgets.label_mono(
			"— no %s runs yet. start your first one above. —" % mode,
			12,
			NSColors.FG_3,
		)
		_list_container.add_child(_empty_label)
		return
	for run in runs:
		_list_container.add_child(_build_row(run))


func _build_row(run: Dictionary) -> Control:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = NSColors.WET_SLATE
	sb.border_color = NSColors.LICHEN
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	wrap.add_theme_stylebox_override("panel", sb)

	var is_editing: bool = _editing_id == run.get("id", "")

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	wrap.add_child(outer)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	outer.add_child(row)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	info.add_child(name_row)

	if is_editing:
		var edit := LineEdit.new()
		edit.text = run.get("name", "")
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.placeholder_text = "rename…"
		edit.text_submitted.connect(func(t: String) -> void: _on_rename_save(run, t))
		name_row.add_child(edit)
		edit.grab_focus.call_deferred()
		edit.select_all.call_deferred()
	else:
		name_row.add_child(NSWidgets.stencil(run.get("name", "?"), 22, NSColors.PAGE_WHITE, 600))
		name_row.add_child(NSWidgets.badge(mode.to_upper(), NSColors.VLF_PHOSPHOR))

	var stats_l := NSWidgets.label_mono(_format_stats(run), 11, NSColors.FG_3)
	info.add_child(stats_l)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(actions)

	if is_editing:
		var save_btn := NSWidgets.button("Save", NSWidgets.Variant.PRIMARY)
		save_btn.pressed.connect(func() -> void:
			var edit_node: LineEdit = name_row.get_child(0) as LineEdit
			_on_rename_save(run, edit_node.text)
		)
		actions.add_child(save_btn)
		var cancel_btn := NSWidgets.button("Cancel", NSWidgets.Variant.GHOST)
		cancel_btn.pressed.connect(_on_rename_cancel)
		actions.add_child(cancel_btn)
	else:
		var rename_btn := NSWidgets.button("Rename", NSWidgets.Variant.GHOST)
		rename_btn.pressed.connect(_on_rename_start.bind(run))
		actions.add_child(rename_btn)
		var load_btn := NSWidgets.button("Load", NSWidgets.Variant.PRIMARY)
		load_btn.pressed.connect(_on_load_pressed.bind(run))
		actions.add_child(load_btn)
		var del_btn := NSWidgets.button("Delete", NSWidgets.Variant.DANGER)
		del_btn.pressed.connect(_on_delete_pressed.bind(run))
		actions.add_child(del_btn)

	if is_editing and _edit_error != "":
		var err := NSWidgets.label_mono(_edit_error, 11, NSColors.WARNING_RUST)
		outer.add_child(err)

	return wrap


func _format_stats(run: Dictionary) -> String:
	var created := int(run.get("created_unix", 0))
	var last := int(run.get("last_played_unix", created))
	var play_time := int(run.get("play_time_s", 0))
	return "CREATED %s  ·  LAST PLAYED %s  ·  %s PLAYED" % [
		_format_date(created),
		_format_relative(last),
		_format_duration(play_time),
	]


static func _format_date(unix: int) -> String:
	if unix <= 0:
		return "—"
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]


static func _format_relative(unix: int) -> String:
	if unix <= 0:
		return "never"
	var delta := int(Time.get_unix_time_from_system()) - unix
	if delta < 60:    return "just now"
	if delta < 3600:  return "%dm ago" % (delta / 60)
	if delta < 86400: return "%dh ago" % (delta / 3600)
	if delta < 86400 * 30: return "%dd ago" % (delta / 86400)
	return _format_date(unix)


static func _format_duration(seconds: int) -> String:
	if seconds <= 0:
		return "0m"
	if seconds < 3600:
		return "%dm" % (seconds / 60)
	var h := seconds / 3600
	var m := (seconds % 3600) / 60
	return "%dh %02dm" % [h, m]


# ---------------------------------------------------------------------
# Actions.
# ---------------------------------------------------------------------

func _on_show_new_run() -> void:
	_new_run_row.visible = true
	_new_run_input.grab_focus()
	_new_run_status.text = ""


func _on_cancel_new_run() -> void:
	_new_run_row.visible = false
	_new_run_input.text = ""
	_new_run_status.text = ""


func _on_confirm_new_run() -> void:
	var name := _new_run_input.text.strip_edges()
	if name == "":
		_new_run_status.text = "Name can't be empty."
		return
	var run: Variant = RunsStore.create(name, mode)
	if run == null:
		_new_run_status.text = "A %s run called \"%s\" already exists." % [mode, name]
		return
	_new_run_input.text = ""
	_new_run_row.visible = false
	_start_session(run)


func _on_load_pressed(run: Dictionary) -> void:
	RunsStore.touch(run.get("id", ""))
	_start_session(run)


func _on_delete_pressed(run: Dictionary) -> void:
	RunsStore.remove(run.get("id", ""))
	_rebuild_rows()


func _on_rename_start(run: Dictionary) -> void:
	_editing_id = run.get("id", "")
	_edit_error = ""
	_rebuild_rows()


func _on_rename_cancel() -> void:
	_editing_id = ""
	_edit_error = ""
	_rebuild_rows()


func _on_rename_save(run: Dictionary, new_name: String) -> void:
	var trimmed := new_name.strip_edges()
	if trimmed == "":
		_edit_error = "Name can't be empty."
		_rebuild_rows()
		return
	if trimmed == run.get("name", ""):
		_on_rename_cancel()
		return
	var ok := RunsStore.rename(run.get("id", ""), trimmed)
	if not ok:
		_edit_error = 'A %s run called "%s" already exists.' % [mode, trimmed]
		_rebuild_rows()
		return
	_editing_id = ""
	_edit_error = ""
	_rebuild_rows()


func _start_session(run: Dictionary) -> void:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var run_id: String = run.get("id", "")
	if run_id.is_empty():
		push_error("RunsScreen: run has no id")
		return
	match mode:
		RunsStore.MODE_COOP: session.host(run_id)
		_:                    session.solo(run_id)
	# Keep the user on the same screen if the session fails to load;
	# successful loads will trigger a scene change via GameSession.


func _go_back() -> void:
	get_tree().change_scene_to_file(PATH_MAIN_MENU)
