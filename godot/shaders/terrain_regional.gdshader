shader_type spatial;
render_mode cull_back, world_vertex_coords, diffuse_burley, specular_disabled;

// Regional backdrop shader — distant terrain rendered as a non-
// collidable mesh wrapping the playable bounds so the level edge
// doesn't read as a hard cliff.
//
// **Flat colors per class, no textures.** PolyHaven aerial textures
// look terrible at backdrop distance (tiling artifacts move with
// camera, mismatched scale, snow/water classes use placeholder rock
// images). Hand-curated colors per FeatureClass read cleanly against
// fog and don't have any animation artifacts. Adjustable via the
// Inspector if a class color needs tuning.
//
// Cost: ~3 features fetches + a small if-chain per fragment. Roughly
// 30× cheaper than the playable shader.

// Per-cell class index, raw R8 byte value (0-23 = FeatureClass
// discriminant). Same layout as the playable `features.r8`.
uniform sampler2D features_texture : filter_nearest;

// Tunable per-class colors (Inspector-editable). Defaults picked to
// read as PNW / Cascade Range biomes against the typical sky-blue
// horizon. Adjust here, no rebake needed.
uniform vec3 color_water     : source_color = vec3(0.16, 0.28, 0.42);
uniform vec3 color_forest    : source_color = vec3(0.16, 0.26, 0.13);
uniform vec3 color_shrubland : source_color = vec3(0.36, 0.38, 0.22);
uniform vec3 color_grassland : source_color = vec3(0.45, 0.50, 0.27);
uniform vec3 color_cropland  : source_color = vec3(0.55, 0.50, 0.30);
uniform vec3 color_builtup   : source_color = vec3(0.42, 0.40, 0.38);
uniform vec3 color_bare      : source_color = vec3(0.50, 0.45, 0.38);
uniform vec3 color_snow      : source_color = vec3(0.92, 0.94, 0.96);
uniform vec3 color_wetland   : source_color = vec3(0.30, 0.36, 0.25);
uniform vec3 color_cliff     : source_color = vec3(0.40, 0.36, 0.32);
uniform vec3 color_default   : source_color = vec3(0.42, 0.42, 0.38);

vec3 class_color(int c) {
    if (c == 1) return color_water;
    if (c == 2) return color_forest;
    if (c == 3) return color_shrubland;
    if (c == 4) return color_grassland;
    if (c == 5) return color_cropland;
    if (c == 6) return color_builtup;
    if (c == 7) return color_bare;
    if (c == 8) return color_snow;
    if (c == 9) return color_wetland;
    if (c == 20) return color_cliff;
    return color_default;
}

void fragment() {
    // 4-corner class lookup with bilinear weights so cell-boundary
    // transitions smear softly instead of stair-stepping. Cells
    // are 100 m at backdrop spacing — visible from a vantage but
    // not hard-edged.
    ivec2 fsz = textureSize(features_texture, 0);
    vec2 f_uv = UV * vec2(fsz) - 0.5;
    vec2 f00 = floor(f_uv);
    vec2 frac = f_uv - f00;
    ivec2 lo = ivec2(f00);
    ivec2 p00 = clamp(lo,                ivec2(0), fsz - ivec2(1));
    ivec2 p10 = clamp(lo + ivec2(1, 0),  ivec2(0), fsz - ivec2(1));
    ivec2 p01 = clamp(lo + ivec2(0, 1),  ivec2(0), fsz - ivec2(1));
    ivec2 p11 = clamp(lo + ivec2(1, 1),  ivec2(0), fsz - ivec2(1));

    int c00 = int(texelFetch(features_texture, p00, 0).r * 255.0 + 0.5);
    int c10 = int(texelFetch(features_texture, p10, 0).r * 255.0 + 0.5);
    int c01 = int(texelFetch(features_texture, p01, 0).r * 255.0 + 0.5);
    int c11 = int(texelFetch(features_texture, p11, 0).r * 255.0 + 0.5);

    float w00 = (1.0 - frac.x) * (1.0 - frac.y);
    float w10 = frac.x         * (1.0 - frac.y);
    float w01 = (1.0 - frac.x) * frac.y;
    float w11 = frac.x         * frac.y;

    ALBEDO =
        class_color(c00) * w00 +
        class_color(c10) * w10 +
        class_color(c01) * w01 +
        class_color(c11) * w11;
    ROUGHNESS = 0.95;
    METALLIC = 0.0;
    // Same as playable: don't write ALPHA (Godot 4 transparent-pass
    // gotcha — depth write disabled if any ALPHA write is present).
}
