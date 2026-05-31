class_name RunsStore
extends RefCounted
## Named-run metadata index stored at `user://runs.json`. A "run" is a
## named save slot — solo or coop — that the player created from the
## shell. Each entry carries enough to render a roster row (name,
## mode, timestamps, play time) and a stable id the sim-side save
## directory keys off of.
##
## Per-run isolation: `save_dir_for(id)` returns
## `user://saves/<id>/`, and `GameSession.solo(run_id)` /
## `host(run_id)` thread the id through to `SimHost.start(save_dir)`.
## Joining clients don't use any `RunsStore` id — their mirror sim
## has no local persistence.

const _PATH := "user://runs.json"
const _SAVE_DIR_ROOT := "user://saves"

const MODE_SOLO := "solo"
const MODE_COOP := "coop"


## Save-dir convention. Solo + coop-host runs key on this path; each
## run has its own sibling directory, so snapshots and journals don't
## collide.
static func save_dir_for(id: String) -> String:
	return "%s/%s" % [_SAVE_DIR_ROOT, id]

## Read the index. Returns an array of run dictionaries with keys:
## `id`, `name`, `mode`, `created_unix`, `last_played_unix`,
## `play_time_s`. Returns an empty array on missing or corrupt file.
static func list_all() -> Array:
	if not FileAccess.file_exists(_PATH):
		return []
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if f == null:
		return []
	var raw := f.get_as_text()
	f.close()
	if raw.strip_edges() == "":
		return []
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary and (parsed as Dictionary).has("runs"):
		var runs: Variant = (parsed as Dictionary)["runs"]
		if runs is Array:
			return runs
	return []


static func list_for_mode(mode: String) -> Array:
	var out: Array = []
	for run in list_all():
		if run is Dictionary and (run as Dictionary).get("mode", "") == mode:
			out.append(run)
	# Sort newest first by last_played_unix, falling back to created_unix.
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var at: float = float(a.get("last_played_unix", a.get("created_unix", 0)))
		var bt: float = float(b.get("last_played_unix", b.get("created_unix", 0)))
		return at > bt
	)
	return out


## Create a new run with the given display name. Returns the
## dictionary that was stored (including its generated id) or null on
## validation failure (empty name, duplicate name within the mode).
static func create(name: String, mode: String) -> Variant:
	var trimmed := name.strip_edges()
	if trimmed == "":
		return null
	var runs := list_all()
	for r in runs:
		if r is Dictionary and r.get("mode", "") == mode and (r.get("name", "") as String).to_lower() == trimmed.to_lower():
			return null
	var now := Time.get_unix_time_from_system()
	var run := {
		"id": _make_id(trimmed, now),
		"name": trimmed,
		"mode": mode,
		"created_unix": now,
		"last_played_unix": now,
		"play_time_s": 0,
	}
	runs.append(run)
	_save(runs)
	return run


## Bump a run's `last_played_unix` to now. No-op if the id isn't known.
static func touch(id: String) -> void:
	var runs := list_all()
	var changed := false
	for r in runs:
		if r is Dictionary and r.get("id", "") == id:
			(r as Dictionary)["last_played_unix"] = Time.get_unix_time_from_system()
			changed = true
	if changed:
		_save(runs)


## Rename an existing run. Returns true on success, false if the new
## name is empty or collides with another run in the same mode (case-
## insensitive). Renaming to the same name (case-insensitive) is a
## no-op returning true.
static func rename(id: String, new_name: String) -> bool:
	var trimmed := new_name.strip_edges()
	if trimmed == "":
		return false
	var runs := list_all()
	var target_mode := ""
	for r in runs:
		if r is Dictionary and r.get("id", "") == id:
			target_mode = r.get("mode", "")
			break
	if target_mode == "":
		return false
	for r in runs:
		if r is Dictionary and r.get("id", "") != id and r.get("mode", "") == target_mode:
			if (r.get("name", "") as String).to_lower() == trimmed.to_lower():
				return false
	for r in runs:
		if r is Dictionary and r.get("id", "") == id:
			(r as Dictionary)["name"] = trimmed
	_save(runs)
	return true


## Return the most-recently-played run across all modes, or null if
## the index is empty. Used by the main menu's CONTINUE quick action.
static func most_recent() -> Variant:
	var runs := list_all()
	if runs.is_empty():
		return null
	var best: Dictionary = runs[0]
	var best_t: float = float(best.get("last_played_unix", best.get("created_unix", 0)))
	for i in range(1, runs.size()):
		var r: Dictionary = runs[i]
		var t: float = float(r.get("last_played_unix", r.get("created_unix", 0)))
		if t > best_t:
			best = r
			best_t = t
	return best


## Remove both the metadata entry AND the on-disk save directory for
## this run. Orphaned save files are garbage that accumulates across
## dev cycles; cleaning them up on delete keeps `user://saves/`
## aligned with `runs.json`.
static func remove(id: String) -> void:
	if id.is_empty():
		return
	var runs := list_all()
	var out: Array = []
	for r in runs:
		if r is Dictionary and r.get("id", "") != id:
			out.append(r)
	_save(out)
	_remove_recursive(save_dir_for(id))


## Recursively delete `path`. Godot 4's `DirAccess` has no built-in
## recursive remove; walk manually, nuking files first then the empty
## dirs on the way up. No-op if `path` doesn't exist.
static func _remove_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_recursive("%s/%s" % [path, sub])
	for f in dir.get_files():
		dir.remove(f)
	# Remove the now-empty directory itself. Use the parent's
	# DirAccess so we don't try to remove our own cwd.
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null:
		parent.remove(path.get_file())


# -------------------------------------------------------------------

static func _make_id(name: String, now: float) -> String:
	var slug := name.to_lower()
	var result := ""
	for i in range(slug.length()):
		var c := slug[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			result += c
		elif c == " " or c == "-" or c == "_":
			result += "-"
	if result.length() > 32:
		result = result.substr(0, 32)
	return "%s-%d" % [result.trim_prefix("-").trim_suffix("-"), int(now)]


static func _save(runs: Array) -> void:
	var f := FileAccess.open(_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("RunsStore: unable to open %s for writing" % _PATH)
		return
	var payload := {"runs": runs}
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
