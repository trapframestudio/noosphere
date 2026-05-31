extends Node
## Listens to `SimHost.projectile_spawned` and
## `projectile_impacted` signals and renders client-side tracer +
## impact effects. Phase 2 host-authoritative fire means the sim
## owns damage/hit resolution; this script is pure presentation.
##
## Attach as a child of `GameSession` so it can find `SimHost`
## once at `_ready`. Stays idle during menu — the signals simply
## never fire when `SimHost` hasn't started a sim.
##
## ## Rendering model
##
## - On `projectile_spawned`: spawn a thin cylinder mesh oriented
##   along the round's velocity, colored by `AmmoVariant`, and
##   tweened from the muzzle toward where the projectile *would*
##   land at max range (impact arrives later and clips the tween
##   early). Tracked in `_live_tracers` keyed on projectile id so
##   the matching impact event can cancel the slide.
## - On `projectile_impacted`: free the in-flight tracer for this
##   id (if any) and spawn a small impact puff at `pos`. Color is
##   red on penetrate, white on block.
##
## Variant tag plumbs in via Phase 4B v2 of the ballistics
## iteration. Variant strings come from `AmmoVariant::as_str` on
## the sim side: `"fmj"` / `"hp"` / `"ap"` / `"tracer"` /
## `"overpressure"`. Unknown variants fall back to FMJ yellow.
##
## Tracer + impact geometry is procedural — no imported meshes.
## Keeps the FX slice dependency-free; art pass can replace later.

const TRACER_FADE_S: float = 0.25
const IMPACT_FADE_S: float = 0.5
## Visible streak length in meters. Tuned short — at typical
## engagement ranges (50–150m), a long cylinder reads as a static
## line rather than a moving bullet trail. Tracer variant gets a
## modestly longer streak so the bright incendiary trail still
## stands out.
const TRACER_LENGTH_DEFAULT_M: float = 2.0
const TRACER_LENGTH_TRACER_M: float = 5.0

## In-flight tracer registry, keyed on projectile id (matches the
## sim's `ProjectileId`). Cleared on impact or natural-tween-end.
var _live_tracers: Dictionary = {}


func _ready() -> void:
	# Walk up to GameSession → SimHost. The autoload is at
	# `/root/GameSession`; SimHost is a child registered in
	# `scenes/session_root.tscn`.
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	var sim := session.get_node_or_null("SimHost")
	if sim == null:
		return
	if sim.has_signal("projectile_spawned"):
		sim.projectile_spawned.connect(_on_projectile_spawned)
	if sim.has_signal("projectile_impacted"):
		sim.projectile_impacted.connect(_on_projectile_impacted)


func _on_projectile_spawned(payload: Dictionary) -> void:
	var id: int = int(payload.get("id", 0))
	var origin: Vector3 = payload.get("origin", Vector3.ZERO)
	var velocity: Vector3 = payload.get("velocity", Vector3.ZERO)
	var max_range_m: float = float(payload.get("max_range_m", 100.0))
	var variant: String = String(payload.get("variant", "fmj"))
	var speed: float = velocity.length()
	if speed < 1.0:
		return

	var dir: Vector3 = velocity / speed
	var color: Color = _tracer_color_for_variant(variant)
	var length_m: float = (
		TRACER_LENGTH_TRACER_M if variant == "tracer" else TRACER_LENGTH_DEFAULT_M
	)

	# Build the streak: a thin cylinder positioned with its tail at
	# the muzzle, head `length_m` forward along velocity. As the
	# projectile flies, we tween the whole mesh forward at `speed`
	# so the streak slides through the air rather than sitting
	# static at the muzzle.
	var inst := _build_tracer_mesh(origin, dir, length_m, color)
	if inst == null:
		return
	_live_tracers[id] = inst

	# Project an endpoint at max range; on natural completion (no
	# impact arrived to cancel us) the tween fades + frees the
	# tracer. On impact we cancel the tween in
	# `_on_projectile_impacted`. Streak center sits length/2
	# behind the head at all times, so the end-of-flight center
	# lives length/2 behind the max-range endpoint.
	var endpoint: Vector3 = origin + dir * max_range_m
	var midpoint_end: Vector3 = endpoint - dir * (length_m * 0.5)
	# Flight duration along the ideal line — the sim has gravity +
	# drag, but for a presentation tracer at typical engagement
	# ranges the deviation is sub-pixel.
	var flight_time: float = max_range_m / speed
	# Fade is shorter than flight when flight is long; never above
	# `TRACER_FADE_S`. Tracer variant gets a slightly longer fade
	# so the brighter streak lingers.
	var fade_time: float = minf(flight_time, TRACER_FADE_S)
	if variant == "tracer":
		fade_time = minf(flight_time, TRACER_FADE_S * 2.0)
	# `create_tween` defaults to ease IN_OUT which accelerates +
	# decelerates the slide. For a tracer the slide must be
	# constant-velocity along a straight line; ease IN_OUT makes
	# the bullet appear to "sweep" through the air. Pin the slide
	# to LINEAR + IN; the fade tween keeps its default since the
	# alpha curve is cosmetic.
	var tween := create_tween().set_parallel(true)
	(
		tween
		.tween_property(inst, "global_position", midpoint_end, flight_time)
		.set_trans(Tween.TRANS_LINEAR)
		.set_ease(Tween.EASE_IN)
	)
	var mat: StandardMaterial3D = inst.mesh.material
	tween.tween_property(mat, "albedo_color:a", 0.0, fade_time).set_delay(flight_time - fade_time)
	# Free + clear registry once the tween chain completes.
	tween.chain().tween_callback(_finalize_tracer.bind(id))


