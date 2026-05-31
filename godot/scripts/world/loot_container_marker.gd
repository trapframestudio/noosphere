@tool
class_name LootContainerMarker3D
extends Node3D

## A scene-authored loot container spawn point. Drop one in via
## **Add Node → search "LootContainerMarker3D"**, set `kind` to pick
## the container size, optionally pick a `model_variant` to swap the
## visual mesh, and the in-editor gizmo updates immediately.
##
## **Why a dedicated node instead of reusing `PoiMarker3D`'s
## `LOOT_CONTAINER` Kind?** POI markers are generic level-design
## landmarks (faction bases, nav anchors, generic POIs). Loot
## containers have extra structure — kind-driven inner grid sizes,
## model variants, and (Phase 3B+) per-kind pool tables / restock
## seeds — that doesn't belong on the generic marker. Keeping them
## separate also lets the offline-graph bake tool route them to a
## different table.
##
## **Authoring contract.**
## - Pick `kind` first; the available `model_variant` list updates
##   to whatever's defined for that kind in `_MODELS_BY_KIND` below.
## - If a variant has a `scene` path, the editor instances it as a
##   child of this node for visualization. If not (scaffold only —
##   art hasn't landed yet), the editor falls back to a wireframe
##   box sized to the kind's authored visual footprint, colored by
##   kind so it reads at a glance.
##
## **Runtime hookup (Phase 3D).** A scene walker on map_ready will
## call `get_tree().get_nodes_in_group("loot_container_markers")` and
## hand each marker's `(kind, transform, is_public)` to the sim via
## a new `SimHost.register_authored_container` bridge method (which
## resolves the kind's inner-grid from `LootContainerRegistry` and
## spawns a `WorldContainer`). Until that lands, this node is
## purely visual / data — the procedural scatter from
## `world_seed.rs::seed_loot_containers` is the only path that
## actually spawns sim entities in the current build.

## Container size / kind. Strings match the ids in
## `crates/simn-sim/data/loot_containers.toml`; drift triggers a
## configuration warning. Kind determines the inner-grid footprint
## consumed by the sim once Phase 3D wires the runtime walker.
enum Kind {
	SMALL_CRATE,    # 4×4 grid — most common loot drop.
	MEDIUM_STASH,   # 6×6 grid — uncommon stash.
	LARGE_CACHE,    # 8×10 grid — rare; story-sized payoff.
}

## How the player accesses the container's contents.
##
## - `OPENABLE` — the existing PR-4c looting flow: walk within
##   range, press `F`, the inventory panel renders the container's
##   grid alongside pockets, click to take. Same UX as scene-placed
##   crates today. Default; matches the bulk of containers.
## - `BREAKABLE` — the container must be **destroyed** first (melee
##   / firearm damage routes through whatever HP system Phase 3D
##   wires up); once HP hits zero, the contents tumble out as a
##   ground container at the same world position. No "[F] OPEN"
##   prompt while intact. Useful for ammo crates and barrels that
##   read as "smash this to loot it" in the gameplay vocabulary.
##
## Phase 3A scaffolds the field on the marker. Runtime semantics
## (damage routing, break VFX, contents transfer) land with
## **Phase 3D**'s walker pass — the marker's job today is letting
## level authors lock in their choice so the data survives into
## the runtime hookup.
enum InteractionMode {
	OPENABLE,
	BREAKABLE,
}

## Per-kind library of selectable visual models.
##
## Each kind maps to a list of `{ id: String, scene: String }` dicts.
## `id` is the variant identifier surfaced in the inspector dropdown;
## `scene` is a `res://...tscn` (or `.glb`) path that gets instanced
## as a child of this node when selected, OR an empty string when
## the variant is **scaffolded but un-arted** — the editor falls
## back to the wireframe gizmo in that case.
##
## **Scaffolding contract:** new visual variants are added by
## dropping a row into the right list. The art pipeline lands real
## scene paths later; the inspector dropdown updates automatically
## via `_get_property_list`.
const _MODELS_BY_KIND := {
	Kind.SMALL_CRATE: [
		{"id": "wooden", "scene": ""},
		{"id": "metal_ammo_can", "scene": ""},
		{"id": "tarp_pile", "scene": ""},
	],
	Kind.MEDIUM_STASH: [
		{"id": "wooden_chest", "scene": ""},
		{"id": "military_footlocker", "scene": ""},
		{"id": "duffel_bag", "scene": ""},
	],
	Kind.LARGE_CACHE: [
		{"id": "weapon_locker", "scene": ""},
		{"id": "shipping_crate", "scene": ""},
		{"id": "hidden_dig_site", "scene": ""},
	],
}

