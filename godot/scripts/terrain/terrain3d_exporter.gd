@tool
class_name Terrain3DExporter
extends RefCounted
## Round-trips Terrain3D's live region data back into the canonical
## bake artifacts. Inverse of [Terrain3DLoader] — used by the
## **Sync to Canonical** button on `Terrain3DBaker` so server-side
## consumers (`simn_terrain::Heightmap::load`, foliage scatter) see
## what the editor sees, to f32 precision.
##
## **What round-trips:**
##   - Height: `heightmap.r32` literal f32 meters, format_version 2.
##   - Splat A/B: `splatmap_a.rgba8` / `splatmap_b.rgba8` per-layer
##     u8 weights for slots 0–7 (Forest / Grassland / Water / Cropland
##     / Bare / BuiltUp / Cliff / Snow).
##   - Roads: `road_density.rgba8` for slots 8–10 (Paved / Unpaved /
##     Trail). A channel left 0 (reserved).
##   - **Iteration 5-13 Phase A2: nav-override mask.** Slot 14
##     (`nav_block`) painted on any cell → `nav_mask.r8` byte = 1
##     (`NavOverride::ForceBlocked`). Slot 15 (`nav_walkable`)
##     painted → byte = 2 (`NavOverride::ForceWalkable`). Block wins
##     when both are present on the same cell. The sim's
##     `GridNavQuery::from_heightmap` honors these overrides per cell
##     (see `sim-iteration-5-13-plan.md` Phase A1).
##   - `terrain.toml`: `blake3` digest is recomputed via the gdext
##     `TerrainHash` helper. `nav_mask_blake3` + `nav_mask_format_version`
##     are rewritten alongside `blake3`. `format_version` is bumped if
##     the source was somehow still on v1 (shouldn't happen — this code
##     path requires v2). Other fields preserved byte-for-byte via line-
##     by-line rewrite.
##
## **What does NOT round-trip (intentional):**
##   - **TYPE_COLOR** (the cosmetic distance-LOD biome tint). Color
##     paint in Terrain3D survives in the `.res` regions; it's not
##     consumed by the server.
##   - **Variant slots 11–13** (mossy_rock, rocky_steppe, mossy_grass,
##     nordic_moss). These are noise-driven decoration applied during
##     the seed bake. If the user paints a variant directly, the synced
##     canonical splat captures the underlying biome (slot 0–10) only —
##     variants reapply on the next seed bake from the new base biomes.
##     The pixel's overlay slot is dropped if it's in the variant range;
##     if both base and overlay are variants, the pixel falls back to
##     whichever non-zero biome weight existed in the previous canonical
##     splat (so unbaked / non-canonical regions don't go to zero).
##     Slots 14 and 15 are nav-override channels (see above), no longer
##     decoration variants.
##   - **`features.r8`** — derived at bake time from splat + slope.
##     Sync clears `features_blake3` so the next consumer that needs
##     `features.r8` re-derives it from the synced splat + heights.
##
## **Out-of-region cells.** Terrain3D returns NaN for cells outside
## any active region. The exporter falls back to the *existing* byte
## value at that index (read from `heightmap.r32` / splat files
## before the new bytes are built), so untouched edges of the
## canonical map don't regress to zero.
##
## See [walkthroughs/terrain3d.md](docs/book/src/walkthroughs/terrain3d.md).

const _T3D_TYPE_HEIGHT := 0
const _T3D_TYPE_CONTROL := 1

# Layer ids that are baked-time-only variants. Their per-pixel weights
# don't survive the round-trip because the canonical splat doesn't
# carry slots 11–13 — they're noise-driven decoration applied each
# time `Terrain3DLoader.bake_into` runs. If the user paints a variant
# in Terrain3D, the underlying biome captures the change; the variant
# overlay reapplies on the next overwrite-force seed bake.
#
# Iteration 5-13 Phase A2: slots 14 and 15 are no longer variants —
# they're the designer-painted nav-override channels (slot 14 =
# nav_block → `NavOverride::ForceBlocked`, slot 15 = nav_walkable →
# `NavOverride::ForceWalkable`). They round-trip via `nav_mask.r8`,
# not via the splat.
const _LAYER_VARIANT_LO := 11
const _LAYER_VARIANT_HI := 14  # exclusive — true variants are 11..13

