@tool
class_name WeatherRig
extends Node3D
## Drop-in weather + time-of-day rig.
##
## Owns the `WorldEnvironment`, sun `DirectionalLight3D`, moon
## `DirectionalLight3D`, and `SunshineCloudsDriver` for a scene. Polls
## `SimHost.world_time()` + `SimHost.weather_state()` each frame and
## drives sun/moon rotation + energy + color, env fog density + tint,
## sky material day/night blend, and cloud compositor properties so
## the visuals follow sim-authoritative weather + time.
##
## To add to a new map scene: instance `res://scenes/weather/weather_rig.tscn`
## as a child of the map root. Nothing else is required — the rig resolves
## its own children at runtime. Every map uses the same rig, so tuning
## lives in one place.
##
## Test / mood fixtures can set `force_weather` to pin the visual state
## to a single weather kind without side-effecting the sim (no
## `set_weather` call is made — this is a local visual override). Leave
## empty to follow the sim.
##
## For editor-time iteration (try every weather kind / sun angle without
## entering play mode), toggle `editor_preview` on the rig instance and
## use the `preview_weather` dropdown + `preview_sun_elevation_deg` slider.
## Editor preview is a one-way push into the cloud compositor + sun + moon
## lights; it never sets `force_weather` or calls the sim. Runtime always
## follows sim first, `force_weather` second — editor previews are ignored
## at runtime, and the moon is procedurally driven from `sim.world_time()`
## every frame. Toggle `editor_preview` off before saving the scene to
## cleanly revert all preview writes; the rig snapshots its committed
## state on `_ready` and restores on toggle-off.
##
## Expected children (wired up in `weather_rig.tscn`):
## - `WorldEnvironment` — references `res://resources/default_environment.tres`
##   with a `Compositor` holding the SunshineClouds2 effect
## - `Sun` (`DirectionalLight3D`) — main sun light
## - `Moon` (`DirectionalLight3D`) — moonlight (energy driven per phase)
## - `SunshineCloudsDriver` — references `res://resources/noosphere_clouds.tres`

@export var force_weather: String = ""

## Apply project-wide shadow perf defaults to `Sun` at `_ready` —
## `directional_shadow_max_distance = 80` (default 100; quadratic cost
## reduction past the player's typical ~50 m gameplay-relevant range)
## and PSSM **2-split** mode (default 4-split is dramatically more
## expensive on Forward+ for marginal quality gains in open world).
## Disable per-rig if a particular scene needs different shadow
## settings; project.godot's atlas-resolution drop to 2048 still
## applies regardless.
@export var apply_shadow_defaults: bool = true

@export_group("Editor preview")
## Toggle to drive the cloud compositor + sun light from the preview
## controls below. Visible in the editor viewport only — runtime ignores
## all editor-preview state and reads weather from the sim (or from
## `force_weather` if set).
@export var editor_preview: bool = false:
	set(value):
		var was_on := editor_preview
		editor_preview = value
		if Engine.is_editor_hint():
			if value and not was_on:
				# First turn-on: load the full preset for the current
				# `preview_weather` so clouds, sky, and fog all match
				# the dropdown up front. After this, individual slider
				# edits push their own values without re-loading.
				_load_preset_into_overrides()
				_apply_editor_preview()
			elif value:
				_apply_editor_preview()
			elif was_on:
				_reset_editor_preview()
## Which weather kind the preview drives. Changing this while
## `editor_preview` is on auto-applies the whole weather look — sky,
## env fog, AND the cloud override sliders (via the same code path as
## the "Load preset" button). Tweaks to the cloud sliders are replaced
## on each dropdown change; if you want to stack tweaks across weather
## kinds, stay on one `preview_weather` and tune, then hand me the
## numbers before moving on.
@export_enum("clear", "partly_cloudy", "overcast", "marine_layer", "fog",
	"drizzle", "light_rain", "heavy_rain", "windstorm", "thunderstorm",
	"smoke_haze") var preview_weather: String = "partly_cloudy":
	set(value):
		preview_weather = value
		if Engine.is_editor_hint() and editor_preview:
			# Full reload: weights, sky, env, clouds, slider mirror.
			_load_preset_into_overrides()
## Sun elevation angle in degrees for the editor preview. 90 = straight
## up (noon), 0 = on the horizon (dawn/dusk), negative = below horizon
## (night).
@export_range(-90.0, 90.0, 1.0) var preview_sun_elevation_deg: float = 45.0:
	set(value):
		preview_sun_elevation_deg = value
		_apply_editor_preview()
## Moon elevation angle in degrees for the editor preview. Same
## convention as the sun slider. Moon light only contributes when the
## sun is below the horizon (`preview_sun_elevation_deg < 0`), so to see
## moonlight in the viewport, drop the sun first.
@export_range(-90.0, 90.0, 1.0) var preview_moon_elevation_deg: float = 30.0:
	set(value):
		preview_moon_elevation_deg = value
		_apply_editor_preview()
## Moon phase illumination, 0 = new moon (no light), 1 = full moon. In
## the runtime path this comes from `sim.world_time().moon_illumination`.
@export_range(0.0, 1.0, 0.01) var preview_moon_illumination: float = 1.0:
	set(value):
		preview_moon_illumination = value
		_apply_editor_preview()

@export_group("Cloud overrides (editor only)")
## Snapshot what the weather formula currently produces for
## `preview_weather` into the sliders below, so you can tweak from that
## starting point. Only the fields the formula touches (coverage,
## sharpness, density, atmospheric density, cloud/atmosphere colors,
## large/medium noise scales, wind multiplier) get overwritten — the
## rest of the sliders keep whatever you last set.
@export_tool_button("Load preset from preview_weather", "Add") var _load_preset_action = _load_preset_into_overrides

# -------- SunshineCloudsGD properties (the compositor effect resource)
# Every `@export` in these subgroups mirrors one field on
# `SunshineCloudsGD` (see `godot/addons/SunshineClouds2/SunshineClouds.gd`).
# Ranges match the addon's own ranges so sliders clamp at the shader-
# sensible bounds. Setters push directly to `_clouds_res` when editor
# preview is on.

@export_subgroup("Basic")
@export_range(0.0, 1.0, 0.01) var cloud_coverage: float = 0.726:
	set(v):
		cloud_coverage = v
		_w_res("clouds_coverage", v)
## Coverage below this threshold disables the cloud effect entirely
## (rig-level gate; not on the addon resource). Default 0 so clouds
## are always on and coverage scales linearly from the user's POV.
@export_range(0.0, 1.0, 0.01) var cloud_coverage_enable_threshold: float = 0.0:
	set(v):
		cloud_coverage_enable_threshold = v
		if Engine.is_editor_hint() and editor_preview and _clouds_res != null:
			_clouds_res.set("enabled", cloud_coverage > v)
@export_range(0.0, 20.0, 0.05) var cloud_density: float = 1.0:
	set(v):
		cloud_density = v
		_w_res("clouds_density", v)
@export_range(0.0, 2.0, 0.01) var cloud_atmospheric_density: float = 0.5:
	set(v):
		cloud_atmospheric_density = v
		_w_res("atmospheric_density", v)
@export_range(0.0, 10.0, 0.05) var cloud_lighting_density: float = 0.55:
	set(v):
		cloud_lighting_density = v
		_w_res("lighting_density", v)
## 0 = cloud shader ignores the env fog; 1 = fully integrates. Works
## together with `cloud_fog_effect_ground`.
@export_range(0.0, 1.0, 0.01) var cloud_use_environment_fog: float = 0.0:
	set(v):
		cloud_use_environment_fog = v
		_w_res("use_environment_fog", v)
@export_range(0.0, 1.0, 0.01) var cloud_fog_effect_ground: float = 1.0:
	set(v):
		cloud_fog_effect_ground = v
		_w_res("fog_effect_ground", v)

@export_subgroup("Colors")
@export var cloud_ambient_color: Color = Color(1.0, 1.0, 1.0):
	set(v):
		cloud_ambient_color = v
		_w_res("cloud_ambient_color", v)
@export var cloud_ambient_tint: Color = Color(0.1276, 0.18766, 0.22):
	set(v):
		cloud_ambient_tint = v
		_w_res("cloud_ambient_tint", v)
@export var cloud_atmosphere_color: Color = Color(0.280153, 0.544962, 0.759771):
	set(v):
		cloud_atmosphere_color = v
		_w_res("atmosphere_color", v)
@export var cloud_ambient_occlusion_color: Color = Color(0.693375, 0.223129, 0, 0.466667):
	set(v):
		cloud_ambient_occlusion_color = v
		_w_res("ambient_occlusion_color", v)

@export_subgroup("Lighting")
## Scattering direction bias — higher = forward scattering (sun backlit).
@export_range(0.0, 1.0, 0.01) var cloud_anisotropy: float = 0.057:
	set(v):
		cloud_anisotropy = v
		_w_res("clouds_anisotropy", v)
## "Dark-edge" powder effect along cloud silhouettes. 0.75 is the
## sweet spot for normal clouds; crank toward 0.85 for ominous weather.
@export_range(0.0, 1.0, 0.01) var cloud_powder: float = 0.75:
	set(v):
		cloud_powder = v
		_w_res("clouds_powder", v)
@export_range(0.0, 2.0, 0.01) var cloud_lighting_sharpness: float = 0.34:
	set(v):
		cloud_lighting_sharpness = v
		_w_res("lighting_sharpness", v)