## Editor-only wireframe footprint per kind (XZ extent in meters).
## Visual hint for "this is a small crate" vs "this is a large
## cache" — does **not** affect any sim collision or lootability
## semantics, which work off the kind's inner grid alone.
const _FOOTPRINT_M := {
	Kind.SMALL_CRATE: Vector3(0.8, 0.6, 0.6),
	Kind.MEDIUM_STASH: Vector3(1.2, 0.9, 0.9),
	Kind.LARGE_CACHE: Vector3(1.8, 1.3, 1.3),
}

## Selected container kind. Setter rebuilds the editor gizmo + the
## model_variant dropdown's available options.
@export var kind: Kind = Kind.SMALL_CRATE: set = _set_kind

## Selected visual model variant for the active kind. The inspector
## shows this as a string dropdown populated from `_MODELS_BY_KIND`
## for the current `kind` (via `_get_property_list`). Empty string
## = "default / no specific variant" — the wireframe gizmo is used
## either way until art lands.
@export var model_variant: String = "": set = _set_model_variant

## How the player accesses this container's contents. See
## [`InteractionMode`] for the semantic split.
@export var interaction_mode: InteractionMode = InteractionMode.OPENABLE:
	set = _set_interaction_mode

## Public containers count toward the crafting kit-pool (workbench
## parts bins). Author sparingly — most authored loot crates are
## **rewards**, not permanent shared crafting resources. Defaults
## false for that reason.
@export var is_public: bool = false: set = _set_is_public

## Stable identifier for save / replication. Becomes the
## `container_id` the Phase 3C deterministic restock seed hashes
## against. Convention: snake_case, prefixed by map
## (`cascade_locks_outpost_crate_east`). Empty = a runtime id
## minted at spawn (only ok for placeholder placements; production
## maps should set this).
@export var container_id: String = ""

@export_group("Debug visual")
## Toggle the wireframe gizmo + variant model in the editor. Off
## in builds (the runtime spawn replaces these with the real
## `WorldContainer` entity once Phase 3D's walker lands).
@export var show_debug_visual: bool = true: set = _set_show_debug_visual

const _GROUP: StringName = &"loot_container_markers"
const _DEBUG_ALPHA: float = 0.7

var _debug_box: MeshInstance3D = null
var _debug_label: Label3D = null
var _model_instance: Node3D = null


func _enter_tree() -> void:
	add_to_group(_GROUP)
	if Engine.is_editor_hint() and show_debug_visual:
		_rebuild_debug_visual()


func _exit_tree() -> void:
	remove_from_group(_GROUP)


# --- Inspector dynamic dropdown ---------------------------------

## Append a hint-enum override for `model_variant` so the inspector
## shows a dropdown of the variants declared for the current kind.
## Re-runs after `kind` changes via `notify_property_list_changed()`.
func _get_property_list() -> Array[Dictionary]:
	var variants := _MODELS_BY_KIND.get(kind, []) as Array
	var ids: Array[String] = [""]  # empty default — "no specific variant"
	for v in variants:
		var id := String((v as Dictionary).get("id", ""))
		if not id.is_empty():
			ids.append(id)
	return [
		{
			"name": "model_variant",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": ",".join(ids),
		},
	]


# --- Setters -----------------------------------------------------