# Layer id → channel mapping, matches `terrain3d_loader.gd` and
# `simn-terrain` slot ordering.
#   splat_a R/G/B/A → 0 / 1 / 2 / 3 (Forest, Grassland, Water, Cropland)
#   splat_b R/G/B/A → 4 / 5 / 6 / 7 (Bare, BuiltUp, Cliff, Snow)
#   road    R/G/B/A → 8 / 9 / 10 / (unused)
const _LAYER_FOREST := 0
const _LAYER_GRASSLAND := 1
const _LAYER_WATER := 2
const _LAYER_CROPLAND := 3
const _LAYER_BARE := 4
const _LAYER_BUILTUP := 5
const _LAYER_CLIFF := 6
const _LAYER_SNOW := 7
const _LAYER_PAVED := 8
const _LAYER_UNPAVED := 9
const _LAYER_TRAIL := 10
# Phase A2: nav-override slots. Not biomes — not weighted in the
# splat. Their presence on a cell stamps a `nav_mask.r8` byte.
const _LAYER_NAV_BLOCK := 14
const _LAYER_NAV_WALKABLE := 15
# Byte values written into `nav_mask.r8`. Match
# `simn_terrain::NavOverride` (Default=0, ForceBlocked=1, ForceWalkable=2)
# and `NAV_MASK_FORMAT_VERSION = 1`.
const _NAV_MASK_DEFAULT := 0
const _NAV_MASK_BLOCK := 1
const _NAV_MASK_WALKABLE := 2
const _NAV_MASK_FORMAT_VERSION := 1


