extends CharacterBody3D
## Segmented humanoid dummy used for NPC visualization and hit routing.
##
## Uses `CharacterBody3D` with `move_and_slide()` so NPCs collide
## with each other and terrain naturally via Godot's physics. The sim
## remains authoritative for *intent* (target position); Godot
## resolves *collision* (whether the NPC can physically get there).
##
## Hitbox shapes live on a child `Area3D` for weapon raycasts —
## separate from the `MovementCollider` capsule used by move_and_slide.
##
## ## LOD tiers
## - **Near** (<100m): full body + colliders + label
## - **Mid** (100–250m): billboard only, colliders disabled
## - **Far** (>250m): hidden entirely

const LOD_NEAR_SQ: float = 100.0 * 100.0
const LOD_MID_SQ: float = 250.0 * 250.0
const MAX_CATCH_UP_SPEED: float = 6.0
const ARRIVE_DEADZONE: float = 0.1
const GRAVITY: float = 20.0

var npc_id: int = 0

var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _has_target: bool = false
var _label: Label3D = null
var _body_root: Node3D = null
var _hitbox_area: Area3D = null
var _movement_collider: CollisionShape3D = null
var _billboard: MeshInstance3D = null
var _current_lod: int = -1
var _labels_enabled: bool = false
var _last_label_state_hash: int = 0


func _ready() -> void:
	_label = get_node_or_null("StateLabel")
	_body_root = get_node_or_null("Body")
	_hitbox_area = get_node_or_null("HitboxArea")
	_movement_collider = get_node_or_null("MovementCollider")



func apply_sim_position(target_pos: Vector3, target_yaw: float, delta: float) -> void:
	var diff := Vector3(target_pos.x - global_position.x, 0, target_pos.z - global_position.z)
	var dist := diff.length()

	if dist < ARRIVE_DEADZONE:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		var speed := clampf(dist / (delta * 3.0), 0.0, MAX_CATCH_UP_SPEED)
		var dir := diff.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	move_and_slide()
	rotation.y = lerp_angle(rotation.y, target_yaw, 10.0 * delta)


func configure(view: Dictionary) -> void:
	npc_id = int(view.get("id", 0))
	var faction: String = view.get("faction", "wanderers")
	if _body_root == null:
		_body_root = get_node_or_null("Body")
	if _body_root != null:
		var torso: MeshInstance3D = _body_root.get_node_or_null("Torso") as MeshInstance3D
		if torso != null:
			torso.material_override = FactionMaterials.of(faction)
	if _label == null:
		_label = get_node_or_null("StateLabel")
	# Propagate npc_id to the HitboxArea so weapon raycasts can
	# recover it from the Area3D hit.
	if _hitbox_area == null:
		_hitbox_area = get_node_or_null("HitboxArea")
	if _hitbox_area != null:
		_hitbox_area.set_meta("npc_id", npc_id)
	set_state(view)


func set_state(view: Dictionary) -> void:
	_target_pos = view.get("pos", Vector3.ZERO)
	_target_yaw = view.get("yaw", 0.0)
	if not _has_target:
		_has_target = true
		rotation.y = _target_yaw
		# Place at sim position immediately. Gravity + move_and_slide
		# will settle the NPC onto the terrain surface.
		global_position = _target_pos
	if _label != null and _labels_enabled and _current_lod == 0:
		var h: int = hash([
			view.get("name", ""),
			view.get("rank", ""),
			view.get("faction", ""),
			view.get("goal", ""),
			view.get("aggro_target", 0),
			int(view.get("health", 0.0)),
			int(view.get("max_health", 1.0)),
			view.get("combat_stance", ""),
			view.get("combat_role", ""),
			view.get("dwell_pose", ""),
			view.get("goal_source", ""),
			view.get("goal_priority", 0),
			view.get("group_id", 0),
		])
		if h != _last_label_state_hash:
			_last_label_state_hash = h
			_label.text = _build_label_text(view)


