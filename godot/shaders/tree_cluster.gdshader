shader_type spatial;
// **Distant tree impostor — lit y-axis billboard.**
//
// The bake captures per-species color (leaf grading + species
// `albedo_modulation`) into UNLIT albedo via
// `imposter_bake_albedo.gdshader`, and view-space surface normals
// into a companion `_normal.png` via `imposter_bake_normal`. This
// runtime shader samples both, rotates the bake-view-space normal
// into world space using the billboard's per-instance basis, then
// runs the same `light()` model as `tree_dynamic.gdshader` (wrap
// diffuse + warm transmission backlight) against the live world
// sun. Result: distant trees track dynamic sun direction, time-of-
// day, and weather lighting just like close-tier trees.
//
// **Why per-species color is in the bake but lighting is at
// runtime**: each `TreeSpecies` authors its own grading +
// modulation; baking that in means each variant's PNG is
// self-contained. Lighting MUST be runtime so impostors respond
// to sunset / dawn / overcast / clouded sun. The runtime grading
// uniforms here are SCATTER-LEVEL extras that compose ON TOP of
// the bake's per-species color — defaults are identity, tune to
// drift the whole distant tier (autumn yellows, etc.) without
// re-baking.
//
// **Geometry contract**: the underlying QuadMesh is a 1×1 quad
// with UV.x ∈ {0,1} and UV.y ∈ {0,1}, root vertex at UV (0.5, 0).
// The vertex shader rebuilds the quad's world position from the
// instance transform's translation (ground anchor) plus UV offset
// along world-up and the rotated card-right vector. Distance-
// scaled ground embed sinks the card's bottom below terrain to
// counter Terrain3D LOD geomorphing at distance.
//
// **Normal basis swap**: the baker captured normals while looking
// along world -Z at the tree. So the bake view frame was:
//   bake-view +X = world +X (right)
//   bake-view +Y = world +Y (up)
//   bake-view +Z = world +Z (toward camera at +Z)
// At runtime the billboard has a fixed per-instance yaw baked into
// MODEL_MATRIX. We map the decoded bake-view normal into world via:
//   billboard_x = normalize(MODEL_MATRIX[0].xyz)  (world card-right)
//   billboard_y = (0, 1, 0)                       (world up)
//   billboard_z = cross(billboard_x, billboard_y) (world card-front)
// Then VIEW_MATRIX × world_normal gives the view-space normal that
// the standard light pipeline expects.
//
// **Legacy fallback**: when `has_normal_map = false` (no companion
// `_normal.png`) the shader degrades to flat unshaded display of
// the baked color — for legacy single-PNG impostors. The `_normal`
// companion is the supported path; ship both files together.
render_mode cull_disabled, depth_draw_opaque;

global uniform vec3 player_cam_pos;

uniform float min_distance_m : hint_range(0.0, 2000.0, 10.0) = 600.0;
uniform float max_distance_m : hint_range(500.0, 6000.0, 50.0) = 2400.0;
uniform float fade_margin_m : hint_range(0.0, 300.0, 10.0) = 80.0;

uniform float card_width_m : hint_range(2.0, 60.0, 0.5) = 8.0;
uniform float card_height_m : hint_range(4.0, 80.0, 0.5) = 18.0;
// Sink the bottom N % of the card BELOW the placement origin
// (terrain surface as sampled at bake time). Counters two effects:
// (1) Terrain3D's distance LOD geomorphing can shift the visible
// terrain Y by ±1–2 m vs the heightmap sample the scatter used at
// placement time — without embedding, impostors visibly float above
// or sink into the rendered terrain.
// (2) When trunks are hidden in the bake, the silhouette's lowest
// pixel is the canopy bottom (which in real life sits a few meters
// above ground); embedding restores that visual offset by sinking
// the card's invisible-trunk region below ground.
//
// Fraction (vs absolute meters) so the embed auto-scales with
// `card_height_m`. 0.25 = "bottom quarter of card under terrain".
// Per-instance scale jitter is also applied (taller trees embed
// proportionally deeper in world units).
uniform float ground_embed_fraction : hint_range(0.0, 0.6, 0.01) = 0.25;
// ADD this much extra embed fraction at `max_distance_m`, ramping
// linearly from 0 at `min_distance_m`. Compensates for Terrain3D's
// CLOD geomorphing — at max draw distance the rendered terrain mesh
// uses 32–64 m vertex spacing vs the canonical 2 m heightmap, so
// sharp ridges drop by several meters. Effective embed clamps to
// 0.6 max so trees never fully disappear below ground regardless of
// base `ground_embed_fraction` + this extra.
//
// Additive (not multiplicative) so an aggressive base fraction
// can't compound into "entire card below terrain" at the far edge.
// 0.10 = "trees at max_distance embed 10 % more of card height
// than trees at min_distance".
uniform float embed_distance_extra : hint_range(0.0, 0.4, 0.01) = 0.10;

