class_name WeaponRaycast
extends RefCounted
## Resolves a weapon-fire raycast into a sim-side hit descriptor.
##
## **Phase 2 note**: hit resolution is sim-authoritative now;
## `player.gd::_fire_debug_weapon` no longer calls `resolve_hit`.
## This class is kept for debug tooling (`debug_overlay.gd` LOS
## visualization) and for NPC bots' future-line-of-sight queries.
## New code should prefer the sim's projectile path.
##
## Single static entry point: `resolve_hit(space, origin, direction,
## max_dist, exclude)`. Returns a dict with `hit`, and when hit is true,
## `npc_id` + `body_part` if a humanoid dummy was struck, or empty
## fields if the ray landed on world geometry.
##
## The ray mask is `Layers.WEAPON_HIT_MASK` (SOLID | CONCEALMENT |
## NPC_HITBOX), so bullets pass through layerless nodes, stop on
## walls/terrain (SOLID), stop on bushes/smoke (CONCEALMENT), and
## score hits on humanoid dummies / the local player (NPC_HITBOX).
##
## Body-part resolution: the raycast result includes a `shape` index
## identifying which of the collider's child shapes was struck. We
## walk back through the CollisionObject3D's owner API to find the
## originating `CollisionShape3D` node and read its `body_part`
## metadata string (set by `humanoid_dummy.tscn`). If metadata is
## missing, `body_part` comes back empty.

## Resolve a single-ray fire.
##
## Returns `{ hit, position, normal, collider, npc_id, body_part }`:
## - `hit: bool` — true if the ray struck anything on the mask.
## - `position: Vector3` — hit point in world space.
## - `normal: Vector3` — surface normal at the hit.
## - `collider: Node` — the hit CollisionObject3D (or null).
## - `npc_id: int` — dummy's `npc_id` property if the hit was a
##   humanoid dummy; 0 otherwise.
## - `body_part: String` — one of `"head"`, `"torso"`, `"left_arm"`,
##   `"right_arm"`, `"left_leg"`, `"right_leg"`, or empty when the
##   ray didn't hit a body-part-tagged shape.
static func resolve_hit(
	space: PhysicsDirectSpaceState3D,
	origin: Vector3,
	direction: Vector3,
	max_dist: float,
	exclude: Array = []
) -> Dictionary:
	var result := {
		"hit": false,
		"position": Vector3.ZERO,
		"normal": Vector3.ZERO,
		"collider": null,
		"npc_id": 0,
		"body_part": "",
	}
	var to := origin + direction.normalized() * max_dist
	var params := PhysicsRayQueryParameters3D.create(origin, to)
	params.collision_mask = Layers.WEAPON_HIT_MASK
	params.collide_with_bodies = true
	params.collide_with_areas = false
	if not exclude.is_empty():
		params.exclude = exclude
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return result
	result["hit"] = true
	result["position"] = hit.get("position", Vector3.ZERO)
	result["normal"] = hit.get("normal", Vector3.ZERO)
	var collider: Object = hit.get("collider")
	result["collider"] = collider
	if collider == null:
		return result
	# Recover npc_id from the hit collider. With CharacterBody3D dummies,
	# the ray may hit either the body root (npc_id script var) or the
	# HitboxArea child (npc_id in metadata).
	if "npc_id" in collider:
		result["npc_id"] = int(collider.npc_id)
	elif collider.has_meta("npc_id"):
		result["npc_id"] = int(collider.get_meta("npc_id"))
	# Resolve which CollisionShape3D was struck so we can read its
	# `body_part` metadata. The result's `shape` index refers to the
	# CollisionObject3D's internal shape list, not a child index; the
	# `shape_find_owner` → `shape_owner_get_owner` dance maps it back
	# to the authoring node.
	var shape_index: int = int(hit.get("shape", -1))
	if shape_index >= 0 and collider.has_method("shape_find_owner"):
		var owner_id: int = collider.shape_find_owner(shape_index)
		if owner_id != 0:
			var owner_node: Object = collider.shape_owner_get_owner(owner_id)
			if owner_node != null and owner_node.has_method("has_meta"):
				if owner_node.has_meta("body_part"):
					result["body_part"] = String(owner_node.get_meta("body_part"))
	return result
