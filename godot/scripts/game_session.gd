extends Node
## Session orchestration layer.
##
## Wires the `NetworkManager` and `SimHost` gdext nodes to the Godot
## scene graph:
## - owns the local player instance, remote pills, and NPC dummies
## - loads/unloads map scenes based on the sim's region graph
## - routes the local player's transform through the sim (sim is the
##   source of truth; Godot follows)
## - publishes the sim's player view over the network each physics tick
## - filters incoming peer state by map id — only render remote pills
##   that are currently on the same map as the local player
##
## Registered as an autoload (see project.godot). Access via
## `/root/GameSession`.

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const REMOTE_PILL_SCENE: PackedScene = preload("res://scenes/remote_pill.tscn")
const BASE_MARKER_SCENE: PackedScene = preload("res://scenes/base_marker.tscn")
const NPC_DUMMY_SCENE: PackedScene = preload("res://scenes/humanoid_dummy.tscn")

## Synthetic Steam ID used in solo mode. Picked deliberately to be
## small + recognizable in logs; real Steam IDs are huge u64 values
## starting at 0x110000100000000, so collision is impossible.
const SOLO_STEAM_ID: int = 0xDEADBEEF

## Emitted when a lobby is created (host) or entered (join). The main
## menu uses this to surface the id so the host can paste it to a
## friend when the Steam overlay is unavailable.
signal lobby_id_changed(lobby_id: int)

## Emitted when the network or sim layers report a failure that the
## player should see. Both the private `_on_network_error` and
## `_on_sim_error` re-emit through this so shell screens (runs list,
## server browser, dev overlay) can surface the message inline
## instead of relying on the console. Source is "network" or "sim".
signal session_failed(source: String, message: String)

var _network: Node = null
var _sim: Node = null
var _current_map_id: String = ""
var _current_map_node: Node = null
var _local_player: Node = null
var _remote_pills: Dictionary = {} # steam_id(int) -> Node OR null (known peer, wrong map)
var _peer_last_state: Dictionary = {} # steam_id(int) -> { map_id, pos, yaw }
var _npc_dummies: Dictionary = {} # npc_id(int) -> Node
## The active run's id (from RunsStore). Solo + coop-host sessions use
## this to key the on-disk save directory `user://saves/<run_id>/`.
## Joining clients leave this empty — their mirror sim has no local
## persistence. Set by `solo(run_id)` / `host(run_id)` entry points.
var _run_id: String = ""
## Dev: show per-NPC state labels above each dummy. Toggle with Tab.
## Default off — at spawn density the Label3D billboards are a
## noticeable fill-rate and CPU cost.
var _npc_labels_visible: bool = false
## Population density preset index. Cycled by F10.
## 0=low (×0.25), 1=default (×1.0), 2=high (×3.0), 3=stress (×8.0)
var _pop_density_idx: int = 1
const POP_DENSITY_LABELS: Array = ["low", "default", "high", "stress"]
const POP_DENSITY_FACTORS: Array = [0.25, 1.0, 3.0, 8.0]
## Wall-clock seconds since the last dummy sync. We only rebuild
## dummies at the sim's 20Hz rate since the underlying data only
## updates that fast; syncing every physics frame at 60Hz wastes
## allocations and doesn't improve visual fidelity (dummies interp).
var _npc_sync_accum: float = 0.0
var _diag_sync_accum: float = 0.0
## Dummy roster + label sync rate. Drops from the original 20 Hz to
## 4 Hz. Position updates already happen every render frame via the
## snapshot-pair lerp (`_lerp_npc_dummies`); this slower path is
## only for spawn/despawn lifecycle and the label-text rebuild
## (faction, goal, HP — slow-changing state).
##
## At 20 Hz the sync was costing 1000+ `_build_label_text` calls/sec
## (50 NPCs × 20 Hz), each one a fresh `String` of Dict gets +
## format-printing. Showed up in the GDScript profiler as a major
## `_process` / `_build` hot spot. 4 Hz cuts that 5×.
const NPC_SYNC_INTERVAL_S: float = 1.0 / 4.0
## Don't even create dummies further than this from the local player.
## The humanoid_dummy LOD tiers handle visual quality between 0–250m;
## this is the hard outer cull. Keeping it at 300m (a bit past the
## mid-LOD threshold of 250m) avoids dummies popping in/out at the
## exact LOD boundary.
const NPC_DRAW_DISTANCE_M: float = 300.0
const NPC_DRAW_DISTANCE_SQ_M: float = NPC_DRAW_DISTANCE_M * NPC_DRAW_DISTANCE_M
## True when started via solo() — Steam is not initialized and the
## local player uses SOLO_STEAM_ID.
var _solo: bool = false


