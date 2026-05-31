extends CharacterBody3D
## FPS controller with walk mode and noclip toggle.
##
## Walk mode: WASD to move, mouse to look, Space to jump, Shift to sprint.
## Noclip mode: WASD to fly, Space/Ctrl for up/down, no collision.
## Press \ to toggle between modes.
## F12 to save screenshot.

## Mouse sensitivity in radians per pixel.
@export var mouse_sensitivity: float = 0.002
## Walk speed (m/s).
@export var walk_speed: float = 5.0
## Sprint speed (m/s).
@export var sprint_speed: float = 10.0
## Noclip fly speed (m/s). Tuned for 5km test maps.
@export var fly_speed: float = 50.0
## Noclip fast fly speed when holding Shift (m/s).
@export var fast_fly_speed: float = 250.0
## Jump impulse (m/s).
@export var jump_velocity: float = 5.0
## Gravity (m/s²).
@export var gravity: float = 20.0

## Ordered list of equipment slot ids the Q/E cycle iterates. Mirrors
## the paper-doll slot ids in `equipment_slots.toml` — the same strings
## `SimHost.reload_weapon` / `fire_weapon` / `player_state` expect.
const WEAPON_SLOTS: Array = ["primary", "secondary", "sidearm"]

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

## True = noclip fly mode, false = walk mode.
var noclip: bool = false

## Current active weapon slot. Index into `WEAPON_SLOTS`; Q/E cycle.
var _active_slot_idx: int = 0
## Seconds remaining before LMB can fire again. Decremented each
## physics frame; shot is gated on `<= 0.0`. Reset from the weapon's
## `fire_interval_s` on each successful fire.
var _fire_cooldown_s: float = 0.0

## Emitted whenever the active slot, loaded rounds, or other HUD-
## visible state changes. Listeners (HUD) re-pull `player_state`.
signal weapon_changed
## Emitted on a fire attempt (successful or dry-click). HUD can
## flash on shot independently of slot-switch refreshes.
signal weapon_fired


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	add_to_group("player")
	# Collision tuning for large trimesh levels
	safe_margin = 0.08
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(50.0)
	wall_min_slide_angle = deg_to_rad(15.0)
	_apply_mode()


func _unhandled_input(event: InputEvent) -> void:
	# LMB: capture the mouse on first click, then becomes fire. This
	# is the standard FPS flow; once the cursor is locked to the
	# viewport, LMB triggers the debug weapon raycast.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return
		_fire_debug_weapon()
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x, -PI / 2.0, PI / 2.0)

	# Toggle noclip with backslash
	if event is InputEventKey and event.pressed and event.keycode == KEY_BACKSLASH:
		noclip = !noclip
		if not noclip:
			_snap_to_floor()
		_apply_mode()
		print("Noclip: ", "ON" if noclip else "OFF")

	# F12 screenshot
	if event is InputEventKey and event.pressed and event.keycode == KEY_F12:
		_take_screenshot()

	# Ctrl+S — force a sim snapshot now (no quit).
	if event.is_action_pressed("save_now"):
		_force_save()

	# Weapon cycling. `weapon_next` / `weapon_prev` are bound to
	# `E` and `Q` respectively in `project.godot`.
	if event.is_action_pressed("weapon_next"):
		_cycle_slot(1)
	elif event.is_action_pressed("weapon_prev"):
		_cycle_slot(-1)

	# Reload (R). Fire-and-forget: host mutation journals a
	# `WeaponReloaded` delta that `player_state["equipped_weapons"]`
	# reflects on the next tick — the HUD picks it up from there.
	if event.is_action_pressed("weapon_reload"):
		_reload_active_weapon()


func _physics_process(delta: float) -> void:
	if _fire_cooldown_s > 0.0:
		_fire_cooldown_s = max(0.0, _fire_cooldown_s - delta)
	if noclip:
		_noclip_move(delta)
	else:
		_walk_move(delta)
	_push_camera_to_shader_globals()


