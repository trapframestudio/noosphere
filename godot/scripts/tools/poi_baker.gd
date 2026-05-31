@tool
class_name PoiBaker
extends Node3D
## Editor tool that scatters bases, activity points, cover volumes,
## and patrol routes across a test map for stress-testing the sim's
## NPC behavior pipeline.
##
## **Workflow**:
## 1. Drop a `PoiBaker` node under the test map root.
## 2. Tune inspector exports (`base_count`, `bake_extents`, etc.).
## 3. Click **Bake POIs**.
## 4. Save the scene.
##
## The baker creates all content under a single `BakedPOIs` child so
## **Clear baked POIs** wipes everything in one shot.
##
## **Key design decisions**:
## - All activity points are **faction-neutral** (`faction = ""`).
##   The sim's squad planner already knows each squad's faction and
##   filters by territorial standing — faction-locking APs caused a
##   mismatch with the randomly-seeded region factions and broke all
##   AP interactions.
## - Cover volumes are scattered across the **entire map** on a grid,
##   not just near bases. Combat AI needs cover within 30-50m to
##   take tactical positions.
## - Bases use a checkered grid pattern to prevent overlapping.

const _BAKED_NODE_NAME: StringName = &"BakedPOIs"
const _POI_MARKER_SCRIPT_PATH: String = "res://scripts/world/poi_marker.gd"
const _INTERACTION_AREA_MARKER_SCRIPT_PATH: String = (
	"res://scripts/world/interaction_area_marker.gd"
)
const _ACTIVITY_POINT_SCRIPT_PATH: String = "res://scripts/world/activity_point_marker.gd"
const _COVER_VOLUME_SCRIPT_PATH: String = "res://scripts/world/cover_volume_marker.gd"
const _PATROL_ROUTE_SCRIPT_PATH: String = "res://scripts/world/patrol_route_marker.gd"

@export_group("Placement")
@export var bake_seed: int = 1: set = _set_bake_seed
@export_range(0, 18, 1) var base_count: int = 18: set = _set_base_count
@export_range(0, 12, 1) var camp_count: int = 8: set = _set_camp_count
@export var bake_extents: Vector2 = Vector2(1800.0, 1800.0)

@export_group("Cover")
## Grid cell size for map-wide cover scatter (meters).
@export var cover_grid_cell_m: float = 120.0
## Cover volumes per grid cell.
@export_range(1, 4, 1) var cover_per_cell: int = 1
## Extra cover volumes clustered near each base.
@export_range(0, 8, 1) var cover_per_base: int = 4

@export_group("Wilderness")
## Faction-neutral guard/lookout APs scattered across the map.
@export_range(0, 200, 1) var wilderness_guard_count: int = 50
## Faction-neutral rest/campfire APs in the wilderness.
@export_range(0, 100, 1) var wilderness_rest_count: int = 30
## Ambush points in the wilderness.
@export_range(0, 60, 1) var wilderness_ambush_count: int = 15
## Patrol routes connecting random bases.
@export_range(0, 20, 1) var patrol_route_count: int = 8

@export_group("Factions")
## Factions for base visual identity (PoiMarker3D). APs are
## faction-neutral regardless of this setting.
@export var factions: PackedStringArray = PackedStringArray(
	["pwa", "linemen", "looters", "federal"]
)

@export_group("Terrain")
@export var terrain3d_path: NodePath = ^"../Terrain3D"

@export_group("Debug")
## Show debug rings/boxes on all baked markers. Disable for perf
## on dense bakes if the editor lags.
@export var show_all_debug_visuals: bool = true: set = _set_show_all_debug

@export_group("Tools")
@export_tool_button("Bake POIs", "PlayBackwards") var bake_action: Callable = _do_bake
@export_tool_button("Clear baked POIs", "Remove") var clear_action: Callable = _do_clear


func _set_show_all_debug(v: bool) -> void:
	show_all_debug_visuals = v
	var baked := get_node_or_null(NodePath(String(_BAKED_NODE_NAME)))
	if baked == null:
		return
	for child in baked.get_children():
		if child.has_method("set") and "show_debug_visual" in child:
			child.set("show_debug_visual", v)