func _ready() -> void:
	_network = get_node_or_null("NetworkManager")
	_sim = get_node_or_null("SimHost")
	if _network == null:
		push_error("GameSession: NetworkManager child node not found")
		return
	if _sim == null:
		push_error("GameSession: SimHost child node not found")
		return

	# Point the sim at Noosphere's proprietary content pack, overlaid on
	# SIMN's embedded generic example (factions / names / chatter come
	# from res://content; mechanics + items inherit from the engine).
	# Must be set before any start()/start_mirror().
	if _sim.has_method("set_content_root"):
		_sim.set_content_root("res://content")

	_network.peer_joined.connect(_on_peer_joined)
	_network.peer_left.connect(_on_peer_left)
	_network.peer_state.connect(_on_peer_state)
	_network.lobby_ready.connect(_on_lobby_ready)
	_network.join_requested.connect(_on_join_requested)
	_network.network_error.connect(_on_network_error)
	_network.snapshot_requested.connect(_on_snapshot_requested)
	_network.snapshot_received.connect(_on_snapshot_received)
	_network.delta_received.connect(_on_delta_received)
	_network.action_received.connect(_on_action_received)

	_sim.sim_error.connect(_on_sim_error)
	_sim.tick_completed.connect(_on_sim_tick_completed)
	_sim.action_requested.connect(_on_sim_action_requested)
	_sim.snapshot_applied.connect(_on_sim_snapshot_applied)

	# Wire SimHost to NetworkManager so the mutation gate inside
	# SimHost can read the local role without a GDScript round-trip.
	if _sim.has_method("attach_network"):
		_sim.attach_network(_network)

	# No sim is started here — solo() / host() / join() entrypoints
	# start the appropriate variant (authoritative with a per-run
	# save dir, or mirror mode for a joining client).

	# Apply the global theme after the filesystem scan is settled. See
	# `docs/book/src/architecture/menu-ui.md` — wiring this via
	# `gui/theme/custom` in project.godot race-loads the theme before
	# font imports finish on a cold project open, cascading parse
	# failures through every script that reads NSFonts.* constants.
	var theme := load("res://resources/theme/noosphere_theme.tres") as Theme
	if theme != null:
		get_tree().root.theme = theme

	get_tree().auto_accept_quit = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_npc_labels"):
		_npc_labels_visible = not _npc_labels_visible
		for id in _npc_dummies.keys():
			var p: Node = _npc_dummies[id]
			if p != null and p.has_method("set_label_visible"):
				p.set_label_visible(_npc_labels_visible)
	elif event.is_action_pressed("cycle_map"):
		# Cycle through every region the sim knows about, in graph
		# order. `all_regions()` is the authoritative list; the old
		# hardcoded MAP_CYCLE const drifted when new maps landed.
		var regions: Array = _sim.all_regions() if _sim != null else []
		if regions.is_empty():
			return
		var idx := regions.find(_current_map_id)
		var next_idx := (idx + 1) % regions.size()
		var next_map: String = regions[next_idx]
		print("[map] → %s" % next_map)
		request_map_change(next_map)
	elif event.is_action_pressed("toggle_behavior_log"):
		if _sim != null and _sim.has_method("set_behavior_log"):
			var on: bool = not _sim.behavior_log_enabled()
			_sim.set_behavior_log(on)
			print("[behavior log] ", ("ON" if on else "OFF"))
	elif event.is_action_pressed("cycle_pop_density"):
		if _sim != null and _sim.has_method("scale_population"):
			# To go from current preset to the next, we undo the
			# current factor and apply the next.
			var old_factor: float = POP_DENSITY_FACTORS[_pop_density_idx]
			_pop_density_idx = (_pop_density_idx + 1) % POP_DENSITY_LABELS.size()
			var new_factor: float = POP_DENSITY_FACTORS[_pop_density_idx]
			_sim.scale_population(new_factor / old_factor)
			print("[population] density → %s (×%.2f)" % [
				POP_DENSITY_LABELS[_pop_density_idx], new_factor
			])


