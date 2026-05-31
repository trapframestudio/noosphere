@tool
class_name TrashKickZone
extends Area3D

## Kick zone for procedural trash. Drop as a child of the player's
## CharacterBody3D (or any moving body) with a CollisionShape3D that
## defines the zone shape.
##
## **Why this exists.** Frozen trash species (bottles, cans, drinks
## — `wind_susceptibility = 0` in TrashScatter) spawn with
## `freeze = true` so they don't drift on slopes. The player's
## CharacterBody3D collision_mask doesn't include `Layers.CONCEALMENT`
## (the trash layer) — bottles shouldn't physically block the player's
## walking — so the player walking past doesn't fire `body_entered` on
## the trash directly. This Area3D bridges the gap: its collision_mask
## DOES include CONCEALMENT, so it sees trash overlapping the player's
## kick volume, unfreezes the body, and applies a velocity-scaled
## impulse so it skitters away in the direction the player was moving.
##
## **Keep-still threshold** (`min_kick_speed`). The handler bails when
## the parent CharacterBody3D is below this speed, so trash that
## streams in while the player is standing still doesn't immediately
## unfreeze + fall + roll downhill. Player must actively walk into a
## piece of trash to wake it.

## Multiplier on the kick impulse. 1.0 = gentle nudge; 2.5 (default)
## = a "boot-toe" kick that scoots a soda can a few meters; 5+ feels
## like an angry punt. Combines multiplicatively with player speed,
## so even a small-impulse setting throws light items further when
## the player is sprinting.
@export_range(0.0, 10.0, 0.1) var impulse_strength: float = 2.5

## Vertical bias added to every kick before normalization, in
## meters-per-second-equivalent. 0 = pure-horizontal slide (bottle
## skids); 0.3-0.5 (default 0.4) = bottle tumbles forward as it
## rolls — reads as "boot-toe scoop" rather than "magic puck".
@export_range(0.0, 2.0, 0.05) var vertical_lift: float = 0.4

## Player must be moving faster than this (m/s) for entering trash
## to unfreeze. Stops "trash falls / drifts as soon as it streams
## in next to a stationary player" — frozen items only react when
## the player actively walks into them. Set to 0 to unfreeze
## anything that touches the zone regardless of player velocity.
@export_range(0.0, 5.0, 0.05) var min_kick_speed: float = 0.5


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if not (body is RigidBody3D):
		return
	var rb: RigidBody3D = body
	# Already dynamic — nothing to unfreeze. The body is already in
	# play (kicked previously, or never frozen — wind species).
	if not rb.freeze:
		return
	# Player must be moving for a kick to register; prevents trash
	# that streams into the zone next to a stationary player from
	# spuriously waking and rolling. See the class doc header.
	var player_speed: float = 0.0
	var parent_node: Node = get_parent()
	if parent_node is CharacterBody3D:
		player_speed = (parent_node as CharacterBody3D).velocity.length()
	if player_speed < min_kick_speed:
		return
	# Direction = horizontal offset from this zone's origin to the
	# body's origin. We zero Y first so flat floor kicks aren't
	# biased upward from the body sitting below the player center;
	# `vertical_lift` adds the toe-scoop bounce explicitly afterward.
	var horiz: Vector3 = Vector3(
		rb.global_position.x - global_position.x,
		0.0,
		rb.global_position.z - global_position.z)
	var dir: Vector3
	if horiz.length_squared() > 0.0001:
		dir = horiz.normalized()
	else:
		# Zone-and-body coincident — fallback to player's facing.
		# Cheap heuristic: use parent's basis Z (for CharacterBody3D
		# whose Z+ is the player's back, -Z is forward).
		dir = -parent_node.global_basis.z if parent_node is Node3D else Vector3.RIGHT
	dir.y = vertical_lift
	dir = dir.normalized()
	# Unfreeze BEFORE applying impulse — `apply_central_impulse` on a
	# frozen body silently no-ops in Godot 4; the body stays static
	# until freeze is cleared.
	rb.freeze = false
	var magnitude: float = player_speed * 0.5 * impulse_strength
	rb.apply_central_impulse(dir * magnitude)
