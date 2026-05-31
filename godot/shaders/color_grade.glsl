// Color grading compositor effect — runs at POST_TRANSPARENT, before
// Godot's tonemap. We grade in HDR (linear scene-referred) space, which
// is the professionally-correct order: primary correction → tonemap →
// display.
//
// Pipeline order (per pixel):
//   1. Exposure  (stops, multiplicative in linear)
//   2. White balance  (temperature + tint, channel scale)
//   3. ASC CDL  (slope → offset → power; gain/lift/gamma)
//   4. Hue shift  (rotation in YIQ-derived chroma plane)
//   5. Saturation  (mix toward Rec.709 luminance)
//   6. Contrast  (around 0.18 mid-gray, the conventional HDR pivot)
//   7. Vignette  (multiplicative falloff in screen-space)

#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;

layout(push_constant, std430) uniform Params {
    // Tone (16 bytes)
    float exposure;
    float temperature;
    float tint;
    float hue_shift;

    // Saturation / contrast (8 bytes)
    float saturation;
    float contrast;
    float _pad_sc0;
    float _pad_sc1;

    // ASC CDL (48 bytes — three vec4s, RGB + master scalar in .a)
    vec4 lift;        // .rgb in [-0.5..0.5] practical range, .a master strength
    vec4 gamma_rgb;   // .rgb in [-0.5..0.5], .a master strength
    vec4 gain;        // .rgb in [-0.5..0.5], .a master strength

    // Vignette (16 bytes)
    float vignette_intensity;  // 0 = off, 1 = edges fully black
    float vignette_radius;     // distance from center where falloff starts
    float vignette_softness;   // width of the falloff band
    float _pad_v;

    // Image dimensions (8 bytes)
    vec2 image_size;
    vec2 _pad_s;
} P;

// Rec.709 luminance.
float luma709(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Hue rotation by `turns` (0..1 = full revolution). Done via the standard
// YIQ chroma-plane rotation — cheaper than RGB↔HSV and behaves correctly
// in HDR (no clipping required).
vec3 hue_rotate(vec3 c, float turns) {
    if (abs(turns) < 1e-5) return c;
    float a = turns * 6.28318530718;
    float s = sin(a);
    float k = cos(a);
    // Constructed from RGB→YIQ, rotate IQ by `a`, YIQ→RGB.
    mat3 m = mat3(
        0.299 + 0.701 * k + 0.168 * s,
        0.587 - 0.587 * k + 0.330 * s,
        0.114 - 0.114 * k - 0.497 * s,

        0.299 - 0.299 * k - 0.328 * s,
        0.587 + 0.413 * k + 0.035 * s,
        0.114 - 0.114 * k + 0.292 * s,

        0.299 - 0.300 * k + 1.250 * s,
        0.587 - 0.588 * k - 1.050 * s,
        0.114 + 0.886 * k - 0.203 * s
    );
    return m * c;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    if (coord.x >= int(P.image_size.x) || coord.y >= int(P.image_size.y)) return;

    vec3 col = imageLoad(color_image, coord).rgb;

    // 1. Exposure (stops → linear multiplier).
    col *= exp2(P.exposure);

    // 2. White balance — simple, fast channel-scale approximation. Real
    // chromatic adaptation needs a Bradford matrix, but for grading taste
    // this is close enough and 0-cost by comparison.
    col.r *= 1.0 + P.temperature * 0.20;
    col.b *= 1.0 - P.temperature * 0.20;
    col.g *= 1.0 + P.tint * 0.20;
    col = max(col, vec3(0.0));

    // 3. ASC CDL: out = (in * slope + offset) ^ (1/gamma)
    //   slope  = 1 + gain.rgb  * gain.a
    //   offset =     lift.rgb  * lift.a
    //   gamma  = 1 + gamma.rgb * gamma.a
    vec3 slope  = vec3(1.0) + P.gain.rgb * P.gain.a;
    vec3 offset =              P.lift.rgb * P.lift.a;
    vec3 power  = vec3(1.0) / max(vec3(1.0) + P.gamma_rgb.rgb * P.gamma_rgb.a, vec3(0.001));
    col = pow(max(col * slope + offset, vec3(0.0)), power);

    // 4. Hue shift.
    col = hue_rotate(col, P.hue_shift);
    col = max(col, vec3(0.0));

    // 5. Saturation around perceptual luma.
    float l = luma709(col);
    col = mix(vec3(l), col, P.saturation);

    // 6. Contrast around HDR mid-gray (0.18). Pivoting at 0.5 would be
    // wrong here — the buffer is scene-linear, not display-encoded.
    col = mix(vec3(0.18), col, P.contrast);
    col = max(col, vec3(0.0));

    // 7. Vignette in screen space — multiplicative darkening past a soft
    // radius. Distance is in normalized screen coords, aspect-corrected
    // so the vignette stays circular on widescreen.
    if (P.vignette_intensity > 0.0) {
        vec2 uv = (vec2(coord) + 0.5) / P.image_size;
        vec2 d = uv - 0.5;
        d.x *= P.image_size.x / max(P.image_size.y, 1.0);
        float r = length(d);
        float inner = max(P.vignette_radius - P.vignette_softness, 0.0);
        float outer = P.vignette_radius;
        float v = 1.0 - smoothstep(inner, outer, r);
        col *= mix(1.0 - P.vignette_intensity, 1.0, v);
    }

    imageStore(color_image, coord, vec4(col, 1.0));
}