func _notification(what: int) -> void:
	# Graceful shutdown on window-close: final snapshot before exiting.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _sim != null:
			_sim.shutdown()
		get_tree().quit()


func _physics_process(delta: float) -> void:
	if _local_player == null or _sim == null or _current_map_id.is_empty():
		return
	# Write local transform into the sim first — sim is authoritative.
	var pos: Vector3 = _local_player.global_position
	var yaw: float = _local_player.rotation.y
	var sid: int = local_steam_id()
	if sid != 0:
		_sim.move_local_player(sid, pos, yaw)
		# In solo mode there's no network to publish to.
		if not _solo and _network != null:
			var view: Dictionary = _sim.player_state(sid)
			if not view.is_empty():
				_network.publish_state(view["region"], view["pos"], view["yaw"])

	# Sync dummy roster (spawn / despawn / label refresh) at the
	# sim's 20Hz. Per-frame position lerp is handled in `_process`
	# via `_lerp_npc_dummies` — the snapshot-pair API makes it
	# frame-rate-independent.
	_npc_sync_accum += delta
	if _npc_sync_accum >= NPC_SYNC_INTERVAL_S:
		_npc_sync_accum = 0.0
		_sync_npc_dummies()

	_lerp_npc_dummies()


## Per-render-frame interpolated position update for existing
## dummies. Reads the sim's snapshot pair via
## `SimHost.snapshot_interp_npcs_near` (one bridge call, parallel
## `PackedArrays`), then sets `global_position` directly on each
## dummy. Bypasses the dummy's own `interp_speed` smoothing — that
## was a constant-rate lag-behind that doesn't track the sim's tick
## rate. With the snapshot-pair lerp we get the exact authoritative
## position interpolated by real time-since-tick, so visual motion
## is smooth at any frame rate from 30 to 240 FPS.
##
## Dummies for IDs we haven't spawned yet are skipped — the slower
## `_sync_npc_dummies` path handles the spawn / despawn / configure
## lifecycle. Threaded-sim PR B (2026-05-11).
func _lerp_npc_dummies() -> void:
	if _sim == null or _current_map_node == null or _local_player == null:
		return
	if _npc_dummies.is_empty():
		return
	if not _sim.has_snapshot_pair():
		return
	var player_pos: Vector3 = _local_player.global_position
	var bundle: Dictionary = _sim.snapshot_interp_npcs_near(
		_current_map_id, player_pos, NPC_DRAW_DISTANCE_M
	)
	if bundle.is_empty():
		return
	var ids: PackedInt64Array = bundle.get("ids", PackedInt64Array())
	var positions: PackedVector3Array = bundle.get("positions", PackedVector3Array())
	var yaws: PackedFloat32Array = bundle.get("yaws", PackedFloat32Array())
	var n: int = ids.size()
	for i in range(n):
		var id: int = ids[i]
		if not _npc_dummies.has(id):
			continue
		var dummy = _npc_dummies[id]
		if dummy == null:
			continue
		dummy.apply_sim_position(positions[i], yaws[i], get_physics_process_delta_time())


