shader_type spatial;
// **Imposter bake pass — albedo channel (unlit, grade-and-modulate
// only).**
//
// Renders the source tree mesh into a transparent-background ortho
// view as UNLIT base color with per-species leaf grading +
// `albedo_modulation` baked in. The runtime impostor shader
// (`tree_cluster.gdshader`) handles lighting against the live sun
// direction — wrap diffuse + warm transmission backlight + sky-bias
// EMISSION — so distant trees track time-of-day and weather.
//
// **Why bake species color but not lighting**: each `TreeSpecies`
// authors its own `leaf_value_mul` × `albedo_modulation`. Baking
// that treatment in means each variant's PNG matches the close-
// tier color authoring at unit lighting; the runtime then adds
// dynamic lighting on top to match close-tier appearance under any
// sun condition. Reproducing the per-species grading at runtime
// would require pushing grading uniforms per-variant; baking it in
// keeps the runtime shader simple and the PNGs self-contained.
//
// **Alpha**: the source albedo texture's alpha is the leaf-card
// cutout mask. Discard below `alpha_cutoff` so the rendered PNG
// has clean silhouette edges.
//
// Used only at bake time inside `godot/tools/imposter_baker.tscn`.
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform sampler2D albedo_texture : source_color, hint_default_white,
	filter_linear_mipmap, repeat_enable;
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.5;

// Per-species green-only HSV grading — mirrors
// `tree_dynamic.gdshader::_grade_greens`. Set per-bake from the
// matching `TreeSpecies` so a species' impostor reproduces its
// authored close-tier color treatment.
uniform float leaf_hue_shift : hint_range(-0.5, 0.5, 0.005) = 0.0;
uniform float leaf_saturation_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_value_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_threshold : hint_range(0.0, 0.5, 0.01) = 0.05;

// Per-species albedo_modulation — applied AFTER leaf grading,
// matching close-tier order. Many species use this to tint
// (e.g. Doug Fir at (0.65, 0.72, 0.55) for "deeper conifer green").
uniform vec3 species_albedo_modulation : source_color = vec3(1.0, 1.0, 1.0);

vec3 _rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)),
		d / (q.x + e), q.x);
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
	vec4 c = texture(albedo_texture, UV);
	if (c.a < alpha_cutoff) {
		discard;
	}
	vec3 graded = _grade_greens(c.rgb);
	ALBEDO = graded * species_albedo_modulation;
	ALPHA = c.a;
}
