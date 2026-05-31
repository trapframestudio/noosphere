shader_type spatial;
// **Double-sided rendering** — every tree species in this project
// (Doug Fir from Fab, Sketchfab pine pack, Sketchfab birch pack)
// authors leaf / cluster / frond surfaces as single-faced quads, so
// `cull_back` makes them invisible from below. The "fix at import
// time" plan from the previous comment didn't pan out — neither the
// .glb materials nor the import sidecars expose a per-surface cull
// flag we can flip cleanly, and runtime `Mesh.flip_faces`-equivalent
// API doesn't exist for ArrayMesh in Godot 4.6.
//
// **Cost**: the obvious worst case is 2× fragment work on every leaf
// pixel, but alpha-scissor discards the transparent areas of the
// leaf textures on BOTH faces — and leaf cards are ~70 % transparent
// — so realized fragment cost is closer to 1.3× per leaf surface,
// not 2×. Tradeoff judged worth it for the visual correctness.
//
// No depth prepass — measured on cascade_locks (5M+ primitives across
// trees + ground cover): the prepass cost was 106 ms / frame, ~40 %
// of the GPU scene cost. The "save overdraw via early-Z" benefit
// only pays off when overdraw is high AND the prepass itself is
// cheap; with this much foliage the prepass dominated.
render_mode cull_disabled;

// `repeat_enable`: tree assets typically authored with bark mapped
// `0..N` (tiled) on the trunk so a single 1K texture covers a 15 m+
// trunk at usable detail. Without repeat the sampler clamps UVs > 1
// to the edge pixel and the trunk reads as horizontal streaks of
// the rightmost-column color (Sketchfab pine pack symptom). Trunk-
// surface UVs that DO stay inside [0,1] (Doug Fir authored as a
// single non-tiled bark map) sample identically with repeat on or
// off, so this is safe across all current species.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;

// Default 0.15 — Pure3D Pine + Fab Doug Fir + USD conifer atlases
// all author needles with soft anti-aliased edges. 0.5 clips
// mid-alpha pixels and the canopy reads as gappy black clusters;
// 0.3 was the original setting but the Pure3D leaf textures have
// alpha values clustered in the 0.1-0.3 range (the dark needle
// body pixels) so 0.3 was discarding most of the canopy and
// leaving black holes. 0.15 keeps the bulk of the leaf body
// visible — silhouettes are slightly softer than 0.5 but the
// canopy reads as full and fluffy instead of skeletal.
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0, 0.01) = 0.15;

// Per-species static albedo modulation. Default identity = no-op.
uniform vec3 albedo_modulation = vec3(1.0, 1.0, 1.0);

// **Green-only color grading.** Applied BEFORE `albedo_modulation`,
// only to fragments where the green channel dominates (leaves /
// needles / atlas), leaving brown bark / branches / ground untouched.
// "Greenness" = max(0, G - max(R, B)) clamped at `leaf_threshold`;
// fragments below the threshold pass through unchanged. Lets the
// user tune the canopy color of an individual species without the
// `albedo_modulation` Color stomping all RGB channels (which dims
// red/blue too — bark goes muddy).
//
// `leaf_hue_shift`: rotate green hue. -0.5..0.5 is one full color
// wheel revolution; useful range is ~-0.05..0.05 (~±18°). Negative
// → blue-green, positive → yellow-green.
//
// `leaf_saturation_mul`: scale saturation. 1 = no change, <1 muted
// (drier / shaded look), >1 vivid.
//
// `leaf_value_mul`: scale brightness. 1 = no change, <1 darker
// (dense canopy interior), >1 brighter (sunlit upper canopy).
//
// `leaf_threshold`: how green a pixel must be before grading kicks
// in. 0.05 catches even subtle greens (lichen on bark);
// 0.3 only fully-green leaves. Default 0.05.
uniform float leaf_hue_shift : hint_range(-0.5, 0.5, 0.005) = 0.0;
uniform float leaf_saturation_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_value_mul : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float leaf_threshold : hint_range(0.0, 0.5, 0.01) = 0.05;

// Anchored wind sway. Bend FROM THE TOP DOWN — quadratic in vertex
// height so trunk near y=0 stays stiff and the canopy flexes.
uniform float trunk_anchor_height : hint_range(0.0, 5.0, 0.1) = 0.5;
uniform float wind_amplitude_scale : hint_range(0.0, 5.0, 0.1) = 0.5;