## Pull the current NPC roster for this region from the sim, spawn
## new dummies, update positions on existing ones, free dummies whose
## NPC vanished. Sim is authoritative; this is purely view layer.
##
## Distance-culls beyond `NPC_DRAW_DISTANCE_M`. The sim still ticks
## those NPCs server-side; we just don't spawn a scene node for
## them until the player gets closer, and we free the node once
## they drift back out of range. Saves draw calls and Label3D fill
## at spawn-dense regions.
##
## **Marshaling cost.** The server-side `npcs_near` API also gates by
## the same draw radius, so the per-NPC `Dictionary` marshaling cost
## (15 keys per NPC, ~hundreds of `Variant` allocations) is only paid
## for NPCs the player can actually see. With ~800 NPCs in a region
## but only ~50 within 300 m of the player, this is the difference
## between 1 FPS and playable.
func _sync_npc_dummies() -> void:
	if _sim == null or _current_map_node == null:
		return
	var player_pos := Vector3.ZERO
	if _local_player != null:
		player_pos = _local_player.global_position
	var views: Array = _sim.npcs_near(_current_map_id, player_pos, NPC_DRAW_DISTANCE_M)
	# DIAGNOSTIC: log once per second so we can see the actual dummy
	# count vs returned views. If dummies >> 50 there's a leak; if
	# views >> 50 the server-side distance filter is broken.
	_diag_sync_accum += NPC_SYNC_INTERVAL_S
	var diag_log: bool = _diag_sync_accum >= 1.0
	if diag_log:
		_diag_sync_accum = 0.0
	var seen: Dictionary = {}
	for view in views:
		var id: int = view.get("id", 0)
		if id == 0:
			continue
		var npc_pos: Vector3 = view.get("pos", Vector3.ZERO)
		var dx: float = npc_pos.x - player_pos.x
		var dz: float = npc_pos.z - player_pos.z
		var dist_sq: float = dx * dx + dz * dz
		seen[id] = true
		if _npc_dummies.has(id):
			var existing: Node = _npc_dummies[id]
			if existing != null and existing.has_method("set_state"):
				existing.set_state(view)
			if existing != null and existing.has_method("apply_lod"):
				existing.apply_lod(dist_sq)
		else:
			var dummy: Node = NPC_DUMMY_SCENE.instantiate()
			_current_map_node.add_child(dummy)
			if dummy.has_method("configure"):
				dummy.configure(view)
			if dummy.has_method("set_label_visible"):
				dummy.set_label_visible(_npc_labels_visible)
			if dummy.has_method("apply_lod"):
				dummy.apply_lod(dist_sq)
			_npc_dummies[id] = dummy
	# Free dummies whose NPC is no longer in this region OR drifted
	# past the draw distance.
	var to_remove: Array = []
	for id in _npc_dummies.keys():
		if not seen.has(id):
			to_remove.append(id)
	for id in to_remove:
		var p: Node = _npc_dummies[id]
		if p != null:
			p.queue_free()
		_npc_dummies.erase(id)
	if diag_log:
		print(
			"[npc_sync map=%s] views_returned=%d dummies=%d player_pos=%s draw_m=%d"
			% [_current_map_id, views.size(), _npc_dummies.size(), player_pos, int(NPC_DRAW_DISTANCE_M)]
		)


# ---------- public API ----------

## Solo path. Skips Steam entirely — no lobby, no overlay, no network
## init. Uses a synthetic Steam ID so the sim's player-keyed lookups
## work identically to multiplayer. The run's save directory is
## `user://saves/<run_id>/`; if a snapshot exists there we resume it.
func solo(run_id: String) -> void:
	if _sim == null or run_id.is_empty():
		push_error("GameSession.solo: run_id required")
		return
	_solo = true
	_run_id = run_id
	_start_authoritative_sim(run_id)
	var sid := SOLO_STEAM_ID
	var region := _starting_region_for_run(run_id)
	var saved: Dictionary = _sim.player_state(sid)
	if not saved.is_empty():
		region = saved.get("region", region)
	_enter_region(region, true)