@export_range(0.0, 50000.0, 100.0) var cloud_lighting_travel_distance: float = 8000.0:
	set(v):
		cloud_lighting_travel_distance = v
		_w_res("lighting_travel_distance", v)

@export_subgroup("Structure")
@export_range(0.0, 2.0, 0.01) var cloud_sharpness: float = 0.5:
	set(v):
		cloud_sharpness = v
		_w_res("clouds_sharpness", v)
@export_range(0.0, 3.0, 0.01) var cloud_detail_power: float = 3.0:
	set(v):
		cloud_detail_power = v
		_w_res("clouds_detail_power", v)
@export_range(0.0, 1.0, 0.01) var cloud_accumulation_decay: float = 0.8:
	set(v):
		cloud_accumulation_decay = v
		_w_res("accumulation_decay", v)
@export_range(100.0, 1000000.0, 500.0) var cloud_extra_large_noise_scale: float = 60000.0:
	set(v):
		cloud_extra_large_noise_scale = v
		_w_res("extra_large_noise_scale", v)
@export_range(100.0, 500000.0, 100.0) var cloud_large_noise_scale: float = 15000.0:
	set(v):
		cloud_large_noise_scale = v
		_w_res("large_noise_scale", v)
@export_range(100.0, 100000.0, 50.0) var cloud_medium_noise_scale: float = 4500.0:
	set(v):
		cloud_medium_noise_scale = v
		_w_res("medium_noise_scale", v)
@export_range(100.0, 10000.0, 10.0) var cloud_small_noise_scale: float = 1500.0:
	set(v):
		cloud_small_noise_scale = v
		_w_res("small_noise_scale", v)
@export_range(0.0, 50000.0, 50.0) var cloud_curl_noise_strength: float = 6184.0:
	set(v):
		cloud_curl_noise_strength = v
		_w_res("curl_noise_strength", v)

@export_subgroup("Wind sweep (vertical motion)")
## Applies sideways distortion proportional to altitude — low clouds
## drift differently than high clouds. `range` is the altitude band
## affected (0 = entire cloud thickness, 1 = narrow slice at top).
@export_range(0.0, 1.0, 0.01) var cloud_wind_swept_range: float = 0.54:
	set(v):
		cloud_wind_swept_range = v
		_w_res("wind_swept_range", v)
@export_range(0.0, 5000.0, 10.0) var cloud_wind_swept_strength: float = 0.0:
	set(v):
		cloud_wind_swept_strength = v
		_w_res("wind_swept_strength", v)

@export_subgroup("Altitude")
## Base of the cloud layer in meters.
@export_range(0.0, 30000.0, 50.0) var cloud_floor: float = 1500.0:
	set(v):
		cloud_floor = v
		_w_res("cloud_floor", v)
## Top of the cloud layer in meters. PNW overcast 500–2000; storms 500.
@export_range(100.0, 50000.0, 50.0) var cloud_ceiling: float = 2000.0:
	set(v):
		cloud_ceiling = v
		_w_res("cloud_ceiling", v)

@export_subgroup("Mask")
## If true, the extra-large noise layer is used as a coverage mask
## (binary-ish) rather than a density contributor.
@export var cloud_extra_large_used_as_mask: bool = false:
	set(v):
		cloud_extra_large_used_as_mask = v
		_w_res("extra_large_used_as_mask", v)
## Mask coverage width in km. Large values = one coherent mask cell
## covers the whole playable area (mostly-cloudy or mostly-clear across
## the map); small values = mask cells smaller than map, so patches.
@export_range(1.0, 2048.0, 1.0) var cloud_mask_width_km: float = 512.0:
	set(v):
		cloud_mask_width_km = v
		_w_res("mask_width_km", v)

@export_subgroup("Render performance")
@export_range(10.0, 2000.0, 10.0) var cloud_max_step_count: float = 300.0:
	set(v):
		cloud_max_step_count = v
		_w_res("max_step_count", v)
## Lighting ray step count. Visually indistinguishable above ~16 at
## typical cloud thicknesses; cranking costs perf without looking
## better. Kept low by default.
@export_range(1.0, 128.0, 1.0) var cloud_max_lighting_steps: float = 16.0:
	set(v):
		cloud_max_lighting_steps = v
		_w_res("max_lighting_steps", v)
## Heavy weather → 0.0 (full detail on big close clouds). Chill weather
## → higher (perf win, and helps mask repetition at distance).
@export_range(0.0, 2.0, 0.01) var cloud_lod_bias: float = 0.7:
	set(v):
		cloud_lod_bias = v
		_w_res("lod_bias", v)
@export_range(1.0, 10000.0, 1.0) var cloud_min_step_distance: float = 100.0:
	set(v):
		cloud_min_step_distance = v
		_w_res("min_step_distance", v)
@export_range(1.0, 10000.0, 1.0) var cloud_max_step_distance: float = 600.0:
	set(v):
		cloud_max_step_distance = v
		_w_res("max_step_distance", v)
@export_range(0.0, 1000.0, 0.1) var cloud_dither_speed: float = 100.8:
	set(v):
		cloud_dither_speed = v
		_w_res("dither_speed", v)
## 15 + quality 2 is the user-confirmed sweet spot for softening noise
## without perf hit. Keep in sync with the .tres defaults or whichever
## value pushes last at runtime wins.
@export_range(0.0, 20.0, 0.1) var cloud_blur_power: float = 15.0:
	set(v):
		cloud_blur_power = v
		_w_res("blur_power", v)
@export_range(0.0, 6.0, 0.1) var cloud_blur_quality: float = 2.0:
	set(v):
		cloud_blur_quality = v
		_w_res("blur_quality", v)

# -------- SunshineCloudsDriver properties (the node sibling)
# These aren't on the compositor resource — they live on the driver
# child of the rig. Exposing them here saves a click into the driver
# node every time you want to iterate on wind.

@export_subgroup("Driver / wind")
@export var cloud_wind_direction: Vector3 = Vector3(1, 0, 0.5):
	set(v):
		cloud_wind_direction = v
		_w_drv("wind_direction", v)
@export_range(0.0, 1000.0, 0.5) var cloud_extra_large_wind_speed: float = 140.0:
	set(v):
		cloud_extra_large_wind_speed = v
		_w_drv("extra_large_structures_wind_speed", v)
@export_range(0.0, 1000.0, 0.5) var cloud_large_wind_speed: float = 100.0:
	set(v):
		cloud_large_wind_speed = v
		_w_drv("large_structures_wind_speed", v)
@export_range(0.0, 1000.0, 0.5) var cloud_medium_wind_speed: float = 40.0:
	set(v):
		cloud_medium_wind_speed = v
		_w_drv("medium_structures_wind_speed", v)
@export_range(0.0, 1000.0, 0.5) var cloud_small_wind_speed: float = 12.0:
	set(v):
		cloud_small_wind_speed = v
		_w_drv("small_structures_wind_speed", v)
@export_range(0.0, 5.0, 0.05) var cloud_directional_light_power_multiplier: float = 1.0:
	set(v):
		cloud_directional_light_power_multiplier = v
		_w_drv("directional_light_power_multiplier", v)

# --- Color grading ----------------------------------------------------
# Surfaces the params on `color_grade.tres` (the CompositorEffect bound
# into this rig's WorldEnvironment). Setters write straight through to
# the resource so the viewport updates live in editor + runtime; values
# are saved on the rig (not the .tres), keeping the tuning baked into
# whichever map instances this scene.

@export_group("Color grading")

@export_subgroup("Tone")
@export_range(-5.0, 5.0, 0.01, "or_greater", "or_less") var grade_exposure: float = 0.0:
	set(v):
		grade_exposure = v
		_w_grade("exposure", v)
@export_range(-1.0, 1.0, 0.01) var grade_temperature: float = 0.0:
	set(v):
		grade_temperature = v
		_w_grade("temperature", v)
@export_range(-1.0, 1.0, 0.01) var grade_tint: float = 0.0:
	set(v):
		grade_tint = v
		_w_grade("tint", v)

@export_subgroup("Primaries ASC CDL")
@export var grade_lift_color: Color = Color(0.5, 0.5, 0.5):
	set(v):
		grade_lift_color = v
		_w_grade("lift_color", v)
@export_range(0.0, 1.0, 0.01) var grade_lift_amount: float = 0.0:
	set(v):
		grade_lift_amount = v
		_w_grade("lift_amount", v)
@export var grade_gamma_color: Color = Color(0.5, 0.5, 0.5):
	set(v):
		grade_gamma_color = v
		_w_grade("gamma_color", v)
@export_range(0.0, 1.0, 0.01) var grade_gamma_amount: float = 0.0:
	set(v):
		grade_gamma_amount = v
		_w_grade("gamma_amount", v)
@export var grade_gain_color: Color = Color(0.5, 0.5, 0.5):
	set(v):
		grade_gain_color = v
		_w_grade("gain_color", v)
@export_range(0.0, 1.0, 0.01) var grade_gain_amount: float = 0.0:
	set(v):
		grade_gain_amount = v
		_w_grade("gain_amount", v)

@export_subgroup("Saturation Contrast Hue")
@export_range(0.0, 2.0, 0.01) var grade_saturation: float = 1.0:
	set(v):
		grade_saturation = v
		_w_grade("saturation", v)
@export_range(0.0, 2.0, 0.01) var grade_contrast: float = 1.0:
	set(v):
		grade_contrast = v
		_w_grade("contrast", v)
