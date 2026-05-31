shader_type spatial;
render_mode cull_disabled, world_vertex_coords;

// World-space position + normal, computed in vertex and interpolated
// to the fragment. Triplanar projection needs both — the normal
// decides which of the three planar projections dominates, the
// position provides the texture coordinates for each projection.
varying vec3 v_world_pos;
varying vec3 v_world_normal;

// Feature classification grid: single-channel R8 texture, each pixel
// a FeatureClass discriminant (0-23). Aligned with the terrain mesh
// UVs so `texelFetch(features_texture, ...)` recovers the class byte
// at a given cell. **Do not mark as source_color** — these are raw
// class indices, not color data; an sRGB→linear conversion would
// corrupt the discriminants.
//
// Today this is used only for line classes (PavedRoad / UnpavedRoad
// / Trail) which are too thin (1-3 cells) to ride a splatmap
// channel without disappearing under blending. Area classes are
// driven by the `splatmap_a` + `splatmap_b` textures below.
uniform sampler2D features_texture : filter_nearest;

// Splatmap pair — RGBA8, filter_linear so adjacent cells smoothly
// interpolate (this is the whole point of moving from categorical
// class indices to splatmaps). Each channel is a per-pixel blend
// weight 0..1 for one class group; weights across all 8 channels
// sum to ~1.
//
// Layout (matches `simn_terrain::splatmap`):
//   splatmap_a.r  Forest      .g  Grassland   .b  Water     .a  Cropland
//   splatmap_b.r  Bare        .g  BuiltUp     .b  Cliff     .a  Snow
//
// `splatmap_present` is set false on legacy maps with no splatmap
// — fragment falls back to the categorical-class debug path so the
// shader still produces something visible.
uniform sampler2D splatmap_a : filter_linear, repeat_disable;
uniform sampler2D splatmap_b : filter_linear, repeat_disable;
uniform bool splatmap_present = false;

// Road density — RGBA8 sampled at filter_linear for sub-cell-
// precision road blending. Per-class densities (R=Paved, G=Unpaved,
// B=Trail) baked once via Gaussian blur on the categorical line
// classes from features.r8, so road centerlines + corners read as
// smooth ribbons instead of 2 m grid stair-step. `road_density_present`
// false → fall back to the in-shader 5×5 Gaussian on legacy bakes.
uniform sampler2D road_density : filter_linear, repeat_disable;
uniform bool road_density_present = false;

// Primary per-class diffuse. Layer index = FeatureClass discriminant,
// so the 24-layer array has ~15 real textures and ~9 gaps (11-19
// reuse the Unknown fallback).
uniform sampler2DArray diffuse_array : filter_linear_mipmap, repeat_enable;

// Variant diffuse — a second texture per class from the same
// family. Blended against the primary by low-frequency noise so
// every class shows within-class variation instead of reading as
// one tiled photo. Same 24-layer layout.
uniform sampler2DArray variant_array : filter_linear_mipmap, repeat_enable;

// Third-variant diffuse — another family member, blended at a
// decoupled noise frequency so the primary+variant pattern isn't
// itself a visible repeat. Three textures per class at two
// independent noise scales produces natural-looking patches.
uniform sampler2DArray variant2_array : filter_linear_mipmap, repeat_enable;

// Fourth-variant diffuse — one more family member to maximize
// within-class variation. Each class now has up to four different
// textures blending smoothly at three independent noise scales.
uniform sampler2DArray variant3_array : filter_linear_mipmap, repeat_enable;

// Per-class tangent-space normal map (OpenGL convention, +Y up).
// Only one normal per class — the eye is far less sensitive to
// normal variation than color variation, so quadrupling the normal
// sample cost to mirror the diffuse variant stack isn't worth it.
// `normal_present` false → fragment falls back to the geometric
// face normal (no perturbation). 24-layer layout mirrors diffuse.
uniform sampler2DArray normal_array : filter_linear_mipmap, repeat_enable;
uniform bool normal_present = false;

// How strongly the sampled normal map perturbs the geometric face
// normal. 0.0 = fully geometric (flat, no micro-detail).
// 1.0 = use the texture's normal at full strength. Larger values
// exaggerate (useful for cliff faces); smaller for smoother
// surfaces (asphalt, packed dirt). Tunable for art direction.
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// Per-class roughness map. Sampled `.r` channel only — both
// PolyHaven and AmbientCG ship single-channel roughness as
// luminance, so r/g/b are identical. `roughness_present` false →
// fragment falls back to a fixed `roughness_default` so the surface
// still responds to specular instead of reading as plastic.
uniform sampler2DArray roughness_array : filter_linear_mipmap, repeat_enable;
uniform bool roughness_present = false;

// Roughness remap: lets a single class be tuned without a rebake.
// Sampled value × strength + bias, clamped to [0, 1]. Default
// strength=1, bias=0 → use the texture as-is. Drop strength to
// 0.6 for a glossier read on wet surfaces (asphalt after rain),
// raise bias for a more matte look.
uniform float roughness_strength : hint_range(0.0, 2.0) = 1.0;
uniform float roughness_bias : hint_range(-0.5, 0.5) = 0.0;
uniform float roughness_default : hint_range(0.0, 1.0) = 0.92;

// Meters per cycle for the per-variant noise heights that drive
// height-blended winner selection. Larger = bigger patches of one
// variant before transitioning to another. ~30-50 m is the sweet
// spot for "distinct rock outcrops in a grass field" reads. Above
// 100 m you get whole-region domination by single variants (boring);
// below 15 m the patches dissolve into per-pixel noise (busy).
uniform float variant_scale_m : hint_range(10.0, 200.0) = 35.0;

// How aggressively variants compete with the primary in the height-
// blended winner selection.
//   0.0 = primary always wins (no variants visible)
//   1.0 = primary competes equally (variants dominate ~75% of pixels)
//   ~0.6-0.7 = primary still character-defining, variants get ~40%
//              of pixels as distinct patches (recommended).
uniform float variant_strength : hint_range(0.0, 1.0) = 0.65;

// Base world-space meters per texture repeat.
//
// **Match this to what the 4K texture actually depicts.** Poly
// Haven `aerial_*` / AmbientCG ground textures are typically shot
// at 1–2 m of real ground per full 4K tile. Setting tile_scale_m
// higher than that stretches the content — leaves, pebbles, grass
// blades all scale with the tile, so at 12 m repeat a leaf reads
// as a meter across. 2.5 m is a reasonable middle: textures show
// realistic detail at ground level, and the anti-repetition stack
// (triplanar + domain warp + variant + macro) hides the tiling.
uniform float tile_scale_m : hint_range(0.5, 10.0) = 2.5;