## Coop-host path. Same as solo but also opens a Steam lobby.
## `run_id` keys the save directory. Joiners will be sent a snapshot
## of the current state once they issue a JoinRequest.
func host(run_id: String) -> void:
	if _network == null or _sim == null or run_id.is_empty():
		push_error("GameSession.host: run_id required")
		return
	_run_id = run_id
	_start_authoritative_sim(run_id)
	_network.host_session()
	var sid: int = local_steam_id()
	var region: String = _starting_region_for_run(run_id)
	if sid != 0:
		var saved: Dictionary = _sim.player_state(sid)
		if not saved.is_empty():
			region = saved.get("region", region)
	_enter_region(region, true)


## Infer which region a fresh run should spawn into from its `run_id`
## slug. Saved state (if any) always takes precedence — this is only
## the fresh-session fallback.
##
## Convention: `run_id` is a lowercase slug of the run's display name
## (see `RunsStore._make_id`). A run whose slug starts with a real
## map's id loads that map (so naming a run "Corbett" / "Latourell
## test" / "The Dalles" lands you in that region). Anything else
## falls back to the default test map.
##
## The list matches the spine entries in
## `RegionGraph::default_test_graph` on the sim side. When branch
## maps land (sandy, eagle_creek, …) extend this list and/or replace
## with a RegionGraph query via `SimHost.all_regions()`.
static func _starting_region_for_run(run_id: String) -> String:
	var lc := run_id.to_lower()
	const REAL_MAP_IDS: Array[String] = [
		"corbett",
		"latourell",
		"multnomah",
		"bonneville",
		"cascade_locks",
		"hood_river",
		"mosier",
		"the_dalles",
		"sandy",
		"bull_run",
		"eagle_creek",
		"hood_river_valley",
		"white_salmon",
		"mt_hood",
		"klickitat_hold",
		"umatilla",
		"hanford_spur",
		"celilo",
		"lost_lake",
	]
	for id in REAL_MAP_IDS:
		if lc.begins_with(id):
			return id
	return "map_a"


## Coop-client path. No local save — starts a mirror sim that consumes
## the host's snapshot and deltas. `join_requested` signal fires after
## the Steam lobby is ready; we reply by sending `send_join_request`
## to ask the host for a snapshot.
func join(lobby_id: int) -> void:
	if _network == null or _sim == null:
		return
	_run_id = ""
	if _sim.has_method("start_mirror"):
		_sim.start_mirror()
		# Prime the faction debug-color cache from the registry now
		# that the mirror sim has loaded the canonical TOML.
		FactionColors.refresh_from_sim(_sim)
	_network.join_session(lobby_id)
	# Don't enter a region yet — wait for the host's snapshot to
	# arrive. `_on_sim_snapshot_applied` triggers the scene load.


func _start_authoritative_sim(run_id: String) -> void:
	var save_dir := _save_dir_for(run_id)
	DirAccess.make_dir_recursive_absolute(save_dir)
	_sim.start(save_dir)
	# Prime the faction debug-color cache from the registry now that
	# the sim has loaded the canonical TOML. Subsequent
	# `FactionColors.of(name)` calls hit the cache.
	FactionColors.refresh_from_sim(_sim)


func _save_dir_for(run_id: String) -> String:
	return OS.get_user_data_dir() + "/saves/" + run_id


func invite() -> void:
	if _network != null:
		_network.open_invite_overlay()


func local_steam_id() -> int:
	if _solo:
		return SOLO_STEAM_ID
	if _network == null:
		return 0
	return _network.local_steam_id()


## Force a sim snapshot now (Ctrl+S hotkey). Calls shutdown +
## re-start so the snapshot is fresh and the journal rotates.
func force_save() -> void:
	if _sim == null:
		return
	# Mirror clients have no local save; force_save is a host-side
	# concern.
	if _run_id.is_empty():
		return
	_sim.shutdown()
	_sim.start(_save_dir_for(_run_id))
	FactionColors.refresh_from_sim(_sim)


