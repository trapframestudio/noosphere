@tool
class_name FaultZone3D
extends Area3D

## A localized hazard field in the world — gravity / electric /
## chemical / thermal / psy / radiation — that damages bodies inside
## its CollisionShape3D footprint and spawns shards in the wider
## ring around it. NPCs of sufficient bravery / equipment converge
## to hunt the shard; the player learns to recognize fault
## kinds and route around or through them depending on what's worth
## the risk.
##
## Volumetric (not a `PoiMarker3D` Kind) because the hazard zone
## itself, the shard orbit, and the NPC interest radius all
## have extent — a point would collapse all three onto one position
## and force every consumer to invent its own radius from `tags`.
##
## **Authoring contract:**
##   1. Drop one in via Add Node → "FaultZone".
##   2. Add a `CollisionShape3D` child — the hazard footprint. Sphere
##      for typical faults (gravity wells, electric arcs); box for
##      "wall of acid" / linear hazards. The Area3D's body-overlap
##      query is what damages bodies inside.
##   3. Set `fault_id`, `fault_kind`, `danger_tier`,
##      `shard_spawn_radius_m`, `shard_pool` in the inspector.
##
## **TODO(sim):** wire two consumers when the fault system lands.
##   - **Damage tick** that walks `get_overlapping_bodies()` per
##     fault per few-frames, applies damage scaled by `danger_tier`
##     + `fault_kind`. Per-kind effects (gravity throw, electric
##     stun, chemical DoT, etc.) live in the damage system.
##   - **Shard spawn / NPC hunt** that scans `fault_zones` group
##     on a slow tick, schedules shard manifests via
##     `respawn_seconds`, and broadcasts hunt-interest events to NPCs
##     filtered by faction bravery vs `danger_tier`. NPCs path to a
##     point sampled in `[hazard_radius, shard_spawn_radius_m]`
##     (the shard orbit) and grab on contact.

## Categorical hazard. Drives the damage type, the visual effect,
## and the default shard pool when `shard_pool` is empty.
enum FaultKind {
	GRAVITY,    # crushing / throw — kinetic damage, area knockback
	ELECTRIC,   # arc / shock — electric damage, brief stun
	CHEMICAL,   # corrosive / toxic — DoT damage, equipment degrade
	THERMAL,    # heat or cold — burn / frostbite damage
	PSY,        # mental / sanity — perception + sanity damage
	RADIATION,  # rad damage — long-tail accumulation, no instant kill
}

## Stable identifier the fault + shard systems route on.
## Convention: snake_case prefixed by map (`cascade_locks_grav_well_west`).
@export var fault_id: String = ""

## What kind of fault this is — drives default damage / visual
## behaviour. Override per-instance via `tags` if a specific fault
## has a hand-tuned profile.
@export var fault_kind: FaultKind = FaultKind.GRAVITY: \
	set = _set_fault_kind

## Wider radius (meters) around the hazard zone where shards
## manifest each charge cycle. Typically 1.5–3× the hazard
## footprint. NPCs sample a point in `[hazard, shard_spawn]`
## ring when hunting. Keep > 0 even if the shard pool is empty
## — drives the NPC interest radius regardless.
@export_range(1.0, 50.0, 0.5) var shard_spawn_radius_m: float = 8.0: \
	set = _set_shard_spawn_radius_m

## Tag key into the shard loot table. Empty = use the
## `fault_kind`'s default pool (e.g. GRAVITY → "gravity_shards").
## Override for hand-curated drops at story / quest faults.
@export var shard_pool: String = ""

## Danger 1 (mild — sparks, brief stun) to 4 (lethal — instant
## kill on contact, large knockback). Drives damage scale, shard
## rarity, and NPC bravery threshold to approach. Faction-AI uses
## `danger_tier` × NPC bravery to gate hunting decisions.
@export_range(1, 4, 1) var danger_tier: int = 1: set = _set_danger_tier

