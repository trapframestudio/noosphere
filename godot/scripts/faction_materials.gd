class_name FactionMaterials
extends RefCounted
## Shared StandardMaterial3D cache, one per faction.
##
## Every NPC pill would otherwise allocate its own material in
## `configure()`, which balloons GPU state changes at spawn-dense
## regions. With this cache, all pills of the same faction share a
## single material resource and the renderer can batch more
## aggressively. Autoload-free singleton: just call `of("linemen")`
## from pill scripts.

static var _cache: Dictionary = {}


static func of(faction: String) -> StandardMaterial3D:
	if _cache.has(faction):
		return _cache[faction]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = FactionColors.of(faction)
	mat.roughness = 0.6
	# Hint to the renderer that this material is shared — reduces
	# redundant uniform uploads.
	mat.resource_local_to_scene = false
	_cache[faction] = mat
	return mat