## Read live `terrain` data, write canonical files for `map_id`.
## Returns true on success. Logs progress + any vert-range expansion.
static func export_canonical(map_id: String, terrain: Terrain3D) -> bool:
	var dir := "res://assets/terrain/%s/" % map_id
	var toml_path := dir + "terrain.toml"
	if not FileAccess.file_exists(toml_path):
		push_error("Terrain3DExporter: missing %s" % toml_path)
		return false
	var meta := _parse_terrain_toml(toml_path)
	if meta.is_empty():
		push_error("Terrain3DExporter: failed to parse %s" % toml_path)
		return false

	var format_version: int = int(meta.get("format_version", 0))
	if format_version < 2:
		push_error(("Terrain3DExporter: %s is format_version %d (expected >= 2). "
			+ "Run `cargo run -p simn-terrain --bin migrate_canonical_format` first.")
			% [toml_path, format_version])
		return false

	var w: int = int(meta.get("width", 0))
	var h: int = int(meta.get("height", 0))
	var spacing_m: float = float(meta.get("spacing_m", 1.0))
	var vert_min: float = float(meta.get("vert_min_m", 0.0))
	var vert_max: float = float(meta.get("vert_max_m", 0.0))
	if w <= 0 or h <= 0:
		push_error("Terrain3DExporter: invalid dimensions in %s" % toml_path)
		return false

	# Existing canonical files — used as fallback for cells outside
	# any active region (Terrain3D returns NaN there).
	var existing_height := _read_bytes(dir + "heightmap.r32")
	var existing_splat_a := _read_bytes(dir + "splatmap_a.rgba8")
	var existing_splat_b := _read_bytes(dir + "splatmap_b.rgba8")
	var existing_road := _read_bytes(dir + "road_density.rgba8")
	# Iteration 5-13 Phase A2: nav-mask byte per cell, written
	# alongside the splat. NaN cells fall back to the existing
	# nav_mask.r8 (same pattern as the splat fallback).
	var existing_nav_mask := _read_bytes(dir + "nav_mask.r8")

	var extent_x := float(w - 1) * spacing_m
	var extent_z := float(h - 1) * spacing_m

	# --- Build new height bytes ---------------------------------------
	var new_height := PackedByteArray()
	new_height.resize(w * h * 4)
	var min_h := INF
	var max_h := -INF
	var nan_height_count := 0
	for pz in h:
		for px in w:
			var i := pz * w + px
			var wx := -extent_x * 0.5 + float(px) * spacing_m
			var wz := -extent_z * 0.5 + float(pz) * spacing_m
			var c: Color = terrain.data.get_pixel(_T3D_TYPE_HEIGHT, Vector3(wx, 0.0, wz))
			var m: float = c.r
			if is_nan(m):
				# Fall back to whatever the canonical already had.
				nan_height_count += 1
				if existing_height.size() == w * h * 4:
					m = existing_height.decode_float(i * 4)
				else:
					m = vert_min
			if m < min_h:
				min_h = m
			if m > max_h:
				max_h = m
			new_height.encode_float(i * 4, m)

	# --- Build new splat bytes ----------------------------------------
	var new_splat_a := PackedByteArray()
	var new_splat_b := PackedByteArray()
	var new_road := PackedByteArray()
	var new_nav_mask := PackedByteArray()
	new_splat_a.resize(w * h * 4)
	new_splat_b.resize(w * h * 4)
	new_road.resize(w * h * 4)
	new_nav_mask.resize(w * h)
	# `to_byte_array()` on a 1-elem PackedFloat32Array gives the f32
	# bit pattern as 4 LE bytes; `decode_u32(0)` yields the encoded
	# control word. Reused per-pixel via this mutable buffer.
	var f_buf := PackedFloat32Array()
	f_buf.resize(1)
	var nan_control_count := 0
	var nav_block_count := 0
	var nav_walkable_count := 0
	for pz in h:
		for px in w:
			var i := pz * w + px
			var wx := -extent_x * 0.5 + float(px) * spacing_m
			var wz := -extent_z * 0.5 + float(pz) * spacing_m
			var c: Color = terrain.data.get_pixel(_T3D_TYPE_CONTROL, Vector3(wx, 0.0, wz))
			# Reconstruct per-layer u8 weights.
			var weights := PackedByteArray()
			weights.resize(11)
			var have_weights := false
			# Phase A2: also decode the nav override (slot 14 / 15)
			# from the same control word so a single Terrain3D pixel
			# can paint both a biome AND a nav override.
			var nav_byte := _NAV_MASK_DEFAULT
			if not is_nan(c.r):
				f_buf[0] = c.r
				var bits: int = f_buf.to_byte_array().decode_u32(0)
				_decode_control_weights(bits, weights)
				nav_byte = _decode_nav_override(bits)
				have_weights = true
			else:
				nan_control_count += 1
			if not have_weights:
				# Fallback: copy the existing canonical splat at this
				# pixel so unbaked edges keep their previous data.
				_copy_existing_splat_pixel(
					i, weights, existing_splat_a, existing_splat_b, existing_road)
				# Likewise carry forward the existing nav_mask byte
				# for out-of-region cells so painted overrides don't
				# get zeroed at map edges.
				if i < existing_nav_mask.size():
					nav_byte = existing_nav_mask[i]
			# Write per-channel.
			var pi := i * 4
			new_splat_a[pi + 0] = weights[_LAYER_FOREST]
			new_splat_a[pi + 1] = weights[_LAYER_GRASSLAND]
			new_splat_a[pi + 2] = weights[_LAYER_WATER]
			new_splat_a[pi + 3] = weights[_LAYER_CROPLAND]
			new_splat_b[pi + 0] = weights[_LAYER_BARE]
			new_splat_b[pi + 1] = weights[_LAYER_BUILTUP]
			new_splat_b[pi + 2] = weights[_LAYER_CLIFF]
			new_splat_b[pi + 3] = weights[_LAYER_SNOW]
			new_road[pi + 0] = weights[_LAYER_PAVED]
			new_road[pi + 1] = weights[_LAYER_UNPAVED]
			new_road[pi + 2] = weights[_LAYER_TRAIL]
			new_road[pi + 3] = 0
			new_nav_mask[i] = nav_byte
			if nav_byte == _NAV_MASK_BLOCK:
				nav_block_count += 1
			elif nav_byte == _NAV_MASK_WALKABLE:
				nav_walkable_count += 1

	# --- Auto-expand vert range if sculpting overflowed ---------------
	var orig_vert_min := vert_min
	var orig_vert_max := vert_max
	var range_changed := false
	if min_h < vert_min:
		vert_min = floorf(min_h - 5.0)
		range_changed = true
	if max_h > vert_max:
		vert_max = ceilf(max_h + 5.0)
		range_changed = true

	# --- Persist files (write through `.tmp` for crash safety) --------
	if not _write_bytes_atomic(dir + "heightmap.r32", new_height):
		return false
	if not _write_bytes_atomic(dir + "splatmap_a.rgba8", new_splat_a):
		return false
	if not _write_bytes_atomic(dir + "splatmap_b.rgba8", new_splat_b):
		return false
	if not _write_bytes_atomic(dir + "road_density.rgba8", new_road):
		return false
	if not _write_bytes_atomic(dir + "nav_mask.r8", new_nav_mask):
		return false

	# --- Recompute blake3 + rewrite terrain.toml ---------------------
	var hasher := TerrainHash.new()
	var new_blake3: String = hasher.blake3_file(dir + "heightmap.r32")
	if new_blake3.is_empty():
		push_warning("Terrain3DExporter: blake3 recompute failed; clearing digest")
	var new_nav_mask_blake3: String = hasher.blake3_file(dir + "nav_mask.r8")
	if new_nav_mask_blake3.is_empty():
		push_warning("Terrain3DExporter: nav_mask blake3 recompute failed")
	if not _rewrite_toml(toml_path, new_blake3, vert_min, vert_max, new_nav_mask_blake3):
		return false

	# --- Summary printout ---------------------------------------------
	var summary: PackedStringArray = []
	summary.append("Terrain3DExporter: synced %s (%d×%d):" % [map_id, w, h])
	summary.append("  heightmap.r32 ← f32 meters, observed range [%.2f, %.2f]"
		% [min_h, max_h])
	if range_changed:
		summary.append("  vert range expanded [%.2f, %.2f] → [%.2f, %.2f]"
			% [orig_vert_min, orig_vert_max, vert_min, vert_max])
	if nan_height_count > 0:
		summary.append("  %d height pixels were out-of-region; preserved canonical"
			% nan_height_count)
	if nan_control_count > 0:
		summary.append("  %d control pixels were out-of-region; preserved canonical"
			% nan_control_count)
	summary.append("  splatmap_a/b + road_density rewritten")
	summary.append("  nav_mask.r8 ← %d block + %d walkable cells"
		% [nav_block_count, nav_walkable_count])
	summary.append("  terrain.toml blake3 = %s" % (new_blake3 if new_blake3 != "" else "<empty>"))
	summary.append("  terrain.toml nav_mask_blake3 = %s"
		% (new_nav_mask_blake3 if new_nav_mask_blake3 != "" else "<empty>"))
	print("\n".join(summary))
	return true


