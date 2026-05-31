shader_type spatial;
// Two-sided. PolyHaven tree assets (pine_sapling_*, fir_sapling_*)
// ship needle cards as single-sided geometry — back-face culling
// hid half the canopy, leaving skeletal trees with gaps the sky
// shows through. The 2× fragment cost is the price of complete
// foliage silhouettes. Re-evaluate if a tree-specific shader
// variant lands later.
render_mode cull_disabled;

// Albedo only. The packed AO/R/M texture (`*_arm_1k.jpg`) was cheap
// per-pixel variance but cost a second sampler bind + fetch on every
// fragment of every leaf. Foliage is roughness-saturated and the
// per-pixel AO mostly fights the lighting; a constant roughness +
// zero metallic + 1.0 AO gives equivalent visual at half the
// fragment-shader bandwidth.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
// `normal_tex` removed entirely. Declaring `uniform sampler2D … :
// hint_normal` (even without sampling it) is enough for Godot's
// renderer to flag the material as normal-mapped and demand
// tangents on every mesh that uses the shader. Some Fab "low" tier
// variant meshes ship without UV arrays so tangent generation
// can't run — the per-frame "shader requires tangents" warning
// comes from that combo. Killing the uniform kills the warning.
// Re-add when we have an asset tier guaranteed to ship with UVs.

// Alpha cutout via luminance. PolyHaven's plant_1k textures don't
// ship an alpha channel — the gltfs declare `alphaMode: MASK` and
// expect alpha in the diff texture, but the JPG has no alpha so
// `albedo.a == 1.0` everywhere. The diff is *premultiplied* though,
// so atlas backgrounds bake to near-black. Threshold the RGB
// luminance to recover the cutout. Per-species default lives on
// `FoliageSpecies.alpha_luminance_cutoff` (0.05 for atlas plants,
// 0.0 for solid-coverage like fern). Inspector slider on the
// ShaderMaterial overrides per-instance for live tuning.
uniform float alpha_luminance_cutoff : hint_range(0.0, 0.5, 0.005) = 0.05;

// Static per-species albedo modulation. Multiplied onto ALBEDO once
// per fragment. Default vec3(1, 1, 1) = no-op. Set per-species in
// `FoliageSpecies.albedo_modulation`; auto-derived by
// `scripts/derive_foliage_modulation.py` from the terrain textures
// each species sits on. Luminance-normalized so it doesn't darken.
uniform vec3 albedo_modulation = vec3(1.0, 1.0, 1.0);

// **Green-only color grading.** Same scheme as `tree_dynamic.gdshader` —
// HSV-shift only fragments where the green channel dominates. Lets
// the user tune leaf hue / saturation / brightness per species
// without `albedo_modulation` stomping the bare-soil and dirt-flecks
// that bleed into ground-cover atlases. See the corresponding
// uniforms on FoliageSpecies for the per-knob meaning.
uniform float leaf_hue_shift : hint_range(-0.5, 0.5, 0.005) = 0.0;
uniform float leaf_saturation_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_value_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_threshold : hint_range(0.0, 0.5, 0.01) = 0.05;

// --- Lighting softening ---------------------------------------------------
// Plant cards have surface normals perpendicular to the leaf face, so a
// sun-facing card lambert-saturates while an edge-on card goes near-black.
// Terrain right next to them sits at mid-tone, so the cards bracket it on
// both ends and read as "stark / doesn't belong". On top of that, dense
// foliage clumps cast hard self-shadows that crush cards in the interior
// to near pitch black under PBR's default attenuation curve. The custom
// `light()` function below replaces Godot's default lambert response with
// half-lambert (wrapped diffuse) + a shadow-attenuation floor, addressing
// both problems independent of the card's authored normal direction.

// Bias the per-vertex NORMAL toward world-up before lighting. Mostly a
// hedge for assets that DO have face normals (fern fronds etc.); for
// flat ground cover with up-pointing normals it's a no-op.
uniform float normal_up_bias : hint_range(0.0, 1.0, 0.05) = 0.3;

// Half-lambert wrap. 0 = pure lambert (dot clamped at 0, hard terminator,
// back-facing cards go to zero diffuse), 1 = full wrap (smooth bell curve
// from N·L=−1 to +1). Lifts the dark side without capping the bright
// peak — pair with `direct_light_strength` to compress the high end.
uniform float light_wrap : hint_range(0.0, 1.0, 0.05) = 0.65;

