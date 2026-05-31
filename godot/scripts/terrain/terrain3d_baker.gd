@tool
# Deliberately NOT declaring `class_name Terrain3DBaker` — `extends Terrain3D`
# combined with class_name registration crashes Godot's editor during the
# global script class cache build (Godot tries to instantiate the script
# for export-property introspection; Terrain3D's C++ constructor doesn't
# survive that out-of-tree call). The bundled `addons/terrain_3d/tools/importer.gd`
# follows the same anonymous-script pattern. Reference this script via
# its path (`res://scripts/terrain/terrain3d_baker.gd`), not a class name.
extends Terrain3D
## Editor-time tooling for Terrain3D ↔ canonical asset round-trip.
##
## Two operations on the same node:
##
##   1. **Bake Now** — seed the on-disk Terrain3D regions
##      (`terrain3d_XX_YY.res`) from the canonical bake artifacts
##      (`heightmap.r32` + `splatmap_a/b.rgba8` + `terrain.toml`). Use
##      this once when starting a new map. Defaults to `SEED_IF_EMPTY`
##      so a misclick can't clobber sculpted/painted regions; flip to
##      `OVERWRITE_FORCE` when a re-seed from canonical is genuinely
##      what's wanted.
##
##   2. **Sync to Canonical** — push live region data back to the
##      canonical assets (height + splat). Click after sculpting or
##      painting in Terrain3D so the server-side Rust path
##      (`simn_terrain::Heightmap::load`) sees what the editor sees,
##      to f32 precision. Variants (slots 11–15) are bake-time
##      decoration and don't round-trip — paint with biome slots
##      0–10 if the change should survive a re-seed.
##
## **Why this is editor-only.** Terrain3D's native extension needs a
## live graphics context for `_enter_tree` / `add_child` to succeed —
## a `--headless` `SceneTree` script crashes in `libterrain.so` during
## node construction. So both operations must run inside the running
## editor.
##
## **Workflow** (typical):
##   - First touch on a map: attach this script to the `Terrain3D`
##     node, set `bake_map_id`, click **Bake Now**.
##   - Save the scene so `data_directory` persists.
##   - Sculpt + paint in Terrain3D as desired.
##   - Click **Sync to Canonical** to push edits back to disk.
##   - Future "Bake Now" clicks will refuse (SEED_IF_EMPTY).
##
## See [walkthroughs/terrain3d.md](docs/book/src/walkthroughs/terrain3d.md).

const Terrain3DLoader := preload("res://scripts/terrain/terrain3d_loader.gd")
const Terrain3DExporter := preload("res://scripts/terrain/terrain3d_exporter.gd")

enum BakeMode {
	## Default. Refuses to overwrite existing region files; prevents
	## accidental clobbering of sculpted / painted data.
	SEED_IF_EMPTY,
	## Re-seed from canonical, overwriting all existing regions.
	OVERWRITE_FORCE,
}

@export_group("Bake")
@export var bake_map_id: String = "cascade_locks"
@export_dir var save_directory_path: String = "res://assets/terrain/cascade_locks/terrain3d/"
## Default `SEED_IF_EMPTY` blocks Bake Now when region files already
## exist on disk, so an accidental click can't destroy sculpted /
## painted edits. Flip to `OVERWRITE_FORCE` to re-seed from the
## canonical `heightmap.r32` / `splatmap_a/b.rgba8` artifacts. The
## flag does NOT auto-reset — leave it on `SEED_IF_EMPTY` for normal
## work.
@export var bake_mode: BakeMode = BakeMode.SEED_IF_EMPTY
## Region edge length in vertices. Applied to `self.region_size` at
## bake time rather than from the .tscn, because Terrain3D's C++
## setter for that property crashes when invoked during scene-load
## property assignment (the underlying `data` isn't initialized
## yet). Default 1024 = ~2 km / region at 2 m vertex spacing.
@export_enum("64:64", "128:128", "256:256", "512:512", "1024:1024", "2048:2048") var bake_region_size: int = 1024
## World meters per terrain vertex. Same property-order workaround
## as `bake_region_size` — set at bake time, not in the .tscn.
@export var bake_vertex_spacing: float = 2.0
## Inspector button that triggers the bake. `@export_tool_button`
## requires Godot 4.4+; replaces the older "checkbox with setter that
## resets itself" pattern, which read as janky in the inspector.
@export_tool_button("Bake Now", "PlayBackwards") var bake_action: Callable = _do_bake
## Round-trip the live Terrain3D height + splat back into the
## canonical `heightmap.r32` / `splatmap_a/b.rgba8` /
## `road_density.rgba8`. Refreshes `terrain.toml`'s `blake3` digest
## via the gdext `TerrainHash` helper. Click after sculpting or
## painting; safe to re-click (idempotent on no-op edits).
@export_tool_button("Sync to Canonical", "Save") var sync_action: Callable = _do_sync_to_canonical

