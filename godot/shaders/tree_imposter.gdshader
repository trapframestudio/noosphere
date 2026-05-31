shader_type spatial;
// Distant-tier tree impostor — minimum-cost shader for proxy MMIs.
//
// `unshaded` skips per-pixel lighting eval. At 100s of m from camera
// the visual difference is invisible; the per-pixel saving is many
// times faster than the close-tier `tree_dynamic.gdshader`. The
// baked impostor PNG is what the player sees directly — runtime
// lighting is bypassed.
//
// **Per-instance dither** mirrors `tree_dynamic.gdshader`'s scheme:
// each tree picks render-vs-collapse based on a stable world-XZ
// hash, so the close-tier↔impostor swap happens tree-by-tree (not
// in tile-coordinated waves) and the discard rule is complementary
// with the close-tier's upper-boundary fade-out → every tree
// renders as exactly one of {close LOD2, impostor} in the swap zone,
// no gaps and no double-rendering.
render_mode cull_back, unshaded;

global uniform vec3 player_cam_pos;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 albedo_modulation = vec3(1.0, 1.0, 1.0);
// Cutout threshold for the impostor card's transparency. Default
// 0.5 — Fab billboard atlases author hard-edge silhouettes that
// scissor cleanly at 0.5.
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0, 0.01) = 0.5;

// Lower fade-in boundary (the close-tier ↔ impostor swap distance).
// Set to the same value as the close-tier MMI's `lod_upper_boundary`
// so the impostor fades in EXACTLY where the close-tier fades out,
// with `lod_fade_half_width` matched on both sides → complementary.
uniform float lod_lower_boundary = 130.0;
uniform float lod_fade_half_width : hint_range(0.5, 50.0, 0.5) = 5.0;

// Hard upper distance cap. Past this, instances collapse — pairs
// with the canopy-card layer that takes over at long range.
uniform float max_render_distance_m = 800.0;

void vertex() {
	vec3 inst_world = MODEL_MATRIX[3].xyz;
	float d = distance(inst_world, player_cam_pos);
	float h = fract(sin(dot(inst_world.xz, vec2(12.9898, 78.233))) * 43758.5453);

	bool collapse = false;

	// Upper fade-out — symmetric with the lower fade-in. Without this
	// the hard `d > max_render_distance_m` cull below was the source
	// of the "tree suddenly appears at a fixed distance" pop the
	// player saw as they approached distant pine / birch tiles. The
	// fade tail spans `2 * lod_fade_half_width` meters before
	// max_render, with per-instance hash dither so individual trees
	// fade out at slightly different distances. Mirrors the close-
	// tier shader's upper-fade handling.
	float ub_max_outer = max_render_distance_m;
	float ub_min_outer = max_render_distance_m - 2.0 * lod_fade_half_width;
	if (d > ub_max_outer) {
		collapse = true;
	} else if (d >= ub_min_outer) {
		float a = (ub_max_outer - d) / (2.0 * lod_fade_half_width);
		if (h > a) {
			collapse = true;
		}
	}

	// Lower boundary fade-in (we're the FAR side of the close↔impostor
	// boundary). Discard if `hash <= 1 - alpha` — same complementary
	// rule as `tree_dynamic.gdshader`'s lower-boundary handling.
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

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb * albedo_modulation;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
}