// Foliage-volume lighting. Three knobs, all per-species, all defaulting
// to "current shipping behavior" so unset species are unaffected.
//
// `canopy_normal_up_blend`: blend per-vertex NORMAL toward world-up.
// Leaf cards as authored have normals perpendicular to the card —
// each card lights independently as the sun catches its quad
// orientation, producing a "salt-and-pepper" specular sparkle that
// reads as wrong on a dense canopy. Blending toward +Y makes the
// canopy light as a unified VOLUME (SpeedTree / Crytek "capsule
// normal" trick). 0 = mesh's authored normal (current). ~0.4-0.6
// for full canopies; lower for sparse pines so individual frond
// silhouettes still get directional shading.
//
// `backlight_strength` + `backlight_color`: writes BACKLIGHT so
// back-lit leaves glow softly instead of going pitch-black. 0 =
// no contribution (current). Tinted slightly warm-yellow by default
// to suggest sunlight transmitted through chlorophyll.
//
// `normal_map_strength`: dampen the texture-supplied normal map.
// Some pine packs (Pure3D Pine, CGTrader Forest) ship leaf-card
// normal maps authored for a flat card, which create erratic
// per-pixel highlights when sampled on geometry that's already a
// leaf card. 0 = ignore the normal map entirely (use vertex normal
// only). 1 = use it as authored.
uniform float canopy_normal_up_blend : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float backlight_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform vec3 backlight_color = vec3(0.85, 0.95, 0.55);
uniform float normal_map_strength : hint_range(0.0, 1.0, 0.01) = 1.0;

global uniform float foliage_wind_strength;
global uniform float foliage_wind_speed;
global uniform vec3 player_cam_pos;
// Brightness knob for close-tier foliage albedo. Per-species
// `leaf_value_mul` × `albedo_modulation` stack to produce vibrant
// foreground trees, but the resulting brightness drifts away from
// the lit-billboard distant impostor tier. Multiply final
// ALBEDO by this so close + distant trees match without re-tuning
// every TreeSpecies. 1.0 = unchanged authored brightness; 0.75 =
// 25 % toned down. Per-shader uniform with a baked default so it
// applies project-wide without needing a Project Settings entry;
// override per-MMI via `set_shader_parameter` if a specific scatter
// needs a different value.
uniform float foliage_close_tier_brightness : hint_range(0.0, 2.0, 0.01)
	= 0.75;

// Per-LOD distance band with complementary-dither crossfade between
// adjacent LODs. Each tree picks ONE LOD individually based on a
// stable world-space hash of its instance position — no tile-
// coordinated pops, no screen-space dither holes (which is why
// VISIBILITY_RANGE_FADE_SELF causes see-through; its hash is per-
// pixel and shifts as the camera moves, and two LODs cross-dithering
// with independent hashes coincide on ~25 % of pixels → gaps).
//
// Why per-instance vs per-pixel: a single tree must render entirely
// as ONE LOD, never half-LOD0/half-LOD1, otherwise its silhouette
// fragments. The hash is computed from the instance's world XZ in
// the vertex shader and is identical for every vertex of one
// instance, so a tree either fully renders or fully collapses to a
// degenerate triangle.
//
// Boundary semantics:
//
//   `lod_lower_boundary < 0` → this is the closest LOD (or the only
//   LOD). No fade-in; renders all the way down to camera.
//
//   `lod_lower_boundary >= 0` → this LOD is the FAR side of a
//   boundary; fades IN over `lod_lower_boundary ±
//   lod_fade_half_width`. Discard rule: `hash <= 1 - alpha` (where
//   alpha is this LOD's coverage in the fade zone, i.e. it grows
//   from 0 to 1 as distance increases past the boundary).
//
//   `lod_upper_boundary < 0` → this is the farthest LOD. No fade-
//   out; renders all the way to `max_render_distance_m`.
//
//   `lod_upper_boundary >= 0` → this LOD is the CLOSE side of a
//   boundary; fades OUT over `lod_upper_boundary ±
//   lod_fade_half_width`. Discard rule: `hash > alpha` (alpha
//   shrinks 1 → 0 with increasing distance).
//
// At a shared boundary B, the close-side LOD's "alpha" + the
// far-side LOD's "alpha" sum to 1 by construction, and the discard
// rules ({hash <= 1 - far_alpha} ⊕ {hash > close_alpha}) partition
// instances disjointly → every instance renders as exactly one LOD.
uniform float lod_lower_boundary = -1.0;
uniform float lod_upper_boundary = -1.0;
uniform float lod_fade_half_width : hint_range(0.5, 50.0, 0.5) = 5.0;

