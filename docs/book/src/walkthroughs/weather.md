# Weather & Time of Day

PNW-inflected weather and a full day / night / moon cycle run on the server sim and the Godot client mirrors them. The player sees overcast drizzle turn into thunderstorms, a moon wax and wane over real time, sunset hit with an orange cast - none of it is staged per-scene. Every map you load inherits the same live rig.

## Server is authoritative

The sim owns two pieces of state that feed the visuals:

- **`WorldTime`** (`crates/simn-sim/src/resources.rs`) - `day: u32`, `seconds_of_day: f32`, `day_length_seconds: f32`. Default `day_length_seconds = 7200` means 2 real hours = 1 in-world day. Exposes `sun_angle_rad()`, `moon_angle_rad()`, `moon_illumination()`, `is_daytime()`. Moon cycle is `LUNAR_CYCLE_DAYS = 29.53` so phase drifts across in-world weeks.
- **`WeatherState`** - `current: Weather`, `next: Weather`, `transitions_at_tick: u64`. 11 variants (`Clear`, `PartlyCloudy`, `Overcast`, `MarineLayer`, `Fog`, `Drizzle`, `LightRain`, `HeavyRain`, `Windstorm`, `Thunderstorm`, `SmokeHaze`) matched to PNW climate: heavy bias on the overcast / drizzle / light-rain band with rarer marine-layer and seasonal smoke-haze. A Markov-chain transition in `systems/weather.rs` rolls a new target every 1800 in-game seconds (30 in-world minutes) with hand-authored next-state weights so `Clear → PartlyCloudy → Overcast → Drizzle` feels plausible and storms don't drop in from nowhere.

Both resources tick inside the sim schedule and serialize with the rest of the world on journal / snapshot save. Joiners replicating the sim see the same weather the host sees. Per-region weather is flagged as TODO in `systems/weather.rs` - today the whole world shares one `WeatherState`.

## GDScript reads, never writes

`simn-godot` exposes two `#[func]`s on `SimHost`:

- `world_time() → Dictionary { day, seconds_of_day, day_fraction, sun_angle_rad, moon_angle_rad, moon_illumination, is_daytime }`
- `weather_state() → Dictionary { current, next, transitions_at_tick }`

And two debug-only mutators: `set_weather(name)` / `cycle_weather()` for hotkey iteration. These aren't used by the rig; they're for dev iteration via the debug overlay.

## The weather rig

`godot/scenes/weather/weather_rig.tscn` is the client-side rig. Every map - production and test - instances it as a child. The rig owns:

- `WorldEnvironment` pointing at shared `res://resources/default_environment.tres`, with a `Compositor` holding the SunshineClouds2 effect (`res://resources/noosphere_clouds.tres`).
- `Sun` (`DirectionalLight3D`) - rotated + recolored per `sun_angle_rad`.
- `Moon` (`DirectionalLight3D`) - rotated per `moon_angle_rad`, energy scaled by `moon_illumination` and current night-ness.
- `SunshineCloudsDriver` - wires the cloud shader to the sun for light-through-cloud shading.

`godot/scripts/weather_rig.gd` polls the sim each frame and drives everything:

1. **Time of day.** Sun rotation from `sun_angle_rad`. Energy from `sin(sun_angle)` so it peaks at noon and floors near zero at night. Ambient energy + ambient tint + procedural sky top / horizon colors lerp toward a night palette based on sun elevation. Moon light fades in as the sun sets, scaled by `moon_illumination` and `sin(moon_angle)` so it only contributes when the moon is up.
2. **Weather weights.** Each frame the rig lerps a per-kind weight dictionary (`clear`, `overcast`, etc., summing near 1) toward a one-hot of the sim's `current` weather. Rate is slower for heavy fronts (`fog`, `windstorm`, `thunderstorm`, `smoke_haze`, `heavy_rain`) so they read as rolling in. First frame snaps instead of lerping from zero so you don't watch clouds draw in from nothing on scene load.
3. **Apply to sky.** Each weather kind has an entry in `_WEATHER_SKY_PRESETS` (sky top, sky horizon, ground top, ground bottom colors). The rig blends by weight and then lerps toward a deep-night palette based on `_current_sun_elev`.
4. **Apply to clouds.** Each weather kind has an entry in `_WEATHER_CLOUD_PRESETS` naming every value the rig writes to the compositor - coverage, density, sharpness, powder, detail power, atmospheric density, fog-effect-ground, curl noise strength, all four noise scales (XL / L / M / S), wind multiplier, and three colors (ambient, ambient tint, atmosphere). The rig sums each field weighted by its kind's weight, then lerps the color fields toward a cool-blue night palette. Tuning principles baked into the presets (from 2026-04-24 playtesting):
   - Coverage is sensitive around 0.8 - below reads as distant clouds, cranked = full overcast. Use as the primary "roll-in" dial.
   - Density pulls clouds overhead vs. horizon.
   - Powder ≈ 0.75 normal, 0.85 ominous weather.
   - Detail power maxed at 3 for cumulus, dropped for flat/heavy weather.
   - Noise scales compress for storms (tight features), stretch for clear (distant wisps).
   - Curl noise low = thick clouds, high = broken wispy.
   - Atmospheric density + `fog_effect_ground` replace native env fog - the cloud compositor's atmosphere is easier to control and integrates with cloud rendering.