// Macro-scale secondary sample — same textures at a larger tile,
// blended on top of the base sample for gentle large-scale color
// variation across many repeats of the base.
uniform float macro_blend : hint_range(0.0, 1.0) = 0.35;
uniform float macro_tile_multiplier : hint_range(1.0, 20.0) = 8.0;

// Total map extent in meters — used to convert UV (0..1) into
// world-space meters for the tiled sample. Set by TerrainNode.
uniform vec2 terrain_extent_m = vec2(5000.0, 3500.0);

// Debug mode: when nonzero, output alternative visualizations so
// we can diagnose which part of the pipeline is misbehaving.
//   0 = textured (production)
//   1 = per-class palette (class coverage + boundaries, no textures)
//   2 = single-texture-per-class, no 4-corner blend
//   3 = face normal as color (x→R, y→G, z→B, each mapped 0..1).
//       A mostly-GREEN frame means everything's flat; on a mountain
//       face we expect red/blue tint where the slope faces that axis.
//   4 = triplanar blend weights (R=YZ plane, G=XZ plane, B=XY plane).
//       A mostly-green mountain face means triplanar thinks it's
//       flat (bad). Should be red/blue on slopes.
uniform int debug_mode : hint_range(0, 4) = 0;

// Domain warp on the features-grid UV before class lookup, applied
// as two octaves:
//
// * **Primary (amplitude/scale)** — large organic meander. Big
//   enough amplitude that straight 10 m ESA cell edges bend into
//   natural-looking coastlines / treelines over tens of meters.
// * **Fine (fine_amplitude/fine_scale)** — feathering at the
//   individual-cell scale. Scrambles pixels across class boundaries
//   into organic fray, so edges don't read as a rasterized step.
//
// Rule of thumb: primary amplitude ~= ESA cell size, fine amplitude
// ~= half cell, primary scale 3-6× cell size, fine scale ~cell size.
uniform float boundary_warp_amplitude_m : hint_range(0.0, 50.0) = 18.0;
uniform float boundary_warp_scale_m : hint_range(10.0, 200.0) = 55.0;
uniform float boundary_warp_fine_amplitude_m : hint_range(0.0, 20.0) = 6.0;
uniform float boundary_warp_fine_scale_m : hint_range(3.0, 30.0) = 9.0;

// Low-frequency per-fragment color modulation. Multiplies the final
// albedo by a slowly-varying ~unit-mean color factor, so "one big
// field of grass" reads as a natural mosaic of light/dark/warmer/
// cooler patches instead of a uniform tiled photo. Strength is the
// peak deviation per channel (0.1 = ±10%).
uniform float color_var_scale_m : hint_range(10.0, 300.0) = 60.0;
uniform float color_var_strength : hint_range(0.0, 0.4) = 0.12;

// How much the per-fragment face normal (from dFdx/dFdy derivatives)
// dominates over the interpolated vertex normal.
//
// face_n gives each triangle a flat, facet-correct normal — great
// for sharp triplanar projection selection on steep slopes, bad for
// smoothness because adjacent triangles jump to a different normal
// and the triplanar blend weights flip at every triangle edge. The
// visible symptom is horizontal banding across mountain faces where
// each mesh row reads as a distinct stripe.
//
// 0.0 = fully smooth (interpolated vertex normal — softer but
// texture can stretch on slopes).
// 1.0 = fully faceted (original face_n behavior — sharp but banded).
// ~0.6 keeps enough face_n to suppress stretching while blurring
// the per-facet jumps that cause the banding.
uniform float face_normal_strength : hint_range(0.0, 1.0) = 0.6;

// ---- Stochastic tiling helpers ---------------------------------------------

// Deterministic 2D hash returning a value in [0,1). Good enough
// for per-tile rotation / offset randomness without needing a
// noise texture.
vec2 hash22(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)),
             dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// Smooth 2D value noise in [0, 1]. Used to warp class-boundary
// lookups so ESA's rectangular 10 m cells read as organic shapes
// rather than a grid of rectangles.
float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash22(i).x;
    float b = hash22(i + vec2(1.0, 0.0)).x;
    float c = hash22(i + vec2(0.0, 1.0)).x;
    float d = hash22(i + vec2(1.0, 1.0)).x;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 3-octave 2D domain-warp vector, values roughly in [-1, 1].
// Three decoupled phases (offsets + frequency multipliers) so the
// output has content at large/medium/small scales without repeating
// at any one of them. Used for both the class-boundary warp and the
// texture-UV warp — callers scale `p` by a per-use "meters per
// cycle" before calling.
vec2 domain_warp(vec2 p) {
    vec2 off_a = vec2(37.2, 91.4);
    vec2 off_b = vec2(17.9, 43.7);
    vec2 off_c = vec2(73.1, 29.8);
    vec2 o1 = vec2(
        value_noise(p)               * 2.0 - 1.0,
        value_noise(p + off_a)       * 2.0 - 1.0
    );
    vec2 o2 = vec2(
        value_noise(p * 2.1 + off_b)         * 2.0 - 1.0,
        value_noise(p * 2.1 + off_b + off_a) * 2.0 - 1.0
    );
    vec2 o3 = vec2(
        value_noise(p * 4.7 + off_c)         * 2.0 - 1.0,
        value_noise(p * 4.7 + off_c + off_a) * 2.0 - 1.0
    );
    return o1 * 0.55 + o2 * 0.30 + o3 * 0.15;
}

// Meters per cycle for the **texture-UV** domain warp. Smaller than
// the class-boundary warp — this one's job is just to bend the
// texture coordinates gently so the underlying tile grid doesn't
// read as straight lines. Keep the amplitude subtle (<= 0.2× tile
// scale) or the texture itself looks smeared.
uniform float texture_warp_scale_m : hint_range(5.0, 60.0) = 18.0;
uniform float texture_warp_amplitude : hint_range(0.0, 0.25) = 0.08;

// Size of a stochastic macrocell in tile units. Stochastic tiling
// (Heitz & Neyret '18, simplified 2-tap form) randomizes the UV
// origin per cell so the regular world-space grid disappears.
//
// **Use 1.0** for the strongest effect: every individual tile gets
// its own hash-random origin. Anything larger means the intra-cell
// grid is still visible, which defeats the whole point — I shipped
// 5.0 first and the A/B slider correctly showed ~no difference
// because within each 5×5 macrocell the texture was still a plain
// regular tiling. Values > 1 exist for softer "patches" if the
// per-tile randomization feels too noisy.
uniform float stochastic_cell_tiles : hint_range(1.0, 16.0) = 1.0;
uniform float stochastic_strength : hint_range(0.0, 1.0) = 1.0;

