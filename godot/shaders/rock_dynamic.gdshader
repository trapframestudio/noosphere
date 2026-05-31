shader_type spatial;
// **Single-sided rendering** — rock meshes are closed convex-ish solids,
// so back-face culling is safe and saves ~half the fragment work vs. the
// foliage shaders. No alpha cards, no wind, no leaf grading; rocks are
// the simplest case in the foliage scatter family.
render_mode cull_back;

// `repeat_enable` — the AmbientCG rock packs author all maps as
// seamless tiles, and the rock meshes use sphere-projected UVs that
// wrap > 1.0 across the silhouette. Without repeat the wrap-around
// pixels would clamp to the edge color and the rock would read as
// stretched stripes on its back side.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

// Per-species static albedo modulation. Default identity = no-op. Use
// to shift toward a regional palette (warm sandstone, cool granite)
// without re-baking the source texture.
uniform vec3 albedo_modulation = vec3(1.0, 1.0, 1.0);

// Roughness floor — multiplied with the roughness map. Rocks are
// always > 0.5 rough in the wild; the AmbientCG maps sometimes dip
// into low-roughness scratches that read as fake-shiny on a granite
// boulder. Default 0.7 floors the scatter to a believable rocky look
// and lets per-species tuning lift specific stones (wet rocks ~ 0.4).
uniform float roughness_floor : hint_range(0.0, 1.0, 0.01) = 0.7;

// Per-instance HSV jitter — applied AFTER `albedo_modulation` so the
// per-species tint still shapes the regional palette and the jitter
// sits on top. Both jitters are stable per-instance via a world-XZ
// hash with a different multiplier from the LOD-dither hash, so
// neighboring rocks differ visibly even though they share LOD picks.
//
// `albedo_value_jitter` shifts lightness by ±value (multiplicative on
// HSV.value). 0 = no jitter; 0.15 = each instance up to ±15 % darker
// or lighter than the source.
//
// `albedo_hue_jitter_deg` rotates hue by ±deg. 0 = no shift; 6° gives
// subtle warm/cool variation, 15° produces visibly mixed-mineral
// compositions.
uniform float albedo_value_jitter : hint_range(0.0, 0.5, 0.01) = 0.0;
uniform float albedo_hue_jitter_deg : hint_range(0.0, 60.0, 1.0) = 0.0;

global uniform vec3 player_cam_pos;

// Per-instance hash channels passed vertex → fragment. `v_inst_hash`
// is the same value used for LOD dither (kept for that path's parity);
// `v_inst_hash2` is an independent channel used to decorrelate the
// HSV jitter from the LOD pick — without it, "rocks fading out at
// LOD boundary" would all share the same hue shift, producing visible
// banding at the band end.
varying float v_inst_hash;
varying float v_inst_hash2;

// Per-LOD distance band with complementary-dither crossfade between
// adjacent LODs — same algorithm as `tree_dynamic.gdshader`. See the
// long comment block there for the boundary semantics + the reason
// VISIBILITY_RANGE_FADE_SELF causes see-through. Short version:
// world-space hash → each instance picks ONE LOD, complementary
// discard rules at the boundary partition cleanly.
uniform float lod_lower_boundary = -1.0;
uniform float lod_upper_boundary = -1.0;
uniform float lod_fade_half_width : hint_range(0.5, 50.0, 0.5) = 5.0;

// Hard distance cap as the final backstop. Defaults huge so it's a
// no-op unless set per-MMI; the LOD fade boundaries normally cull
// before this.
uniform float max_render_distance_m = 10000.0;

void vertex() {
	vec3 inst_world = MODEL_MATRIX[3].xyz;
	float d = distance(inst_world, player_cam_pos);

	// Stable per-instance hash from world XZ — identical for every
	// vertex of one instance, so the entire rock either renders or
	// collapses to a degenerate triangle (rasterizer-discard).
	float h = fract(sin(dot(inst_world.xz, vec2(12.9898, 78.233))) * 43758.5453);
	// Second hash channel for the HSV jitter — different multiplier
	// constants → uncorrelated with `h`, so an instance's LOD-fade
	// behavior doesn't predict its hue shift.
	float h2 = fract(sin(dot(inst_world.xz, vec2(63.7264, 31.5314))) * 17483.1247);
	v_inst_hash = h;
	v_inst_hash2 = h2;

	bool collapse = false;

	if (d > max_render_distance_m) {
		collapse = true;
	}

	if (lod_lower_boundary >= 0.0) {
		float lb_min = lod_lower_boundary - lod_fade_half_width;
		float lb_max = lod_lower_boundary + lod_fade_half_width;
		if (d < lb_min) {
			collapse = true;
		} else if (d <= lb_max) {
			float alpha = (d - lb_min) / (2.0 * lod_fade_half_width);
			if (h <= 1.0 - alpha) {
				collapse = true;
			}
		}
	}

	if (lod_upper_boundary >= 0.0) {
		float ub_min = lod_upper_boundary - lod_fade_half_width;
		float ub_max = lod_upper_boundary + lod_fade_half_width;
		if (d > ub_max) {
			collapse = true;
		} else if (d >= ub_min) {
			float alpha = (ub_max - d) / (2.0 * lod_fade_half_width);
			if (h > alpha) {
				collapse = true;
			}
		}
	}

	if (collapse) {
		VERTEX = vec3(0.0);
	}
}

// HSV ↔ RGB helpers (compact branchless form, Sam Hocevar 2010).
vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float dh = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * dh + e)),
				dh / (q.x + e),
				q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb * albedo_modulation;

	// Per-instance HSV jitter. Skip the round-trip when both jitters
	// are 0 — typical when a species hasn't opted into variation.
	if (albedo_value_jitter > 0.0 || albedo_hue_jitter_deg > 0.0) {
		vec3 hsv = rgb2hsv(base);
		// Map [0, 1) hashes onto symmetric [-1, 1] perturbations.
		float val_t = v_inst_hash * 2.0 - 1.0;
		float hue_t = v_inst_hash2 * 2.0 - 1.0;
		// Multiplicative value jitter — preserves shadow detail on
		// dark stones and doesn't crush highlights on bright ones.
		hsv.z *= 1.0 + val_t * albedo_value_jitter;
		hsv.z = clamp(hsv.z, 0.0, 2.0);
		// Hue is wrap-around so we just add and let fract() in
		// hsv2rgb handle the wrap.
		hsv.x += hue_t * albedo_hue_jitter_deg / 360.0;
		base = hsv2rgb(hsv);
	}

	ALBEDO = base;

	// PBR — opaque, non-metal, roughness from map clamped above floor.
	float r = texture(roughness_tex, UV).r;
	ROUGHNESS = max(r, roughness_floor);
	METALLIC = 0.0;
	AO = 1.0;

	NORMAL_MAP = texture(normal_tex, UV).rgb;
}