@export_range(-0.5, 0.5, 0.01) var grade_hue_shift: float = 0.0:
	set(v):
		grade_hue_shift = v
		_w_grade("hue_shift", v)

@export_subgroup("Vignette")
@export_range(0.0, 1.0, 0.01) var grade_vignette_intensity: float = 0.0:
	set(v):
		grade_vignette_intensity = v
		_w_grade("vignette_intensity", v)
@export_range(0.0, 1.5, 0.01) var grade_vignette_radius: float = 0.7:
	set(v):
		grade_vignette_radius = v
		_w_grade("vignette_radius", v)
@export_range(0.0, 1.0, 0.01) var grade_vignette_softness: float = 0.3:
	set(v):
		grade_vignette_softness = v
		_w_grade("vignette_softness", v)

# Property-name pairs for `_push_all_color_grade()`. Keep in sync with the
# @exports above. Left = rig prop, right = color_grade.tres prop.
const _GRADE_FIELD_MAP := [
	["grade_exposure",           "exposure"],
	["grade_temperature",        "temperature"],
	["grade_tint",               "tint"],
	["grade_lift_color",         "lift_color"],
	["grade_lift_amount",        "lift_amount"],
	["grade_gamma_color",        "gamma_color"],
	["grade_gamma_amount",       "gamma_amount"],
	["grade_gain_color",         "gain_color"],
	["grade_gain_amount",        "gain_amount"],
	["grade_saturation",         "saturation"],
	["grade_contrast",           "contrast"],
	["grade_hue_shift",          "hue_shift"],
	["grade_vignette_intensity", "vignette_intensity"],
	["grade_vignette_radius",    "vignette_radius"],
	["grade_vignette_softness",  "vignette_softness"],
]

const WEATHER_KINDS := [
	"clear", "partly_cloudy", "overcast", "marine_layer", "fog",
	"drizzle", "light_rain", "heavy_rain", "windstorm", "thunderstorm",
	"smoke_haze",
]
## Heavy fronts transition slowly so they read as rolling in; light
## shifts move faster since they're subtle and shouldn't feel laggy.
const WEATHER_LERP_RATE_FAST: float = 0.08
const WEATHER_LERP_RATE_SLOW: float = 0.02

## Per-weather cloud tuning. Blending by weight at runtime gives smooth
## transitions between kinds.
##
## Tuning model (2026-04-24 pass, guided by Jon's playtesting):
## - **XL noise scale is the coverage pattern.** High XL (200k–300k) =
##   uniform across the map → overcast / storms / rain. Moderate XL
##   (80k–150k) = scattered pattern → clear / partly cloudy / smoke
##   haze. XL is not a "size" dial, it's a "uniform vs. scattered" dial.
## - **L / M / S are break-up noise.** They introduce the variation on
##   top of the XL base. Larger values = smoother blanket (overcast,
##   marine). Smaller values = visible detail / churn (storms). Too
##   much S with too-flat L/M tiles visibly — always keep a mix.
## - `coverage` is sensitive around 0.8. Sub-0.8 reads as distant
##   clouds, cranked ≈ full overcast. Good "roll-in" dial.
## - `density` drives overhead vs. horizon feel. Higher = pressed
##   overhead; lower = far off.
## - `sharpness`: high = defined cumulus, low = soft smear.
## - `powder` 0.75 normal, 0.85 ominous.
## - `detail_power` 2.5–3 for cumulus puffiness; storms slightly lower.
## - `curl_noise_strength`: low = thick clouds, high = broken wispy.
## - `atmospheric_density` + `fog_effect_ground` = the cloud shader's
##   own fog. Pair with a light native env fog for full atmosphere.
## - `env_fog_density` = native `Environment.fog_density`. Kept subtle
##   everywhere — cloud atmosphere does the heavy lifting.
## - `wind_mul` scales all four driver wind tiers.
const _WEATHER_CLOUD_PRESETS := {
	"clear": {
		"coverage": 0.35, "density": 0.3, "sharpness": 1.0, "powder": 0.75,
		"detail_power": 2.5, "lighting_density": 0.4, "lighting_sharpness": 0.4,
		"atmospheric_density": 0.8, "fog_effect_ground": 0.0, "lod_bias": 1.5,
		"cloud_floor": 2800.0, "cloud_ceiling": 3800.0,
		"curl_noise_strength": 8000.0,
		"xl_scale": 90000.0, "large_scale": 20000.0,
		"medium_scale": 4000.0, "small_scale": 1200.0,
		"wind_mul": 1.0, "env_fog_density": 0.00001,
		"ambient_color": Color(1.0, 1.0, 1.0),
		"ambient_tint": Color(0.13, 0.19, 0.22),
		"atmosphere_color": Color(0.30, 0.55, 0.76),
	},
	"partly_cloudy": {
		"coverage": 0.70, "density": 1.0, "sharpness": 0.70, "powder": 0.75,
		"detail_power": 3.0, "lighting_density": 0.55, "lighting_sharpness": 0.45,
		"atmospheric_density": 0.85, "fog_effect_ground": 0.0, "lod_bias": 1.2,
		"cloud_floor": 2200.0, "cloud_ceiling": 3500.0,
		"curl_noise_strength": 6500.0,
		"xl_scale": 130000.0, "large_scale": 25000.0,
		"medium_scale": 7000.0, "small_scale": 2500.0,
		"wind_mul": 1.1, "env_fog_density": 0.00003,
		"ambient_color": Color(0.97, 0.97, 0.97),
		"ambient_tint": Color(0.14, 0.20, 0.24),
		"atmosphere_color": Color(0.30, 0.55, 0.76),
	},
	"overcast": {
		"coverage": 0.99, "density": 2.5, "sharpness": 0.18, "powder": 0.78,
		"detail_power": 1.8, "lighting_density": 1.4, "lighting_sharpness": 0.95,
		"atmospheric_density": 1.0, "fog_effect_ground": 0.25, "lod_bias": 0.7,
		"cloud_floor": 1800.0, "cloud_ceiling": 3200.0,
		"curl_noise_strength": 4200.0,
		"xl_scale": 300000.0, "large_scale": 50000.0,
		"medium_scale": 15000.0, "small_scale": 5000.0,
		"wind_mul": 1.0, "env_fog_density": 0.00006,
		"ambient_color": Color(0.82, 0.83, 0.85),
		"ambient_tint": Color(0.15, 0.18, 0.20),
		"atmosphere_color": Color(0.50, 0.54, 0.60),
	},
	"marine_layer": {
		"coverage": 0.90, "density": 1.5, "sharpness": 0.30, "powder": 0.77,
		"detail_power": 2.0, "lighting_density": 0.9, "lighting_sharpness": 0.75,
		"atmospheric_density": 0.95, "fog_effect_ground": 0.45, "lod_bias": 1.0,
		"cloud_floor": 800.0, "cloud_ceiling": 1900.0,
		"curl_noise_strength": 5200.0,
		"xl_scale": 220000.0, "large_scale": 22000.0,
		"medium_scale": 5000.0, "small_scale": 2000.0,
		"wind_mul": 0.7, "env_fog_density": 0.00015,
		"ambient_color": Color(0.88, 0.90, 0.92),
		"ambient_tint": Color(0.17, 0.21, 0.24),
		"atmosphere_color": Color(0.70, 0.74, 0.78),
	},
	"fog": {
		"coverage": 0.70, "density": 1.8, "sharpness": 0.20, "powder": 0.70,
		"detail_power": 1.2, "lighting_density": 1.1, "lighting_sharpness": 0.9,
		"atmospheric_density": 1.0, "fog_effect_ground": 0.85, "lod_bias": 1.0,
		"cloud_floor": 0.0, "cloud_ceiling": 600.0,
		"curl_noise_strength": 2800.0,
		"xl_scale": 190000.0, "large_scale": 22000.0,
		"medium_scale": 5500.0, "small_scale": 1400.0,
		"wind_mul": 0.4, "env_fog_density": 0.0005,
		"ambient_color": Color(0.85, 0.88, 0.92),
		"ambient_tint": Color(0.20, 0.22, 0.24),
		"atmosphere_color": Color(0.82, 0.85, 0.90),
	},
	"drizzle": {
		"coverage": 0.85, "density": 1.6, "sharpness": 0.22, "powder": 0.72,
		"detail_power": 1.8, "lighting_density": 1.3, "lighting_sharpness": 1.0,
		"atmospheric_density": 0.95, "fog_effect_ground": 0.30, "lod_bias": 0.6,
		"cloud_floor": 1700.0, "cloud_ceiling": 3000.0,
		"curl_noise_strength": 3600.0,
		"xl_scale": 270000.0, "large_scale": 18000.0,
		"medium_scale": 4000.0, "small_scale": 2000.0,
		"wind_mul": 1.3, "env_fog_density": 0.00008,
		"ambient_color": Color(0.55, 0.57, 0.62),
		"ambient_tint": Color(0.08, 0.10, 0.12),
		"atmosphere_color": Color(0.45, 0.48, 0.55),
	},
	"light_rain": {
		"coverage": 0.97, "density": 2.4, "sharpness": 0.16, "powder": 0.70,
		"detail_power": 2.0, "lighting_density": 1.4, "lighting_sharpness": 1.1,
		"atmospheric_density": 0.95, "fog_effect_ground": 0.35, "lod_bias": 0.4,
		"cloud_floor": 1500.0, "cloud_ceiling": 3500.0,
		"curl_noise_strength": 3000.0,
		"xl_scale": 290000.0, "large_scale": 16000.0,
		"medium_scale": 3000.0, "small_scale": 1800.0,
		"wind_mul": 1.6, "env_fog_density": 0.00012,
		"ambient_color": Color(0.55, 0.58, 0.65),
		"ambient_tint": Color(0.10, 0.12, 0.15),
		"atmosphere_color": Color(0.42, 0.46, 0.54),
	},
	"heavy_rain": {
		"coverage": 0.99, "density": 5.0, "sharpness": 0.12, "powder": 0.65,
		"detail_power": 2.3, "lighting_density": 3.0, "lighting_sharpness": 1.8,
		"atmospheric_density": 1.0, "fog_effect_ground": 0.40, "lod_bias": 0.0,
		"cloud_floor": 1000.0, "cloud_ceiling": 5000.0,
		"curl_noise_strength": 2500.0,
		"xl_scale": 300000.0, "large_scale": 20000.0,
		"medium_scale": 5000.0, "small_scale": 2500.0,
		"wind_mul": 2.5, "env_fog_density": 0.0002,
		"ambient_color": Color(0.18, 0.20, 0.24),
		"ambient_tint": Color(0.02, 0.03, 0.05),
		"atmosphere_color": Color(0.14, 0.18, 0.24),
	},
	"windstorm": {
		"coverage": 0.92, "density": 3.0, "sharpness": 0.30, "powder": 0.75,
		"detail_power": 2.5, "lighting_density": 1.5, "lighting_sharpness": 1.05,
		"atmospheric_density": 0.90, "fog_effect_ground": 0.25, "lod_bias": 0.3,
		"cloud_floor": 1500.0, "cloud_ceiling": 3800.0,
		"curl_noise_strength": 6000.0,
		"xl_scale": 150000.0, "large_scale": 11000.0,
		"medium_scale": 5000.0, "small_scale": 1800.0,
		"wind_mul": 4.0, "env_fog_density": 0.00012,
		"ambient_color": Color(0.52, 0.55, 0.60),
		"ambient_tint": Color(0.10, 0.12, 0.15),
		"atmosphere_color": Color(0.40, 0.45, 0.52),
	},
	"thunderstorm": {
		"coverage": 0.99, "density": 7.0, "sharpness": 0.12, "powder": 0.65,
		"detail_power": 2.8, "lighting_density": 4.0, "lighting_sharpness": 2.2,
		"atmospheric_density": 1.0, "fog_effect_ground": 0.45, "lod_bias": 0.0,
		"cloud_floor": 800.0, "cloud_ceiling": 6500.0,
		"curl_noise_strength": 2800.0,
		"xl_scale": 300000.0, "large_scale": 18000.0,
		"medium_scale": 4500.0, "small_scale": 2000.0,
		"wind_mul": 3.5, "env_fog_density": 0.0003,
		"ambient_color": Color(0.10, 0.12, 0.16),
		"ambient_tint": Color(0.015, 0.02, 0.04),
		"atmosphere_color": Color(0.10, 0.13, 0.18),
	},
	"smoke_haze": {
		"coverage": 0.55, "density": 1.0, "sharpness": 0.85, "powder": 0.72,
		"detail_power": 2.5, "lighting_density": 0.5, "lighting_sharpness": 0.4,
		"atmospheric_density": 1.0, "fog_effect_ground": 0.90, "lod_bias": 1.0,
		"cloud_floor": 1500.0, "cloud_ceiling": 3500.0,
		"curl_noise_strength": 7000.0,
		"xl_scale": 130000.0, "large_scale": 32000.0,
		"medium_scale": 12000.0, "small_scale": 3500.0,
		"wind_mul": 0.5, "env_fog_density": 0.00015,
		"ambient_color": Color(0.82, 0.62, 0.45),
		"ambient_tint": Color(0.28, 0.18, 0.12),
		"atmosphere_color": Color(0.92, 0.68, 0.42),
	},
}