func _set_bake_seed(v: int) -> void:
	bake_seed = max(0, v)


func _set_base_count(v: int) -> void:
	base_count = clampi(v, 0, 18)


func _set_camp_count(v: int) -> void:
	camp_count = clampi(v, 0, 12)


# --- Bake / clear -----------------------------------------------

func _do_clear() -> void:
	if not Engine.is_editor_hint():
		return
	var prior := get_node_or_null(NodePath(String(_BAKED_NODE_NAME)))
	if prior != null:
		prior.queue_free()


func _do_bake() -> void:
	if not Engine.is_editor_hint():
		push_warning("PoiBaker: bake outside editor; ignoring.")
		return
	var prior := get_node_or_null(NodePath(String(_BAKED_NODE_NAME)))
	if prior != null:
		remove_child(prior)
		prior.queue_free()

	var poi_script: Script = load(_POI_MARKER_SCRIPT_PATH)
	var area_script: Script = load(_INTERACTION_AREA_MARKER_SCRIPT_PATH)
	var ap_script: Script = load(_ACTIVITY_POINT_SCRIPT_PATH)
	var cv_script: Script = load(_COVER_VOLUME_SCRIPT_PATH)
	var pr_script: Script = load(_PATROL_ROUTE_SCRIPT_PATH)
	if poi_script == null or area_script == null:
		push_error("PoiBaker: missing required marker scripts")
		return

	var baked := Node3D.new()
	baked.name = _BAKED_NODE_NAME
	add_child(baked)
	var scene_root := get_tree().get_edited_scene_root() if Engine.is_editor_hint() else null
	if scene_root != null:
		baked.owner = scene_root

	var rng := RandomNumberGenerator.new()
	rng.seed = bake_seed

	var base_positions: Array[Vector3] = []
	var counts := {"bases": 0, "camps": 0, "aps": 0, "cover": 0, "routes": 0, "areas": 0}

	# ── Pass 1: Bases (checkered grid) ──────────────────────────
	const STRATA: int = 6
	var cell_w := bake_extents.x * 2.0 / float(STRATA)
	var cell_h := bake_extents.y * 2.0 / float(STRATA)
	var cells: Array = []
	# Checkered pattern: only use cells where (x+z) is even.
	# Guarantees no two bases are in adjacent cells.
	for cx in STRATA:
		for cz in STRATA:
			if (cx + cz) % 2 == 0:
				cells.append(Vector2(cx, cz))
	_shuffle(cells, rng)

	var inset := 0.20
	var base_idx := 0
	while base_idx < base_count and base_idx < cells.size():
		var cell: Vector2 = cells[base_idx]
		var origin_x := -bake_extents.x + cell.x * cell_w
		var origin_z := -bake_extents.y + cell.y * cell_h
		var pos_x := origin_x + cell_w * lerpf(inset, 1.0 - inset, rng.randf())
		var pos_z := origin_z + cell_h * lerpf(inset, 1.0 - inset, rng.randf())
		var faction_name := ""
		if factions.size() > 0:
			faction_name = factions[base_idx % factions.size()]
		var kind_id := _pick_base_kind(rng, faction_name)
		var pos := Vector3(pos_x, 0.0, pos_z)
		pos.y = _sample_terrain_y(pos.x, pos.z)
		var marker: Node3D = _make_node(poi_script)
		marker.name = "Poi_%s_%d" % [faction_name, base_idx]
		marker.position = pos
		marker.set("kind", kind_id)
		marker.set("faction", _faction_id_from_name(faction_name))
		marker.set("poi_id", "%s_%s_%d" % [_map_id(), faction_name, base_idx])
		_add_to_bake(baked, marker, scene_root)
		base_positions.append(pos)
		counts["bases"] += 1

		# Per-base interaction areas (rest + one extra).
		var area_pos := pos + Vector3(8.0, 0.0, 0.0)
		area_pos.y = _sample_terrain_y(area_pos.x, area_pos.z)
		var rest_area: Node3D = _make_node(area_script)
		rest_area.name = "Rest_%s_%d" % [faction_name, base_idx]
		rest_area.position = area_pos
		rest_area.set("interaction_kind", "rest")
		rest_area.set("area_id", "%s_rest_%d" % [_map_id(), base_idx])
		rest_area.set("capacity", 2)
		rest_area.set("extents", Vector3(3.0, 1.0, 3.0))
		_add_to_bake(baked, rest_area, scene_root)
		counts["areas"] += 1

		# Per-base activity points — ALL faction-neutral.
		if ap_script != null:
			for ap_def in _activity_points_for_kind(kind_id):
				var ap := Marker3D.new()
				ap.set_script(ap_script)
				var offset_v: Vector3 = ap_def["offset"]
				var ap_pos: Vector3 = pos + offset_v
				ap_pos.y = _sample_terrain_y(ap_pos.x, ap_pos.z)
				ap.name = "AP_%s_%d" % [ap_def["label"], base_idx]
				ap.position = ap_pos
				ap.set("kind", ap_def["kind"])
				ap.set("faction", "")  # faction-neutral
				ap.set("radius_m", ap_def.get("radius", 2.0))
				ap.set("capacity", ap_def.get("capacity", 1))
				if ap_def.has("facing"):
					ap.set("facing_yaw_deg", ap_def["facing"])
				if ap_def.has("loop_id"):
					ap.set("loop_id", "%s_%d" % [ap_def["loop_id"], base_idx])
				_add_to_bake(baked, ap, scene_root)
				counts["aps"] += 1

		base_idx += 1

	# Neutral camp sites.
	var camp_idx := 0
	while camp_idx < camp_count and (base_idx + camp_idx) < cells.size():
		var cell: Vector2 = cells[base_idx + camp_idx]
		var origin_x := -bake_extents.x + cell.x * cell_w
		var origin_z := -bake_extents.y + cell.y * cell_h
		var pos := Vector3(
			origin_x + cell_w * lerpf(inset, 1.0 - inset, rng.randf()),
			0.0,
			origin_z + cell_h * lerpf(inset, 1.0 - inset, rng.randf()),
		)
		pos.y = _sample_terrain_y(pos.x, pos.z)
		var marker: Node3D = _make_node(poi_script)
		marker.name = "Camp_%d" % camp_idx
		marker.position = pos
		marker.set("kind", 5)  # BASE_CAMP_SITE
		marker.set("faction", 0)  # NONE
		marker.set("poi_id", "%s_camp_%d" % [_map_id(), camp_idx])
		_add_to_bake(baked, marker, scene_root)
		base_positions.append(pos)
		counts["camps"] += 1
		if ap_script != null:
			for camp_ap in _activity_points_for_kind(5):
				var cap := Marker3D.new()
				cap.set_script(ap_script)
				var coffset_v: Vector3 = camp_ap["offset"]
				var cap_pos: Vector3 = pos + coffset_v
				cap_pos.y = _sample_terrain_y(cap_pos.x, cap_pos.z)
				cap.name = "AP_%s_camp_%d" % [camp_ap["label"], camp_idx]
				cap.position = cap_pos
				cap.set("kind", camp_ap["kind"])
				cap.set("faction", "")
				cap.set("radius_m", camp_ap.get("radius", 2.0))
				cap.set("capacity", camp_ap.get("capacity", 1))
				_add_to_bake(baked, cap, scene_root)
				counts["aps"] += 1
		camp_idx += 1

	# ── Pass 2: Cover volumes (map-wide grid) ──────────────────
	if cv_script != null:
		var grid_nx := int(bake_extents.x * 2.0 / cover_grid_cell_m)
		var grid_nz := int(bake_extents.y * 2.0 / cover_grid_cell_m)
		for gx in grid_nx:
			for gz in grid_nz:
				for _ci in cover_per_cell:
					var cx := -bake_extents.x + (gx + rng.randf()) * cover_grid_cell_m
					var cz := -bake_extents.y + (gz + rng.randf()) * cover_grid_cell_m
					var cv := _make_cover(cv_script, rng, cx, cz)
					cv.name = "Cover_%d_%d_%d" % [gx, gz, _ci]
					_add_to_bake(baked, cv, scene_root)
					counts["cover"] += 1

		# Extra cover near each base.
		for bi in base_positions.size():
			var bp := base_positions[bi]
			for ci in cover_per_base:
				var dx := rng.randf_range(-25.0, 25.0)
				var dz := rng.randf_range(-25.0, 25.0)
				var cv := _make_cover(cv_script, rng, bp.x + dx, bp.z + dz)
				cv.name = "BaseCover_%d_%d" % [bi, ci]
				_add_to_bake(baked, cv, scene_root)
				counts["cover"] += 1

	# ── Pass 3: Wilderness activity points ─────────────────────
	if ap_script != null:
		# Guard / lookout.
		for i in wilderness_guard_count:
			var kind_pick: int = 0 if rng.randf() < 0.6 else 4  # GUARD_STATIC or LOOKOUT
			var wap := _make_wilderness_ap(
				ap_script, rng, kind_pick,
				"WildGuard_%d" % i
			)
			_add_to_bake(baked, wap, scene_root)
			counts["aps"] += 1

		# Rest / campfire.
		for i in wilderness_rest_count:
			var kind_pick: int = 3 if rng.randf() < 0.5 else 5  # REST_SPOT or CAMPFIRE
			var wap := _make_wilderness_ap(
				ap_script, rng, kind_pick,
				"WildRest_%d" % i
			)
			wap.set("capacity", rng.randi_range(2, 4))
			_add_to_bake(baked, wap, scene_root)
			counts["aps"] += 1

		# Ambush points.
		for i in wilderness_ambush_count:
			var wap := _make_wilderness_ap(ap_script, rng, 9, "WildAmbush_%d" % i)
			_add_to_bake(baked, wap, scene_root)
			counts["aps"] += 1

	# ── Pass 4: Patrol routes ──────────────────────────────────
	if pr_script != null and base_positions.size() >= 2:
		for ri in patrol_route_count:
			var a_idx := rng.randi() % base_positions.size()
			var b_idx := rng.randi() % base_positions.size()
			while b_idx == a_idx and base_positions.size() > 1:
				b_idx = rng.randi() % base_positions.size()
			var route := Path3D.new()
			route.set_script(pr_script)
			route.name = "Patrol_%d" % ri
			var curve := Curve3D.new()
			var pa := base_positions[a_idx]
			var pb := base_positions[b_idx]
			# Add a midpoint with slight offset for non-straight paths.
			var mid := (pa + pb) * 0.5
			mid.x += rng.randf_range(-100.0, 100.0)
			mid.z += rng.randf_range(-100.0, 100.0)
			mid.y = _sample_terrain_y(mid.x, mid.z)
			curve.add_point(pa)
			curve.add_point(mid)
			curve.add_point(pb)
			route.curve = curve
			route.set("route_id", "%s_patrol_%d" % [_map_id(), ri])
			route.set("faction", "")
			route.set("loop_route", true)
			route.set("priority", 5)
			_add_to_bake(baked, route, scene_root)
			counts["routes"] += 1

	# ── Pass 5: Extra interaction areas ────────────────────────
	const EXTRA_KINDS: Array[String] = ["work", "socialize", "scavenge", "patrol_node"]
	for i in 12:
		var pos := Vector3(
			lerpf(-bake_extents.x, bake_extents.x, rng.randf()),
			0.0,
			lerpf(-bake_extents.y, bake_extents.y, rng.randf()),
		)
		pos.y = _sample_terrain_y(pos.x, pos.z)
		var area: Node3D = _make_node(area_script)
		var kind: String = EXTRA_KINDS[i % EXTRA_KINDS.size()]
		area.name = "%s_%d" % [kind.capitalize(), i]
		area.position = pos
		area.set("interaction_kind", kind)
		area.set("area_id", "%s_%s_%d" % [_map_id(), kind, i])
		area.set("capacity", 1)
		area.set("extents", Vector3(2.0, 1.0, 2.0))
		_add_to_bake(baked, area, scene_root)
		counts["areas"] += 1

	print(
		"PoiBaker: baked %d bases, %d camps, %d APs, %d cover, %d routes, %d areas — save to commit"
		% [counts["bases"], counts["camps"], counts["aps"],
		   counts["cover"], counts["routes"], counts["areas"]]
	)