# Pushes camera world position + forward direction to the global shader
# parameters that ground-cover (and any future view-cone-modulated
# foliage) reads each frame to compute density. Two near-free
# RenderingServer calls; they replace what would otherwise be every
# foliage shader's first job each frame.
func _push_camera_to_shader_globals() -> void:
	var fwd := -camera.global_transform.basis.z
	RenderingServer.global_shader_parameter_set("player_cam_pos", camera.global_position)
	RenderingServer.global_shader_parameter_set("player_cam_forward", fwd)


func _walk_move(delta: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = jump_velocity

	# Horizontal movement
	var speed := sprint_speed if Input.is_key_pressed(KEY_SHIFT) else walk_speed
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_basis := global_transform.basis
	var move_dir := (cam_basis.z * input_dir.y + cam_basis.x * input_dir.x)
	move_dir.y = 0.0
	if move_dir.length_squared() > 0.0:
		move_dir = move_dir.normalized()

	velocity.x = move_dir.x * speed
	velocity.z = move_dir.z * speed

	move_and_slide()


func _noclip_move(delta: float) -> void:
	var speed := fast_fly_speed if Input.is_key_pressed(KEY_SHIFT) else fly_speed
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_basis := head.global_transform.basis
	var move_dir := Vector3.ZERO
	move_dir += cam_basis.z * input_dir.y
	move_dir += cam_basis.x * input_dir.x

	if Input.is_key_pressed(KEY_SPACE):
		move_dir.y += 1.0
	if Input.is_key_pressed(KEY_CTRL):
		move_dir.y -= 1.0

	if move_dir.length_squared() > 0.0:
		move_dir = move_dir.normalized()

	global_position += move_dir * speed * delta


## When switching from noclip to walk, raycast down to find the floor
## and place the player on it. Prevents spawning inside/below geometry.
func _snap_to_floor() -> void:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 0.5
	var to := global_position + Vector3.DOWN * 20.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var result := space.intersect_ray(query)
	if result:
		# Place player on top of the hit point (capsule center offset)
		global_position = result.position + Vector3.UP * 1.0
		print("Snapped to floor at Y=", result.position.y)
	else:
		print("No floor found below — staying in place")


func _apply_mode() -> void:
	if noclip:
		# Disable collision for noclip
		set_collision_layer(0)
		set_collision_mask(0)
		collision_shape.disabled = true
		velocity = Vector3.ZERO
	else:
		# Walk mode: player is a humanoid on NPC_HITBOX (bit 2) so LOS
		# raycasts ignore it — NPCs never occlude sight *to* the player
		# via the player's own body. Mask stops on SOLID (world) and
		# NPC_HITBOX (other humanoids) but passes through CONCEALMENT.
		set_collision_layer(Layers.NPC_HITBOX)
		set_collision_mask(Layers.PLAYER_MOVE_MASK)
		collision_shape.disabled = false
		velocity = Vector3.ZERO


func _force_save() -> void:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return
	if session.has_method("force_save"):
		session.force_save()
		print("[save] forced sim snapshot")


## Return the id of the currently-active weapon slot ("primary" /
## "secondary" / "sidearm"). HUD reads this to pick the right entry
## out of `player_state["equipped_weapons"]`.
func active_weapon_slot() -> String:
	return WEAPON_SLOTS[_active_slot_idx]


func _cycle_slot(direction: int) -> void:
	_active_slot_idx = posmod(_active_slot_idx + direction, WEAPON_SLOTS.size())
	# Reset cooldown on switch so the player isn't gated on the
	# previous weapon's fire interval.
	_fire_cooldown_s = 0.0
	weapon_changed.emit()


## Fire the active weapon. Phase 2 is fully host-authoritative —
## the sim spawns the projectile, ticks it, and broadcasts
## `ProjectileSpawned` + `ProjectileImpacted` deltas. The client
## sends `(aim_yaw, aim_pitch)` derived from the camera and lets
## the sim do the rest. No raycast, no hit resolution here.
## Fire-rate cooldown reads `fire_interval_s` out of
## `player_state.equipped_weapons[slot]` once per shot.
func _fire_debug_weapon() -> void:
	if _fire_cooldown_s > 0.0:
		return
	var sim := _sim_host()
	if sim == null or camera == null:
		return
	var sid := _local_steam_id()
	if sid <= 0:
		return
	# Derive aim from the camera's world basis. Godot's forward
	# is `-Z`; yaw is the atan2 of the horizontal projection, and
	# pitch is the angle above horizontal. The sim reconstructs
	# the world-space direction identically from `(yaw, pitch)`.
	var fwd := -camera.global_transform.basis.z
	var aim_yaw: float = atan2(fwd.x, fwd.z)
	var flat_len: float = sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
	var aim_pitch: float = atan2(fwd.y, flat_len)
	var result: Dictionary = sim.fire_weapon(sid, active_weapon_slot(), aim_yaw, aim_pitch)
	var ok: bool = bool(result.get("ok", false))
	weapon_fired.emit()
	if not ok:
		var err: String = String(result.get("error", "unknown"))
		print("[fire] dry-click: %s" % err)
		return
	# HUD reactivity — remaining_rounds updates on the sim's
	# `WeaponFired` delta broadcast; refresh label on signal.
	weapon_changed.emit()
	# Cooldown read from player_state's equipped_weapons dict
	# (populated by `equipped_weapons_to_dict` in the bridge).
	var state: Dictionary = sim.player_state(sid)
	var weapons: Variant = state.get("equipped_weapons", null)
	if typeof(weapons) == TYPE_DICTIONARY:
		var entry: Variant = (weapons as Dictionary).get(active_weapon_slot(), null)
		if typeof(entry) == TYPE_DICTIONARY:
			_fire_cooldown_s = float((entry as Dictionary).get("fire_interval_s", 0.25))
	print("[fire] slot=%s rounds_left=%d" % [
		active_weapon_slot(),
		int(result.get("remaining_rounds", -1)),
	])


func _reload_active_weapon() -> void:
	var sim := _sim_host()
	if sim == null:
		return
	var sid := _local_steam_id()
	if sid <= 0:
		return
	var ok: bool = bool(sim.reload_weapon(sid, active_weapon_slot()))
	if ok:
		print("[reload] slot=%s" % active_weapon_slot())
	else:
		print("[reload] failed (slot=%s); check no-mag-in-pockets or wrong caliber" % active_weapon_slot())
	weapon_changed.emit()


## Rotate `direction` by a uniform-random angle in
## `[-spread_deg, spread_deg]` around each perpendicular axis of
## the camera's local plane (yaw + pitch). Spread of 0 is a no-op.
func _apply_spread(direction: Vector3, spread_deg: float) -> Vector3:
	if spread_deg <= 0.0 or camera == null:
		return direction
	var yaw_rad: float = deg_to_rad(randf_range(-spread_deg, spread_deg))
	var pitch_rad: float = deg_to_rad(randf_range(-spread_deg, spread_deg))
	# Rotate around the camera's local up (yaw) then right (pitch).
	var up := camera.global_transform.basis.y
	var right := camera.global_transform.basis.x
	var d := direction.rotated(up, yaw_rad)
	d = d.rotated(right, pitch_rad)
	return d.normalized()


func _sim_host() -> Node:
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return null
	return session.get_node_or_null("SimHost")


func _local_steam_id() -> int:
	var session := get_node_or_null("/root/GameSession")
	if session == null or not session.has_method("local_steam_id"):
		return 0
	return int(session.local_steam_id())


func _take_screenshot() -> void:
	var image := get_viewport().get_texture().get_image()
	var dir_path := "user://screenshots"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/screenshot_%s.png" % [dir_path, timestamp]
	image.save_png(path)
	print("Screenshot saved: ", path)
	DisplayServer.clipboard_set(ProjectSettings.globalize_path(path))
	print("Path copied to clipboard")