# --- Control-word decode -----------------------------------------------

# Decode a Terrain3D control u32 into per-canonical-layer u8 weights.
# Bit layout (Terrain3D v1.0+):
#   bits 27-31  base_id      (5 bits, slot 0-31)
#   bits 22-26  overlay_id   (5 bits, slot 0-31)
#   bits 14-21  blend        (8 bits, 0-255)
#   bits 0-13   uv params + hole/nav/auto flags (not used here)
# Weights are populated for slots 0..10 only; variant slots 11..15 are
# bake-time decoration and don't round-trip.
static func _decode_control_weights(bits: int, out_weights: PackedByteArray) -> void:
	for k in 11:
		out_weights[k] = 0
	var base_id: int = (bits >> 27) & 0x1F
	var overlay_id: int = (bits >> 22) & 0x1F
	var blend: int = (bits >> 14) & 0xFF
	var base_is_variant := base_id >= _LAYER_VARIANT_LO and base_id < _LAYER_VARIANT_HI
	var overlay_is_variant := overlay_id >= _LAYER_VARIANT_LO and overlay_id < _LAYER_VARIANT_HI

	if base_is_variant and overlay_is_variant:
		# Both variants — no biome info to round-trip. Caller will
		# fall back to the existing canonical pixel (see
		# `_copy_existing_splat_pixel`).
		return
	if base_is_variant:
		# User painted a variant as base; treat overlay as the biome.
		if overlay_id < 11:
			out_weights[overlay_id] = 255
		return
	if overlay_is_variant:
		# Variant overlay (the common bake-time case). Drop the
		# overlay; assign full weight to the base biome.
		if base_id < 11:
			out_weights[base_id] = 255
		return

	# Standard case: both base and overlay are real biome slots.
	# Reconstruct (1 - blend, blend) split.
	if base_id < 11:
		out_weights[base_id] = 255 - blend
	if overlay_id < 11:
		# If base == overlay (rare), the previous line zeroed it; we
		# want the combined weight, so OR-add.
		var prev: int = out_weights[overlay_id]
		out_weights[overlay_id] = mini(prev + blend, 255)