# --- Helpers ----------------------------------------------------

func _add_to_bake(parent: Node3D, child: Node, scene_root: Node) -> void:
	parent.add_child(child)
	if scene_root != null:
		child.owner = scene_root


func _make_node(script: Script) -> Node3D:
	var n := Node3D.new()
	n.set_script(script)
	return n


func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _sample_terrain_y(x: float, z: float) -> float:
	var t3d := get_node_or_null(terrain3d_path)
	if t3d != null:
		var data = t3d.get("data")
		if data != null and data.has_method("get_height"):
			var h: float = float(data.call("get_height", Vector3(x, 0.0, z)))
			if not (is_nan(h) or is_inf(h)):
				return h
	return 0.0


func _make_cover(
	cv_script: Script,
	rng: RandomNumberGenerator,
	x: float,
	z: float,
) -> Node3D:
	var cv := Node3D.new()
	cv.set_script(cv_script)
	var y := _sample_terrain_y(x, z)
	cv.position = Vector3(x, y + 0.5, z)
	# Random material + height.
	var mat_pick := rng.randi() % 5
	# 0=CONCRETE, 4=WOOD_THICK, 7=EARTH, 10=VEHICLE_BODY, 6=SANDBAG
	var mat_map: Array[int] = [0, 4, 7, 10, 6]
	var thick_map: Array[float] = [250.0, 120.0, 400.0, 80.0, 200.0]
	cv.set("material", mat_map[mat_pick])
	cv.set("thickness_mm", thick_map[mat_pick])
	cv.set("height", rng.randi() % 3)  # LOW, HIGH, FULL
	cv.set("half_extents", Vector3(
		rng.randf_range(0.6, 2.5),
		rng.randf_range(0.5, 1.5),
		rng.randf_range(0.4, 2.0),
	))
	cv.set("show_debug_visual", show_all_debug_visuals)
	return cv