func _build_label_text(view: Dictionary) -> String:
	var id: int = view.get("id", 0)
	var dname: String = String(view.get("name", ""))
	var rank: String = String(view.get("rank", ""))
	var faction: String = view.get("faction", "?")
	var goal: String = view.get("goal", "?")
	var aggro: int = view.get("aggro_target", 0)
	var hp: float = view.get("health", 0.0)
	var max_hp: float = view.get("max_health", 1.0)
	var stance: String = String(view.get("combat_stance", ""))
	var role: String = String(view.get("combat_role", ""))
	var pose: String = String(view.get("dwell_pose", ""))
	var goal_source: String = String(view.get("goal_source", ""))
	var goal_priority: int = int(view.get("goal_priority", 0))
	var group_id: int = int(view.get("group_id", 0))
	var lines: Array[String] = []
	var ident: String
	if dname.is_empty():
		ident = "#%d" % id
	elif rank.is_empty():
		ident = dname
	else:
		ident = "%s (%s)" % [dname, rank]
	# Line 1: identity + faction + goal kind + HP. The ▶ marker only
	# appears in combat (when there's an aggro target).
	var line_1: String = "%s · %s · %s · %d/%d" % [ident, faction, goal, int(hp), int(max_hp)]
	if aggro != 0:
		line_1 += " ▶%d" % aggro
	lines.append(line_1)
	# Line 2: arbiter telemetry — ALWAYS shown so debugging "why is
	# this NPC doing X" is immediate. Format: [source:prio] G:<group>
	# Examples: [squad_obj:80] G:42  /  [aggro_solo:150]  /
	# [personality:65] G:7  /  [survival:220]  /  [idle:0]
	var arbiter: String = ""
	if not goal_source.is_empty() and goal_source != "?":
		arbiter = "[%s:%d]" % [goal_source, goal_priority]
	else:
		arbiter = "[?:%d]" % goal_priority
	var line_2_parts: Array[String] = [arbiter]
	if group_id != 0:
		line_2_parts.append("G:%d" % group_id)
	lines.append(" ".join(line_2_parts))
	# Line 3: tactical / dwell context — combat stance, squad combat
	# role, dwell pose. Each tag omitted when empty. The whole line is
	# skipped if all three are empty (idle solo NPC outside combat).
	var ctx: Array[String] = []
	if not stance.is_empty():
		ctx.append("S:" + stance)
	if not role.is_empty():
		ctx.append("R:" + role)
	if not pose.is_empty():
		ctx.append("P:" + pose)
	if not ctx.is_empty():
		lines.append(" ".join(ctx))
	var bp_dict: Variant = view.get("body_parts")
	if bp_dict is Dictionary:
		var bp: Dictionary = bp_dict
		var any_damaged: bool = false
		for key in ["head", "torso", "left_arm", "right_arm", "left_leg", "right_leg"]:
			if float(bp.get(key, 100.0)) < 100.0:
				any_damaged = true
				break
		if any_damaged:
			lines.append(
				"H%d T%d LA%d RA%d LL%d RL%d"
				% [
					int(bp.get("head", 0.0)),
					int(bp.get("torso", 0.0)),
					int(bp.get("left_arm", 0.0)),
					int(bp.get("right_arm", 0.0)),
					int(bp.get("left_leg", 0.0)),
					int(bp.get("right_leg", 0.0)),
				]
			)
	var wounds_any: Variant = view.get("wounds")
	if wounds_any is Array and (wounds_any as Array).size() > 0:
		var wounds: Array = wounds_any
		var bleed_count: int = 0
		var infected_count: int = 0
		var tourniquet_count: int = 0
		for w_any in wounds:
			if not (w_any is Dictionary):
				continue
			var w: Dictionary = w_any
			var treatment: String = String(w.get("treatment", ""))
			var kind: String = String(w.get("kind", ""))
			if treatment == "untreated" and kind == "bleed":
				bleed_count += 1
			if bool(w.get("infected", false)):
				infected_count += 1
			if treatment == "tourniquet":
				tourniquet_count += 1
		var parts: Array[String] = ["W:%d" % wounds.size()]
		if bleed_count > 0:
			parts.append("B:%d" % bleed_count)
		if infected_count > 0:
			parts.append("I:%d" % infected_count)
		if tourniquet_count > 0:
			parts.append("T:%d" % tourniquet_count)
		lines.append(" ".join(parts))
	return "\n".join(lines)


func set_label_visible(v: bool) -> void:
	_labels_enabled = v
	if _label == null:
		_label = get_node_or_null("StateLabel")
	if _label != null:
		_label.visible = v and _current_lod == 0


func apply_lod(dist_sq: float) -> void:
	var lod: int
	if dist_sq < LOD_NEAR_SQ:
		lod = 0
	elif dist_sq < LOD_MID_SQ:
		lod = 1
	else:
		lod = 2
	if lod == _current_lod:
		return
	_current_lod = lod
	match lod:
		0:
			if _body_root != null:
				_body_root.visible = true
			if _billboard != null:
				_billboard.visible = false
			collision_layer = Layers.NPC_HITBOX
			if _movement_collider != null:
				_movement_collider.disabled = false
			if _hitbox_area != null:
				_hitbox_area.collision_layer = Layers.NPC_HITBOX
			if _label != null:
				_label.visible = _labels_enabled
		1:
			if _body_root != null:
				_body_root.visible = false
			_ensure_billboard()
			if _billboard != null:
				_billboard.visible = true
			collision_layer = 0
			if _hitbox_area != null:
				_hitbox_area.collision_layer = 0
			if _label != null:
				_label.visible = false
		2:
			if _body_root != null:
				_body_root.visible = false
			if _billboard != null:
				_billboard.visible = false
			collision_layer = 0
			if _hitbox_area != null:
				_hitbox_area.collision_layer = 0
			if _label != null:
				_label.visible = false


func _ensure_billboard() -> void:
	if _billboard != null:
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 2.0)
	_billboard = MeshInstance3D.new()
	_billboard.name = "Billboard"
	_billboard.mesh = quad
	_billboard.position = Vector3(0, 1.0, 0)
	var source_mat: StandardMaterial3D = null
	if _body_root != null:
		var torso: MeshInstance3D = _body_root.get_node_or_null("Torso") as MeshInstance3D
		if torso != null:
			source_mat = torso.material_override as StandardMaterial3D
	var bb_mat: StandardMaterial3D
	if source_mat != null:
		bb_mat = source_mat.duplicate() as StandardMaterial3D
	else:
		bb_mat = StandardMaterial3D.new()
		bb_mat.albedo_color = Color(0.6, 0.6, 0.6)
	bb_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_billboard.material_override = bb_mat
	add_child(_billboard)