func _set_kind(v: Kind) -> void:
	var changed: bool = v != kind
	kind = v
	if changed:
		# Available model variants depend on kind, so the dropdown
		# needs to be rebuilt. Reset variant to default since the
		# old id may not exist on the new kind.
		if not _variant_exists_for_kind(model_variant, kind):
			model_variant = ""
		notify_property_list_changed()
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()
	update_configuration_warnings()


func _set_model_variant(v: String) -> void:
	model_variant = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_rebuild_debug_visual()
	update_configuration_warnings()


func _set_interaction_mode(v: InteractionMode) -> void:
	interaction_mode = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_is_public(v: bool) -> void:
	is_public = v
	if Engine.is_editor_hint() and is_inside_tree() and show_debug_visual:
		_apply_debug_appearance()
	update_configuration_warnings()


func _set_show_debug_visual(v: bool) -> void:
	show_debug_visual = v
	if v and Engine.is_editor_hint() and is_inside_tree():
		_rebuild_debug_visual()
	elif not v:
		_clear_debug_visual()


# --- Configuration warnings -------------------------------------

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not model_variant.is_empty() and not _variant_exists_for_kind(model_variant, kind):
		warnings.append(
			"model_variant '%s' is not defined for kind %s — pick a valid variant from the dropdown or clear the field."
				% [model_variant, Kind.keys()[kind]]
		)
	if container_id.strip_edges().is_empty():
		warnings.append(
			"container_id is empty — Phase 3C restock seed hashes against this id, so production placements should set a stable snake_case id (map-prefixed). A blank id is only ok for temporary placements."
		)
	if is_public:
		warnings.append(
			"is_public=true makes this container count toward the crafting kit-pool (workbench parts bins). Use sparingly — most authored loot crates are rewards, not shared crafting resources."
		)
	if interaction_mode == InteractionMode.BREAKABLE and is_public:
		warnings.append(
			"interaction_mode=BREAKABLE + is_public=true is contradictory — a destroyed container can't serve as an ongoing kit-pool surface. Either keep it OPENABLE or clear is_public."
		)
	return warnings


static func _variant_exists_for_kind(variant_id: String, k: Kind) -> bool:
	if variant_id.is_empty():
		return true
	for v in (_MODELS_BY_KIND.get(k, []) as Array):
		if String((v as Dictionary).get("id", "")) == variant_id:
			return true
	return false


# --- Debug visual ------------------------------------------------

func _rebuild_debug_visual() -> void:
	_clear_debug_visual()
	if not Engine.is_editor_hint() or not show_debug_visual:
		return
	if not is_inside_tree():
		return

	# Try to instance the selected variant's scene. If it's set + on
	# disk, that's the authoritative visual; the wireframe box stays
	# off so the editor view reads like the runtime build.
	var scene_path := _scene_path_for_variant(kind, model_variant)
	if not scene_path.is_empty() and ResourceLoader.exists(scene_path):
		var packed := load(scene_path) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Node3D
			if inst != null:
				inst.name = "_LootModel"
				add_child(inst, false, Node.INTERNAL_MODE_BACK)
				_model_instance = inst
				_build_debug_label()  # always show the kind/variant text
				return

	# No model available — fall back to the wireframe footprint
	# gizmo so authors at least see something at the placement.
	_debug_box = MeshInstance3D.new()
	_debug_box.name = "_LootDebugBox"
	var box := BoxMesh.new()
	box.size = _FOOTPRINT_M.get(kind, Vector3.ONE) as Vector3
	_debug_box.mesh = box
	add_child(_debug_box, false, Node.INTERNAL_MODE_BACK)
	_build_debug_label()
	_apply_debug_appearance()


func _build_debug_label() -> void:
	_debug_label = Label3D.new()
	_debug_label.name = "_LootDebugLabel"
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_debug_label.no_depth_test = true
	# Match NPC `StateLabel`'s world-scaling sizing — `fixed_size =
	# true` rendered the label at constant screen size so distant
	# markers stamped huge text across the viewport.
	_debug_label.fixed_size = false
	_debug_label.pixel_size = 0.004
	_debug_label.position = Vector3(
		0.0, (_FOOTPRINT_M.get(kind, Vector3.ONE) as Vector3).y + 0.5, 0.0
	)
	_debug_label.font_size = 22
	_debug_label.outline_size = 4
	_debug_label.modulate = Color(1.0, 1.0, 1.0, _DEBUG_ALPHA)
	add_child(_debug_label, false, Node.INTERNAL_MODE_BACK)
	_apply_debug_appearance()