// Hard distance cap as the final backstop. Defaults huge so it's a
// no-op unless set per-MMI. The `lod_upper_boundary` fade handles
// the typical LOD→LOD or LOD→impostor transition; this is just a
// safety net for instances that somehow escape the upper boundary.
uniform float max_render_distance_m = 10000.0;

void vertex() {
	vec3 inst_world = MODEL_MATRIX[3].xyz;
	float d = distance(inst_world, player_cam_pos);

	// Stable per-instance hash from world XZ. Same value for every
	// vertex of one instance → uniform collapse → degenerate triangle
	// (rasterizer discards). The 12.9898/78.233/43758.5453 constants
	// are the standard 1D-from-2D hash; works fine for foliage
	// distribution with no visible patterning.
	float h = fract(sin(dot(inst_world.xz, vec2(12.9898, 78.233))) * 43758.5453);

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
	} else {
		// Anchored wind — quadratic with height past `trunk_anchor_height`
		// so canopy flexes hard while trunk base barely moves. The
		// coefficient was originally 0.05, which produced reasonable
		// sway on ~5-10 m trees but blew up on 20 m+ pines (h_above
		// up to 16 m → bend = 16² × 0.05 = 12.8 → peak displacement
		// 12.8 × wind_strength × wind_amp ≈ 0.5 m even at default
		// wind values). At close range the canopy visibly detached
		// from the trunk and read as a duplicate "stretching" tree
		// drifting alongside the static base. Coefficient dropped to
		// 0.005 (10×) AND capped at bend=2 so neither tall PNW
		// ponderosas nor any future taller species can produce >~0.1 m
		// peak canopy displacement at typical wind settings.
		float h_above = max(VERTEX.y - trunk_anchor_height, 0.0);
		float bend = min(h_above * h_above * 0.005, 2.0);
		float wt = TIME * foliage_wind_speed;
		float sway_x = sin(wt * 0.4 + inst_world.x * 0.15 + inst_world.z * 0.1)
			* bend * foliage_wind_strength * wind_amplitude_scale;
		float sway_z = cos(wt * 0.33 + inst_world.x * 0.1 - inst_world.z * 0.15)
			* bend * foliage_wind_strength * wind_amplitude_scale;
		VERTEX.x += sway_x;
		VERTEX.z += sway_z;
		// Canopy-up normal blend: replace some fraction of the per-
		// vertex normal with object-local +Y. Done in OBJECT space so
		// the blend follows the tree's orientation (per-instance yaw
		// rotation in MMI doesn't break it). Skip below the wind
		// anchor — trunk normals stay accurate. Above the anchor we
		// fade in the up-blend with the same h_above we use for wind,
		// so the lower trunk's bark normals don't get flattened out.
		if (canopy_normal_up_blend > 0.0 && h_above > 0.0) {
			float up_blend = canopy_normal_up_blend
				* clamp(h_above * 0.5, 0.0, 1.0);
			NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), up_blend));
		}
	}
}

// Sourced from Sam Hocevar's classic branchless RGB↔HSV
// (http://lolengine.net/blog/2013/07/27/rgb-to-hsv-in-glsl). Self-
// contained, no external defines. ~10 ALU per call on modern GPUs.
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