## Per-weather sky + ground colors for the `ProceduralSkyMaterial`.
## Same blend-by-weight model; day/night blend applied on top.
const _WEATHER_SKY_PRESETS := {
	"clear": {
		"top": Color(0.30, 0.48, 0.72),
		"horizon": Color(0.72, 0.80, 0.82),
		"ground_top": Color(0.50, 0.50, 0.46),
		"ground_bot": Color(0.22, 0.22, 0.20),
	},
	"partly_cloudy": {
		"top": Color(0.32, 0.50, 0.72),
		"horizon": Color(0.74, 0.80, 0.82),
		"ground_top": Color(0.50, 0.50, 0.46),
		"ground_bot": Color(0.22, 0.22, 0.20),
	},
	"overcast": {
		"top": Color(0.55, 0.60, 0.64),
		"horizon": Color(0.72, 0.74, 0.76),
		"ground_top": Color(0.42, 0.42, 0.40),
		"ground_bot": Color(0.20, 0.20, 0.18),
	},
	"marine_layer": {
		"top": Color(0.62, 0.66, 0.70),
		"horizon": Color(0.80, 0.82, 0.84),
		"ground_top": Color(0.45, 0.45, 0.43),
		"ground_bot": Color(0.20, 0.20, 0.19),
	},
	"fog": {
		"top": Color(0.70, 0.72, 0.75),
		"horizon": Color(0.82, 0.84, 0.86),
		"ground_top": Color(0.50, 0.50, 0.48),
		"ground_bot": Color(0.22, 0.22, 0.20),
	},
	"drizzle": {
		"top": Color(0.45, 0.48, 0.52),
		"horizon": Color(0.62, 0.64, 0.68),
		"ground_top": Color(0.38, 0.38, 0.36),
		"ground_bot": Color(0.18, 0.18, 0.16),
	},
	"light_rain": {
		"top": Color(0.38, 0.40, 0.46),
		"horizon": Color(0.55, 0.58, 0.62),
		"ground_top": Color(0.35, 0.35, 0.33),
		"ground_bot": Color(0.16, 0.16, 0.14),
	},
	"heavy_rain": {
		"top": Color(0.28, 0.30, 0.36),
		"horizon": Color(0.42, 0.44, 0.48),
		"ground_top": Color(0.30, 0.30, 0.28),
		"ground_bot": Color(0.14, 0.14, 0.12),
	},
	"windstorm": {
		"top": Color(0.38, 0.42, 0.48),
		"horizon": Color(0.55, 0.58, 0.62),
		"ground_top": Color(0.35, 0.35, 0.33),
		"ground_bot": Color(0.16, 0.16, 0.14),
	},
	"thunderstorm": {
		"top": Color(0.18, 0.20, 0.28),
		"horizon": Color(0.32, 0.34, 0.38),
		"ground_top": Color(0.22, 0.22, 0.20),
		"ground_bot": Color(0.10, 0.10, 0.08),
	},
	"smoke_haze": {
		"top": Color(0.55, 0.42, 0.30),
		"horizon": Color(0.78, 0.55, 0.35),
		"ground_top": Color(0.50, 0.40, 0.30),
		"ground_bot": Color(0.22, 0.18, 0.14),
	},
}

var _sun: DirectionalLight3D = null
var _moon: DirectionalLight3D = null
var _env: Environment = null
var _clouds_driver: Node = null
var _clouds_res: Resource = null
var _color_grade: CompositorEffect = null
var _weather_weights: Dictionary = {}
var _weather_first_frame: bool = true

## Cached `sin(sun_angle_rad)` ∈ [-1,1]. Updated each frame at runtime
## (`_update_sun`) and on every preview apply at edit-time
## (`_apply_preview_sun`) so cloud + sky color blending can factor time
## of day without re-resolving sim.
var _current_sun_elev: float = 0.5

## Scene-default sun/moon state + shared cloud-resource tuning as they
## were at `_ready`. Captured before the first `_apply_editor_preview()`
## so toggling `editor_preview` back off in the inspector restores the
## viewport to the committed .tscn state — preview writes never get
## baked into the scene file silently.
var _rest_snapshot: Dictionary = {}