// 2-tap stochastic texture sample with per-cell **rotation + offset**.
// Takes a plain tile-space UV (already divided by tile_m), buckets
// world-space into macrocells of `stochastic_cell_tiles` tile repeats
// per edge, and samples the texture at two independently hash-rotated
// + hash-offset copies of the grid, blending by a smooth hashed weight.
//
// **Why rotation matters.** Offset-only stochastic tiling (the prior
// version) shifts the texture per cell but keeps the orientation
// fixed. So adjacent cells show the same texture content with the
// same orientation — features that point northeast in cell A also
// point northeast in cell B. The eye locks onto that recurring
// orientation as "this is a tiled photo" even when the offsets
// differ. Per-cell rotation around each cell's center gives each
// tile a different orientation, breaking the orientation-recurrence
// the eye uses to detect tiling.
//
// **Cost.** 2 texture reads + 2 sin/cos pairs + 4 mat2 muls. Cheap.
//
// **Caveat for normal maps.** Rotating the UV rotates the tangent
// frame the normal-map xy components live in. Callers that sample a
// normal map need to counter-rotate the .xy of the result by the
// same per-cell angle to bring it back to world tangent frame. We
// don't do that here because a single function-level result has
// already been blended across two rotations; normal-map sampling
// uses `stochastic_normal_tex2d` below which keeps the rotations
// separate and counter-rotates each before the blend.
vec3 stochastic_tex2d(sampler2DArray arr, float layer, vec2 uv, float cell_tiles, float strength) {
    vec2 gp = uv / cell_tiles;
    vec2 c1 = floor(gp);
    vec2 c2 = floor(gp - vec2(0.5));

    // Per-cell random offset.
    vec2 off1 = hash22(c1)                  * cell_tiles * strength;
    vec2 off2 = hash22(c2 + vec2(31.7, 7.1)) * cell_tiles * strength;

    // Per-cell random rotation, hashed off a different basis to
    // decorrelate rotation from offset.
    float a1 = hash22(c1 + vec2(53.7, 11.3)).x * 6.28318;
    float a2 = hash22(c2 + vec2(91.1, 29.5)).x * 6.28318;
    float ca1 = cos(a1), sa1 = sin(a1);
    float ca2 = cos(a2), sa2 = sin(a2);
    mat2 rot1 = mat2(vec2(ca1, sa1), vec2(-sa1, ca1));
    mat2 rot2 = mat2(vec2(ca2, sa2), vec2(-sa2, ca2));

    // Rotate UV around the cell center. Cell center in tile-space:
    // (c + 0.5) * cell_tiles. Translate to center, rotate, translate
    // back. This keeps the rotation localized — adjacent cells rotate
    // around their own centers, not a shared origin.
    vec2 cc1 = (c1 + 0.5) * cell_tiles;
    vec2 cc2 = (c2 + vec2(0.5) + vec2(0.5)) * cell_tiles;
    vec2 ruv1 = rot1 * (uv - cc1) + cc1 + off1;
    vec2 ruv2 = rot2 * (uv - cc2) + cc2 + off2;

    // Derivatives have to be rotated too — the GPU uses them to pick
    // a mip level, and an unrotated derivative gives a wrong-anisotropy
    // sample for a rotated UV. Without this, rotated cells would alias
    // at glancing angles.
    vec2 dx = dFdx(uv);
    vec2 dy = dFdy(uv);
    vec3 s1 = textureGrad(arr, vec3(fract(ruv1), layer), rot1 * dx, rot1 * dy).rgb;
    vec3 s2 = textureGrad(arr, vec3(fract(ruv2), layer), rot2 * dx, rot2 * dy).rgb;

    float w = smoothstep(0.25, 0.75, value_noise(gp * 2.0 + vec2(11.3, 27.1)));
    return mix(s1, s2, w);
}

// Stochastic sample for **normal maps**. Same per-cell rotation +
// offset as `stochastic_tex2d`, but counter-rotates each sample's
// tangent-space .xy components back to the world tangent frame
// before blending. Without this the per-cell rotation would inject
// random per-tile lighting bias.
//
// Returns the unpacked tangent-space normal in [-1, 1] range
// (caller does not remap — different convention from the diffuse
// helper which returns [0, 1] sample). Pass to a Whiteout-style
// triplanar accumulator.
vec3 stochastic_normal_tex2d(sampler2DArray arr, float layer, vec2 uv, float cell_tiles, float strength) {
    vec2 gp = uv / cell_tiles;
    vec2 c1 = floor(gp);
    vec2 c2 = floor(gp - vec2(0.5));

    vec2 off1 = hash22(c1)                  * cell_tiles * strength;
    vec2 off2 = hash22(c2 + vec2(31.7, 7.1)) * cell_tiles * strength;

    float a1 = hash22(c1 + vec2(53.7, 11.3)).x * 6.28318;
    float a2 = hash22(c2 + vec2(91.1, 29.5)).x * 6.28318;
    float ca1 = cos(a1), sa1 = sin(a1);
    float ca2 = cos(a2), sa2 = sin(a2);
    mat2 rot1 = mat2(vec2(ca1, sa1), vec2(-sa1, ca1));
    mat2 rot2 = mat2(vec2(ca2, sa2), vec2(-sa2, ca2));

    vec2 cc1 = (c1 + 0.5) * cell_tiles;
    vec2 cc2 = (c2 + vec2(0.5) + vec2(0.5)) * cell_tiles;
    vec2 ruv1 = rot1 * (uv - cc1) + cc1 + off1;
    vec2 ruv2 = rot2 * (uv - cc2) + cc2 + off2;

    vec2 dx = dFdx(uv);
    vec2 dy = dFdy(uv);
    vec3 s1 = textureGrad(arr, vec3(fract(ruv1), layer), rot1 * dx, rot1 * dy).rgb;
    vec3 s2 = textureGrad(arr, vec3(fract(ruv2), layer), rot2 * dx, rot2 * dy).rgb;

    // Decode + counter-rotate. Inverse of the UV rotation is the
    // transpose of the 2D rotation matrix (orthonormal property).
    s1.xy = s1.xy * 2.0 - 1.0;
    s2.xy = s2.xy * 2.0 - 1.0;
    s1.xy = mat2(vec2(ca1, -sa1), vec2(sa1, ca1)) * s1.xy;
    s2.xy = mat2(vec2(ca2, -sa2), vec2(sa2, ca2)) * s2.xy;

    float w = smoothstep(0.25, 0.75, value_noise(gp * 2.0 + vec2(11.3, 27.1)));
    return mix(s1, s2, w);
}