func _make_wilderness_ap(
	ap_script: Script,
	rng: RandomNumberGenerator,
	kind: int,
	label: String,
) -> Marker3D:
	var wx := lerpf(-bake_extents.x, bake_extents.x, rng.randf())
	var wz := lerpf(-bake_extents.y, bake_extents.y, rng.randf())
	var wap := Marker3D.new()
	wap.set_script(ap_script)
	wap.name = label
	wap.position = Vector3(wx, _sample_terrain_y(wx, wz), wz)
	wap.set("kind", kind)
	wap.set("faction", "")
	wap.set("radius_m", 3.0)
	wap.set("capacity", 2)
	wap.set("show_debug_visual", show_all_debug_visuals)
	return wap


func _pick_base_kind(rng: RandomNumberGenerator, faction: String) -> int:
	var weights: Array[float]
	match faction:
		"pwa":
			weights = [0.30, 0.30, 0.15, 0.10, 0.10, 0.05]
		"linemen":
			weights = [0.35, 0.10, 0.10, 0.30, 0.05, 0.10]
		"federal":
			weights = [0.20, 0.10, 0.05, 0.30, 0.30, 0.05]
		"looters":
			weights = [0.05, 0.40, 0.40, 0.00, 0.00, 0.15]
		_:
			weights = [0.20, 0.30, 0.20, 0.10, 0.10, 0.10]
	var total := 0.0
	for w in weights:
		total += w
	var pick := rng.randf() * total
	var acc := 0.0
	for i in weights.size():
		acc += weights[i]
		if pick < acc:
			return i
	return 1


