@tool
class_name FoliageGlobals
extends Resource
## Shader-side foliage globals as a single inspectable resource.
##
## All parameters here map 1:1 to `global uniform` declarations in
## `shaders/ground_cover_dynamic.gdshader`. The values are pushed via
## `RenderingServer.global_shader_parameter_set` — the project also
## ships defaults in `project.godot` under `[shader_globals]`, but
## a `FoliageGlobals` resource attached to a `GroundCoverScatter`
## overrides those at runtime / in editor preview.
##
## **Cost of editing these:** zero rebake, zero tile-rebuild. The
## values are pushed every frame by the scatter (in editor) or at
## startup + on signal (at runtime), so dragging a slider in the
## inspector is reflected immediately on the next frame.
##
## See `docs/book/src/walkthroughs/foliage.md` for the broader
## "what triggers what rebuild" matrix.

@export_group("Wind")
## Side-to-side amplitude in world meters at the top of a 1m-tall
## plant (scales linearly with vertex height). 0.0 = no wind, 0.2 =
## strong gusts.
@export_range(0.0, 0.5, 0.005) var wind_strength: float = 0.12

## Animation speed multiplier (radians per second of TIME). 1.0 = a
## complete sway cycle every ~6.3s; 2.0 = twice as fast.
@export_range(0.0, 6.0, 0.05) var wind_speed: float = 1.7

@export_group("View-cone density")
## Full-density radius along the camera forward direction (meters).
## Plants beyond this distance are GPU-culled regardless of cone
## position.
@export_range(8.0, 200.0, 1.0) var radius_front: float = 95.0

## Radius behind the camera (meters). Smaller values save draw calls
## but expose pop-in if the camera spins. Should typically be a
## fraction of `radius_front`.
@export_range(4.0, 120.0, 1.0) var radius_rear: float = 20.0

## Half-angle (degrees) of the "always full density" cone in front
## of the camera. Inside this cone every instance whose roll is in
## the kept fraction is drawn. 45° gives a tight forward focus; 90°
## fills most of the screen with full density.
@export_range(5.0, 175.0, 1.0) var cone_full_deg: float = 45.0

## Half-angle (degrees) outside which density falls to `density_rear`.
## Between `cone_full_deg` and this angle, density linearly ramps
## from full down to `density_periph`.
@export_range(5.0, 180.0, 1.0) var cone_periph_deg: float = 110.0

## Density multiplier at the `cone_periph_deg` boundary (0..1).
## 0.5 = half the plants visible at the edge of the periph cone.
@export_range(0.0, 1.0, 0.01) var density_periph: float = 0.5

## Density multiplier behind the periph cone (0..1). Usually the
## smallest of the three since you can't see what's behind you.
@export_range(0.0, 1.0, 0.01) var density_rear: float = 0.2

@export_group("Per-tier scatter radius")
## CPU-side cull: species with `size_tier = SMALL` (ground cover —
## moss, ferns, weeds) only spawn in tiles within this distance from
## the player. Past this radius they're not even baked. Saves the
## fragment cost of grass blades the player will never see clearly.
@export_range(8.0, 200.0, 1.0) var tier_radius_small_m: float = 35.0

## Same idea, MEDIUM tier (mid-canopy plants, knee-height shrubs).
@export_range(16.0, 200.0, 1.0) var tier_radius_medium_m: float = 60.0

## Same idea, LARGE tier (waist-high+ bushes, saplings, dead trunks).
## Should be at most `GroundCoverScatter.active_radius_m`; tiles beyond
## that don't bake at all regardless of tier.
@export_range(32.0, 240.0, 1.0) var tier_radius_large_m: float = 90.0

## Width of the soft-cull dither band before each cull boundary
## (meters). Density ramps from 1.0 at `cull_radius - fade_band_m`
## down to 0.0 at `cull_radius`; the fragment shader dithers pixels
## by density so plants dissolve smoothly instead of popping. Bump
## up if you can still see the cull edge; drop if the dither noise
## reads too far inward.
@export_range(0.5, 30.0, 0.5) var fade_band_m: float = 12.0


## Names of globals we've confirmed exist on the renderer this session.
## Editor-only state — at runtime we don't query the renderer at all,
## just trust `project.godot → [shader_globals]` registered everything
## at engine init.
static var _known_globals: Dictionary = {}


## Push a float global. Behavior diverges by mode:
##
## **Editor**: dynamically registers new globals via `_get_list` +
## `_add`. Lets us add a uniform to a `.gdshader` and see it pushed
## without restarting the editor (otherwise we'd have to add it to
## `project.godot` and reload). The `_get_list` and `_add` calls are
## editor-only — calling them at runtime warns and may corrupt
## state.
##
## **Runtime**: only `_set`. Assumes the global was registered via
## `project.godot → [shader_globals]` at engine init. If a param
## isn't in `[shader_globals]`, the `_set` call warns once and is a
## no-op. Skipping the `_get_list / _add` dance avoids the
## "should never be used outside the editor" errors AND dodges the
## `has(p_name) is true` add-while-already-registered crash.
static func _set_global_float(name: String, value: float) -> void:
	if Engine.is_editor_hint():
		if not _known_globals.has(name):
			_known_globals.clear()
			for g_name in RenderingServer.global_shader_parameter_get_list():
				_known_globals[String(g_name)] = true
			if not _known_globals.has(name):
				RenderingServer.global_shader_parameter_add(
					name, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, value)
				_known_globals[name] = true
	RenderingServer.global_shader_parameter_set(name, value)


## Push every value to the RenderingServer global shader parameter
## table. Cheap (8 setters); call once per frame from the scatter.
func apply_to_renderer() -> void:
	_set_global_float("foliage_wind_strength", wind_strength)
	_set_global_float("foliage_wind_speed", wind_speed)
	_set_global_float("gc_radius_front", radius_front)
	_set_global_float("gc_radius_rear", radius_rear)
	# Cone angles convert to dot-product thresholds at push time so
	# the inspector shows human-readable degrees while the shader
	# does the cheap dot comparison without a per-pixel acos.
	_set_global_float("gc_cone_full_cos", cos(deg_to_rad(cone_full_deg)))
	_set_global_float("gc_cone_periph_cos", cos(deg_to_rad(cone_periph_deg)))
	_set_global_float("gc_density_periph", density_periph)
	_set_global_float("gc_density_rear", density_rear)
	# Per-tier distance cull bands (GPU-side, applied per-instance via
	# `INSTANCE_CUSTOM.y`).
	_set_global_float("gc_tier_radius_small", tier_radius_small_m)
	_set_global_float("gc_tier_radius_medium", tier_radius_medium_m)
	_set_global_float("gc_tier_radius_large", tier_radius_large_m)
	_set_global_float("gc_fade_band_m", fade_band_m)