// Triplanar sample: project world position onto the three world
// axis planes (XZ/top, XY/side, YZ/side), sample each, and blend by
// the surface normal so vertical cliffs use the side projection
// (no horizontal stretching) while flat ground uses the top
// projection. The `sharpness` power on the blend weights (default
// 4.0) ensures the top dominates wherever the surface is near-flat,
// so the majority of terrain still sees a single-sample cost.
//
// Cost note: with stochastic sampling (2 tex reads per projection)
// and 4-corner × primary+3 variants × 2-scale × triplanar, worst
// case is 192 samples per fragment. Fine on any desktop GPU.
vec3 sample_triplanar(
    sampler2DArray arr,
    float layer,
    vec3 world_pos,
    vec3 n,
    float tile_m
) {
    // Sharp blend: flat surfaces stay fully top-projected; anything
    // past ~30° from horizontal starts getting meaningful side
    // contribution; ~60°+ slopes are almost entirely side-projected.
    // Power 8 is a good middle ground — lower values bleed between
    // projections on gentle slopes (stretched-looking textures),
    // higher values create visibly sharp transitions at moderate
    // inclines.
    vec3 blend = pow(abs(n), vec3(8.0));
    blend /= max(dot(blend, vec3(1.0)), 1e-4);

    // Subtle per-projection domain warp to break grid alignment
    // without introducing cell-rotation artifacts.
    vec2 warp_xz = domain_warp(world_pos.xz / texture_warp_scale_m) * texture_warp_amplitude;
    vec2 warp_xy = domain_warp(world_pos.xy / texture_warp_scale_m) * texture_warp_amplitude;
    vec2 warp_yz = domain_warp(world_pos.yz / texture_warp_scale_m) * texture_warp_amplitude;

    // Per-projection UV decoupling. The naive triplanar (xz / xy / yz
    // straight through) has XY and YZ projections both keyed on
    // world-Y, so any texture feature aligned with the V axis of the
    // diffuse shows up as a horizontal band in 3D — and both side
    // projections reinforce that band on mountain faces, producing
    // the "contour line" artifact.
    //
    // Fix: axis-swap XY → YX and YZ → ZY, plus a phase offset per
    // projection. Now texture-V maps to a different world axis in
    // each projection, so horizontal bands don't coincide. The phase
    // offset also ensures the three projections sample different
    // parts of the texture even where they overlap.
    //
    // This is safe for diffuse-only; normal/AO maps would need the
    // orientation baked into their tangent frames if we add them.
    vec2 uv_xz = world_pos.xz / tile_m + warp_xz;
    vec2 uv_xy = world_pos.yx / tile_m + warp_xy + vec2(0.37, 0.71);
    vec2 uv_yz = world_pos.zy / tile_m + warp_yz + vec2(0.83, 0.29);

    vec3 xz = stochastic_tex2d(arr, layer, uv_xz, stochastic_cell_tiles, stochastic_strength);
    vec3 xy = stochastic_tex2d(arr, layer, uv_xy, stochastic_cell_tiles, stochastic_strength);
    vec3 yz = stochastic_tex2d(arr, layer, uv_yz, stochastic_cell_tiles, stochastic_strength);

    return xz * blend.y + xy * blend.z + yz * blend.x;
}

// Sample all four class diffuse arrays (triplanar each) and pick a
// **per-fragment winner** via noise-driven height blending. Industry-
// standard approach: each variant gets an independent low-frequency
// noise field; whichever variant has the highest "height" at this
// pixel wins, with a narrow soft-blend zone around the tie line.
//
// Why this beats the old `mix()` approach: linear blends average
// colors (rock + grass at 50% = muddy yellow-green). Height-blend
// picks one variant per pixel, so you actually see "rock here, grass
// there" with sharp organic boundaries — the rocks-peeking-through
// effect that PolyHaven aerial textures show in their preview shots.
//
// `variant_strength` controls how aggressively variants compete with
// the primary:
//   0.0 = primary always wins (no variants visible)
//   1.0 = primary competes equally with all variants (maximally chaotic)
//   ~0.6 = primary dominates ~60% of the surface; variants fill the
//          rest with distinct patches (good default for natural look)
//
// **Must be defined after `sample_triplanar`** — GLSL is forward-
// reference strict.
vec3 sample_with_variant(float layer, vec3 world_pos, vec3 n, float tile_m) {
    vec3 t0 = sample_triplanar(diffuse_array,  layer, world_pos, n, tile_m);
    vec3 t1 = sample_triplanar(variant_array,  layer, world_pos, n, tile_m);
    vec3 t2 = sample_triplanar(variant2_array, layer, world_pos, n, tile_m);
    vec3 t3 = sample_triplanar(variant3_array, layer, world_pos, n, tile_m);

    // Per-variant noise heights. Phase- and frequency-decoupled so
    // each variant has its own "patch domain" — the locations where
    // it dominates form independent organic shapes.
    vec2 p = world_pos.xz;
    float h0 = value_noise(p / variant_scale_m);
    float h1 = value_noise(p / variant_scale_m + vec2(27.3, 53.1));
    float h2 = value_noise(p / (variant_scale_m * 0.85) + vec2(71.9, 19.7));
    float h3 = value_noise(p / (variant_scale_m * 1.15) + vec2(11.7, 41.5));

    // Bias the primary so it tends to win — without this, variants
    // dominate 75% of the surface and the primary character is lost.
    h0 += (1.0 - variant_strength);

    // Height-blend (Unity-HDRP / Unreal-Landscape style). Only
    // variants within `blend_height` of the winner contribute. Most
    // pixels: a single variant wins outright. Narrow transition zones:
    // smooth blend between two near-equal variants. No more averaging
    // four textures into mud.
    float hmax = max(max(h0, h1), max(h2, h3));
    const float blend_height = 0.06;
    float w0 = max(h0 - hmax + blend_height, 0.0);
    float w1 = max(h1 - hmax + blend_height, 0.0);
    float w2 = max(h2 - hmax + blend_height, 0.0);
    float w3 = max(h3 - hmax + blend_height, 0.0);
    float wsum = max(w0 + w1 + w2 + w3, 1e-4);
    return (t0 * w0 + t1 * w1 + t2 * w2 + t3 * w3) / wsum;
}

// Per-class tile scale multiplier. Different materials read naturally
// at different physical scales — snow grains are sub-meter, cliff
// faces span several meters per visible feature, road surface texture
// is dense at ~1 m. Multiplied by the global `tile_scale_m` uniform
// so the Inspector slider stays a single "global zoom" while each
// class gets its appropriate density.
//
// Layer index = FeatureClass discriminant. Branches compile to a
// flat if-chain on the GPU — fine for the ~12 productive classes.
float per_class_tile_multiplier(float layer) {
    int c = int(layer + 0.5);
    if (c == 1)  return 0.6;   // Water — fine ripples (placeholder)
    if (c == 2)  return 1.4;   // Forest — coarser leaf/needle litter
    if (c == 3)  return 1.6;   // Shrubland — rocky scrub, larger features
    if (c == 4)  return 0.7;   // Grassland — fine grass blades
    if (c == 5)  return 1.0;   // Cropland — rows at moderate scale
    if (c == 6)  return 0.9;   // BuiltUp — concrete texture detail
    if (c == 7)  return 0.8;   // Bare — fine dirt/pebble grain
    if (c == 8)  return 0.4;   // Snow — fine grain (avoid huge snow-blob tiles)
    if (c == 9)  return 0.9;   // Wetland — moderate
    if (c == 10) return 0.6;   // Moss — fine
    if (c == 20) return 1.8;   // Cliff — large rock features
    if (c == 21) return 0.7;   // PavedRoad — asphalt detail
    if (c == 22) return 0.7;   // UnpavedRoad — gravel
    if (c == 23) return 0.5;   // Trail — fine dirt path
    return 1.0;                // Unknown / gap — default
}

