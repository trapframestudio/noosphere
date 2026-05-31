# PhysicsSetup

`class PhysicsSetup extends RefCounted`

Runtime trimesh collision shape builder for static props. Populates
empty `CollisionShape3D` children of a static prop with trimesh
shapes built from sibling `MeshInstance3D` meshes. Caches per-mesh
across the process, so spawning 100 instances of the same prop
builds each shape once.

Stateless except for the process-wide cache - any node can
instantiate one as needed.

**Source:** `crates/simn-godot/src/physics_setup.rs`

---

## Methods

### `func attach_static_collision(model: Node) -> int`

Walk `model`'s `CollisionShape3D` descendants; for each empty one,
find a sibling `MeshInstance3D`, build a trimesh
`ConcavePolygonShape3D` from its mesh, and install it.

| Arg | Type | Notes |
|---|---|---|
| `model` | `Node` | Typically a `StaticBody3D` root with mixed `MeshInstance3D` + empty `CollisionShape3D` children. |

**Returns:** `int` - number of collision shapes populated this
call. `0` means either every shape was already populated or no
candidates were found.

**Example (GDScript):**
```gdscript
var setup := PhysicsSetup.new()
var count := setup.attach_static_collision(prop_root)
print("attached %d collision shapes" % count)
```

### `func clear_cache() -> void`

Clear the process-wide shape cache. Useful when hot-reloading
`.glb` assets mid-session; otherwise the old mesh's cached shape
keeps being reused.