func _faction_id_from_name(faction: String) -> int:
	match faction:
		"pwa": return 1
		"linemen": return 2
		"revere_guard": return 3
		"federal": return 4
		"gulf_compact": return 5
		"merged": return 6
		"noosphere_worshippers": return 7
		"looters": return 8
		"corporate_research": return 9
		"wanderers": return 10
		_: return 0


func _activity_points_for_kind(base_kind: int) -> Array:
	match base_kind:
		0:  # CHECKPOINT
			return [
				{"kind": 0, "offset": Vector3(6, 0, 0), "label": "guard_l", "facing": 90.0},
				{"kind": 0, "offset": Vector3(-6, 0, 0), "label": "guard_r", "facing": 270.0},
				{"kind": 3, "offset": Vector3(0, 0, -5), "label": "rest"},
			]
		1:  # OUTPOST
			return [
				{"kind": 0, "offset": Vector3(12, 0, 0), "label": "guard_n", "facing": 0.0},
				{"kind": 0, "offset": Vector3(0, 0, 12), "label": "guard_e", "facing": 90.0},
				{"kind": 0, "offset": Vector3(-12, 0, 0), "label": "guard_s", "facing": 180.0},
				{"kind": 0, "offset": Vector3(0, 0, -12), "label": "guard_w", "facing": 270.0},
				{"kind": 5, "offset": Vector3(3, 0, 3), "label": "campfire", "capacity": 3},
			]
		2:  # SAFEHOUSE
			return [
				{"kind": 0, "offset": Vector3(8, 0, 0), "label": "guard_door", "facing": 0.0},
				{"kind": 3, "offset": Vector3(-4, 0, 3), "label": "rest_a", "capacity": 2},
				{"kind": 3, "offset": Vector3(4, 0, -3), "label": "rest_b", "capacity": 2},
				{"kind": 6, "offset": Vector3(-6, 0, -4), "label": "workbench"},
			]
		3:  # HEADQUARTERS
			return [
				{"kind": 0, "offset": Vector3(10, 0, 0), "label": "guard_n", "facing": 0.0},
				{"kind": 0, "offset": Vector3(-10, 0, 0), "label": "guard_s", "facing": 180.0},
				{"kind": 0, "offset": Vector3(0, 0, 10), "label": "guard_e", "facing": 90.0},
				{"kind": 0, "offset": Vector3(25, 0, 0), "label": "guard_out_n", "facing": 0.0},
				{"kind": 0, "offset": Vector3(-25, 0, 0), "label": "guard_out_s", "facing": 180.0},
				{"kind": 3, "offset": Vector3(5, 0, -5), "label": "rest_a", "capacity": 3},
				{"kind": 3, "offset": Vector3(-5, 0, 5), "label": "rest_b", "capacity": 3},
				{"kind": 4, "offset": Vector3(20, 0, 15), "label": "lookout_ne"},
				{"kind": 4, "offset": Vector3(-20, 0, -15), "label": "lookout_sw"},
				{"kind": 8, "offset": Vector3(0, 0, 30), "label": "sniper"},
			]
		4:  # RESEARCH_POST
			return [
				{"kind": 0, "offset": Vector3(8, 0, 0), "label": "guard_a", "facing": 0.0},
				{"kind": 0, "offset": Vector3(-4, 0, 7), "label": "guard_b", "facing": 120.0},
				{"kind": 6, "offset": Vector3(-3, 0, 0), "label": "workbench"},
				{"kind": 7, "offset": Vector3(4, 0, -4), "label": "stash"},
			]
		5:  # CAMP_SITE
			return [
				{"kind": 3, "offset": Vector3(3, 0, 0), "label": "rest_a", "capacity": 2},
				{"kind": 3, "offset": Vector3(-3, 0, 0), "label": "rest_b", "capacity": 2},
				{"kind": 5, "offset": Vector3(0, 0, 2), "label": "campfire", "capacity": 4},
			]
	return []


func _map_id() -> String:
	var scene_path := get_tree().get_edited_scene_root().scene_file_path \
		if Engine.is_editor_hint() else ""
	if scene_path.is_empty():
		return "map"
	return scene_path.get_file().get_basename()