// Triplanar **normal-map** sample — Whiteout-blend variant.
// Instead of sampling a full world-space normal vector per
// projection, we treat each plane's tangent normal as a 2D
// perturbation (texture R, G) of the world axes the plane is
// parameterized by, leaving the plane's outward axis unperturbed.
// Three perturbation vectors blended by the same triplanar weights
// as diffuse → a perturbation vector that, added to the geometric
// face normal, produces tangent-space-equivalent micro-detail
// without any tangent matrix. Cheaper than full per-projection
// normal reorientation and visually indistinguishable on terrain.
//
// The UV swizzles must match `sample_triplanar` exactly so the
// micro-detail aligns with the diffuse pattern — same axes, same
// phase offsets — otherwise normals would lift in places where the
// diffuse shows seams.
//
// **BC5/BPTC normal compression dropped the .b channel.** We
// reconstruct .z from `sqrt(1 - x² - y²)` after the [-1,1] remap.
// On uncompressed sources .z is already correct, so this is also
// safe there. Only .x and .y are used in the perturbation anyway,
// so .z reconstruction is mostly bookkeeping for clarity.
vec3 sample_normal_triplanar(
    sampler2DArray arr,
    float layer,
    vec3 world_pos,
    vec3 n,
    float tile_m
) {
    vec3 blend = pow(abs(n), vec3(8.0));
    blend /= max(dot(blend, vec3(1.0)), 1e-4);

    vec2 warp_xz = domain_warp(world_pos.xz / texture_warp_scale_m) * texture_warp_amplitude;
    vec2 warp_xy = domain_warp(world_pos.xy / texture_warp_scale_m) * texture_warp_amplitude;
    vec2 warp_yz = domain_warp(world_pos.yz / texture_warp_scale_m) * texture_warp_amplitude;

    vec2 uv_xz = world_pos.xz / tile_m + warp_xz;
    vec2 uv_xy = world_pos.yx / tile_m + warp_xy + vec2(0.37, 0.71);
    vec2 uv_yz = world_pos.zy / tile_m + warp_yz + vec2(0.83, 0.29);

    vec3 nm_xz = stochastic_normal_tex2d(arr, layer, uv_xz, stochastic_cell_tiles, stochastic_strength);
    vec3 nm_xy = stochastic_normal_tex2d(arr, layer, uv_xy, stochastic_cell_tiles, stochastic_strength);
    vec3 nm_yz = stochastic_normal_tex2d(arr, layer, uv_yz, stochastic_cell_tiles, stochastic_strength);
    // stochastic_normal_tex2d already returns counter-rotated tangent
    // normals in [-1, 1] range — no remap needed here.

    // Whiteout perturbations. For each projection, the tangent
    // texture R/G correspond to perturbation along the world axes
    // that parameterize the plane (matching the swizzles in
    // `sample_triplanar`). The plane's outward axis stays at 0
    // here — the geometric face normal supplies it after the sum.
    //
    //   uv_xz = world.xz   → R perturbs world.x, G perturbs world.z
    //   uv_xy = world.yx   → R perturbs world.y, G perturbs world.x
    //   uv_yz = world.zy   → R perturbs world.z, G perturbs world.y
    vec3 p_xz = vec3(nm_xz.x, 0.0,      nm_xz.y);
    vec3 p_xy = vec3(nm_xy.y, nm_xy.x,  0.0    );
    vec3 p_yz = vec3(0.0,     nm_yz.y,  nm_yz.x);

    return p_xz * blend.y + p_xy * blend.z + p_yz * blend.x;
}

// Triplanar **roughness** sample. Sample three projections, blend
// by the same weights as diffuse so corners read as the same
// material. Returns a single float (the .r channel — both PolyHaven
// and AmbientCG roughness textures store identical values across
// r/g/b). Cheaper than diffuse — no variant stack — but reuses the
// stochastic tiling so the roughness pattern doesn't read as a
// repeating grid that diverges from the (variant-rich) diffuse.
float sample_roughness_triplanar(
    sampler2DArray arr,
    float layer,
    vec3 world_pos,
    vec3 n,
    float tile_m
) {
    vec3 blend = pow(abs(n), vec3(8.0));
    blend /= max(dot(blend, vec3(1.0)), 1e-4);

    vec2 warp_xz = domain_warp(world_pos.xz / texture_warp_scale_m) * texture_warp_amplitude;
    vec2 warp_xy = domain_warp(world_pos.xy / texture_warp_scale_m) * texture_warp_amplitude;
    vec2 warp_yz = domain_warp(world_pos.yz / texture_warp_scale_m) * texture_warp_amplitude;

    vec2 uv_xz = world_pos.xz / tile_m + warp_xz;
    vec2 uv_xy = world_pos.yx / tile_m + warp_xy + vec2(0.37, 0.71);
    vec2 uv_yz = world_pos.zy / tile_m + warp_yz + vec2(0.83, 0.29);

    float r_xz = stochastic_tex2d(arr, layer, uv_xz, stochastic_cell_tiles, stochastic_strength).r;
    float r_xy = stochastic_tex2d(arr, layer, uv_xy, stochastic_cell_tiles, stochastic_strength).r;
    float r_yz = stochastic_tex2d(arr, layer, uv_yz, stochastic_cell_tiles, stochastic_strength).r;

    return r_xz * blend.y + r_xy * blend.z + r_yz * blend.x;
}

// ---- Debug palette ---------------------------------------------------------

vec3 class_palette(int idx) {
    if (idx == 1) return vec3(0.12, 0.28, 0.40);        // Water
    else if (idx == 2) return vec3(0.18, 0.35, 0.18);   // Forest
    else if (idx == 3) return vec3(0.45, 0.45, 0.25);   // Shrubland
    else if (idx == 4) return vec3(0.55, 0.58, 0.28);   // Grassland
    else if (idx == 5) return vec3(0.62, 0.55, 0.25);   // Cropland
    else if (idx == 6) return vec3(0.45, 0.42, 0.40);   // BuiltUp
    else if (idx == 7) return vec3(0.60, 0.52, 0.38);   // Bare
    else if (idx == 8) return vec3(0.90, 0.92, 0.95);   // Snow
    else if (idx == 9) return vec3(0.30, 0.38, 0.28);   // Wetland
    else if (idx == 10) return vec3(0.42, 0.50, 0.32);  // Moss
    else if (idx == 20) return vec3(0.50, 0.45, 0.40);  // Cliff
    else if (idx == 21) return vec3(0.22, 0.22, 0.24);  // PavedRoad
    else if (idx == 22) return vec3(0.48, 0.38, 0.24);  // UnpavedRoad
    else if (idx == 23) return vec3(0.58, 0.48, 0.32);  // Trail
    else return vec3(0.40, 0.40, 0.40);                 // Unknown
}