func _on_projectile_impacted(payload: Dictionary) -> void:
	var id: int = int(payload.get("id", 0))
	var pos: Vector3 = payload.get("pos", Vector3.ZERO)
	var penetrated: bool = bool(payload.get("penetrated", false))
	# Cancel the in-flight tracer for this projectile so we don't
	# end up with a streak still sliding through the air past the
	# impact point. Untyped read + validity check before the typed
	# bind — see `_finalize_tracer` for the rationale.
	if _live_tracers.has(id):
		var raw: Variant = _live_tracers[id]
		_live_tracers.erase(id)
		if raw is Node and is_instance_valid(raw):
			(raw as Node).queue_free()
	var color := Color(1.0, 0.3, 0.2, 0.9) if penetrated else Color(0.9, 0.9, 0.9, 0.8)
	_spawn_impact_puff(pos, color)


## Build the moving streak mesh. Returns the `MeshInstance3D`
## positioned with its center at `origin + dir * length_m * 0.5`
## (i.e., head at the muzzle, body trailing along velocity).
func _build_tracer_mesh(origin: Vector3, dir: Vector3, length_m: float, color: Color) -> MeshInstance3D:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return null
	var mesh := CylinderMesh.new()
	# Tracer variant gets a thicker streak so the brighter trail
	# reads at distance without a brittle "wireframe" feel.
	mesh.top_radius = 0.025 if color.r > 0.9 and color.g < 0.6 else 0.018
	mesh.bottom_radius = mesh.top_radius
	mesh.height = length_m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Bright tracers look better with a subtle emission halo.
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	mesh.material = mat
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	# Orient +Y of the cylinder along the velocity vector. Local
	# basis only — safe to set before the node is in the tree.
	var up := dir
	var pick := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	inst.basis = Basis.looking_at(up, pick).rotated(Vector3(1, 0, 0), PI / 2.0)
	# Add to the tree BEFORE touching `global_position` — the
	# setter reads `get_global_transform()` to preserve the basis,
	# which errors out on a Node3D that hasn't entered the tree yet.
	scene_root.add_child(inst)
	# Position the streak so its leading edge is at the muzzle.
	# CylinderMesh is centered on its origin and aligned along
	# +Y, so the midpoint sits `length_m/2` behind the muzzle.
	inst.global_position = origin - dir * (length_m * 0.5)
	return inst


## Spawn an impact sphere at `pos`, fade over `IMPACT_FADE_S`.
func _spawn_impact_puff(pos: Vector3, color: Color) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sphere.material = mat
	var inst := MeshInstance3D.new()
	inst.mesh = sphere
	# Same pattern as `_build_tracer_mesh` — add to the tree
	# before `global_position` so the setter's `get_global_transform`
	# read doesn't fire `!is_inside_tree()` errors.
	scene_root.add_child(inst)
	inst.global_position = pos
	var tween := create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, IMPACT_FADE_S)
	tween.tween_callback(inst.queue_free)


## Tween completion callback — clears the registry slot and frees
## the mesh if the impact path didn't already.
##
## Read as `Variant` then validate before the typed bind, because
## a scene reload can free the tracer node out from under us
## while this callback is still pending in the tween chain. The
## dictionary entry survives, but assigning the freed reference
## to a typed `Node` would trip Godot's previously-freed check
## with a script error.
func _finalize_tracer(id: int) -> void:
	if not _live_tracers.has(id):
		return
	var raw: Variant = _live_tracers[id]
	_live_tracers.erase(id)
	if raw is Node and is_instance_valid(raw):
		(raw as Node).queue_free()


## Map an `AmmoVariant` string to its presentation color. Unknown
## variants fall back to FMJ yellow.
func _tracer_color_for_variant(variant: String) -> Color:
	# Slight alpha bias for the brighter / hotter variants so the
	# additive-like read holds during the fade.
	match variant:
		"tracer":
			# Iconic orange tracer — high R + G, bright + brief.
			return Color(1.0, 0.55, 0.15, 1.0)
		"ap":
			# Cooler steel-tipped feel — pale blue-white.
			return Color(0.7, 0.85, 1.0, 0.9)
		"hp":
			# Soft-point / hollow — slightly red-shifted warm yellow.
			return Color(1.0, 0.6, 0.35, 0.9)
		"overpressure":
			# +P+ / proof-load — searing hot white-yellow.
			return Color(1.0, 0.95, 0.7, 1.0)
		_:
			# FMJ baseline (and unknown variants).
			return Color(1.0, 0.85, 0.3, 0.9)
