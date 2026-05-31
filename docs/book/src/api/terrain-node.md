# TerrainNode

`class TerrainNode extends StaticBody3D`

Loads a canonical `.r16` heightmap from
`res://assets/terrain/<map_id>/` via `simn_terrain::Heightmap::load`
and materializes it as a visual `MeshInstance3D` (ArrayMesh built
from the grid) + collision `HeightMapShape3D`.

The visual mesh is centered on the node's position, so a 5 km × 5 km
map at `(0, 0, 0)` extends `±2.5 km` on X / Z. Collision is scaled
by `spacing_m` on X / Z so the physical extent matches the visual.

**Source:** `crates/simn-godot/src/terrain.rs`

---

## Exported properties

| Name | Type | Notes |
|---|---|---|
| `map_id` | `String` | Sub-directory of `res://assets/terrain/` to load. Set in the inspector. |
| `auto_load` | `bool` | When `true`, `_ready()` calls `load_map(map_id)` automatically. |

---

## Signals

### `terrain_loaded(map_id: String)`

Emitted after a successful load. `map_id` is the id that was loaded
(useful if multiple `TerrainNode`s share a parent).

### `terrain_error(msg: String)`

Emitted when `load_map` fails (missing file, unreadable, version
mismatch). `msg` carries the underlying `anyhow::Error` chain.

---

## Methods

### `func load_map(map_id: String) -> void`

Load a named map, replacing any previous terrain (both visual mesh
and collision shape). Resolves `res://assets/terrain/<map_id>/` to
an OS path, calls `Heightmap::load`, builds the `ArrayMesh`, sizes
the `HeightMapShape3D`.

Emits `terrain_loaded(map_id)` on success or `terrain_error(msg)` on
failure.

### `func grid_dims() -> Vector2i`

Width × height of the currently loaded heightmap, in samples. Returns
`(0, 0)` before `load_map` succeeds. Used by `test_map.gd` to size
the live-Terrain3D heightmap push to `SimHost`.

### `func spacing_m() -> float`

World-local spacing between samples in meters (same value as
`TerrainMetadata::spacing_m`). Returns `0.0` before `load_map`
succeeds.