# Iteration 5-13 Phase A2: decode the nav override stamped on a
# Terrain3D control word. Returns one of `_NAV_MASK_DEFAULT`,
# `_NAV_MASK_BLOCK`, `_NAV_MASK_WALKABLE`. Block wins if both slot
# 14 (block) and slot 15 (walkable) are painted on the same cell
# (safer default for AI; mirrors the merge rule documented in
# `sim-iteration-5-13-plan.md`).
static func _decode_nav_override(bits: int) -> int:
	var base_id: int = (bits >> 27) & 0x1F
	var overlay_id: int = (bits >> 22) & 0x1F
	var saw_block := (base_id == _LAYER_NAV_BLOCK) or (overlay_id == _LAYER_NAV_BLOCK)
	var saw_walkable := (base_id == _LAYER_NAV_WALKABLE) or (overlay_id == _LAYER_NAV_WALKABLE)
	if saw_block:
		return _NAV_MASK_BLOCK
	if saw_walkable:
		return _NAV_MASK_WALKABLE
	return _NAV_MASK_DEFAULT


# Fallback for pixels with no live Terrain3D data: copy whatever the
# existing canonical splat said at that index.
static func _copy_existing_splat_pixel(
		i: int, out_weights: PackedByteArray,
		existing_splat_a: PackedByteArray,
		existing_splat_b: PackedByteArray,
		existing_road: PackedByteArray) -> void:
	for k in 11:
		out_weights[k] = 0
	var pi := i * 4
	if pi + 3 < existing_splat_a.size():
		out_weights[_LAYER_FOREST] = existing_splat_a[pi + 0]
		out_weights[_LAYER_GRASSLAND] = existing_splat_a[pi + 1]
		out_weights[_LAYER_WATER] = existing_splat_a[pi + 2]
		out_weights[_LAYER_CROPLAND] = existing_splat_a[pi + 3]
	if pi + 3 < existing_splat_b.size():
		out_weights[_LAYER_BARE] = existing_splat_b[pi + 0]
		out_weights[_LAYER_BUILTUP] = existing_splat_b[pi + 1]
		out_weights[_LAYER_CLIFF] = existing_splat_b[pi + 2]
		out_weights[_LAYER_SNOW] = existing_splat_b[pi + 3]
	if pi + 3 < existing_road.size():
		out_weights[_LAYER_PAVED] = existing_road[pi + 0]
		out_weights[_LAYER_UNPAVED] = existing_road[pi + 1]
		out_weights[_LAYER_TRAIL] = existing_road[pi + 2]


# --- File I/O helpers --------------------------------------------------

static func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


# Atomic-ish write: stage `<path>.tmp`, then rename. If the editor or
# Godot crashes mid-write the canonical file isn't half-overwritten —
# the .tmp gets stranded for next time but the previous canonical
# stays intact.
static func _write_bytes_atomic(path: String, bytes: PackedByteArray) -> bool:
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_error("Terrain3DExporter: failed to open %s for writing (err=%d)"
			% [tmp_path, FileAccess.get_open_error()])
		return false
	f.store_buffer(bytes)
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp_path)
	var abs_dst := ProjectSettings.globalize_path(path)
	var err := DirAccess.rename_absolute(abs_tmp, abs_dst)
	if err != OK:
		push_error("Terrain3DExporter: failed to rename %s → %s (err=%d)"
			% [abs_tmp, abs_dst, err])
		return false
	return true