## Walk the scene tree from the edited scene root, find every
## TreeScatter / RockScatter / GroundCoverScatter descendant, and
## trigger each one's whole-map bake. Useful after a fresh **Bake
## Now** (terrain seed) so vegetation caches populate the full map
## without per-tile gameplay pop-in. Slow on large maps: cascade_locks
## ≈ several minutes per scatter type. Logs progress per scatter.
##
## Does NOT include `TreeCoverageBaker` (distant-tree tint texture)
## or `TreeClusterScatter` (distant impostors), and does NOT
## canonicalize. Use **Bake Everything** for the full chain after
## adding/moving exclusion zones.
@export_tool_button("Rebake Vegetation (whole map)", "Refresh") var rebake_veg_action: Callable = _do_rebake_vegetation

## One-click full bake chain. Run after adding or moving exclusion
## zones (or any other change that should propagate everywhere). Order:
##
##   1. `TreeCoverageBaker.bake()` — produces `tree_coverage.res`,
##      bound to the Terrain3D shader (distant-tree tint) and
##      consumed by step 5.
##   2. `RockScatter._bake_cache_whole_map()` — rocks first because
##      they publish `_tile_tree_exclusions` that step 3 consumes.
##   3. `TreeScatter._bake_cache_whole_map()` — close-tier trees see
##      both exclusion zones AND rock exclusions.
##   4. `GroundCoverScatter._bake_cache_whole_map()` — close-tier
##      plants. Independent of the above; ordered after for predictable
##      log output.
##   5. `TrashScatter._bake_cache_whole_map()` — road / town litter.
##      Filtered to road-or-zone tiles internally so this stage is
##      bounded regardless of map size.
##   6. `TreeClusterScatter._bake()` — distant impostor cards. Reads
##      the coverage texture written in step 1, so the holes carved
##      out there propagate to the impostors.
##   7. `Terrain3DExporter.export_canonical()` — sync live Terrain3D
##      height + splat back to the canonical `.r32` / `.rgba8` files.
##
## Slow: cascade_locks runs ~5–10 minutes end to end. Reload the
## scene afterward to drop in-memory MMIs from before the rebake.
@export_tool_button("Bake Everything (zones → scatters → canonical)", "Save") var bake_all_action: Callable = _do_bake_everything