// ---- Vertex ----------------------------------------------------------------

void vertex() {
    // With `world_vertex_coords` render_mode above, VERTEX is already
    // in world space. NORMAL stays in model space, so we transform
    // it explicitly via MODEL_MATRIX. For TerrainNode's pure-
    // translation transform this is a no-op, but being explicit
    // protects against future parents that rotate the terrain.
    v_world_pos = VERTEX;
    v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// ---- Fragment --------------------------------------------------------------

void fragment() {
    vec3 world_pos = v_world_pos;

    // Per-fragment face normal from world-position derivatives.
    // Interpolated vertex normals (`v_world_normal`) smooth out
    // across adjacent triangles, which softens the triplanar blend
    // and leaves visible texture stretching on steep slopes where
    // the interpolated normal doesn't match the actual facet
    // orientation. `dFdx` + `dFdy` give the true face normal at the
    // current pixel. Falls back to the vertex normal's sign to keep
    // the result pointing outward (triangle winding can flip the
    // cross-product direction).
    vec3 dpx = dFdx(world_pos);
    vec3 dpy = dFdy(world_pos);
    vec3 face_n = normalize(cross(dpx, dpy));
    if (dot(face_n, v_world_normal) < 0.0) {
        face_n = -face_n;
    }
    // Blend toward the interpolated vertex normal to soften per-facet
    // triplanar discontinuities (see `face_normal_strength` uniform).
    vec3 world_n = normalize(
        mix(v_world_normal, face_n, face_normal_strength)
    );

    // Domain-warp the UV before class lookup so ESA's rectangular
    // class cells become organic, frayed shapes instead of straight
    // grid-aligned edges. Two octaves in world-space meters:
    //
    //   * Primary — bends big boundaries (rivers, forest edges) into
    //     natural meander at tens of meters.
    //   * Fine — feathers individual cell edges so class transitions
    //     read as organic fray rather than a rasterized staircase.
    //
    // Without the fine octave, doubling the primary amplitude just
    // makes bigger straight-ish wobbles; the two-scale combo is what
    // kills the "minecraft" look.
    vec2 world_m = UV * terrain_extent_m;
    vec2 warp_large = domain_warp(world_m / boundary_warp_scale_m)
                    * boundary_warp_amplitude_m;
    vec2 warp_fine  = domain_warp(world_m / boundary_warp_fine_scale_m)
                    * boundary_warp_fine_amplitude_m;
    vec2 warped_world_m = world_m + warp_large + warp_fine;
    vec2 warped_UV = warped_world_m / terrain_extent_m;

    // Locate the 4 features-grid texels around this position. Use
    // **unwarped UV** so line classes (PavedRoad / UnpavedRoad /
    // Trail) at their native 1-3 cell width survive the lookup —
    // sampling at `warped_UV` displaces the fetch by up to
    // boundary_warp_amplitude_m (~18 m), much wider than the road
    // brush, so most road pixels would lookup an off-road cell and
    // the line overlay would silently disappear.
    ivec2 fsz = textureSize(features_texture, 0);
    vec2 f_uv = UV * vec2(fsz) - 0.5;
    vec2 f00 = floor(f_uv);
    vec2 frac = f_uv - f00;
    ivec2 lo = ivec2(f00);
    ivec2 p00 = clamp(lo,                     ivec2(0), fsz - ivec2(1));
    ivec2 p10 = clamp(lo + ivec2(1, 0),       ivec2(0), fsz - ivec2(1));
    ivec2 p01 = clamp(lo + ivec2(0, 1),       ivec2(0), fsz - ivec2(1));
    ivec2 p11 = clamp(lo + ivec2(1, 1),       ivec2(0), fsz - ivec2(1));

    float c00 = texelFetch(features_texture, p00, 0).r * 255.0 + 0.5;
    float c10 = texelFetch(features_texture, p10, 0).r * 255.0 + 0.5;
    float c01 = texelFetch(features_texture, p01, 0).r * 255.0 + 0.5;
    float c11 = texelFetch(features_texture, p11, 0).r * 255.0 + 0.5;

    // Bilinear weights (sum to 1).
    float w00 = (1.0 - frac.x) * (1.0 - frac.y);
    float w10 = frac.x         * (1.0 - frac.y);
    float w01 = (1.0 - frac.x) * frac.y;
    float w11 = frac.x         * frac.y;

    vec3 diffuse;

    if (debug_mode == 3) {
        // Face normal visualization. Map [-1, 1] → [0, 1] per axis.
        diffuse = world_n * 0.5 + 0.5;
    } else if (debug_mode == 4) {
        // Triplanar blend weights — R = YZ plane (x-facing side),
        // G = XZ plane (top), B = XY plane (z-facing side).
        vec3 blend = pow(abs(world_n), vec3(8.0));
        blend /= max(dot(blend, vec3(1.0)), 1e-4);
        diffuse = vec3(blend.x, blend.y, blend.z);
    } else if (debug_mode == 1) {
        // Class palette only — smooth-blended, no textures.
        diffuse =
            class_palette(int(floor(c00))) * w00 +
            class_palette(int(floor(c10))) * w10 +
            class_palette(int(floor(c01))) * w01 +
            class_palette(int(floor(c11))) * w11;
    } else if (debug_mode == 2) {
        // Single-texture-per-class (no 4-corner blend). Diagnoses
        // "is blending the problem, or are the textures themselves
        // too similar?"
        int c_nearest = int(floor(
            w00 >= max(w10, max(w01, w11)) ? c00 :
            w10 >= max(w01, w11) ? c10 :
            w01 >= w11 ? c01 : c11
        ));
        diffuse = sample_triplanar(
            diffuse_array, float(c_nearest), world_pos, world_n, tile_scale_m
        );
    } else {
        // **Production path.** Two flavors:
        //
        // - **Splatmap × variant** (when splatmap_present): per-pixel
        //   class blend weights from `splatmap_a/b` sampled at
        //   filter_linear give sub-cell-precision class boundaries.
        //   Each channel's weight multiplies a variant-rich
        //   `sample_with_variant` call for that class. This is the
        //   splatmap approach done right after PR #49's first
        //   attempt dropped variants and looked flat.
        //
        // - **Legacy categorical** (no splatmap on disk): 4-corner
        //   bilinear with variant blending. Cell-precision class
        //   boundaries; visible 2 m steps.
        //
        // Channel → FeatureClass enum for the splatmap path:
        //   A.r Forest=2,  A.g Grassland=4,  A.b Water=1,  A.a Cropland=5
        //   B.r Bare=7,    B.g BuiltUp=6,    B.b Cliff=20, B.a Snow=8
        if (splatmap_present) {
            vec4 splat_a = texture(splatmap_a, UV);
            vec4 splat_b = texture(splatmap_b, UV);

            diffuse =
                sample_with_variant(2.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(2.0))  * splat_a.r +
                sample_with_variant(4.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(4.0))  * splat_a.g +
                sample_with_variant(1.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(1.0))  * splat_a.b +
                sample_with_variant(5.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(5.0))  * splat_a.a +
                sample_with_variant(7.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(7.0))  * splat_b.r +
                sample_with_variant(6.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(6.0))  * splat_b.g +
                sample_with_variant(20.0, world_pos, world_n, tile_scale_m * per_class_tile_multiplier(20.0)) * splat_b.b +
                sample_with_variant(8.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(8.0))  * splat_b.a;
        } else {
            float ts00 = tile_scale_m * per_class_tile_multiplier(floor(c00));
            float ts10 = tile_scale_m * per_class_tile_multiplier(floor(c10));
            float ts01 = tile_scale_m * per_class_tile_multiplier(floor(c01));
            float ts11 = tile_scale_m * per_class_tile_multiplier(floor(c11));
            float macro_mul = macro_tile_multiplier;

            vec3 base =
                sample_with_variant(floor(c00), world_pos, world_n, ts00) * w00 +
                sample_with_variant(floor(c10), world_pos, world_n, ts10) * w10 +
                sample_with_variant(floor(c01), world_pos, world_n, ts01) * w01 +
                sample_with_variant(floor(c11), world_pos, world_n, ts11) * w11;

            vec3 macro =
                sample_with_variant(floor(c00), world_pos, world_n, ts00 * macro_mul) * w00 +
                sample_with_variant(floor(c10), world_pos, world_n, ts10 * macro_mul) * w10 +
                sample_with_variant(floor(c01), world_pos, world_n, ts01 * macro_mul) * w01 +
                sample_with_variant(floor(c11), world_pos, world_n, ts11 * macro_mul) * w11;

            diffuse = mix(base, macro, macro_blend);
        }

        // **Line-class overlay** — driven by the bake-time
        // road_density texture (RGBA8 sampled at filter_linear).
        // Each channel is a per-pixel road weight 0..1:
        //
        //   R = PavedRoad   → diffuse_array layer 21 (asphalt)
        //   G = UnpavedRoad → diffuse_array layer 22 (gravel)
        //   B = Trail       → diffuse_array layer 23 (dirt path)
        //
        // Hardware filter_linear gives sub-cell-precision smoothing
        // of road edges + corner geometry — the per-class Gaussian
        // applied at bake time means we get smooth diagonal road
        // segments without the 2 m grid stair-step.
        //
        // Precedence by visual prominence: paved (highest weight),
        // then unpaved, then trail. Where a paved road and a trail
        // overlap (rare — but happens at trail crossings), the
        // paved texture wins.
        if (road_density_present) {
            vec4 rd = texture(road_density, UV);
            float total = rd.r + rd.g + rd.b;
            if (total > 0.001) {
                // Pick the dominant road class for the texture
                // pick (instead of cross-blending paved+unpaved
                // which produces a muddy in-between color).
                float layer;
                if (rd.r >= rd.g && rd.r >= rd.b) layer = 21.0;
                else if (rd.g >= rd.b) layer = 22.0;
                else layer = 23.0;
                vec3 road_tex = sample_triplanar(
                    diffuse_array, layer,
                    world_pos, world_n, tile_scale_m * per_class_tile_multiplier(layer)
                );
                // Use the dominant channel's weight as the blend
                // strength. Slight boost to keep road cores strong
                // even where Gaussian falloff dropped them below 1.
                // Treatment boost: 1.6× multiplier (was 1.2) so
                // roads stay visibly present out to the edge of
                // their blur halo, with a min weight of 0.4 inside
                // the road core so the road texture isn't washed
                // out by the underlying biome.
                float dom = max(max(rd.r, rd.g), rd.b);
                float road_weight = clamp(dom * 1.6, 0.0, 1.0);
                diffuse = mix(diffuse, road_tex, road_weight);
            }
        } else {
            // **Legacy fallback** for bakes that predate the
            // road_density texture. 5×5 in-shader Gaussian over
            // the categorical features.r8 grid — works but lacks
            // sub-cell precision so corners still show stair-step.
            ivec2 fc = ivec2(UV * vec2(fsz));
            float road_weight = 0.0;
            int line_class_int = -1;
            const float K[5] = float[5](0.05, 0.20, 0.50, 0.20, 0.05);
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    ivec2 q = clamp(fc + ivec2(dx, dy), ivec2(0), fsz - ivec2(1));
                    float cn = texelFetch(features_texture, q, 0).r * 255.0 + 0.5;
                    if (cn >= 21.0 && cn <= 23.0) {
                        float w = K[dx + 2] * K[dy + 2];
                        road_weight += w;
                        if (line_class_int < 0) line_class_int = int(floor(cn));
                    }
                }
            }
            road_weight = clamp(road_weight * 1.3, 0.0, 1.0);
            if (road_weight > 0.0 && line_class_int >= 0) {
                float lc = float(line_class_int);
                vec3 road_tex = sample_triplanar(
                    diffuse_array, lc,
                    world_pos, world_n, tile_scale_m * per_class_tile_multiplier(lc)
                );
                diffuse = mix(diffuse, road_tex, road_weight);
            }
        }

        // Low-frequency per-channel color modulation. Three noise
        // octaves at phase-decoupled scales, mapped to a ~unit-mean
        // RGB multiplier with peak deviation `color_var_strength`.
        // Breaks within-class uniformity (a whole field of identical
        // green) and softens class-boundary reads by letting
        // neighboring classes share overlapping color tints.
        vec2 cp = world_pos.xz;
        float cvR = value_noise(cp / color_var_scale_m);
        float cvG = value_noise(cp / (color_var_scale_m * 1.7) + vec2(41.0, 79.0));
        float cvB = value_noise(cp / (color_var_scale_m * 2.3) + vec2(13.7, 62.1));
        vec3 color_var = vec3(
            mix(1.0 - color_var_strength, 1.0 + color_var_strength, cvR),
            mix(1.0 - color_var_strength, 1.0 + color_var_strength, cvG),
            mix(1.0 - color_var_strength, 1.0 + color_var_strength, cvB)
        );
        diffuse *= color_var;
    }

    // ---- Normal + roughness (production path only) ---------------------
    //
    // Debug modes write a synthetic ALBEDO and want a flat-lit read,
    // so normal/roughness only run when `debug_mode == 0`. Normals
    // accumulate the same 4-corner / splatmap class weights as
    // diffuse so a forest/meadow boundary smoothly transitions
    // micro-detail too. Roads, when present, override the per-class
    // normal/rough with their own (asphalt / gravel / dirt-path).
    vec3 view_normal = NORMAL; // default: interpolated face normal
    float roughness_value = roughness_default;
    if (debug_mode == 0) {
        if (normal_present) {
            vec3 perturb;
            if (splatmap_present) {
                vec4 sa = texture(splatmap_a, UV);
                vec4 sb = texture(splatmap_b, UV);
                perturb =
                    sample_normal_triplanar(normal_array, 2.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(2.0))  * sa.r +
                    sample_normal_triplanar(normal_array, 4.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(4.0))  * sa.g +
                    sample_normal_triplanar(normal_array, 1.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(1.0))  * sa.b +
                    sample_normal_triplanar(normal_array, 5.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(5.0))  * sa.a +
                    sample_normal_triplanar(normal_array, 7.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(7.0))  * sb.r +
                    sample_normal_triplanar(normal_array, 6.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(6.0))  * sb.g +
                    sample_normal_triplanar(normal_array, 20.0, world_pos, world_n, tile_scale_m * per_class_tile_multiplier(20.0)) * sb.b +
                    sample_normal_triplanar(normal_array, 8.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(8.0))  * sb.a;
            } else {
                float ts00n = tile_scale_m * per_class_tile_multiplier(floor(c00));
                float ts10n = tile_scale_m * per_class_tile_multiplier(floor(c10));
                float ts01n = tile_scale_m * per_class_tile_multiplier(floor(c01));
                float ts11n = tile_scale_m * per_class_tile_multiplier(floor(c11));
                perturb =
                    sample_normal_triplanar(normal_array, floor(c00), world_pos, world_n, ts00n) * w00 +
                    sample_normal_triplanar(normal_array, floor(c10), world_pos, world_n, ts10n) * w10 +
                    sample_normal_triplanar(normal_array, floor(c01), world_pos, world_n, ts01n) * w01 +
                    sample_normal_triplanar(normal_array, floor(c11), world_pos, world_n, ts11n) * w11;
            }

            // Road overlay — same blending logic as diffuse: where a
            // road dominates, replace per-class perturb with the
            // road's own normal so wet asphalt rolls + gravel pebble
            // bumps come through instead of being averaged out by
            // the underlying biome.
            if (road_density_present) {
                vec4 rd = texture(road_density, UV);
                float dom = max(max(rd.r, rd.g), rd.b);
                if (dom > 0.001) {
                    float layer;
                    if (rd.r >= rd.g && rd.r >= rd.b) layer = 21.0;
                    else if (rd.g >= rd.b) layer = 22.0;
                    else layer = 23.0;
                    vec3 road_perturb = sample_normal_triplanar(
                        normal_array, layer, world_pos, world_n,
                        tile_scale_m * per_class_tile_multiplier(layer)
                    );
                    float road_weight = clamp(dom * 1.6, 0.0, 1.0);
                    perturb = mix(perturb, road_perturb, road_weight);
                }
            }

            vec3 perturbed_world_n = normalize(world_n + perturb * normal_strength);
            view_normal = (VIEW_MATRIX * vec4(perturbed_world_n, 0.0)).xyz;
        }

        if (roughness_present) {
            float r;
            if (splatmap_present) {
                vec4 sa = texture(splatmap_a, UV);
                vec4 sb = texture(splatmap_b, UV);
                r =
                    sample_roughness_triplanar(roughness_array, 2.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(2.0))  * sa.r +
                    sample_roughness_triplanar(roughness_array, 4.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(4.0))  * sa.g +
                    sample_roughness_triplanar(roughness_array, 1.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(1.0))  * sa.b +
                    sample_roughness_triplanar(roughness_array, 5.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(5.0))  * sa.a +
                    sample_roughness_triplanar(roughness_array, 7.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(7.0))  * sb.r +
                    sample_roughness_triplanar(roughness_array, 6.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(6.0))  * sb.g +
                    sample_roughness_triplanar(roughness_array, 20.0, world_pos, world_n, tile_scale_m * per_class_tile_multiplier(20.0)) * sb.b +
                    sample_roughness_triplanar(roughness_array, 8.0,  world_pos, world_n, tile_scale_m * per_class_tile_multiplier(8.0))  * sb.a;
            } else {
                float ts00r = tile_scale_m * per_class_tile_multiplier(floor(c00));
                float ts10r = tile_scale_m * per_class_tile_multiplier(floor(c10));
                float ts01r = tile_scale_m * per_class_tile_multiplier(floor(c01));
                float ts11r = tile_scale_m * per_class_tile_multiplier(floor(c11));
                r =
                    sample_roughness_triplanar(roughness_array, floor(c00), world_pos, world_n, ts00r) * w00 +
                    sample_roughness_triplanar(roughness_array, floor(c10), world_pos, world_n, ts10r) * w10 +
                    sample_roughness_triplanar(roughness_array, floor(c01), world_pos, world_n, ts01r) * w01 +
                    sample_roughness_triplanar(roughness_array, floor(c11), world_pos, world_n, ts11r) * w11;
            }

            if (road_density_present) {
                vec4 rd = texture(road_density, UV);
                float dom = max(max(rd.r, rd.g), rd.b);
                if (dom > 0.001) {
                    float layer;
                    if (rd.r >= rd.g && rd.r >= rd.b) layer = 21.0;
                    else if (rd.g >= rd.b) layer = 22.0;
                    else layer = 23.0;
                    float road_r = sample_roughness_triplanar(
                        roughness_array, layer, world_pos, world_n,
                        tile_scale_m * per_class_tile_multiplier(layer)
                    );
                    float road_weight = clamp(dom * 1.6, 0.0, 1.0);
                    r = mix(r, road_r, road_weight);
                }
            }

            roughness_value = clamp(r * roughness_strength + roughness_bias, 0.0, 1.0);
        }
    }

    ALBEDO = diffuse;
    NORMAL = view_normal;
    ROUGHNESS = roughness_value;
    METALLIC = 0.0;
    // **Do not write ALPHA** — in Godot 4 spatial shaders, any
    // assignment to ALPHA (even 1.0) flips the material into the
    // transparent render pass, which disables depth-write and
    // makes the terrain render see-through against the editor grid
    // and sky. Leave ALPHA alone to stay in the opaque pass.
}