## Returns true when a session is active (player has entered a
## region). Shell-side overlays use this to gate whether the game
## menu can open — main-menu contexts should not show it.
func in_game() -> bool:
	return _current_map_node != null and _current_map_id != ""


## Snapshot current state, free the current map + local entities, and
## change scene back to the main menu. Mouse capture is released so
## the main menu is usable. The network lobby is *not* torn down on
## this path — the `simn-net` side needs a `leave_session` entrypoint
## for a clean Steam exit; until then, quitting the app is the
## reliable way to drop the lobby.
func leave_session_to_menu() -> void:
	force_save()
	_current_map_id = ""
	if _local_player != null:
		_local_player.queue_free()
		_local_player = null
	_remote_pills.clear()
	_peer_last_state.clear()
	_npc_dummies.clear()
	if _current_map_node != null:
		_current_map_node.queue_free()
		_current_map_node = null
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file("res://scenes/menus/mainMenu.tscn")


## Dev shortcut: wipe saves, reinit sim, and re-enter the current
## region so the player is re-registered and NPC dummies reset. Used
## by the in-game Ctrl+Shift+R binding.
func wipe_and_reenter() -> void:
	var current := _current_map_id
	wipe_world()
	if current != "":
		_enter_region(current, false)


## Wipe the world: delete save files on disk and reinitialize the
## sim from scratch. Surfaces the latest seeder output without
## requiring a terminal. Operates on the active run's save directory
## — mirror clients (empty `_run_id`) no-op. Returns true if files
## were actually removed.
func wipe_world() -> bool:
	if _sim != null:
		_sim.shutdown()
	if _run_id.is_empty():
		return false
	var save_dir := _save_dir_for(_run_id)
	var removed := false
	var dir := DirAccess.open(save_dir)
	if dir != null:
		for filename in dir.get_files():
			dir.remove(filename)
			removed = true
	DirAccess.make_dir_recursive_absolute(save_dir)
	if _sim != null:
		_sim.start(save_dir)
		FactionColors.refresh_from_sim(_sim)
	return removed


## Asks the sim to change the local player's region, then loads the
## scene the sim reports for that region. Called by transition cubes.
## Always spawns at the target map's PlayerSpawn — we don't restore
## mid-region positions across transitions.
func request_map_change(new_region: String) -> void:
	if new_region == _current_map_id or _sim == null:
		return
	_enter_region(new_region, false)


# ---------- region/scene loading ----------