func _clear_debug_visual() -> void:
	if _debug_box != null and is_instance_valid(_debug_box):
		_debug_box.queue_free()
	_debug_box = null
	if _debug_label != null and is_instance_valid(_debug_label):
		_debug_label.queue_free()
	_debug_label = null
	if _model_instance != null and is_instance_valid(_model_instance):
		_model_instance.queue_free()
	_model_instance = null


func _apply_debug_appearance() -> void:
	if _debug_box != null and is_instance_valid(_debug_box):
		var mat := StandardMaterial3D.new()
		var col := _color_for_kind(kind)
		# Public containers tint a touch warmer so authors notice the
		# kit-pool flag visually.
		if is_public:
			col = col.lerp(Color(1.0, 0.85, 0.35, _DEBUG_ALPHA), 0.4)
		# Breakable containers tint toward red — a visual reminder
		# that this is a "smash to loot" placement vs the default
		# "[F] open" flow.
		if interaction_mode == InteractionMode.BREAKABLE:
			col = col.lerp(Color(0.95, 0.30, 0.20, _DEBUG_ALPHA), 0.35)
		mat.albedo_color = col
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.render_priority = 10
		_debug_box.material_override = mat
	if _debug_label != null and is_instance_valid(_debug_label):
		_debug_label.text = _label_text()


static func _color_for_kind(k: Kind) -> Color:
	match k:
		Kind.SMALL_CRATE: return Color(0.55, 0.85, 0.20, _DEBUG_ALPHA)
		Kind.MEDIUM_STASH: return Color(0.30, 0.75, 0.45, _DEBUG_ALPHA)
		Kind.LARGE_CACHE: return Color(0.20, 0.55, 0.75, _DEBUG_ALPHA)
		_: return Color(0.50, 0.50, 0.50, _DEBUG_ALPHA)


func _label_text() -> String:
	var kind_str := Kind.keys()[kind] as String
	var variant_suffix := ""
	if not model_variant.is_empty():
		variant_suffix = " · %s" % model_variant
	var mode_suffix := " [break]" if interaction_mode == InteractionMode.BREAKABLE else ""
	var public_suffix := " [public]" if is_public else ""
	var id_suffix := ""
	if not container_id.is_empty():
		id_suffix = "\n%s" % container_id
	return "%s%s%s%s%s" % [kind_str, variant_suffix, mode_suffix, public_suffix, id_suffix]


# --- Public helpers (for the future runtime walker) -------------

## Lowercase TOML id for this marker's kind. Use when handing the
## kind across the gdext bridge — string ids stay stable across
## GDScript enum reorderings.
func kind_id() -> String:
	match kind:
		Kind.SMALL_CRATE: return "small_crate"
		Kind.MEDIUM_STASH: return "medium_stash"
		Kind.LARGE_CACHE: return "large_cache"
		_: return ""


## Lowercase interaction-mode id for the gdext bridge. Same
## rationale as `kind_id()`.
func interaction_mode_id() -> String:
	match interaction_mode:
		InteractionMode.OPENABLE: return "openable"
		InteractionMode.BREAKABLE: return "breakable"
		_: return "openable"


## Selected variant's scene path, or `""` if none / not configured.
## The runtime walker reads this so a future "swap variant at
## runtime" feature can hold on to the path rather than re-running
## the dropdown logic.
func scene_path_for_active_variant() -> String:
	return _scene_path_for_variant(kind, model_variant)


static func _scene_path_for_variant(k: Kind, variant_id: String) -> String:
	if variant_id.is_empty():
		return ""
	for v in (_MODELS_BY_KIND.get(k, []) as Array):
		if String((v as Dictionary).get("id", "")) == variant_id:
			return String((v as Dictionary).get("scene", ""))
	return ""
