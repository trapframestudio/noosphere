shader_type spatial;
// **Imposter bake pass — normal channel.**
//
// Renders the source tree mesh's view-space surface normals into
// RGB, encoded as `n * 0.5 + 0.5`, and writes the matching alpha
// silhouette so the resulting PNG shares UVs with the `_albedo`
// pass after trim.
//
// `tree_cluster.gdshader` samples this PNG at runtime, decodes the
// view-space normal, rotates it into world space via the billboard's
// per-instance basis, and feeds it to its custom `light()` so
// distant trees track live sun direction + weather lighting.
//
// **View-space encoding**: Godot's fragment-stage `NORMAL` is in
// view space (camera-relative) by default. The bake camera looks
// along world -Z toward the tree at world origin, so view-space
// directly corresponds to "billboard local" at runtime: view +X =
// billboard right, view +Y = world up, view +Z = billboard front
// (toward camera). The runtime shader's basis swap re-projects
// these into world space wherever the billboard's MMI yaw points.
//
// **Alpha cutoff** identical to the albedo pass — we render to the
// same silhouette outline so albedo + normal PNGs share UVs after
// trim.
//
// Used only at bake time inside `godot/tools/imposter_baker.tscn`.
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform sampler2D albedo_texture : source_color, hint_default_white,
	filter_linear_mipmap, repeat_enable;
uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.5;

void fragment() {
	vec4 c = texture(albedo_texture, UV);
	if (c.a < alpha_cutoff) {
		discard;
	}
	// NORMAL is view-space, normalized. Encode to [0,1] for PNG.
	vec3 n = normalize(NORMAL);
	ALBEDO = n * 0.5 + 0.5;
	ALPHA = 1.0;
}
