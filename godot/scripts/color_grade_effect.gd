@tool
class_name ColorGradeEffect
extends CompositorEffect

## Whole-game color grading post-process.
##
## Applies an ASC CDL primary correction + saturation / contrast / hue /
## vignette over the HDR scene buffer, just before Godot's tonemap. Drop
## this resource into a [Compositor]'s `compositor_effects` array; every
## camera that uses that compositor (via WorldEnvironment or Camera3D)
## inherits the grade.
##
## Parameters are grouped to match a typical color-grade UI: tone first,
## then primaries (lift/gamma/gain), then saturation/contrast/hue, then
## vignette. All defaults are neutral — a fresh resource is a no-op.

const SHADER_PATH := "res://shaders/color_grade.glsl"

# `enabled` is inherited from CompositorEffect; the engine respects it
# automatically, so don't redeclare it here.

@export_group("Tone")
## Exposure compensation in stops. +1 = twice as bright.
@export_range(-5.0, 5.0, 0.01, "or_greater", "or_less") var exposure: float = 0.0
## Warm/cool shift. Negative = cooler (more blue), positive = warmer (more red).
@export_range(-1.0, 1.0, 0.01) var temperature: float = 0.0
## Green/magenta shift. Negative = magenta, positive = green.
@export_range(-1.0, 1.0, 0.01) var tint: float = 0.0

@export_group("Primaries (ASC CDL)")
## Shadow color shift (offset). Color picker; gray = neutral.
@export var lift_color: Color = Color(0.5, 0.5, 0.5)
## Strength of the lift shift. 0 = ignore [member lift_color] entirely.
@export_range(0.0, 1.0, 0.01) var lift_amount: float = 0.0
## Midtone color shift (inverse gamma). Color picker; gray = neutral.
@export var gamma_color: Color = Color(0.5, 0.5, 0.5)
## Strength of the gamma shift.
@export_range(0.0, 1.0, 0.01) var gamma_amount: float = 0.0
## Highlight color shift (slope). Color picker; gray = neutral.
@export var gain_color: Color = Color(0.5, 0.5, 0.5)
## Strength of the gain shift.
@export_range(0.0, 1.0, 0.01) var gain_amount: float = 0.0

@export_group("Saturation / Contrast / Hue")
## 1.0 = identity, 0.0 = grayscale, >1 = oversaturated.
@export_range(0.0, 2.0, 0.01) var saturation: float = 1.0
## 1.0 = identity. Pivots around HDR mid-gray (0.18), not display 0.5.
@export_range(0.0, 2.0, 0.01) var contrast: float = 1.0
## Hue rotation in turns. 0.5 = 180°.
@export_range(-0.5, 0.5, 0.01) var hue_shift: float = 0.0

@export_group("Vignette")
## 0 = off, 1 = edges fully black.
@export_range(0.0, 1.0, 0.01) var vignette_intensity: float = 0.0
## Radius from center (aspect-corrected) where the vignette starts to fall off.
@export_range(0.0, 1.5, 0.01) var vignette_radius: float = 0.7
## Width of the falloff band. Higher = softer edge.
@export_range(0.0, 1.0, 0.01) var vignette_softness: float = 0.3


# --- internal -----------------------------------------------------------

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _initialized: bool = false


func _init() -> void:
	# POST_TRANSPARENT runs after the main scene is composited but before
	# tonemap+glow — the right place for HDR-space primary correction.
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	needs_motion_vectors = false
	needs_normal_roughness = false
	needs_separate_specular = false


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# PREDELETE can fire while the script is still resolving (e.g. during
	# editor reload of an @tool Resource), so any indirection — even a
	# member-function call — can land on a null receiver. Free GPU
	# resources inline and only if everything is in a known-good state.
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
		_pipeline = RID()
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()
	_initialized = false


func _ensure_pipeline() -> bool:
	if _initialized:
		return true
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false
	var src := load(SHADER_PATH) as RDShaderFile
	if src == null:
		push_error("ColorGradeEffect: failed to load %s" % SHADER_PATH)
		return false
	var spirv := src.get_spirv()
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		push_error("ColorGradeEffect: shader_create_from_spirv returned invalid RID")
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("ColorGradeEffect: compute_pipeline_create returned invalid RID")
		_rd.free_rid(_shader)
		_shader = RID()
		return false
	_initialized = true
	return true


# Map a 0..1 color (where 0.5 = neutral) into a -0.5..0.5 signed offset.
# This way the inspector shows familiar Color pickers but the shader gets
# zero-centered values it can scale by an `amount` directly.
static func _signed_rgb(c: Color) -> Vector3:
	return Vector3(c.r - 0.5, c.g - 0.5, c.b - 0.5)


func _build_push_constant() -> PackedByteArray:
	# 24 floats laid out to match the std430 push_constant block in the shader.
	var pc := PackedFloat32Array()
	pc.resize(24)

	# Tone (4 floats)
	pc[0] = exposure
	pc[1] = temperature
	pc[2] = tint
	pc[3] = hue_shift

	# Saturation / contrast (4 floats; last 2 padding)
	pc[4] = saturation
	pc[5] = contrast
	pc[6] = 0.0
	pc[7] = 0.0

	# Lift  (vec4: rgb signed offset + amount)
	var l := _signed_rgb(lift_color)
	pc[8]  = l.x
	pc[9]  = l.y
	pc[10] = l.z
	pc[11] = lift_amount

	# Gamma (vec4: rgb signed offset + amount)
	var g := _signed_rgb(gamma_color)
	pc[12] = g.x
	pc[13] = g.y
	pc[14] = g.z
	pc[15] = gamma_amount

	# Gain  (vec4: rgb signed offset + amount)
	var ga := _signed_rgb(gain_color)
	pc[16] = ga.x
	pc[17] = ga.y
	pc[18] = ga.z
	pc[19] = gain_amount

	# Vignette (4 floats; last 1 padding)
	pc[20] = vignette_intensity
	pc[21] = vignette_radius
	pc[22] = vignette_softness
	pc[23] = 0.0

	return pc.to_byte_array()


func _render_callback(p_callback_type: int, render_data: RenderData) -> void:
	if p_callback_type != effect_callback_type:
		return
	if not _ensure_pipeline():
		return

	var scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if scene_buffers == null:
		return
	var size := scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count := scene_buffers.get_view_count()
	# Push constant: 24 grading floats (96B) + image_size + padding (16B) = 112B,
	# safely under the 128B Vulkan minimum guarantee.
	var pc := _build_push_constant()
	var size_floats := PackedFloat32Array()
	size_floats.resize(4)
	size_floats[0] = float(size.x)
	size_floats[1] = float(size.y)
	size_floats[2] = 0.0
	size_floats[3] = 0.0
	pc.append_array(size_floats.to_byte_array())

	var groups_x := int(ceil(float(size.x) / 8.0))
	var groups_y := int(ceil(float(size.y) / 8.0))

	for view in view_count:
		var color_tex := scene_buffers.get_color_layer(view)
		if not color_tex.is_valid():
			continue

		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = 0
		u.add_id(color_tex)
		var uset := UniformSetCacheRD.get_cache(_shader, 0, [u])
		if not uset.is_valid():
			# Per the noosphere RD playbook (CLAUDE.md): if uniform_set_create
			# returns invalid, drop everything and let the next frame rebuild.
			# Here the cache helper handles invalidation, but bail this frame.
			continue

		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uset, 0)
		_rd.compute_list_set_push_constant(compute_list, pc, pc.size())
		_rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
		_rd.compute_list_end()
