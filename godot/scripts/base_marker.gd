extends Node3D
## Visual marker for a faction-owned base.
##
## Spawned by `GameSession` from data the sim returns via
## `SimHost.bases_in_region(name)`. Mesh shape encodes `BaseKind`,
## color encodes `Faction`. A floating Label3D shows kind + faction
## text so we can read the world without a HUD yet.

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _label: Label3D = $Label


## Configure the marker from a base view dict matching the format
## SimHost.bases_in_region returns:
##   { kind: String, faction: String, pos: Vector3, health: f32, max_health: f32 }
func configure(view: Dictionary) -> void:
	var kind: String = view.get("kind", "outpost")
	var faction: String = view.get("faction", "wanderers")
	var pos: Vector3 = view.get("pos", Vector3.ZERO)

	global_position = pos
	_mesh.mesh = _mesh_for_kind(kind)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = FactionColors.of(faction)
	mat.metallic = 0.0
	mat.roughness = 0.6
	# Subtle emission so markers read at distance on a 5km plane.
	mat.emission_enabled = true
	mat.emission = mat.albedo_color * 0.4
	mat.emission_energy_multiplier = 0.6
	_mesh.material_override = mat

	_label.text = "%s\n%s" % [kind, faction]
	_label.modulate = mat.albedo_color

	# Campsites get a warm ember light + override emission so they
	# read as a neutral rest spot regardless of faction color.
	# Removed on reconfigure so previous flame nodes don't stack.
	var prev_flame := get_node_or_null("Flame")
	if prev_flame != null:
		prev_flame.queue_free()
	if kind == "campsite":
		var flame_mat := StandardMaterial3D.new()
		flame_mat.albedo_color = Color(0.55, 0.4, 0.3)
		flame_mat.emission_enabled = true
		flame_mat.emission = Color(1.0, 0.55, 0.2)
		flame_mat.emission_energy_multiplier = 1.5
		_mesh.material_override = flame_mat
		var light := OmniLight3D.new()
		light.name = "Flame"
		light.light_color = Color(1.0, 0.55, 0.2)
		light.light_energy = 2.5
		light.omni_range = 18.0
		light.position = Vector3(0, 2, 0)
		add_child(light)
		_label.modulate = Color(1.0, 0.7, 0.45)


static func _mesh_for_kind(kind: String) -> Mesh:
	# Deliberately distinct silhouettes so kind reads at a glance from
	# a distance even before the label is legible.
	match kind:
		"checkpoint":
			var m := BoxMesh.new()
			m.size = Vector3(3, 3, 3)
			return m
		"outpost":
			var m := CylinderMesh.new()
			m.height = 4.0
			m.top_radius = 1.5
			m.bottom_radius = 1.5
			return m
		"safehouse":
			var m := SphereMesh.new()
			m.radius = 1.8
			m.height = 3.6
			return m
		"headquarters":
			var m := CapsuleMesh.new()
			m.radius = 1.6
			m.height = 6.0
			return m
		"research_post":
			var m := PrismMesh.new()
			m.size = Vector3(3, 4, 3)
			return m
		"campsite":
			# Squat, wide tetrahedron silhouette — reads as a
			# stone-circle / tent cluster from a distance.
			var m := PrismMesh.new()
			m.size = Vector3(3.5, 1.5, 3.5)
			return m
		_:
			var m := BoxMesh.new()
			m.size = Vector3(3, 3, 3)
			return m