// Apply leaf_hue_shift / leaf_saturation_mul / leaf_value_mul ONLY
// to fragments that are clearly green-dominant. Bark / branch /
// ground-bleed pixels (where R or B competes with G) pass through
// unchanged. `strength` ramps smoothly from 0 to 1 over 0.1 of
// greenness past `leaf_threshold`, so the grading doesn't have a
// hard edge between "graded" and "untouched" pixels.
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
	// Skip the HSV conversion + greenness compute when no leaf
	// grading is configured. Coherent uniform branch — every fragment
	// of an MMI takes the same path. Most species use defaults, so
	// the canopy-wide common case is the cheap branch.
	vec3 graded;
	if (leaf_hue_shift == 0.0
			&& leaf_saturation_mul == 1.0
			&& leaf_value_mul == 1.0) {
		graded = albedo.rgb;
	} else {
		graded = _grade_greens(albedo.rgb);
	}
	ALBEDO = graded * albedo_modulation * foliage_close_tier_brightness;
	ALPHA = albedo.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;

	// PBR constants for the foliage tier — metallic=0 so leaves render
	// as proper diffuse surfaces instead of dark mirrors. Roughness
	// 0.95 (fully matte) — was 0.85 but produced specular hotspots
	// on the leaf cards when the sun caught a flat-facing quad,
	// reading as "trees reflecting too aggressively" against the dark
	// canopy. AO baked into the albedo where the asset shipped it.
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
	AO = 1.0;

	// Dampen the normal map by `normal_map_strength`. The normal-map
	// is stored as values centered at 0.5 (= "no perturbation");
	// blending toward 0.5 reduces the perturbation amount. At
	// strength=0, NORMAL_MAP is a flat 0.5,0.5,1.0 = use vertex
	// normal as-is.
	//
	// Skip the texture fetch entirely when the strength is at the
	// "off" extremes — saves one sampler tap per fragment on species
	// configured with strength=0 (Pure3D Pine, CGTrader Forest leaf
	// cards). Coherent uniform branch: every fragment of an MMI takes
	// the same path, so no warp divergence on modern GPUs.
	if (normal_map_strength > 0.001) {
		vec3 nm = texture(normal_tex, UV).rgb;
		vec3 flat_normal = vec3(0.5, 0.5, 1.0);
		NORMAL_MAP = mix(flat_normal, nm, normal_map_strength);
	}

	// Transmission handled by the custom `light()` function below
	// (wrap diffuse + back transmission). BACKLIGHT not used here —
	// once `light()` is defined Godot bypasses the standard BACKLIGHT
	// path anyway, so explicit transmission in `light()` is the
	// single source of truth.

	// Skylight bounce — emitted lift that BYPASSES shadow attenuation.
	// Real-world surfaces in cascade shadow still receive scattered
	// sky light, especially in semi-open forest. Without this floor,
	// the extended directional_shadow_max_distance puts more trunks
	// under canopy shadow than the world env ambient can lift, and
	// trunks read as muddy-dark silhouettes against the bright canopy.
	//
	// `EMISSION` (not AMBIENT_LIGHT) because AMBIENT_LIGHT is only
	// writable in `light()` and we want this to apply once per
	// fragment regardless of how many lights affect the surface.
	// Strength is tuned low enough that it doesn't trigger bloom on
	// the dark-albedo leaves and bark.
	//
	// The `sky_bias` term peaks on up-facing surfaces (top of canopy)
	// and falls off on down-facing surfaces (leaf undersides). Trunks
	// land at the midpoint — enough lift to keep bark legible in deep
	// shadow without washing out the canopy's lit-vs-shaded contrast.
	float sky_bias = 0.5 + 0.5 * NORMAL.y;
	EMISSION = ALBEDO * vec3(0.20, 0.22, 0.25) * sky_bias;
}

// Custom light() function — replaces Godot's default Lambert / Burley
// diffuse with two foliage-specific contributions:
//
// 1. **Wrap diffuse**: extends NdotL past 90° so the shadow side of
//    a leaf still receives partial sun. Real leaves transmit and
//    bounce so much internally that even back-to-sun fronds aren't
//    pitch black under direct sun. `wrap = 0.6` → ~50° past the
//    tangent still gets light → no more silhouette-black undersides.
//
// 2. **Transmission**: when the surface faces AWAY from the sun
//    (NdotL < 0), light passes THROUGH the leaf and exits the
//    camera-side. Tinted by `backlight_color` (warm-yellow chlorophyll
//    by default), scaled by `backlight_strength`. View-independent —
//    true leaf SSS is view-coupled, but at 5+ m canopy distances the
//    constant-tint approximation reads correctly.
//
// Specular intentionally not handled — ROUGHNESS = 0.95 makes the
// specular contribution negligible anyway, and the previous
// "specular hotspots on flat leaf cards" issue is gone with the
// standard pipeline disabled here.
void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrap = 0.6;
	float wrapped = max((ndl + wrap) / (1.0 + wrap), 0.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * wrapped * ATTENUATION;

	float back = max(-ndl, 0.0);
	DIFFUSE_LIGHT += backlight_color * LIGHT_COLOR
		* backlight_strength * back * ATTENUATION;
}