func _do_bake() -> void:
	if not Engine.is_editor_hint():
		push_warning("Terrain3DBaker: bake button pressed outside editor; ignoring.")
		return
	if data == null:
		push_error("Terrain3DBaker: `data` is null — Terrain3D needs to be in"
			+ " the scene tree with the addon initialized before baking.")
		return
	if save_directory_path.is_empty():
		push_error("Terrain3DBaker: save_directory_path is empty.")
		return

	# Ensure the destination directory exists.
	var abs_dir := ProjectSettings.globalize_path(save_directory_path)
	var err := DirAccess.make_dir_recursive_absolute(abs_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("Terrain3DBaker: failed to create %s (err=%d)"
			% [abs_dir, err])
		return

	# Guard: refuse to overwrite existing region data unless the user
	# explicitly opts in. Without this, a misclick on Bake Now silently
	# destroys sculpting / painting work because import_images +
	# save_directory rewrites every terrain3d_XX_YY.res from canonical.
	if bake_mode == BakeMode.SEED_IF_EMPTY and _has_existing_regions(save_directory_path):
		push_error("Terrain3DBaker: %s already has region files. Refusing to "
			% save_directory_path
			+ "clobber sculpted/painted data. To re-seed from canonical "
			+ "(.r32/.rgba8) anyway, set bake_mode = OVERWRITE_FORCE on "
			+ "this node and click Bake Now again.")
		return

	# Apply region_size + vertex_spacing here, where `data` is fully
	# initialized — these can't be set from the .tscn without
	# crashing Terrain3D's C++ side.
	if region_size != bake_region_size:
		region_size = bake_region_size
	if vertex_spacing != bake_vertex_spacing:
		vertex_spacing = bake_vertex_spacing

	# Run the converter — populates `self.data` with regions in memory.
	if not Terrain3DLoader.bake_into(bake_map_id, self):
		push_error("Terrain3DBaker: bake_into returned false")
		return

	# Persist regions to disk + point ourselves at the directory so a
	# scene save serializes the right reference.
	data.save_directory(save_directory_path)
	data_directory = save_directory_path
	print("Terrain3DBaker: saved %d regions to %s — save the scene to commit"
		% [data.get_regions_active().size(), save_directory_path])


func _do_sync_to_canonical() -> void:
	if not Engine.is_editor_hint():
		push_warning("Terrain3DBaker: sync button pressed outside editor; ignoring.")
		return
	if data == null:
		push_error("Terrain3DBaker: `data` is null — Terrain3D needs to be in"
			+ " the scene tree before syncing.")
		return
	if bake_map_id.is_empty():
		push_error("Terrain3DBaker: bake_map_id is empty.")
		return
	Terrain3DExporter.export_canonical(bake_map_id, self)


func _do_rebake_vegetation() -> void:
	if not Engine.is_editor_hint():
		push_warning("Terrain3DBaker: rebake-vegetation pressed outside editor; ignoring.")
		return
	var root := get_tree().get_edited_scene_root()
	if root == null:
		push_error("Terrain3DBaker: no edited scene root — open a scene first.")
		return
	var scatters: Array[Node] = []
	_collect_scatters(root, scatters)
	if scatters.is_empty():
		push_warning("Terrain3DBaker: no TreeScatter / RockScatter / "
			+ "GroundCoverScatter / TrashScatter descendants found in the scene.")
		return
	print("Terrain3DBaker: rebaking %d vegetation scatter(s) for whole map..."
		% scatters.size())
	var t_start := Time.get_ticks_msec()
	for i in scatters.size():
		var scatter: Node = scatters[i]
		print("Terrain3DBaker: [%d/%d] %s — %s"
			% [i + 1, scatters.size(), scatter.name, scatter.get_script().resource_path])
		# Each scatter exposes `_bake_cache_whole_map` (added 2026-05-03).
		# Public `bake_whole_map` would be cleaner, but the private
		# names match what the inspector buttons already invoke.
		if scatter.has_method("_bake_cache_whole_map"):
			scatter.call("_bake_cache_whole_map")
		else:
			push_warning("Terrain3DBaker: %s has no _bake_cache_whole_map (skipped)"
				% scatter.get_path())
	var elapsed_s := float(Time.get_ticks_msec() - t_start) / 1000.0
	print("Terrain3DBaker: rebake vegetation COMPLETE in %.1fs" % elapsed_s)


# Walk the scene tree, append every TreeScatter / RockScatter /
# GroundCoverScatter descendant to `out`. Identification by script
# `resource_path` rather than `is ClassName` because the Godot
# global class_name registry can be stale in @tool context after
# script reloads (same root cause as the static-dispatch fix in
# `tree_scatter.gd`'s exclusion checks).
func _collect_scatters(node: Node, out: Array[Node]) -> void:
	var script: Script = node.get_script()
	if script != null:
		var path: String = script.resource_path
		if path == "res://scripts/foliage/tree_scatter.gd" \
				or path == "res://scripts/foliage/rock_scatter.gd" \
				or path == "res://scripts/foliage/ground_cover.gd" \
				or path == "res://scripts/foliage/trash_scatter.gd":
			out.append(node)
	for child in node.get_children():
		_collect_scatters(child, out)


# Generic version of `_collect_scatters` — append every descendant
# whose script's `resource_path` matches `script_path`. Same
# stale-class_name-registry rationale as `_collect_scatters`.
func _collect_by_script(node: Node, script_path: String, out: Array[Node]) -> void:
	var script: Script = node.get_script()
	if script != null and script.resource_path == script_path:
		out.append(node)
	for child in node.get_children():
		_collect_by_script(child, script_path, out)


# Run all `bakers` through `method`, wrapping in a visually distinct
# stage header + footer with elapsed time. Returns elapsed seconds so
# the orchestrator can build a final per-stage breakdown.
# `optional` suppresses the "no nodes found" warning for stages not
# universally present (e.g. distant tree cluster is map-specific).
func _run_stage(stage_num: int, stage_total: int, label: String,
		bakers: Array[Node], method: String, optional: bool) -> float:
	var header := "==== STAGE %d/%d: %s" % [stage_num, stage_total, label]
	if bakers.is_empty():
		if not optional:
			push_warning("%s — no nodes found (REQUIRED)" % header)
		else:
			print("%s — no nodes (optional, skipped) ====" % header)
		return 0.0
	print("%s (%d node%s) ====" % [
		header, bakers.size(), "" if bakers.size() == 1 else "s"])
	var t0 := Time.get_ticks_msec()
	for i in bakers.size():
		var b: Node = bakers[i]
		print("  [%d/%d] %s — %s"
			% [i + 1, bakers.size(), b.name, b.get_script().resource_path])
		if b.has_method(method):
			b.call(method)
		else:
			push_warning("    no method %s on %s (skipped)"
				% [method, b.get_path()])
	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	print("==== STAGE %d/%d: %s done in %.1fs ====\n"
		% [stage_num, stage_total, label, elapsed])
	return elapsed


# Pre-flight log: list every exclusion zone the bake will see. The
# user clicks Bake Everything because they added/moved a zone, so
# surfacing the zone count + names up front lets them spot "I forgot
# to add this scene's exclusion to the right parent" before sitting
# through a 10-minute bake. Reads the same group `density_multiplier`
# queries at bake time, so what's printed here is exactly what the
# bakers will see.
func _log_exclusion_zones(root: Node) -> void:
	var zones: Array[Node] = get_tree().get_nodes_in_group(
		&"procedural_exclusion_zones")
	# Filter to descendants of the edited scene root only — group
	# members from autoloads or stray editor scratch don't count.
	var in_scene: Array[Node] = []
	for z in zones:
		var n: Node = z
		while n != null and n != root:
			n = n.get_parent()
		if n == root:
			in_scene.append(z)
	if in_scene.is_empty():
		print("  exclusion zones: NONE in current scene")
		print("    (if you expected zones, check they're parented under"
			+ " the edited scene root)")
		return
	print("  exclusion zones: %d in scene" % in_scene.size())
	for z in in_scene:
		var label: String = z.name
		var detail := ""
		if "shape" in z:
			# Don't import ProceduralExclusionZone here (avoid stale
			# class_name registry); read by property names which work
			# whether or not the script class is registered. Size now
			# comes from `transform.scale` (per the 2026-05-04 unit-
			# primitive schema) rather than radius_m / half_extents.
			var shape_v: int = int(z.get("shape"))
			var s: Vector3 = z.scale
			match shape_v:
				0:  # CYLINDER
					detail = "cylinder %.0f×%.0f×%.0fm" % [s.x, s.y, s.z]
				1:  # BOX
					detail = "box %.0f×%.0f×%.0fm" % [s.x, s.y, s.z]
		var trash_str := ""
		if "trash_density_mul" in z:
			trash_str = " trash=%.2f" % float(z.get("trash_density_mul"))
		var muls := "tree=%.2f rock=%.2f gc=%.2f%s" % [
			float(z.get("tree_density_mul")),
			float(z.get("rock_density_mul")),
			float(z.get("ground_cover_density_mul")),
			trash_str]
		print("    - %s @ %v  %s  %s" % [label, z.global_position, detail, muls])


func _do_bake_everything() -> void:
	if not Engine.is_editor_hint():
		push_warning("Terrain3DBaker: bake-everything pressed outside editor; ignoring.")
		return
	var root := get_tree().get_edited_scene_root()
	if root == null:
		push_error("Terrain3DBaker: no edited scene root — open a scene first.")
		return

	# Pre-flight: enumerate everything the bake is about to touch so
	# the user can sanity-check before committing to a multi-minute run.
	print("\n========================================================")
	print("Terrain3DBaker: BAKE EVERYTHING — pre-flight")
	print("========================================================")
	print("  scene root: %s" % root.name)
	print("  map id:     %s" % bake_map_id)
	var coverage_bakers: Array[Node] = []
	var rocks: Array[Node] = []
	var trees: Array[Node] = []
	var gc: Array[Node] = []
	var clusters: Array[Node] = []
	var trash: Array[Node] = []
	_collect_by_script(root, "res://scripts/foliage/tree_coverage_baker.gd",
		coverage_bakers)
	_collect_by_script(root, "res://scripts/foliage/rock_scatter.gd", rocks)
	_collect_by_script(root, "res://scripts/foliage/tree_scatter.gd", trees)
	_collect_by_script(root, "res://scripts/foliage/ground_cover.gd", gc)
	_collect_by_script(root, "res://scripts/foliage/tree_cluster_scatter.gd",
		clusters)
	_collect_by_script(root, "res://scripts/foliage/trash_scatter.gd", trash)
	print("  bakers found:")
	print("    %d × TreeCoverageBaker" % coverage_bakers.size())
	print("    %d × RockScatter"        % rocks.size())
	print("    %d × TreeScatter"        % trees.size())
	print("    %d × GroundCoverScatter" % gc.size())
	print("    %d × TreeClusterScatter" % clusters.size())
	print("    %d × TrashScatter"       % trash.size())
	_log_exclusion_zones(root)
	print("--------------------------------------------------------\n")

	var t_start := Time.get_ticks_msec()
	const N_STAGES: int = 7
	var stage_times: Array[float] = []

	# Stage 1: Tree coverage (writes tree_coverage.res, binds to
	# Terrain3D shader's tree_coverage_map uniform). Must run before
	# step 5 since the cluster scatter reads from this output.
	stage_times.append(_run_stage(1, N_STAGES, "tree coverage",
		coverage_bakers, "bake", true))

	# Stages 2-4: explicit rock-then-tree-then-ground-cover ordering so
	# trees see rock exclusions during their bake. The plain
	# "Rebake Vegetation" button walks scene-tree order, which only
	# does the right thing if the user authored the scene with rocks
	# above trees; this button enforces it regardless.
	stage_times.append(_run_stage(2, N_STAGES, "rocks",
		rocks, "_bake_cache_whole_map", true))
	stage_times.append(_run_stage(3, N_STAGES, "trees",
		trees, "_bake_cache_whole_map", true))
	stage_times.append(_run_stage(4, N_STAGES, "ground cover",
		gc, "_bake_cache_whole_map", true))

	# Stage 5: Trash. Runs after ground cover so trash placements
	# can sit on top of (and not fight with) the foliage layer.
	# Filtered to road / zone tiles internally so this is bounded
	# regardless of map size.
	stage_times.append(_run_stage(5, N_STAGES, "trash",
		trash, "_bake_cache_whole_map", true))

	# Stage 6: Distant impostor cluster — reads tree_coverage.res
	# written in stage 1.
	stage_times.append(_run_stage(6, N_STAGES, "distant tree cluster",
		clusters, "_bake", true))

	# Stage 7: Sync live Terrain3D height + splat back to canonical.
	# Idempotent on no-op edits, so safe to always run. Wrapped here
	# rather than via _run_stage because it's a one-shot internal call
	# (no scene-tree node collection) — same header shape kept manually.
	print("==== STAGE 7/%d: sync to canonical ====" % N_STAGES)
	var t6 := Time.get_ticks_msec()
	_do_sync_to_canonical()
	var t6_elapsed := float(Time.get_ticks_msec() - t6) / 1000.0
	stage_times.append(t6_elapsed)
	print("==== STAGE 7/%d: sync to canonical done in %.1fs ====\n"
		% [N_STAGES, t6_elapsed])

	var stage_labels := [
		"tree coverage", "rocks", "trees",
		"ground cover", "trash", "distant tree cluster", "sync to canonical"]
	var total_s := float(Time.get_ticks_msec() - t_start) / 1000.0
	print("========================================================")
	print("Terrain3DBaker: BAKE EVERYTHING COMPLETE in %.1fs" % total_s)
	print("========================================================")
	print("  per-stage:")
	for i in stage_times.size():
		var pct: float = 100.0 * stage_times[i] / maxf(total_s, 0.001)
		print("    %d. %-22s  %7.1fs  (%4.1f%%)"
			% [i + 1, stage_labels[i], stage_times[i], pct])
	print("  next: save the scene to commit, then reload to drop")
	print("        in-memory MMIs from before the rebake.")
	print("========================================================\n")


# Returns true iff `dir_res_path` already contains at least one
# `terrain3d_*.res` region file. Used to gate Bake Now against
# accidental data loss.
func _has_existing_regions(dir_res_path: String) -> bool:
	var dir := DirAccess.open(dir_res_path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.begins_with("terrain3d_") \
				and name.ends_with(".res"):
			dir.list_dir_end()
			return true
		name = dir.get_next()
	dir.list_dir_end()
	return false