// Shadow attenuation floor. PBR maps shadow-mapped attenuation 0→1
// directly onto direct-light contribution, so a card in cast shadow
// drops to ambient-only and reads as near-black inside dense foliage.
// This lifts the floor so even fully-shadowed cards retain a fraction of
// the lit diffuse — the single biggest "stop reading as cardboard"
// knob for clump interiors. 0 = vanilla PBR, 0.5 = very forgiving.
uniform float shadow_lift : hint_range(0.0, 1.0, 0.05) = 0.55;

// Multiplier on the direct-sun diffuse contribution. Brings down the
// bright peak (a sun-facing card at N·L=1 hits ALBEDO * LIGHT_COLOR *
// 1.0 under both lambert and wrap, which over-exposes against the
// terrain). Lower = more weight on ambient/IBL relative to direct sun,
// closer to the terrain's perceived brightness. Doesn't affect darks.
uniform float direct_light_strength : hint_range(0.0, 1.5, 0.05) = 0.5;

// Translucency. When light hits the back of a leaf, scatter some
// through to the camera-facing side. Distinct from `shadow_lift`: this
// is for the geometry case (sun on the far side of the card), shadow
// lift is for the attenuation case (cast shadow from another card).
uniform float backlight_strength : hint_range(0.0, 1.0, 0.05) = 0.25;

// Tint of transmitted light. **Constant**, not multiplied by ALBEDO,
// for the same reason `tree_dynamic.gdshader` does it that way: leaf
// textures are dark (chlorophyll RGB ~50/255), so multiplying the
// backlight by ALBEDO collapses the transmission to invisible. Real
// leaves transmit chlorophyll-tinted light regardless of the leaf's
// own reflectance, so a constant warm-yellow-green tint is more
// physically right than albedo-modulated.
uniform vec3 backlight_color = vec3(0.85, 0.95, 0.55);

// `specular_amount` removed — was the source of "leaves shining like
// wet plastic when the sun catches them". Custom `light()` bypasses
// Godot's standard ROUGHNESS path, so any specular contribution had
// to be added explicitly there; removing the explicit Phong block
// gives true matte foliage. Re-add a uniform here if a future asset
// tier (waxy / dewy leaves) actually wants the highlight back.

// Constant ambient floor, applied as EMISSION = ALBEDO * floor. Where
// `shadow_lift` addresses the direct-attenuation case (cast shadow), this
// addresses the ambient case — when the WorldEnvironment's IBL / sky
// contribution itself is too small to fill canopy interiors (overcast,
// dawn/dusk, deep clumps). Unconditional, so lifts every fragment by
// the same fraction; lit cards aren't perceptibly brighter (already at
// ~ALBEDO from direct sun) but shadowed/dim cards get a true minimum
// brightness instead of crushing to black. Keep small or foliage will
// glow at night.
uniform float ambient_floor : hint_range(0.0, 0.3, 0.01) = 0.15;

// Sun-driven wind already wired by WeatherRig; reused as-is.
global uniform float foliage_wind_strength;
global uniform float foliage_wind_speed;

// View-cone density modulation. Pushed each frame by the player.
//   player_cam_pos      world-space camera origin
//   player_cam_forward  world-space camera forward (XZ used)
//   gc_radius_front     full-density radius along +cam_fwd
//   gc_radius_rear      full-density radius along -cam_fwd
//   gc_cone_full_cos    dot(cam_fwd, to_instance) above which density = 1
//   gc_cone_periph_cos  dot below which density = gc_density_rear
//   gc_density_periph   density at periph_cos boundary (linear ramp to 1.0)
//   gc_density_rear     density behind periph_cos
global uniform vec3 player_cam_pos;
global uniform vec3 player_cam_forward;
global uniform float gc_radius_front;
global uniform float gc_radius_rear;
global uniform float gc_cone_full_cos;
global uniform float gc_cone_periph_cos;
global uniform float gc_density_periph;
global uniform float gc_density_rear;

// Per-tier hard-cull radii. INSTANCE_CUSTOM.y carries the species's
// `size_tier` (0=SMALL, 1=MEDIUM, 2=LARGE); the vertex shader compares
// instance distance against the tier's radius and collapses the
// instance to its origin past that. A 5 m soft-fade band before the
// hard radius scales density smoothly to avoid pop-in.
global uniform float gc_tier_radius_small;
global uniform float gc_tier_radius_medium;
global uniform float gc_tier_radius_large;
// Width (meters) of the soft-cull band before each cull boundary.
// Density ramps smoothly from 1.0 at `cull_radius - fade_band` down
// to 0.0 at `cull_radius`. The fragment shader then dithers pixels
// based on density, giving a noisy dissolve instead of a hard pop.
// Larger = softer transition + more "dust at the edge" look; smaller
// = tighter but riskier pop. Tune via `globals.tres → fade_band_m`.
global uniform float gc_fade_band_m;

