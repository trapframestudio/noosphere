shader_type spatial;
// Distant-tier rock impostor — minimum-cost shader for proxy MMIs.
//
// `unshaded` skips per-pixel lighting eval. At 200+ m from camera the
// visual difference vs. the close-tier `rock_dynamic.gdshader` (PBR +
// normal map + shadow receiving) is invisible, but the per-pixel
// saving is large — roughly 5× cheaper than the close-tier shader.
// Combined with `cast_shadow = OFF` on the proxy MMI, distant rocks
// cost essentially nothing per pixel.
//
// **Same mesh as the close-tier LOD2** — rocks don't have authored
// billboard cards (the procedural pack tops out at LOD2 = 27-vert
// polyhedra). The "impostor" here is just LOD2 again, rendered with
// this much cheaper shader. At ≥ 200 m a 27-vert polyhedron reads as
// a single colored blob anyway, so no detail loss.
//
// **Per-instance dither** mirrors `rock_dynamic.gdshader` /
// `tree_imposter.gdshader`: each rock picks render-vs-collapse based
// on a stable world-XZ hash, so the close-tier↔impostor swap happens
// rock-by-rock (not in tile-coordinated waves) and the discard rule
// is complementary with the close-tier's upper-boundary fade-out →
// every rock renders as exactly one of {close LOD2, impostor} in the
// swap zone, no gaps and no double-rendering.
render_mode cull_back, unshaded;

global uniform vec3 player_cam_pos;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 albedo_modulation = vec3(1.0, 1.0, 1.0);

// Per-instance HSV jitter — mirrors `rock_dynamic.gdshader` so a rock
// keeps its tint as it crosses the close↔impostor swap. Same world-XZ
// hash (channel 2) drives the fragment-stage HSV shift.
uniform float albedo_value_jitter : hint_range(0.0, 0.5, 0.01) = 0.0;
uniform float albedo_hue_jitter_deg : hint_range(0.0, 60.0, 1.0) = 0.0;

varying float v_inst_hash;
varying float v_inst_hash2;

// Constant darkening factor — `unshaded` loses the diffuse-darkening
// + AO that the close-tier shader gets through Godot's lighting
// pipeline, so the impostor reads brighter than its lit close-tier
// neighbors at the swap distance. Multiplying by ~0.7 brings the
// impostor's average tone down to roughly what the close-tier reads
// as in cascade_locks's typical sky-light setup.
const float IMPOSTER_DIM_FACTOR = 0.7;

// Lower fade-in boundary (the close-tier ↔ impostor swap distance).
// Set to the same value as the close-tier MMI's `lod_upper_boundary`
// for the highest LOD so the impostor fades in EXACTLY where the
// close-tier fades out, with `lod_fade_half_width` matched on both
// sides → complementary.
uniform float lod_lower_boundary = 200.0;
uniform float lod_fade_half_width : hint_range(0.5, 50.0, 0.5) = 10.0;

// Hard upper distance cap. Past this, instances collapse.
uniform float max_render_distance_m = 800.0;

void vertex() {
	vec3 inst_world = MODEL_MATRIX[3].xyz;
	float d = distance(inst_world, player_cam_pos);
	float h = fract(sin(dot(inst_world.xz, vec2(12.9898, 78.233))) * 43758.5453);
	// Independent hash channel for HSV jitter — same constants as
	// `rock_dynamic.gdshader` so a rock has the same hue shift in both
	// close-tier and impostor materials, no flicker at the swap.
	float h2 = fract(sin(dot(inst_world.xz, vec2(63.7264, 31.5314))) * 17483.1247);
	v_inst_hash = h;
	v_inst_hash2 = h2;

	bool collapse = false;

	if (d > max_render_distance_m) {
		collapse = true;
	}

	// Lower boundary fade-in (we're the FAR side of the close↔impostor
	// boundary). Discard if `hash <= 1 - alpha` — same complementary
	// rule as `rock_dynamic.gdshader`'s lower-boundary handling.
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

	if (collapse) {
		VERTEX = vec3(0.0);
	}
}

// HSV ↔ RGB helpers — same compact branchless form as
// `rock_dynamic.gdshader`. Inlined per-shader because GDShader doesn't
// support shader-level includes for spatial shaders.
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

	if (albedo_value_jitter > 0.0 || albedo_hue_jitter_deg > 0.0) {
		vec3 hsv = rgb2hsv(base);
		float val_t = v_inst_hash * 2.0 - 1.0;
		float hue_t = v_inst_hash2 * 2.0 - 1.0;
		hsv.z *= 1.0 + val_t * albedo_value_jitter;
		hsv.z = clamp(hsv.z, 0.0, 2.0);
		hsv.x += hue_t * albedo_hue_jitter_deg / 360.0;
		base = hsv2rgb(hsv);
	}

	ALBEDO = base * IMPOSTER_DIM_FACTOR;
}