func _ready() -> void:
	# Group used by gameplay systems (trash physics wind, future
	# weather-driven vfx) to find the active rig without coupling to a
	# specific scene path.
	add_to_group("weather_rigs")
	for kind in WEATHER_KINDS:
		_weather_weights[kind] = 0.0
	_sun = get_node_or_null("Sun") as DirectionalLight3D
	if _sun != null and apply_shadow_defaults:
		# Shadow perf wins applied once at startup. Per-scene .tscn
		# values are overwritten — flip `apply_shadow_defaults = false`
		# on the rig if a scene needs custom shadow tuning.
		_sun.directional_shadow_max_distance = 80.0
		_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	# Moon sits in the scene with `sky_mode = LIGHT_ONLY`, so
	# ProceduralSkyMaterial won't render a sun-disc for it (which is
	# what created the black-splotch bug when the moon was pre-placed
	# with default sky_mode and energy 0). Safe to live in the tree at
	# edit-time now; preview controls drive it.
	_moon = get_node_or_null("Moon") as DirectionalLight3D
	_clouds_driver = get_node_or_null("SunshineCloudsDriver")
	# Wire the clouds driver to the sun (both in editor and runtime).
	# Without this the driver's tracked list stays empty, its @tool
	# `_process` fights the cloud resource's baked `directional_lights_data`
	# each frame (size mismatch → `retrieve_texture_data()` clears the
	# data → shader re-adds defaults → mismatch again), and the editor
	# viewport renders clouds black. Play mode hides the bug because
	# we'd wire the lights here anyway; the fix is to run this path in
	# editor too, which is why the script is `@tool`.
	if _clouds_driver != null and _sun != null:
		var lights: Array[DirectionalLight3D] = [_sun]
		var steps: Array[int] = [4]
		_clouds_driver.tracked_directional_lights = lights
		_clouds_driver.tracked_directional_light_shadow_steps = steps
	# Cache the shared clouds resource ref in both editor and runtime so
	# the preview controls can write to it at edit-time.
	if _clouds_driver != null:
		_clouds_res = _clouds_driver.get("clouds_resource")
	# Resolve the env in both editor and runtime so sky / ambient
	# modulation can run in either. At runtime we duplicate so per-frame
	# mutations don't leak back to the shared .tres; in editor we share
	# and rely on the snapshot/reset path to revert when preview is off.
	var world_env: WorldEnvironment = get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env != null and world_env.environment != null:
		if Engine.is_editor_hint():
			_env = world_env.environment
		else:
			world_env.environment = world_env.environment.duplicate()
			_env = world_env.environment
	if _clouds_driver != null and _env != null:
		_clouds_driver.ambience_sample_environment = _env
	# Resolve the color-grade compositor effect so the rig's `grade_*`
	# exports can drive it. The rig is the source of truth — push initial
	# values immediately so a fresh scene-load reflects whatever's saved
	# on the rig (overriding the .tres).
	if world_env == null:
		push_warning("WeatherRig: no WorldEnvironment child — color grading inactive.")
	elif world_env.compositor == null:
		push_warning("WeatherRig: WorldEnvironment.compositor is null on this scene — color grading inactive. The base weather_rig.tscn ships with a compositor; if a parent .tscn overrides it to null (e.g. cascade_locks_test disables clouds this way), give it a Compositor that includes res://resources/color_grade.tres.")
	else:
		for effect in world_env.compositor.compositor_effects:
			# Prefer a class check, but fall back to resource_path so the
			# resolve still works during editor reloads when the script
			# class index might be transiently stale.
			if effect is ColorGradeEffect or (effect != null and effect.resource_path == "res://resources/color_grade.tres"):
				_color_grade = effect
				break
		if _color_grade == null:
			push_warning("WeatherRig: compositor exists but no ColorGradeEffect found in compositor_effects. Add res://resources/color_grade.tres to the array.")
		else:
			_push_all_color_grade()
	# Snapshot the committed state (env sky material colors, cloud res
	# props, sun/moon transforms) so toggling `editor_preview` off
	# cleanly reverts. Must happen AFTER `_env` is resolved.
	_capture_rest_snapshot()
	if Engine.is_editor_hint():
		_apply_editor_preview()
		return


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var sim := _resolve_sim()
	_update_sun(sim)
	_update_ambient()
	_update_moon(sim)
	_update_weather_weights(delta, sim)
	_apply_weather_to_sky()
	_apply_weather_to_env()
	_apply_weather_to_clouds()
	_apply_weather_to_foliage()


func _resolve_sim() -> Node:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return null
	return session.get_node_or_null("SimHost")


## Sun rotation + energy + color. Caches elevation in `_current_sun_elev`
## so the cloud + sky + ambient updates later in the frame can key off
## time of day without re-resolving sim.
func _update_sun(sim: Node) -> void:
	if _sun == null or sim == null or not sim.has_method("world_time"):
		return
	var time: Dictionary = sim.world_time()
	if time.is_empty():
		return
	var sun_angle: float = time.get("sun_angle_rad", 0.0)
	_sun.rotation = Vector3(-sun_angle, deg_to_rad(45.0), 0.0)
	var elevation := sin(sun_angle)
	_current_sun_elev = elevation
	var energy := clampf(0.04 + elevation * 1.0, 0.01, 1.0)
	var color: Color
	if elevation > 0.3:
		color = Color(1.0, 0.96, 0.88)
	elif elevation > 0.0:
		color = Color(1.0, 0.76, 0.45).lerp(Color(1.0, 0.96, 0.88), elevation / 0.3)
	else:
		color = Color(0.15, 0.18, 0.3)
	var smoke: float = _weather_weights.get("smoke_haze", 0.0)
	if smoke > 0.01:
		color = color.lerp(Color(1.0, 0.45, 0.15), smoke * 0.9)
		energy *= lerp(1.0, 0.55, smoke)
	var heavy: float = _weather_weights.get("heavy_rain", 0.0)
	var thunder: float = _weather_weights.get("thunderstorm", 0.0)
	var light_rn: float = _weather_weights.get("light_rain", 0.0)
	# Hard dim on rain / storm — clouds should block most direct sun.
	var dim: float = max(light_rn * 0.4, heavy * 0.75, thunder * 0.9)
	if dim > 0.01:
		energy *= (1.0 - dim)
	_sun.light_energy = energy
	_sun.light_color = color


## Env ambient energy + color driven by cached sun elevation. Independent
## of weather for now — weather affects the cloud-side ambient/tint
## instead.
func _update_ambient() -> void:
	if _env == null:
		return
	var elevation := _current_sun_elev
	var ambient_e := clampf(0.08 + max(elevation, 0.0) * 0.52, 0.08, 0.6)
	# Heavy weather darkens the whole scene — the cloud layer above is
	# blocking direct light from reaching us, so ambient drops too.
	# Hand-tuned per kind; weighted blend so transitions cross-fade.
	var w_overcast: float = _weather_weights.get("overcast", 0.0)
	var w_drizzle: float = _weather_weights.get("drizzle", 0.0)
	var w_light: float = _weather_weights.get("light_rain", 0.0)
	var w_heavy: float = _weather_weights.get("heavy_rain", 0.0)
	var w_wind: float = _weather_weights.get("windstorm", 0.0)
	var w_thunder: float = _weather_weights.get("thunderstorm", 0.0)
	var w_fog: float = _weather_weights.get("fog", 0.0)
	var w_smoke: float = _weather_weights.get("smoke_haze", 0.0)
	var dim := (
		0.15 * w_overcast
		+ 0.18 * w_drizzle
		+ 0.30 * w_light
		+ 0.55 * w_heavy
		+ 0.30 * w_wind
		+ 0.70 * w_thunder
		+ 0.20 * w_fog
		+ 0.25 * w_smoke
	)
	_env.ambient_light_energy = ambient_e * (1.0 - clampf(dim, 0.0, 0.85))
	var night_t := clampf(-elevation * 2.0, 0.0, 1.0)
	_env.ambient_light_color = Color(0.7, 0.75, 0.85).lerp(
		Color(0.12, 0.15, 0.25), night_t
	)


func _update_moon(sim: Node) -> void:
	if _moon == null or sim == null or not sim.has_method("world_time"):
		return
	var time: Dictionary = sim.world_time()
	if time.is_empty():
		return
	var moon_angle: float = time.get("moon_angle_rad", 0.0)
	var moon_illum: float = time.get("moon_illumination", 0.0)
	var sun_elev: float = sin(time.get("sun_angle_rad", 0.0))
	# Yaw 90° off from the sun so moon + sun shadows don't stack.
	_moon.rotation = Vector3(-moon_angle, deg_to_rad(-45.0), 0.0)
	var night := clampf(1.0 - max(sun_elev, 0.0) * 3.0, 0.0, 1.0)
	var moon_elev := sin(moon_angle)
	var above := clampf(moon_elev, 0.0, 1.0)
	_moon.light_energy = 0.25 * night * moon_illum * above
	var smoke: float = _weather_weights.get("smoke_haze", 0.0)
	if smoke > 0.01:
		_moon.light_color = Color(0.55, 0.65, 0.9).lerp(
			Color(1.0, 0.55, 0.3), smoke * 0.85
		)
	else:
		_moon.light_color = Color(0.55, 0.65, 0.9)


func _update_weather_weights(delta: float, sim: Node) -> void:
	var target_kind: String = _resolve_target_weather(sim)
	if target_kind.is_empty():
		return
	if _weather_first_frame:
		_weather_first_frame = false
		for kind in _weather_weights.keys():
			_weather_weights[kind] = 1.0 if kind == target_kind else 0.0
		return
	var is_heavy: bool = target_kind in [
		"heavy_rain", "thunderstorm", "windstorm", "fog", "smoke_haze"
	]
	var lerp_rate := WEATHER_LERP_RATE_SLOW if is_heavy else WEATHER_LERP_RATE_FAST
	var rate := clampf(lerp_rate * delta, 0.0, 1.0)
	for kind in _weather_weights.keys():
		var target_w := 1.0 if kind == target_kind else 0.0
		var current_w: float = _weather_weights[kind]
		_weather_weights[kind] = lerp(current_w, target_w, rate)


## Test/mood fixtures can pin weather locally by setting `force_weather`;
## otherwise we follow sim.
func _resolve_target_weather(sim: Node) -> String:
	if not force_weather.is_empty():
		return force_weather
	if sim == null or not sim.has_method("weather_state"):
		# No sim wired up (test scenes, standalone map previews). Fall
		# back to whatever the editor preview was set to, OR a sane
		# "clear" default. Returning "" here used to leave
		# `_weather_weights` at its all-zeros initial state, which
		# caused `_apply_weather_to_sky` to compute Color(0, 0, 0)
		# for every sky color → fully black sky in play mode for any
		# scene without a SimHost. Verified during the cloud-removal
		# debugging pass.
		return preview_weather if not preview_weather.is_empty() else "clear"
	var w: Dictionary = sim.weather_state()
	if w.is_empty():
		return preview_weather if not preview_weather.is_empty() else "clear"
	return w.get("current", "clear")