# Rewrite `terrain.toml` line-by-line, replacing only `blake3 = ...`,
# `vert_min_m = ...`, `vert_max_m = ...`, and (Iteration 5-13 Phase A2)
# `nav_mask_blake3 = ...` + `nav_mask_format_version = ...`. Other
# lines pass through byte-identical so user-edited fields (UTM origin,
# region_size_m etc.) and any inline comments survive.
#
# If the existing toml has no `nav_mask_*` lines (a pre-5-13 file),
# they're appended at the end so the next `Heightmap::load` sees the
# new mask.
static func _rewrite_toml(path: String, new_blake3: String,
		new_vert_min: float, new_vert_max: float,
		new_nav_mask_blake3: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Terrain3DExporter: failed to open %s for reading" % path)
		return false
	var text := f.get_as_text()
	f.close()
	var lines := text.split("\n", false)
	var out: PackedStringArray = []
	var saw_blake3 := false
	var saw_vert_min := false
	var saw_vert_max := false
	var saw_nav_mask_blake3 := false
	var saw_nav_mask_version := false
	for line in lines:
		var stripped := line.strip_edges(true, false)
		if stripped.begins_with("blake3") and stripped.find("=") >= 0 \
				and not stripped.begins_with("blake3_") \
				and not stripped.begins_with("features_blake3") \
				and not stripped.begins_with("nav_mask_blake3"):
			out.append(_indent_of(line) + "blake3 = \"%s\"" % new_blake3)
			saw_blake3 = true
		elif stripped.begins_with("nav_mask_blake3") and stripped.find("=") >= 0:
			out.append(_indent_of(line)
				+ "nav_mask_blake3 = \"%s\"" % new_nav_mask_blake3)
			saw_nav_mask_blake3 = true
		elif stripped.begins_with("nav_mask_format_version") and stripped.find("=") >= 0:
			out.append(_indent_of(line)
				+ "nav_mask_format_version = %d" % _NAV_MASK_FORMAT_VERSION)
			saw_nav_mask_version = true
		elif stripped.begins_with("vert_min_m") and stripped.find("=") >= 0:
			out.append(_indent_of(line) + "vert_min_m = %s" % _format_float(new_vert_min))
			saw_vert_min = true
		elif stripped.begins_with("vert_max_m") and stripped.find("=") >= 0:
			out.append(_indent_of(line) + "vert_max_m = %s" % _format_float(new_vert_max))
			saw_vert_max = true
		else:
			out.append(line)
	if not saw_blake3:
		push_error("Terrain3DExporter: %s has no `blake3 =` line" % path)
		return false
	if not saw_vert_min or not saw_vert_max:
		push_warning("Terrain3DExporter: %s missing vert_min_m/vert_max_m" % path)
	# Append nav_mask fields if missing — pre-5-13 toml files don't
	# carry them; subsequent rewrites take the rewrite branches above.
	if not saw_nav_mask_version:
		out.append("nav_mask_format_version = %d" % _NAV_MASK_FORMAT_VERSION)
	if not saw_nav_mask_blake3:
		out.append("nav_mask_blake3 = \"%s\"" % new_nav_mask_blake3)
	# Preserve the file's original trailing-newline behavior.
	var separator := "\n"
	var joined := separator.join(out)
	if text.ends_with("\n"):
		joined += "\n"
	var fw := FileAccess.open(path, FileAccess.WRITE)
	if fw == null:
		push_error("Terrain3DExporter: failed to open %s for writing" % path)
		return false
	fw.store_string(joined)
	fw.close()
	return true


# Leading whitespace of a line (for preserving indentation when rewriting).
static func _indent_of(line: String) -> String:
	var i := 0
	while i < line.length() and (line[i] == " " or line[i] == "\t"):
		i += 1
	return line.substr(0, i)


# Match the toml crate's float formatting (`1234.5` style). Python /
# Rust toml writers emit `123.0` for integers-as-floats; we do the
# same so a no-op sync produces a tiny diff.
static func _format_float(v: float) -> String:
	if v == floorf(v):
		return "%.1f" % v
	return "%g" % v


# --- Minimal TOML reader for the flat schema in our terrain.toml -----

# Supports key = value lines with `value` ∈ {int, float, "string"}.
# Same shape as terrain3d_loader._parse_terrain_toml; deduplicated to
# keep the exporter standalone.
static func _parse_terrain_toml(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var out: Dictionary = {}
	for raw_line in text.split("\n", false):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("["):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var val_str := line.substr(eq + 1).strip_edges()
		if val_str.begins_with("\""):
			out[key] = val_str.trim_prefix("\"").trim_suffix("\"")
		elif val_str.contains("."):
			out[key] = val_str.to_float()
		else:
			out[key] = int(val_str)
	return out