// Baked albedo (unlit, leaf-graded if species had grading set).
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap,
	repeat_disable;
// Baked view-space normals encoded as `n * 0.5 + 0.5`. When unset
// (legacy single-PNG bakes), the shader falls back to a flat
// camera-facing normal — still lit, just without per-leaf surface
// detail.
uniform sampler2D normal_tex : hint_default_white,
	filter_linear_mipmap, repeat_disable;
uniform bool has_normal_map = false;

// Default identity so the new bake doesn't need a warm-correction
// to mask Cycles bake dimness. Per-variant overrides via
// `tree_cluster_scatter.gd` still work.
uniform vec3 albedo_modulation : source_color = vec3(1.0, 1.0, 1.0);

// Scatter-level color grading on top of the bake's per-species
// color treatment (which is leaf-graded + albedo_modulated UNLIT
// albedo). These uniforms compose ON TOP, letting the user tune
// all distant trees globally without re-baking. Defaults are
// identity (no-op) so the bake's per-species color shows through
// unchanged. Bark/trunk protection isn't needed (trunks hidden in
// bake), so threshold = 0 applies the grade to all canopy pixels.
uniform float leaf_hue_shift : hint_range(-0.5, 0.5, 0.005) = 0.0;
uniform float leaf_saturation_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_value_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_threshold : hint_range(0.0, 0.5, 0.01) = 0.0;
// Brightness scale applied to the final ALBEDO (matches close-tier's
// `foliage_close_tier_brightness` knob). Default 1.0 = no change.
uniform float distant_brightness : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0, 0.01) = 0.15;

// Distance-LOD alpha tricks — copied from the unlit version, unchanged.
uniform float alpha_mip_cap : hint_range(0.0, 8.0, 0.1) = 2.0;
uniform float alpha_far_boost : hint_range(0.0, 2.0, 0.05) = 0.6;

// Foliage-volume lighting — mirrors `tree_dynamic.gdshader` so the
// LOD ring at the close-tier → distant-tier handoff disappears.
// Tune to match the foreground species the impostor band is fading
// into.
uniform float backlight_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform vec3 backlight_color : source_color = vec3(0.85, 0.95, 0.55);
// Sky-bias emission floor (per-fragment, bypasses shadow). Same
// math as `tree_dynamic.gdshader`'s skylight bounce so trees in
// cascade shadow don't crater to black.
uniform vec3 emission_skylight_color : source_color =
	vec3(0.20, 0.22, 0.25);

varying vec3 v_billboard_x;
varying vec3 v_billboard_z;

// Sourced from Sam Hocevar's classic branchless RGB↔HSV — same
// helpers tree_dynamic.gdshader uses for the close-tier leaf
// grading. Lifted verbatim so the math stays bit-identical across
// the LOD handoff.
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
	// `leaf_threshold = 0` (the impostor default — trunks are
	// already hidden in the bake, no bark to protect) skips the
	// green-only filter entirely and grades every pixel uniformly.
	// Necessary because some species' baked albedo (after per-
	// species grading + warm `albedo_modulation`) lands with R ≥ G,
	// making `greenness = G - max(R,B)` zero → grade silently
	// skipped without this carve-out.
	float strength;
	if (leaf_threshold <= 0.0) {
		strength = 1.0;
	} else {
		float greenness = max(0.0, rgb.g - max(rgb.r, rgb.b));
		if (greenness < leaf_threshold) {
			return rgb;
		}
		strength = smoothstep(
			leaf_threshold, leaf_threshold + 0.1, greenness);
	}
	vec3 hsv = _rgb2hsv(rgb);
	hsv.x = fract(hsv.x + leaf_hue_shift * strength);
	hsv.y = clamp(hsv.y * mix(1.0, leaf_saturation_mul, strength),
		0.0, 1.0);
	hsv.z = clamp(hsv.z * mix(1.0, leaf_value_mul, strength),
		0.0, 1.0);
	return _hsv2rgb(hsv);
}