## Subtle native env fog for aerial perspective only. The cloud
## compositor's own atmosphere does the weather-colored heavy lifting;
## this pass is just enough to grey out distant terrain. Densities per
## preset are tuned small (0.00015–0.003 — exponential fog is aggressive
## at higher values). Color stays near a neutral cool-gray with only a
## small weather tint so it doesn't bleed into ground textures.
func _apply_weather_to_env() -> void:
	if _env == null:
		return
	var density := 0.0
	var weather_color := Color(0, 0, 0)
	for kind in _weather_weights.keys():
		var w: float = _weather_weights[kind]
		if w <= 0.0:
			continue
		var p: Dictionary = _WEATHER_CLOUD_PRESETS[kind]
		density += (p["env_fog_density"] as float) * w
		weather_color += (p["atmosphere_color"] as Color) * w
	# Neutral PNW atmospheric-haze gray, with a hint of the weather's
	# atmosphere color mixed in. Keeping weather weight low (~15%) so
	# fog reads as distance haze, not a weather-colored wash.
	var neutral := Color(0.78, 0.80, 0.82)
	var color := neutral.lerp(weather_color, 0.15)
	# Night: darken the neutral so horizon isn't bright under a dark sky.
	var night_t := clampf(-_current_sun_elev * 2.0, 0.0, 1.0)
	color = color.lerp(Color(0.10, 0.12, 0.18), night_t * 0.8)
	_env.fog_enabled = true
	_env.fog_density = density
	_env.fog_light_color = color
	# Don't let native fog wash the sky — the sky material renders its
	# own horizon, and the cloud compositor's `atmospheric_density`
	# handles sky-level haze. `fog_sky_affect` at 1 (default) paints
	# the fog color over the whole sky, which made clear days look
	# completely fogged out. 0 = fog only applies to scene geometry.
	_env.fog_sky_affect = 0.0
	_env.fog_aerial_perspective = 0.0


## Blend per-weather sky + ground colors onto the `ProceduralSkyMaterial`,
## then darken toward a night palette based on `_current_sun_elev`. Runs
## both at runtime (following sim weather) and in editor preview
## (one-hot on `preview_weather`).
func _apply_weather_to_sky() -> void:
	if _env == null or _env.sky == null:
		return
	var sky_mat := _env.sky.sky_material as ProceduralSkyMaterial
	if sky_mat == null:
		return
	var top := Color(0, 0, 0)
	var horizon := Color(0, 0, 0)
	var ground_top := Color(0, 0, 0)
	var ground_bot := Color(0, 0, 0)
	for kind in _weather_weights.keys():
		var w: float = _weather_weights[kind]
		if w <= 0.0:
			continue
		var p: Dictionary = _WEATHER_SKY_PRESETS[kind]
		top += (p["top"] as Color) * w
		horizon += (p["horizon"] as Color) * w
		ground_top += (p["ground_top"] as Color) * w
		ground_bot += (p["ground_bot"] as Color) * w
	var night_t := clampf(-_current_sun_elev * 2.5, 0.0, 1.0)
	top = top.lerp(Color(0.02, 0.03, 0.08), night_t)
	horizon = horizon.lerp(Color(0.05, 0.06, 0.10), night_t)
	ground_top = ground_top.lerp(Color(0.05, 0.05, 0.06), night_t)
	ground_bot = ground_bot.lerp(Color(0.02, 0.02, 0.03), night_t)
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_horizon_color = ground_top
	sky_mat.ground_bottom_color = ground_bot


## Blend per-weather cloud settings (`_WEATHER_CLOUD_PRESETS`) onto the
## compositor resource + driver. Coverage is the primary "roll-in" dial
## (sensitive around 0.8); density pulls clouds overhead; noise scales
## compress under heavy weather so storms read dense/tight. Cloud
## ambient + atmosphere colors then get a day/night lerp on top.
func _apply_weather_to_clouds() -> void:
	if _clouds_res == null:
		return
	# Scalar accumulators.
	var coverage := 0.0
	var density := 0.0
	var sharpness := 0.0
	var powder := 0.0
	var detail_power := 0.0
	var lighting_density := 0.0
	var lighting_sharpness := 0.0
	var atmospheric_density := 0.0
	var fog_effect_ground := 0.0
	var lod_bias := 0.0
	var cloud_floor_blend := 0.0
	var cloud_ceiling_blend := 0.0
	var curl_noise_strength := 0.0
	var xl_scale := 0.0
	var large_scale := 0.0
	var medium_scale := 0.0
	var small_scale := 0.0
	var wind_mul := 0.0
	# Color accumulators (Color * float + Color blends component-wise).
	var ambient_color := Color(0, 0, 0)
	var ambient_tint := Color(0, 0, 0)
	var atmosphere_color := Color(0, 0, 0)
	for kind in _weather_weights.keys():
		var w: float = _weather_weights[kind]
		if w <= 0.0:
			continue
		var p: Dictionary = _WEATHER_CLOUD_PRESETS[kind]
		coverage += (p["coverage"] as float) * w
		density += (p["density"] as float) * w
		sharpness += (p["sharpness"] as float) * w
		powder += (p["powder"] as float) * w
		detail_power += (p["detail_power"] as float) * w
		lighting_density += (p["lighting_density"] as float) * w
		lighting_sharpness += (p["lighting_sharpness"] as float) * w
		atmospheric_density += (p["atmospheric_density"] as float) * w
		fog_effect_ground += (p["fog_effect_ground"] as float) * w
		lod_bias += (p["lod_bias"] as float) * w
		cloud_floor_blend += (p["cloud_floor"] as float) * w
		cloud_ceiling_blend += (p["cloud_ceiling"] as float) * w
		curl_noise_strength += (p["curl_noise_strength"] as float) * w
		xl_scale += (p["xl_scale"] as float) * w
		large_scale += (p["large_scale"] as float) * w
		medium_scale += (p["medium_scale"] as float) * w
		small_scale += (p["small_scale"] as float) * w
		wind_mul += (p["wind_mul"] as float) * w
		ambient_color += (p["ambient_color"] as Color) * w
		ambient_tint += (p["ambient_tint"] as Color) * w
		atmosphere_color += (p["atmosphere_color"] as Color) * w
	# Day/night modulation on the cloud colors. Ambient color fades to
	# deep cool-blue at night; tint drops darker; atmosphere dims.
	var night_t := clampf(-_current_sun_elev * 2.0, 0.0, 1.0)
	ambient_color = ambient_color.lerp(Color(0.20, 0.22, 0.28), night_t)
	ambient_tint = ambient_tint.lerp(Color(0.05, 0.06, 0.08), night_t * 0.8)
	atmosphere_color = atmosphere_color.lerp(Color(0.10, 0.12, 0.18), night_t * 0.9)
	# Push to resource. `enabled` stays true — the rig sets
	# `cloud_coverage_enable_threshold = 0` by default so coverage == 0
	# alone gates rendering inside the shader.
	_clouds_res.set("enabled", true)
	_clouds_res.set("clouds_coverage", clampf(coverage, 0.0, 1.0))
	_clouds_res.set("clouds_density", clampf(density, 0.0, 20.0))
	_clouds_res.set("clouds_sharpness", clampf(sharpness, 0.0, 2.0))
	_clouds_res.set("clouds_powder", clampf(powder, 0.0, 1.0))
	_clouds_res.set("clouds_detail_power", clampf(detail_power, 0.0, 3.0))
	_clouds_res.set("lighting_density", clampf(lighting_density, 0.0, 10.0))
	_clouds_res.set("lighting_sharpness", clampf(lighting_sharpness, 0.0, 2.0))
	_clouds_res.set("atmospheric_density", clampf(atmospheric_density, 0.0, 2.0))
	_clouds_res.set("fog_effect_ground", clampf(fog_effect_ground, 0.0, 1.0))
	_clouds_res.set("lod_bias", clampf(lod_bias, 0.0, 2.0))
	_clouds_res.set("cloud_floor", cloud_floor_blend)
	_clouds_res.set("cloud_ceiling", cloud_ceiling_blend)
	_clouds_res.set("curl_noise_strength", clampf(curl_noise_strength, 0.0, 50000.0))
	_clouds_res.set("extra_large_noise_scale", xl_scale)
	_clouds_res.set("large_noise_scale", large_scale)
	_clouds_res.set("medium_noise_scale", medium_scale)
	_clouds_res.set("small_noise_scale", small_scale)
	_clouds_res.set("cloud_ambient_color", ambient_color)
	_clouds_res.set("cloud_ambient_tint", ambient_tint)
	_clouds_res.set("atmosphere_color", atmosphere_color)
	if _clouds_driver != null:
		var max_w := 0.0
		for kind in _weather_weights.keys():
			var wv: float = _weather_weights[kind]
			if wv > max_w:
				max_w = wv
		# During transitions (no single weight dominant), boost wind so
		# clouds appear to blow in with the wind rather than materialize
		# everywhere at once.
		var transition_boost := clampf((1.0 - max_w) * 4.0, 1.0, 3.0)
		var wind := wind_mul * transition_boost
		_clouds_driver.set("medium_structures_wind_speed", 40.0 * wind)
		_clouds_driver.set("small_structures_wind_speed", 12.0 * wind)
		_clouds_driver.set("large_structures_wind_speed", 100.0 * wind)
		_clouds_driver.set("extra_large_structures_wind_speed", 140.0 * transition_boost)