func _enter_region(region_name: String, try_saved_state: bool) -> void:
	if _sim == null:
		return
	var scene_path: String = _sim.region_map_scene(region_name)
	if scene_path.is_empty():
		push_error("GameSession: unknown region '%s'" % region_name)
		return

	# Unload previous scene and local entities.
	if _current_map_node != null:
		_current_map_node.queue_free()
		_current_map_node = null
	_remote_pills.clear()
	# NPC dummies are children of the freed map node, so they go with
	# it; just drop our id->Node bookkeeping so we re-spawn fresh.
	_npc_dummies.clear()
	if _local_player != null:
		_local_player.queue_free()
		_local_player = null

	# Free whatever scene is currently the main scene (e.g. the menu)
	# so it doesn't keep eating input on top of the map.
	var prev_scene := get_tree().current_scene
	if prev_scene != null and prev_scene != _current_map_node:
		prev_scene.queue_free()
		get_tree().current_scene = null

	var scene: PackedScene = load(scene_path) as PackedScene
	if scene == null:
		push_error("GameSession: failed to load %s" % scene_path)
		return
	_current_map_node = scene.instantiate()
	get_tree().root.add_child(_current_map_node)
	get_tree().current_scene = _current_map_node
	_current_map_id = region_name

	# Capture the mouse for FPS look immediately — no click needed.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	_local_player = PLAYER_SCENE.instantiate()
	_current_map_node.add_child(_local_player)
	_local_player.add_to_group("local_player")

	var sid: int = local_steam_id()
	var spawn_pos: Vector3 = Vector3.ZERO
	var spawn_yaw: float = 0.0
	var used_saved: bool = false

	# If the caller said "use saved state if we have it," try the sim
	# first. Only honor the saved position when the saved region also
	# matches what we're entering.
	if sid != 0 and try_saved_state:
		var view: Dictionary = _sim.player_state(sid)
		if not view.is_empty() and view.get("region", "") == region_name:
			spawn_pos = view["pos"]
			spawn_yaw = view["yaw"]
			used_saved = true

	if not used_saved:
		var spawn := _current_map_node.get_node_or_null("PlayerSpawn")
		if spawn != null:
			spawn_pos = spawn.global_position
		# Record the fresh spawn authoritatively in the sim so the
		# journal captures it (and so publish_state has something to
		# read on the next frame).
		if sid != 0:
			_sim.upsert_local_player(sid, region_name, spawn_pos, spawn_yaw)

	_local_player.global_position = spawn_pos
	_local_player.rotation.y = spawn_yaw

	# Spawn faction-colored base markers for every base in this region.
	_spawn_base_markers(region_name)

	# Re-spawn remote pills for peers already reported on this region.
	for peer_sid in _peer_last_state.keys():
		var s: Dictionary = _peer_last_state[peer_sid]
		if s.get("map_id", "") == _current_map_id:
			_spawn_remote_pill(peer_sid, s["pos"], s["yaw"])


func _spawn_base_markers(region_name: String) -> void:
	if _sim == null or _current_map_node == null:
		return
	var bases: Array = _sim.bases_in_region(region_name)
	for view in bases:
		var marker: Node = BASE_MARKER_SCENE.instantiate()
		_current_map_node.add_child(marker)
		# configure() reads pos/kind/faction from the dict and sets
		# global_position itself.
		if marker.has_method("configure"):
			marker.configure(view)


# ---------- NetworkManager signal handlers ----------

func _on_peer_joined(steam_id: int) -> void:
	print("peer joined: ", steam_id)
	# Host-side: a Steam peer just entered the lobby. Spawn their
	# player entity at map_a's default position so the snapshot we
	# send them includes their own avatar. Slice 2 picks up stored
	# position if the peer was already in this run.
	if _network != null and _sim != null and _network.role() == "host":
		_sim.upsert_local_player(steam_id, "map_a", Vector3.ZERO, 0.0)


func _on_peer_left(steam_id: int) -> void:
	_peer_last_state.erase(steam_id)
	if _remote_pills.has(steam_id):
		var p: Node = _remote_pills[steam_id]
		if p != null:
			p.queue_free()
		_remote_pills.erase(steam_id)
	# Host-side: remove the peer's player entity from the authoritative
	# sim. Mirror clients should NOT call remove_player (role gate
	# inside SimHost handles this).
	if _sim != null:
		_sim.remove_player(steam_id)


func _on_peer_state(steam_id: int, map_id: String, pos: Vector3, yaw: float) -> void:
	_peer_last_state[steam_id] = {"map_id": map_id, "pos": pos, "yaw": yaw}
	if map_id == _current_map_id:
		if not _remote_pills.has(steam_id) or _remote_pills[steam_id] == null:
			_spawn_remote_pill(steam_id, pos, yaw)
		else:
			_remote_pills[steam_id].set_remote_state(pos, yaw)
	else:
		if _remote_pills.has(steam_id) and _remote_pills[steam_id] != null:
			_remote_pills[steam_id].queue_free()
			_remote_pills[steam_id] = null


func _on_lobby_ready(lobby_id: int) -> void:
	print("lobby ready: ", lobby_id)
	lobby_id_changed.emit(lobby_id)
	if _network == null:
		return
	# Host: open the Steam invite overlay so friends can join.
	# Client: send a JoinRequest so the host replies with a snapshot.
	var role: String = _network.role()
	if role == "host":
		_network.open_invite_overlay()
	elif role == "client":
		_network.send_join_request()