// Carry the per-instance "density" value (combined cone falloff +
// radius edge fade + tier fade) from vertex to fragment so the
// fragment can dither pixels at the edge of the cull band. Density
// of 1.0 = fully visible, 0.0 = fully culled. The fragment compares
// against a per-pixel hash threshold and scissors below it — gives
// a smooth dissolve between fully-visible and fully-culled instead
// of a binary edge.
varying float v_density;
// World-space position of the fragment, used as the dither hash
// input. Screen-space hashes shimmer as the camera moves (the
// SAME world point gets a different threshold each frame); world-
// space keeps each plant's per-pixel dither stable so the fade
// reads as a smooth dissolve, not a noise crawl.
varying vec3 v_world_pos;

void vertex() {
	// Per-instance random roll — packed into INSTANCE_CUSTOM.x at bake
	// time. Compared against view-cone density to decide cull.
	float roll = INSTANCE_CUSTOM.x;

	// Instance world-space origin = MODEL_MATRIX translation column.
	// (MMI is kept at identity; per-instance transforms are world-space.)
	vec3 inst_world = MODEL_MATRIX[3].xyz;

	// View-cone test in XZ plane (camera pitch shouldn't pull foliage
	// in/out as you look up/down).
	vec3 to_inst_xz = vec3(inst_world.x - player_cam_pos.x, 0.0,
		inst_world.z - player_cam_pos.z);
	float dist = length(to_inst_xz);
	vec3 fwd_xz = vec3(player_cam_forward.x, 0.0, player_cam_forward.z);
	float fwd_len = length(fwd_xz);
	float dot_fwd = (dist > 1e-4 && fwd_len > 1e-4)
		? dot(to_inst_xz / dist, fwd_xz / fwd_len)
		: 1.0;

	// Density curve: full → periph (linear ramp) → rear (flat).
	float density;
	if (dot_fwd >= gc_cone_full_cos) {
		density = 1.0;
	} else if (dot_fwd >= gc_cone_periph_cos) {
		float t = (dot_fwd - gc_cone_periph_cos)
			/ max(gc_cone_full_cos - gc_cone_periph_cos, 1e-4);
		density = mix(gc_density_periph, 1.0, t);
	} else {
		density = gc_density_rear;
	}

	// Distance falloff. Radius interpolated front→rear by dot.
	// Smoothstep over the fade band so plants don't pop hard at the
	// boundary; combined with the tier fade below this gives a
	// dual-falloff (whichever culls first wins).
	//
	// `gc_fade_band_m` is clamped to ≥ 0.5 to avoid `smoothstep(x, x, y)`
	// which is division-by-zero / NaN territory in GLSL. NaN propagated
	// through `density` zeroed every plant's ALPHA — looked like the
	// shader was completely killing albedo. Clamp keeps the math safe
	// even if the global is uninitialised (defaults to 0 before
	// `FoliageGlobals.apply_to_renderer` first runs).
	float fade_band = max(gc_fade_band_m, 0.5);
	float t_radius = clamp((dot_fwd + 1.0) * 0.5, 0.0, 1.0);
	float radius = mix(gc_radius_rear, gc_radius_front, t_radius);
	float radius_keep = 1.0 - smoothstep(
		max(radius - fade_band, 0.0), radius, dist);
	density *= radius_keep;

	// Per-tier distance cull with soft fade (read tier from
	// INSTANCE_CUSTOM.y: 0=SMALL, 1=MEDIUM, 2=LARGE). The fade band
	// scales density linearly from 1 at `tier_max - fade_band` down
	// to 0 at `tier_max`, eliminating the hard pop the prior
	// CPU-side filter caused.
	float tier = INSTANCE_CUSTOM.y;
	float tier_max = mix(gc_tier_radius_small, gc_tier_radius_medium,
		step(0.5, tier));
	tier_max = mix(tier_max, gc_tier_radius_large, step(1.5, tier));
	float fade_start = max(tier_max - fade_band, 0.0);
	float tier_keep = 1.0 - smoothstep(fade_start, tier_max, dist);
	density *= tier_keep;

	// Carry to fragment for per-pixel dither — handles ALL visibility
	// transitions (cone falloff + radius edge + tier edge) smoothly,
	// no per-instance binary cull. Past culling toggled the whole
	// instance on/off when `roll` crossed `density`; that was the
	// remaining visible "pop" the user complained about. With dither
	// alone, density 0.4 means ~40% of pixels survive — instance fades
	// in/out continuously instead of flickering.
	//
	// Hard cull only when density is essentially zero — past the fade
	// band entirely, no point running the wind shader. Saves the
	// fragment work for fully-out-of-range instances; the tail-end of
	// the dither is already invisible (threshold > 0 always for
	// `fract(...)` so density < 0.001 → all pixels scissored anyway).
	v_density = density;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (density < 0.001) {
		VERTEX = vec3(0.0);
	} else {
		// Wind sway, scaled by vertex height so root stays planted.
		// Cap the linear scaling at 1m — taller plants (saplings,
		// shrubs, dead trunks) are woody and shouldn't whip around
		// like blades of grass. Anything above 1m gets a small
		// 0.15× residual so leaf tips still drift.
		float h_raw = max(VERTEX.y, 0.0);
		float h = min(h_raw, 1.0) + max(h_raw - 1.0, 0.0) * 0.15;
		float wt = TIME * foliage_wind_speed;
		float sway_x = sin(wt + inst_world.x * 0.7 + inst_world.z * 0.3)
			* h * foliage_wind_strength;
		float sway_z = cos(wt * 0.83 + inst_world.x * 0.4 - inst_world.z * 0.6)
			* h * foliage_wind_strength;
		VERTEX.x += sway_x;
		VERTEX.z += sway_z;
	}
}