## Drive `foliage_card.gdshader` global wind uniforms from the same
## weather-weight blend the cloud system uses. Strength scales linearly
## with `wind_mul` (0.4 fog → 4.0 windstorm); speed scales sublinear via
## `sqrt` so blade sway frequency doesn't go frantic at storm levels —
## the visual story is "stronger sway", not "vibrating blades."
##
## Globals are declared in project.godot's `[shader_globals]` so the
## shader has working defaults if no WeatherRig is in the scene; this
## function overrides those defaults each frame the rig is active.
const _FOLIAGE_WIND_STRENGTH_BASE: float = 0.12
const _FOLIAGE_WIND_SPEED_BASE: float = 1.7

func _apply_weather_to_foliage() -> void:
	# Same wind_mul accumulation as the cloud function — pull from
	# _WEATHER_CLOUD_PRESETS so a single number governs both systems.
	var wind_mul := 0.0
	var max_w := 0.0
	for kind in _weather_weights.keys():
		var w: float = _weather_weights[kind]
		if w <= 0.0:
			continue
		var p: Dictionary = _WEATHER_CLOUD_PRESETS[kind]
		wind_mul += (p["wind_mul"] as float) * w
		if w > max_w:
			max_w = w

	# Mid-transition gust boost — not as strong as the cloud-side boost
	# (we don't want trees thrashing wildly during a routine 1pm light-
	# rain handoff), but enough to read as "wind picking up before the
	# weather lands."
	var transition_boost := clampf((1.0 - max_w) * 1.5, 1.0, 1.4)
	var effective := wind_mul * transition_boost

	var strength := _FOLIAGE_WIND_STRENGTH_BASE * effective
	var speed := _FOLIAGE_WIND_SPEED_BASE * sqrt(maxf(effective, 0.0))
	RenderingServer.global_shader_parameter_set(
		"foliage_wind_strength", strength)
	RenderingServer.global_shader_parameter_set(
		"foliage_wind_speed", speed)
	# Cache the same `effective` magnitude for `wind_strength()`. Reusing
	# the foliage curve keeps physics gusts and visible foliage sway in
	# lockstep — when the trees are thrashing, the trash also gets blown.
	_current_wind_strength = effective


# Public wind API — read by trash physics + future wind-driven systems.
# `cloud_wind_direction` is the rig's authored wind vector (not
# normalized); we project to XZ and normalize for gameplay use. Strength
# follows the same `wind_mul × transition_boost` curve foliage uses, so
# physics gusts read as in-step with foliage sway.
var _current_wind_strength: float = 0.0


## Horizontal wind direction (XZ, world-space, unit vector). Always a
## valid normalized Vector2 — falls back to (1, 0) if the configured
## wind direction is zero on XZ. Z component flipped to match Godot's
## right-handed world axes (forward = -Z).
func wind_direction_xz() -> Vector2:
	var v := Vector2(cloud_wind_direction.x, cloud_wind_direction.z)
	if v.length_squared() < 1e-6:
		return Vector2(1.0, 0.0)
	return v.normalized()


## Current wind strength, 0 = calm, ~1 = light breeze, ~4 = windstorm.
## Same `effective` value pushed into `foliage_wind_strength` (modulo
## the foliage base scalar), so trash physics gusts blend with visible
## foliage sway.
func wind_strength() -> float:
	return _current_wind_strength


## Convenience: horizontal wind vector with magnitude (XZ direction
## scaled by strength). Returns zero when calm.
func wind_vector_xz() -> Vector2:
	return wind_direction_xz() * _current_wind_strength


## Snap cloud + sun visuals to the `preview_*` exports. Editor-only; the
## setters fire during scene instancing (before `_ready`) and again on any
## inspector change. Guarded on `_clouds_res` / `_sun` so the early calls
## before `_ready` is done just no-op — `_ready` finishes with a final
## apply so the initial preview matches the inspector.
## Maps rig-side export name → `SunshineCloudsGD` property name. Driven
## by the helpers below so a new override field is a one-line addition.
const _CLOUD_RES_FIELD_MAP := [
	["cloud_coverage", "clouds_coverage"],
	["cloud_density", "clouds_density"],
	["cloud_atmospheric_density", "atmospheric_density"],
	["cloud_lighting_density", "lighting_density"],
	["cloud_use_environment_fog", "use_environment_fog"],
	["cloud_fog_effect_ground", "fog_effect_ground"],
	["cloud_ambient_color", "cloud_ambient_color"],
	["cloud_ambient_tint", "cloud_ambient_tint"],
	["cloud_atmosphere_color", "atmosphere_color"],
	["cloud_ambient_occlusion_color", "ambient_occlusion_color"],
	["cloud_anisotropy", "clouds_anisotropy"],
	["cloud_powder", "clouds_powder"],
	["cloud_lighting_sharpness", "lighting_sharpness"],
	["cloud_lighting_travel_distance", "lighting_travel_distance"],
	["cloud_sharpness", "clouds_sharpness"],
	["cloud_detail_power", "clouds_detail_power"],
	["cloud_accumulation_decay", "accumulation_decay"],
	["cloud_extra_large_noise_scale", "extra_large_noise_scale"],
	["cloud_large_noise_scale", "large_noise_scale"],
	["cloud_medium_noise_scale", "medium_noise_scale"],
	["cloud_small_noise_scale", "small_noise_scale"],
	["cloud_curl_noise_strength", "curl_noise_strength"],
	["cloud_wind_swept_range", "wind_swept_range"],
	["cloud_wind_swept_strength", "wind_swept_strength"],
	["cloud_floor", "cloud_floor"],
	["cloud_ceiling", "cloud_ceiling"],
	["cloud_extra_large_used_as_mask", "extra_large_used_as_mask"],
	["cloud_mask_width_km", "mask_width_km"],
	["cloud_max_step_count", "max_step_count"],
	["cloud_max_lighting_steps", "max_lighting_steps"],
	["cloud_lod_bias", "lod_bias"],
	["cloud_min_step_distance", "min_step_distance"],
	["cloud_max_step_distance", "max_step_distance"],
	["cloud_dither_speed", "dither_speed"],
	["cloud_blur_power", "blur_power"],
	["cloud_blur_quality", "blur_quality"],
]

## Maps rig-side export name → `SunshineCloudsDriver` property name.
const _CLOUD_DRV_FIELD_MAP := [
	["cloud_wind_direction", "wind_direction"],
	["cloud_extra_large_wind_speed", "extra_large_structures_wind_speed"],
	["cloud_large_wind_speed", "large_structures_wind_speed"],
	["cloud_medium_wind_speed", "medium_structures_wind_speed"],
	["cloud_small_wind_speed", "small_structures_wind_speed"],
	["cloud_directional_light_power_multiplier", "directional_light_power_multiplier"],
]


## Setter helper: push one rig export value to the cloud compositor
## resource. Guards on editor-preview-on so slider drags in play mode
## (impossible today, but robust) and out-of-editor invocations no-op.
func _w_res(prop: String, value) -> void:
	if Engine.is_editor_hint() and editor_preview and _clouds_res != null:
		_clouds_res.set(prop, value)


## Setter helper for driver-level properties (wind speeds, wind direction).
func _w_drv(prop: String, value) -> void:
	if Engine.is_editor_hint() and editor_preview and _clouds_driver != null:
		_clouds_driver.set(prop, value)


## Setter helper for color-grade properties. Unlike `_w_res` this is
## NOT gated on `editor_preview` — color grading has no weather formula
## yet, so the rig's @exports are the source of truth in both editor and
## runtime.
func _w_grade(prop: String, value) -> void:
	if _color_grade != null:
		_color_grade.set(prop, value)


## Push every grade override to the color_grade compositor effect at
## once. Called from `_ready` so a fresh scene load syncs immediately.
func _push_all_color_grade() -> void:
	if _color_grade == null:
		return
	for pair in _GRADE_FIELD_MAP:
		_color_grade.set(pair[1], get(pair[0]))


## Push every cloud override export to the compositor resource + driver
## at once. Called when `editor_preview` flips on (individual setters
## handle incremental pushes thereafter).
func _push_all_cloud_overrides() -> void:
	if _clouds_res != null:
		for pair in _CLOUD_RES_FIELD_MAP:
			_clouds_res.set(pair[1], get(pair[0]))
		_clouds_res.set("enabled", cloud_coverage > cloud_coverage_enable_threshold)
	if _clouds_driver != null:
		for pair in _CLOUD_DRV_FIELD_MAP:
			_clouds_driver.set(pair[1], get(pair[0]))