func _on_join_requested(lobby_id: int) -> void:
	print("join requested from overlay: ", lobby_id)
	join(lobby_id)


func _on_network_error(message: String) -> void:
	push_error("[network] " + message)
	session_failed.emit("network", message)


func _on_sim_error(message: String) -> void:
	push_error("[sim] " + message)
	session_failed.emit("sim", message)


# ---------- Replication signal handlers (slice-1) ----------

## Host: a peer asked for a snapshot. Serialize current state and
## send it only to them (rather than broadcasting) — snapshots are
## large and we don't want to re-send to everyone on every join.
func _on_snapshot_requested(peer_steam_id: int) -> void:
	if _sim == null or _network == null:
		return
	if _network.role() != "host":
		return
	var payload: Dictionary = _sim.serialize_snapshot_payload()
	if payload.is_empty():
		push_error("GameSession: snapshot serialization returned empty")
		return
	var tick: int = payload.get("tick", 0)
	var bytes: PackedByteArray = payload.get("payload", PackedByteArray())
	_network.send_snapshot(peer_steam_id, tick, bytes)


## Client: host sent us a full-world snapshot. Apply to mirror sim,
## then enter the region the local player ended up in.
func _on_snapshot_received(tick: int, payload: PackedByteArray) -> void:
	if _sim == null:
		return
	_sim.apply_network_snapshot(tick, payload)
	# `_on_sim_snapshot_applied` does the region entry once the sim
	# has finished ingesting the snapshot.


## Client: host sent us a per-tick delta batch. Apply to mirror.
func _on_delta_received(tick: int, payload: PackedByteArray) -> void:
	if _sim == null:
		return
	_sim.apply_network_delta_batch(tick, payload)


## Host: a client sent us an action to apply. Dispatch into the
## authoritative sim — the resulting journal deltas will broadcast
## back to everyone via the usual tick_completed path.
func _on_action_received(peer_steam_id: int, steam_id: int, payload: PackedByteArray) -> void:
	if _sim == null:
		return
	# Peer-steam-id is the sender; steam-id is the acting player. In
	# slice 1 they're always equal (no host-initiated remote actions
	# yet), but validation lives in slice 3.
	var _p: int = peer_steam_id
	_sim.dispatch_network_action(steam_id, payload)


# ---------- SimHost signal handlers (slice-1) ----------

## Host: SimHost finished a frame's tick catch-up and has a delta
## batch ready to broadcast. Forward to every lobby peer.
func _on_sim_tick_completed(tick: int, payload: PackedByteArray) -> void:
	if _network == null:
		return
	_network.broadcast_delta(tick, payload)


## Client: local mutation tried to run but we're in client role.
## Package the encoded action as a network message to the host.
func _on_sim_action_requested(steam_id: int, payload: PackedByteArray) -> void:
	if _network == null:
		return
	_network.send_action(steam_id, payload)


## Client: mirror sim finished applying a host-sent snapshot. Figure
## out which region the local player ended up in and load that scene.
func _on_sim_snapshot_applied(tick: int) -> void:
	var _t: int = tick
	if _sim == null:
		return
	var sid: int = local_steam_id()
	var view: Dictionary = _sim.player_state(sid)
	var region: String = view.get("region", "map_a")
	_enter_region(region, true)


# ---------- internals ----------

func _spawn_remote_pill(steam_id: int, pos: Vector3, yaw: float) -> void:
	if _current_map_node == null:
		return
	var pill: Node = REMOTE_PILL_SCENE.instantiate()
	_current_map_node.add_child(pill)
	pill.global_position = pos
	pill.rotation.y = yaw
	pill.set_meta("steam_id", steam_id)
	if pill.has_method("set_peer_color"):
		pill.set_peer_color(steam_id)
	_remote_pills[steam_id] = pill
