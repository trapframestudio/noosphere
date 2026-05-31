class_name SettingsStore
extends RefCounted
## Persistent user settings at `user://settings.json`. A flat dict of
## typed values, organized by tab key. Loaded once into an in-memory
## cache on first access; writes go through immediately (tiny payload,
## write-amplification is not a concern).
##
## This is the shared backing store — each Settings tab reads and
## writes its own keys. Callers should not assume key presence; always
## default through `get_value`. When a real audio / video / radio
## subsystem lands, it reads from this store at startup and
## subscribes to change notifications.

const _PATH := "user://settings.json"

## Defaults. Tabs extend this as they come online; keep keys
## dotted (`tab.key`) so there's no collision across tabs.
const DEFAULTS: Dictionary = {
	# AUDIO (volumes are 0–100; real bus dB mapping happens in the
	# wire-up pass once `default_bus_layout.tres` is authored)
	"audio.master_volume":   100,
	"audio.sfx_volume":      100,
	"audio.music_volume":    70,
	"audio.voice_volume":    100,
	"audio.ambient_volume":  80,

	# VIDEO (window_mode/vsync are applied immediately via
	# DisplayServer; ui_scale via Window.content_scale_factor)
	"video.window_mode":     "FULLSCREEN",
	"video.vsync":           "ON",
	"video.ui_scale":        100,
	"video.view_distance":   800,

	# RADIO
	"radio.primary_frequency":       "146.520",
	"radio.transmit_mode":           "PUSH-TO-TALK",
	"radio.proximity_range":         60,
	"radio.input_gain":              72,
	"radio.background_static":       34,
	"radio.broadcast_shadow_glitch": "FULL",

	# ACCESSIBILITY
	"accessibility.color_blind":   "NONE",
	"accessibility.subtitles":     false,
	"accessibility.reduced_motion": false,
	"accessibility.screen_shake":  true,

	# SERVER RULES (host-time defaults; per-lobby overrides come later)
	"server.pvp_mode":       "PVE",
	"server.friendly_fire":  false,
	"server.hardcore":       false,
	"server.peace_bond_hubs": true,
}

static var _cache: Dictionary = {}
static var _loaded: bool = false


static func get_value(key: String) -> Variant:
	_ensure_loaded()
	if _cache.has(key):
		return _cache[key]
	return DEFAULTS.get(key, null)


static func set_value(key: String, value: Variant) -> void:
	_ensure_loaded()
	_cache[key] = value
	_save()


static func reset(key: String) -> void:
	_ensure_loaded()
	if _cache.erase(key):
		_save()


static func reset_all() -> void:
	_cache.clear()
	_save()


# -------------------------------------------------------------------

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(_PATH):
		return
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	if raw.strip_edges() == "":
		return
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary:
		_cache = parsed


static func _save() -> void:
	var f := FileAccess.open(_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("SettingsStore: unable to open %s for writing" % _PATH)
		return
	f.store_string(JSON.stringify(_cache, "\t"))
	f.close()