// HSV helpers + green-only grading — see `tree_dynamic.gdshader` for
// the rationale and the source attribution. Duplicated rather than
// shared because Godot 4 spatial shaders don't have an `#include`
// directive that survives the editor's hot-reload + parameter
// binding (a custom-shader `include` was added then reverted in 4.x
// for shader sandboxing reasons).
vec3 _rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 _hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

vec3 _grade_greens(vec3 rgb) {
	float greenness = max(0.0, rgb.g - max(rgb.r, rgb.b));
	if (greenness < leaf_threshold) {
		return rgb;
	}
	float strength = smoothstep(
		leaf_threshold, leaf_threshold + 0.1, greenness);
	vec3 hsv = _rgb2hsv(rgb);
	hsv.x = fract(hsv.x + leaf_hue_shift * strength);
	hsv.y = clamp(hsv.y * mix(1.0, leaf_saturation_mul, strength),
		0.0, 1.0);
	hsv.z = clamp(hsv.z * mix(1.0, leaf_value_mul, strength),
		0.0, 1.0);
	return _hsv2rgb(hsv);
}

void fragment() {
	vec4 albedo = texture(albedo_tex, UV);
	// Skip HSV conversion when no leaf grading is configured.
	// Coherent uniform branch — most ground-cover species use defaults
	// so the cheap path is the common one.
	vec3 graded;
	if (leaf_hue_shift == 0.0
			&& leaf_saturation_mul == 1.0
			&& leaf_value_mul == 1.0) {
		graded = albedo.rgb;
	} else {
		graded = _grade_greens(albedo.rgb);
	}
	ALBEDO = graded * albedo_modulation;
	// Cutout via ALPHA + ALPHA_SCISSOR_THRESHOLD instead of `discard`.
	// Lets Godot route the material through the alpha-tested path
	// (depth pre-pass + opaque sort), eliminating overdraw on stacked
	// leaves rather than paying for it. Combined gate handles both:
	//   1. Real alpha channel (PNG sources, future asset tier).
	//   2. Premultiplied-to-near-black background (PolyHaven plant_1k
	//      JPG diff). The JPG has alpha = 1.0 so path 1 never fires
	//      for those — the luminance threshold is what cuts them out.
	float lum = dot(albedo.rgb, vec3(0.299, 0.587, 0.114));
	float cutout = (albedo.a >= 0.5 && lum >= alpha_luminance_cutoff)
		? 1.0 : 0.0;
	// Edge dither: per-pixel hash compared against the instance's
	// density (carried from vertex). Density is 1.0 for fully-visible
	// instances (all pixels survive); drops smoothly toward 0 at the
	// cull radius / tier boundary, dithering pixels out as the
	// instance approaches the edge.
	//
	// Hash on **world position** rather than screen position. Screen
	// hash shimmers because as the camera moves, the same world pixel
	// lands at a new screen coord → new threshold → flickers in/out
	// frame to frame. World-space keeps each plant's pixel-pattern
	// stable — only crosses the threshold when density actually
	// changes (player walks closer/further), so the dither reads as
	// a smooth dissolve instead of noise crawl.
	float threshold = fract(sin(dot(v_world_pos.xz * 25.0,
		vec2(12.9898, 78.233))) * 43758.5453);
	float fade_keep = (v_density >= threshold) ? 1.0 : 0.0;
	ALPHA = cutout * fade_keep;
	ALPHA_SCISSOR_THRESHOLD = 0.5;

	// Constant material params — see arm_tex comment at top. Roughness
	// 0.95 (was 0.85) matches `tree_dynamic.gdshader`: any sub-1
	// roughness produces specular hotspots on flat-facing leaf cards
	// when the sun catches a quad edge-on, reading as "leaves
	// reflecting too aggressively" — fully matte fixes it.
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
	// NORMAL_MAP intentionally not assigned — see normal_tex comment above.

	// World-up in view space. VIEW_MATRIX transforms world→view, and a
	// 0-w vector transforms as a direction (no translation).
	vec3 world_up_view = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	NORMAL = normalize(mix(NORMAL, world_up_view, normal_up_bias));
	// Backlight + specular are applied inside `light()` below — the
	// PBR-builtin BACKLIGHT only fires when N·L < 0, which never
	// happens for upward-pointing card normals lit from above.

	// Skylight bounce floor — matches `tree_dynamic.gdshader`. Biased
	// by NORMAL.y so up-facing fragments (top of grass tuft, leaf
	// upper sides) catch more sky-bounce than down-facing ones (leaf
	// undersides). Bypasses shadow attenuation: real-world surfaces
	// in cascade shadow still receive scattered sky light. The
	// constant `(0.20, 0.22, 0.25)` is the same cool-tint sky bounce
	// the tree shader uses; `ambient_floor` scales the magnitude
	// (0.15 default reproduces the tree shader's baseline).
	float sky_bias = 0.5 + 0.5 * NORMAL.y;
	EMISSION = ALBEDO * vec3(0.20, 0.22, 0.25) * sky_bias * (ambient_floor / 0.15);
}