5. **Wind.** Scales all four driver wind tiers by the preset's `wind_mul`, with a transition-boost (up to 3×) during weather cross-fades so clouds appear to blow in rather than materialize in place. The same `wind_mul × transition_boost` blend is exposed to gameplay code via `WeatherRig.wind_strength()` (scalar) and `WeatherRig.wind_vector_xz()` (Vector2: horizontal direction × strength), driven from the authored `cloud_wind_direction` Vector3. Trash physics polls these every wind tick to apply gust impulses to lightweight items - the rig is in the `weather_rigs` group so consumers can resolve it via `get_tree().get_first_node_in_group("weather_rigs")` without coupling to a specific scene path.
6. **Env resource safety.** The rig calls `Environment.duplicate()` on `_ready()` at runtime so per-frame mutations don't leak back to the shared `default_environment.tres`. In editor preview mode, the rig shares the env but snapshots the committed state; toggling `editor_preview` off restores it fully.

## Extension points

- **Editor preview.** Open `godot/scenes/weather/weather_rig.tscn` (or click the rig instance in any map scene), toggle `editor_preview` on, and use the preview controls to iterate live in the viewport. The rig is `@tool` so inspector changes apply immediately.
  - `preview_weather` picks a weather kind for the "Load preset" button; changing the dropdown alone doesn't apply anything so you don't lose tweaks by switching.
  - `preview_sun_elevation_deg` rotates the sun and reruns the dawn/dusk/midday/night color curve (same curve the runtime uses from `sim.world_time().sun_angle_rad`).
  - `preview_moon_elevation_deg` + `preview_moon_illumination` rotate and light the moon; it only contributes when `preview_sun_elevation_deg < 0` (same `night` factor the runtime path applies).
  - **Cloud overrides** - every knob on `SunshineCloudsGD` (the compositor effect) and `SunshineCloudsDriver` (the node) is mirrored as an inspector slider/picker: coverage, density, sharpness, atmospheric density, lighting density, anisotropy, powder, cloud/atmosphere/AO colors, all four noise scales (extra-large / large / medium / small), curl noise strength, accumulation decay, wind-sweep, floor, ceiling, mask settings, render performance knobs (step counts, blur, dither, lighting steps), and driver-level wind direction + per-tier wind speeds. Each slider pushes directly to the shared resource/driver. Use the **Load preset from preview_weather** tool button to snap the formula-driven overrides (coverage / sharpness / density / atmo density / colors / noise scales / wind speeds) to whatever `_apply_weather_to_clouds` would output for the selected kind, then tune from there.
  - Editor preview is a one-way push into the shared cloud compositor + the rig's sun/moon lights; it never calls the sim and is fully ignored at runtime - runtime always drives the moon procedurally from `sim.world_time()`. Toggling `editor_preview` off restores the rig to its committed .tscn state (snapshot captured on `_ready`), so preview writes can't silently leak into saved scenes.
- **Pin a mood for screenshots / test scenes.** Set `force_weather = "thunderstorm"` (or any kind) on the `WeatherRig` instance in a scene. The rig skips the sim poll and clamps the weight dictionary to that kind at *runtime*. Use this in `godot/scenes/test/*.tscn` if you need a fixed mood for playtesting; use `sim.set_weather(...)` / `cycle_weather()` during gameplay to drive the actual authoritative state.
- **Per-map static overrides.** Production maps under `godot/scenes/maps/*.tscn` (and freshly-baked maps via `write_scene_once` in `crates/simn-terrain/src/bake.rs`) declare `[editable path="WeatherRig"]`, so the `WorldEnvironment`, `Sun`, `Moon`, and `SunshineCloudsDriver` children are exposed in the inspector and per-map tweaks land as scene overrides on that map only. Caveat: anything `weather_rig.gd` writes every frame (sun rotation, env fog density/tint, sky day/night blend) is clobbered at runtime - only static fields survive. Use this for region-specific knobs the rig doesn't drive, or for an extra fill light parented under the rig.
- **Tune once, apply everywhere.** Change cloud coverage curves, fog density multipliers, sun color blends, etc. in `weather_rig.gd` and every map picks up the tuning on next load. Same for the shared env defaults in `default_environment.tres`.
- **Per-region weather.** When the sim slice lands for per-region weather, update `_resolve_target_weather()` in the rig to pass the local `region_id` (already exposed on `real_map.gd` / `test_map.gd` roots) into the `weather_state(region_id)` query. The rig's existing weight-lerp pipeline doesn't need to change.

## Known rough edges

- **Sun disc through clouds.** SunshineClouds2's sun overlay currently disappears when `resource_local_to_scene = true` on the compositor effect (black-hole artifact). The workaround: the shared `noosphere_clouds.tres` stays `resource_local_to_scene = false`, so all maps share one live resource. Since only one map is active at a time this is safe today, but multiple concurrent world views (split-screen, spectator cams) would need a proper shader-level sun-through-clouds pass.
- **Moon can't sit in the scene tree at edit-time.** `ProceduralSkyMaterial` renders a sun disc for every `DirectionalLight3D` in the scene with default `sky_mode`. A moonlight with `light_energy = 0` (or very low) renders a *black* disc, which punches a visible hole in the sky. The rig spawns the `Moon` node procedurally in `_ready()` rather than pre-placing it in `weather_rig.tscn`, and sets `Moon.sky_mode = LIGHT_ONLY` so it contributes to scene lighting without asking the sky material to draw a disc for it. If you add a second directional light to the rig later, set its `sky_mode` explicitly.
- **Single global weather.** See the TODO in `systems/weather.rs` - weather is world-wide, not per-region. Biome differentiation (dry east, wet west, alpine mt. hood) is waiting on the region-state slice.
- **No particle layer.** Rain / snow particles aren't wired. The rig changes fog + sun + cloud look to imply precipitation; dedicated rain / snow particle effects will land alongside the per-region weather pass.