## Run the weather formula with a one-hot weight on `preview_weather`,
## write the output into the shared cloud resource, then mirror those
## values back into the rig's override exports so the inspector shows
## the starting point for tuning. Called by the "Load preset" tool
## button. After this, tweak individual sliders; each push updates the
## viewport live.
func _load_preset_into_overrides() -> void:
	if _clouds_res == null or _clouds_driver == null:
		return
	if not Engine.is_editor_hint():
		return
	# Snap weights one-hot on preview_weather and push the formula to
	# sky, env fog, and clouds all at once so the viewport reflects the
	# full weather look immediately.
	for kind in _weather_weights.keys():
		_weather_weights[kind] = 1.0 if kind == preview_weather else 0.0
	_apply_weather_to_sky()
	_apply_weather_to_env()
	_apply_weather_to_clouds()
	# Mirror the formula's output (the handful of properties it writes)
	# back into the corresponding exports. Unrelated exports keep their
	# current values — the formula doesn't claim authority over things
	# like anisotropy or step counts.
	cloud_coverage = _clouds_res.get("clouds_coverage")
	cloud_sharpness = _clouds_res.get("clouds_sharpness")
	cloud_density = _clouds_res.get("clouds_density")
	cloud_powder = _clouds_res.get("clouds_powder")
	cloud_detail_power = _clouds_res.get("clouds_detail_power")
	cloud_lighting_density = _clouds_res.get("lighting_density")
	cloud_lighting_sharpness = _clouds_res.get("lighting_sharpness")
	cloud_atmospheric_density = _clouds_res.get("atmospheric_density")
	cloud_fog_effect_ground = _clouds_res.get("fog_effect_ground")
	cloud_lod_bias = _clouds_res.get("lod_bias")
	cloud_floor = _clouds_res.get("cloud_floor")
	cloud_ceiling = _clouds_res.get("cloud_ceiling")
	cloud_curl_noise_strength = _clouds_res.get("curl_noise_strength")
	cloud_ambient_color = _clouds_res.get("cloud_ambient_color")
	cloud_ambient_tint = _clouds_res.get("cloud_ambient_tint")
	cloud_atmosphere_color = _clouds_res.get("atmosphere_color")
	cloud_extra_large_noise_scale = _clouds_res.get("extra_large_noise_scale")
	cloud_large_noise_scale = _clouds_res.get("large_noise_scale")
	cloud_medium_noise_scale = _clouds_res.get("medium_noise_scale")
	cloud_small_noise_scale = _clouds_res.get("small_noise_scale")
	cloud_extra_large_wind_speed = _clouds_driver.get("extra_large_structures_wind_speed")
	cloud_large_wind_speed = _clouds_driver.get("large_structures_wind_speed")
	cloud_medium_wind_speed = _clouds_driver.get("medium_structures_wind_speed")
	cloud_small_wind_speed = _clouds_driver.get("small_structures_wind_speed")


func _apply_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	if not editor_preview:
		return
	if _clouds_res == null or _sun == null:
		return
	# Sun first so `_current_sun_elev` is fresh for the sky + cloud
	# color day/night lerps that run below.
	_apply_preview_sun()
	_apply_preview_moon()
	# Snap weights to a one-hot of `preview_weather` so the sky + env-fog
	# preset blends match the dropdown. Cloud visuals come from the
	# override sliders (not the formula), so we push those separately.
	for kind in _weather_weights.keys():
		_weather_weights[kind] = 1.0 if kind == preview_weather else 0.0
	_apply_weather_to_sky()
	_apply_weather_to_env()
	_push_all_cloud_overrides()


## Sun rotation + energy + color from `preview_sun_elevation_deg`, using
## the same day/night blend curve the runtime path applies from sim's
## `sun_angle_rad`. Ambient isn't previewed — it lives on the shared env
## which we don't mutate at edit-time.
func _apply_preview_sun() -> void:
	if _sun == null:
		return
	var sun_angle_rad := deg_to_rad(preview_sun_elevation_deg)
	_sun.rotation = Vector3(-sun_angle_rad, deg_to_rad(45.0), 0.0)
	var elevation := sin(sun_angle_rad)
	_current_sun_elev = elevation
	_sun.light_energy = clampf(0.04 + elevation * 1.0, 0.01, 1.0)
	var color: Color
	if elevation > 0.3:
		color = Color(1.0, 0.96, 0.88)
	elif elevation > 0.0:
		color = Color(1.0, 0.76, 0.45).lerp(Color(1.0, 0.96, 0.88), elevation / 0.3)
	else:
		color = Color(0.15, 0.18, 0.3)
	_sun.light_color = color


## Moon rotation + energy + color from `preview_moon_*` exports, gated
## by `preview_sun_elevation_deg` so the moon only contributes when the
## sun is below the horizon (same "night" factor the runtime path uses).
func _apply_preview_moon() -> void:
	if _moon == null:
		return
	var moon_angle_rad := deg_to_rad(preview_moon_elevation_deg)
	var sun_elev := sin(deg_to_rad(preview_sun_elevation_deg))
	_moon.rotation = Vector3(-moon_angle_rad, deg_to_rad(-45.0), 0.0)
	var night := clampf(1.0 - max(sun_elev, 0.0) * 3.0, 0.0, 1.0)
	var moon_elev := sin(moon_angle_rad)
	var above := clampf(moon_elev, 0.0, 1.0)
	_moon.light_energy = 0.25 * night * preview_moon_illumination * above
	_moon.light_color = Color(0.55, 0.65, 0.9)


## Grab the committed values of everything the preview path writes to,
## so `_reset_editor_preview` can fully roll back. Covers every field
## in `_CLOUD_RES_FIELD_MAP` + `_CLOUD_DRV_FIELD_MAP` plus sun + moon.
func _capture_rest_snapshot() -> void:
	_rest_snapshot = {}
	if _sun != null:
		_rest_snapshot["sun_transform"] = _sun.transform
		_rest_snapshot["sun_energy"] = _sun.light_energy
		_rest_snapshot["sun_color"] = _sun.light_color
	if _moon != null:
		_rest_snapshot["moon_transform"] = _moon.transform
		_rest_snapshot["moon_energy"] = _moon.light_energy
		_rest_snapshot["moon_color"] = _moon.light_color
	if _env != null:
		_rest_snapshot["env_ambient_energy"] = _env.ambient_light_energy
		_rest_snapshot["env_ambient_color"] = _env.ambient_light_color
		_rest_snapshot["env_fog_enabled"] = _env.fog_enabled
		_rest_snapshot["env_fog_density"] = _env.fog_density
		_rest_snapshot["env_fog_light_color"] = _env.fog_light_color
		_rest_snapshot["env_fog_sky_affect"] = _env.fog_sky_affect
		_rest_snapshot["env_fog_aerial_perspective"] = _env.fog_aerial_perspective
		if _env.sky != null:
			var sky_mat := _env.sky.sky_material as ProceduralSkyMaterial
			if sky_mat != null:
				_rest_snapshot["sky_top"] = sky_mat.sky_top_color
				_rest_snapshot["sky_horizon"] = sky_mat.sky_horizon_color
				_rest_snapshot["sky_ground_top"] = sky_mat.ground_horizon_color
				_rest_snapshot["sky_ground_bot"] = sky_mat.ground_bottom_color
	if _clouds_res != null:
		_rest_snapshot["res_enabled"] = _clouds_res.get("enabled")
		for pair in _CLOUD_RES_FIELD_MAP:
			_rest_snapshot["res_" + String(pair[1])] = _clouds_res.get(pair[1])
	if _clouds_driver != null:
		for pair in _CLOUD_DRV_FIELD_MAP:
			_rest_snapshot["drv_" + String(pair[1])] = _clouds_driver.get(pair[1])


## Undo any `_apply_editor_preview` mutations, leaving the sun, moon,
## shared clouds resource, and driver at the values the scene shipped
## with.
func _reset_editor_preview() -> void:
	if _rest_snapshot.is_empty():
		return
	if _sun != null and _rest_snapshot.has("sun_transform"):
		_sun.transform = _rest_snapshot["sun_transform"]
		_sun.light_energy = _rest_snapshot["sun_energy"]
		_sun.light_color = _rest_snapshot["sun_color"]
	if _moon != null and _rest_snapshot.has("moon_transform"):
		_moon.transform = _rest_snapshot["moon_transform"]
		_moon.light_energy = _rest_snapshot["moon_energy"]
		_moon.light_color = _rest_snapshot["moon_color"]
	if _env != null and _rest_snapshot.has("env_ambient_energy"):
		_env.ambient_light_energy = _rest_snapshot["env_ambient_energy"]
		_env.ambient_light_color = _rest_snapshot["env_ambient_color"]
		_env.fog_enabled = _rest_snapshot["env_fog_enabled"]
		_env.fog_density = _rest_snapshot["env_fog_density"]
		_env.fog_light_color = _rest_snapshot["env_fog_light_color"]
		_env.fog_sky_affect = _rest_snapshot["env_fog_sky_affect"]
		_env.fog_aerial_perspective = _rest_snapshot["env_fog_aerial_perspective"]
		if _env.sky != null:
			var sky_mat := _env.sky.sky_material as ProceduralSkyMaterial
			if sky_mat != null and _rest_snapshot.has("sky_top"):
				sky_mat.sky_top_color = _rest_snapshot["sky_top"]
				sky_mat.sky_horizon_color = _rest_snapshot["sky_horizon"]
				sky_mat.ground_horizon_color = _rest_snapshot["sky_ground_top"]
				sky_mat.ground_bottom_color = _rest_snapshot["sky_ground_bot"]
	if _clouds_res != null:
		if _rest_snapshot.has("res_enabled"):
			_clouds_res.set("enabled", _rest_snapshot["res_enabled"])
		for pair in _CLOUD_RES_FIELD_MAP:
			var key: String = "res_" + String(pair[1])
			if _rest_snapshot.has(key):
				_clouds_res.set(pair[1], _rest_snapshot[key])
	if _clouds_driver != null:
		for pair in _CLOUD_DRV_FIELD_MAP:
			var key: String = "drv_" + String(pair[1])
			if _rest_snapshot.has(key):
				_clouds_driver.set(pair[1], _rest_snapshot[key])