void light() {
	// Wrapped diffuse. `lambert` is the standard clamp(N·L, 0, 1)
	// response with its hard zero-terminator; `wrap` is the smooth
	// half-lambert (N·L * 0.5 + 0.5)^2 that lifts back-facing fragments.
	// `light_wrap` blends the two so 0 = vanilla PBR and 1 = full wrap.
	float NdotL = dot(NORMAL, LIGHT);
	float lambert = max(NdotL, 0.0);
	float wrapped = NdotL * 0.5 + 0.5;
	wrapped = wrapped * wrapped;
	float diffuse_term = mix(lambert, wrapped, light_wrap);

	// Shadow attenuation floor. ATTENUATION = 0 (full shadow) → 1 (lit).
	// Map onto [shadow_lift, 1.0] so cast-shadow regions retain a
	// fraction of the diffuse instead of dropping to ambient-only.
	float attenuated = mix(shadow_lift, 1.0, ATTENUATION);

	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * diffuse_term * attenuated * direct_light_strength;

	// Translucency: when light hits the back of the card (NdotL < 0),
	// scatter chlorophyll-tinted light to the camera-facing side. Uses
	// `backlight_color` directly (NOT multiplied by ALBEDO) — same
	// reason `tree_dynamic.gdshader` does it that way: leaf textures
	// are dark, so multiplying by ALBEDO collapses transmission to
	// invisible. Real leaves transmit chlorophyll-tinted light
	// regardless of their own reflectance. Uses the same shadow lift
	// so backlit-but-cast-shadowed leaves still glow.
	float back = max(-NdotL, 0.0);
	DIFFUSE_LIGHT += backlight_color * LIGHT_COLOR * back * backlight_strength * attenuated * direct_light_strength;

	// Specular intentionally not handled — matches `tree_dynamic.gdshader`.
	// Custom `light()` bypasses Godot's standard ROUGHNESS-driven
	// specular path, so the previous explicit Phong block was the
	// ONLY specular source for ground cover. With ROUGHNESS = 0.95
	// (fully matte) set in fragment(), foliage should have ~no
	// reflective highlights; adding Phong manually was contradicting
	// the matte intent and reading as "leaves catching the sun like
	// wet plastic". Leaving SPECULAR_LIGHT untouched = zero specular.
}