void vertex() {
	vec3 inst_world = MODEL_MATRIX[3].xyz;
	float d = distance(inst_world, player_cam_pos);
	float h = fract(sin(dot(inst_world.xz, vec2(12.9898, 78.233)))
		* 43758.5453);
	bool collapse = false;
	if (d < min_distance_m - fade_margin_m || d > max_distance_m) {
		collapse = true;
	} else if (fade_margin_m > 0.0 && d < min_distance_m) {
		float fade_t = (d - (min_distance_m - fade_margin_m))
			/ fade_margin_m;
		if (h > fade_t) {
			collapse = true;
		}
	}
	if (collapse) {
		VERTEX = vec3(0.0);
		v_billboard_x = vec3(1.0, 0.0, 0.0);
		v_billboard_z = vec3(0.0, 0.0, 1.0);
	} else {
		float scale_x = length(MODEL_MATRIX[0].xyz);
		float scale_y = length(MODEL_MATRIX[1].xyz);
		vec3 right = MODEL_MATRIX[0].xyz / scale_x;
		float w = card_width_m * scale_x;
		float ht = card_height_m * scale_y;
		// Embed the card base. Base = `ground_embed_fraction`,
		// plus a distance-scaled extra (`embed_distance_extra` at
		// the far edge of the band, ramping linearly from 0 at
		// the close edge). Clamped to 0.6 so trees never fully
		// disappear below ground regardless of how the two knobs
		// are tuned.
		float dist_norm = clamp(
			(d - min_distance_m) / max(max_distance_m - min_distance_m, 1.0),
			0.0, 1.0);
		float effective_embed_frac = clamp(
			ground_embed_fraction + dist_norm * embed_distance_extra,
			0.0, 0.6);
		float embed = ht * effective_embed_frac;
		float y_offset = UV.y * ht - embed;
		vec3 world_pos = inst_world
			+ right * (UV.x - 0.5) * w
			+ vec3(0.0, y_offset, 0.0);
		VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;
		// Cache the world-space billboard basis for the fragment shader
		// to rotate baked-normal samples back into world space.
		// `billboard_z = cross(right, up)` points "out of the card front
		// face" in world space — i.e. the direction the bake camera
		// looked FROM. We can't compute this in fragment() because
		// MODEL_MATRIX[0] there reflects the (possibly degenerate)
		// vertex stage, and a varying is cheaper than recomputing.
		v_billboard_x = right;
		v_billboard_z = normalize(cross(right, vec3(0.0, 1.0, 0.0)));
	}
}

void fragment() {
	// Albedo with the same alpha-mip-cap trick the unlit version used
	// (silhouette starts losing coverage past mip ~2 because the alpha
	// border averages with transparent — see comment block in the unlit
	// shader's git history).
	vec3 col = texture(albedo_tex, UV).rgb;
	float auto_mip = textureQueryLod(albedo_tex, UV).y;
	float used_mip = min(auto_mip, alpha_mip_cap);
	float a = textureLod(albedo_tex, UV, used_mip).a;
	a = clamp(a * (1.0 + max(auto_mip - alpha_mip_cap, 0.0)
		* alpha_far_boost), 0.0, 1.0);
	// Per-instance tint modulator around 1.0 (±30 %) so adjacent
	// trees have hue jitter without crushing dark-green texel ×
	// dark-green tint to black. Applied multiplicatively on the
	// already-lit baked color.
	vec3 tint_modulator = mix(vec3(1.0),
		clamp(COLOR.rgb * 4.0, vec3(0.6), vec3(1.4)), 0.4);
	// Apply scatter-level HSV grading on top of the baked color.
	// Defaults are identity so this is a no-op until tuned.
	vec3 graded;
	if (leaf_hue_shift == 0.0
			&& leaf_saturation_mul == 1.0
			&& leaf_value_mul == 1.0) {
		graded = col;
	} else {
		graded = _grade_greens(col);
	}
	vec3 tinted = graded * tint_modulator * albedo_modulation
		* distant_brightness;
	ALPHA = a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;

	if (has_normal_map) {
		// Lit-billboard path. Sample baked view-space normal,
		// rotate it into world space via the billboard's basis,
		// then re-project into view space for the standard light()
		// pipeline.
		ALBEDO = tinted;
		ROUGHNESS = 0.95;  // matches tree_dynamic.gdshader
		METALLIC = 0.0;
		vec3 n_baked = texture(normal_tex, UV).rgb * 2.0 - 1.0;
		vec3 n_world = normalize(
			n_baked.x * v_billboard_x
			+ n_baked.y * vec3(0.0, 1.0, 0.0)
			+ n_baked.z * v_billboard_z);
		NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
		// Sky-bias emission floor — bypasses shadow attenuation so
		// impostors in cascade shadow don't crater to black while
		// close-tier still has ambient lift. `sky_bias` peaks at
		// canopy top and falls off on undersides.
		float sky_bias = 0.5 + 0.5 * n_world.y;
		EMISSION = ALBEDO * emission_skylight_color * sky_bias;
	} else {
		// Legacy unshaded fallback: no normal companion, just
		// display the baked color flat. Suppresses light()
		// contributions by zeroing ALBEDO and emitting the tinted
		// color directly.
		ALBEDO = vec3(0.0);
		EMISSION = tinted;
		NORMAL = vec3(0.0, 0.0, 1.0);
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
	}
}

// Mirrors `tree_dynamic.gdshader::light()`: wrap diffuse + warm
// transmission backlight. Specular intentionally not handled —
// ROUGHNESS = 0.95 makes it negligible.
void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrap = 0.6;
	float wrapped = max((ndl + wrap) / (1.0 + wrap), 0.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * wrapped * ATTENUATION;

	float back = max(-ndl, 0.0);
	DIFFUSE_LIGHT += backlight_color * LIGHT_COLOR
		* backlight_strength * back * ATTENUATION;
}