## Seconds between charge cycles — how often the fault re-spawns
## a fresh shard. 0 = never (one-shot / hand-set; the shard
## that's there stays until grabbed). Positive = recurring;
## shard-spawn system schedules next manifest from this.
@export_range(0.0, 86400.0, 1.0) var respawn_seconds: float = 600.0

## Free-form metadata for the shard-spawn / NPC-hunt systems.
## Examples: `shard_count=3` (multi-shard faults),
## `static_shard=quest_battery_a` (one-shot story drop),
## `damage_override_per_sec=12` (hand-tune past fault_kind defaults).
@export var tags: Dictionary = {}

@export_group("Debug visual")
## Show a translucent sphere at the shard-spawn radius in the
## editor — the hazard zone is already rendered by the Area3D's
## own collision shape gizmo, so the shard ring is what needs a
## visual hint. Off in builds.
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"fault_zones"
const _DEBUG_ALPHA: float = 0.15

var _debug_ring: MeshInstance3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


func _set_fault_kind(v: FaultKind) -> void:
	fault_kind = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_color()


func _set_shard_spawn_radius_m(v: float) -> void:
	shard_spawn_radius_m = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_size()


func _set_danger_tier(_v: int) -> void:
	danger_tier = _v
	update_configuration_warnings()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if fault_id.strip_edges().is_empty():
		warnings.append(
			"fault_id is empty — set a stable identifier so the "
			+ "fault + shard-spawn systems have a key to route on.")
	var has_shape := false
	for child in get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			has_shape = true
			break
	if not has_shape:
		warnings.append(
			"No CollisionShape3D child with a Shape — the hazard zone "
			+ "has no footprint and won't damage anything. Add a "
			+ "CollisionShape3D and pick a SphereShape3D / BoxShape3D.")
	if shard_spawn_radius_m <= 0.0:
		warnings.append(
			"shard_spawn_radius_m must be > 0 — drives the NPC "
			+ "interest radius even when shard_pool is empty.")
	return warnings


# --- Editor visualization ----------------------------------------

func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return
	_debug_ring = MeshInstance3D.new()
	_debug_ring.name = "_FaultShardRing"
	var sphere := SphereMesh.new()
	sphere.radius = shard_spawn_radius_m
	sphere.height = shard_spawn_radius_m * 2.0
	_debug_ring.mesh = sphere
	add_child(_debug_ring, false, Node.INTERNAL_MODE_BACK)
	_apply_debug_color()


func _clear_debug_visual() -> void:
	if _debug_ring != null and is_instance_valid(_debug_ring):
		_debug_ring.queue_free()
	_debug_ring = null


func _apply_debug_color() -> void:
	if _debug_ring == null or not is_instance_valid(_debug_ring):
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color_for_kind(fault_kind)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = 9
	_debug_ring.material_override = mat


func _apply_debug_size() -> void:
	if _debug_ring == null or not is_instance_valid(_debug_ring):
		_rebuild_debug_visual()
		return
	var sphere: SphereMesh = _debug_ring.mesh as SphereMesh
	if sphere == null:
		_rebuild_debug_visual()
		return
	sphere.radius = shard_spawn_radius_m
	sphere.height = shard_spawn_radius_m * 2.0


# Per-kind color for the debug shard ring. Distinct hues so a
# scene full of mixed faults reads at a glance.
static func _color_for_kind(k: FaultKind) -> Color:
	match k:
		FaultKind.GRAVITY: return Color(0.55, 0.20, 0.85, _DEBUG_ALPHA)
		FaultKind.ELECTRIC: return Color(0.30, 0.65, 1.00, _DEBUG_ALPHA)
		FaultKind.CHEMICAL: return Color(0.55, 0.85, 0.20, _DEBUG_ALPHA)
		FaultKind.THERMAL: return Color(0.95, 0.45, 0.20, _DEBUG_ALPHA)
		FaultKind.PSY: return Color(0.85, 0.30, 0.65, _DEBUG_ALPHA)
		FaultKind.RADIATION: return Color(0.95, 0.85, 0.20, _DEBUG_ALPHA)
		_: return Color(0.50, 0.50, 0.50, _DEBUG_ALPHA)
