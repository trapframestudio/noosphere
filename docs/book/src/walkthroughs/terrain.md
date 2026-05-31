# Terrain - server-master heightmaps

## The problem we're solving

Noosphere wants handcrafted maps that look like real geography. The
Columbia River Gorge corridor is the v1 play area, so we're starting
with **real DEM data** (USGS 3DEP 1 m LIDAR, where available) as the
base shape for each 4–6 km authored map, hand-edited in Blender for
gameplay (carve chokepoints, flatten POI pads, steepen ridgelines).

But terrain isn't just a rendering problem. If the **server** computes
an NPC's line-of-sight or a bullet's trajectory using one elevation
function, and the **client** renders something even slightly different,
the whole co-op illusion falls apart - you miss shots, NPCs pathfind
into cliffs that aren't there on your screen, Y-snap kicks players
through the floor. So the server has to own elevation truth, and the
client has to read from the *exact same file with the exact same math*.

That's what `simn-terrain` is.

## The architecture

```
Real DEM  ──► Author/erode in Blender ──► canonical heightmap.r16 ──► committed asset (LFS)
                                                      │
                                      ┌───────────────┴────────────────┐
                                      ▼                                ▼
                            simn-terrain::Heightmap            Godot HeightMapShape3D
                            (server: AI, ballistics,           (client: render mesh
                             Y-snap, slope checks)              + physics collider)
                                      │                                │
                                      └──────── parity test ───────────┘
                                          (CI gate: agree to <1 mm)
```

One file per map on disk, two readers. The file is stored under
`godot/assets/terrain/<map_id>/` with a small `terrain.toml` sidecar
that carries dimensions, spacing, vertical range, UTM origin, and a
BLAKE3 checksum. The `.r16` itself is raw 16-bit grid samples - no
header, no compression, just `width × height × 2` bytes little-endian.

## Why these format choices

- **Raw R16 over PNG**: Godot's heightmap import path eats raw `.r16`
  natively, no decoder. Rust reads it with a two-line `chunks_exact(2)`.
  Trivial, deterministic, no decoder-version divergence between sides.
- **Sidecar TOML instead of embedded header**: dimensions and vertical
  range are authoring-time decisions, not runtime-computed. Keeping
  metadata in text means diffs are legible and humans can spot-check
  the numbers when something goes wrong.
- **Per-map vertical range**: a 16-bit sample spans `vert_min_m` to
  `vert_max_m`, mapped by the same formula on both sides. A 1000 m
  span gives ~1.5 cm vertical precision - plenty for gameplay. Maps
  with smaller vertical relief get proportionally more precision for
  free without changing the pipeline.
- **BLAKE3 checksum in the sidecar**: fast, cryptographically sound,
  detects any asset drift (LFS miss, manual edit, corruption) at load.
  Optional - empty string skips the check, used for ephemeral test
  fixtures.

## Sampling

Given a world-local `(x, z)` query, the sampler:

1. Divides by `spacing_m` to get fractional grid coordinates `(u, v)`.
2. Clamps to `[0, width-1] × [0, height-1]` - out-of-bounds queries
   snap to the nearest edge rather than wrapping.
3. Reads the four surrounding grid samples, bilinearly interpolates.
4. Converts the resulting u16 back to meters with
   `vert_min_m + t × (vert_max_m − vert_min_m)`.

Bilinear is the natural default. **The open question** is whether
Godot's `HeightMapShape3D` will agree with bilinear at the sub-cell
level, or whether it uses triangle interpolation (the heightfield
internally triangulates each cell into two triangles, and collision
queries return triangle-exact values). The Rust side may need to
switch from bilinear to triangle interpolation with the same diagonal
orientation Godot uses. That decision is deferred until the parity
test can drive it empirically - write both, pick the one that matches,
document the finding as a Critical Rule.

## What's in and what's not

**Landed so far:**
- `simn-terrain` crate: `Heightmap`, `TerrainMetadata`, sampler math
  (bilinear + surface normal + r16 codec), format + integrity validation
  on load, 12 tests, plus `Heightmap::from_raw` for procedural construction
- `simn-godot::TerrainNode` - `StaticBody3D` subclass that calls
  `Heightmap::load` then builds both a visual `ArrayMesh` and a
  `HeightMapShape3D` collider from the same grid; exports `map_id` and
  `auto_load`
- `generate_test_maps` example in `simn-terrain` that writes four
  synthetic test maps (ramp, hills, basin, ridge) to
  `godot/assets/terrain/test_map_{1..4}/` at 1250² samples @ 4 m spacing
- Test scenes `test_map_1.tscn` … `test_map_4.tscn` swapped from flat
  `PlaneMesh` to `TerrainNode`, each pointing at its synthetic map
- **Sim ↔ terrain integration**: `TerrainMaps` resource in `simn-sim`,
  `Sim::attach_region_terrain` snaps existing bases in a region to
  ground when terrain attaches, and the per-tick `clamp_npc_terrain_y`
  system keeps NPC Y on the surface as they walk. Regions without
  attached terrain retain the legacy flat-floor behavior.
- `SimHost::load_region_terrain(region_name, map_id)` - Godot bridge
  resolves `res://assets/terrain/<map_id>/`, calls `Heightmap::load`,
  hands the heightmap to the sim. Wired from `test_map.gd::_ready` so
  scene load → sim hookup happens automatically per region.
- **Live-Terrain3D push (preferred when Terrain3D is a sibling).**
  `SimHost::attach_region_terrain_from_packed_heights(region, w, h,
  spacing, vert_min, vert_max, PackedFloat32Array, obstacles)` takes
  the heightmap as a flat f32 buffer instead of reading the canonical
  `.r32`. `test_map.gd::_push_terrain3d_heightmap_to_sim` walks
  `Terrain3D.data.get_pixel(TYPE_HEIGHT, ..)` over `w × h` cells and
  ships the buffer through this bridge. **Why this matters:**
  `Terrain3DLoader.bake_into` is lossy in the canonical → Terrain3D
  direction — sampling at multiple XZ points on the test maps showed
  ~9–18 m height drift after import. Reading the canonical for sim
  Y-snap while the player walks on Terrain3D's surface buries
  spawns underground. The live push cuts canonical out of the
  runtime sim ↔ visible-surface contract: both consume the same
  pixel grid. The path is gated on `TerrainNode.grid_dims()` /
  `spacing_m()` being non-zero (i.e. `terrain_loaded` has fired) so
  the live push knows the sim-side grid resolution; if Terrain3D is
  absent the caller falls back to `load_region_terrain` reading the
  canonical disk path (which is what production maps using
  `real_map.gd` still do).
- **Extent convention fix (2026-04-23):** `TerrainMetadata::extent_m`
  returns `(W - 1) * spacing`, matching the mesh + collision edge-
  to-edge distance. Using `W * spacing` instead drifted sim-side
  ground sampling by half a cell and caused visible NPC-in-terrain
  clipping on steep slopes (`test_map_2`). See the matching Critical
  Rule in `CLAUDE.md`.
- **Debug-tier visuals on TerrainNode** (to be replaced by a textured
  splatmap shader later): per-vertex classifier writes one of 15
  `FeatureClass` tints into vertex color via
  `ALBEDO_FROM_VERTEX_COLOR` on a `StandardMaterial3D`.
  `CullMode::DISABLED` keeps the mesh visible from both sides until
  winding + parity are proven. Diagnostic `godot_print!` on load
  reports built vertex count, triangle count, AABB, and the observed
  Y-range vs the metadata's declared range. **Slice 3 of the 5-slice
  texturing plan has landed.** Classification is now a three-source
  stack baked into `features.r8`:
  1. **ESA WorldCover v2 (2021), base layer.** Real 10 m land-cover
     raster - Water / Forest / Shrubland / Grassland / Cropland /
     BuiltUp / Bare / Snow / Wetland / Moss - mapped 1:1 from ESA
     class bytes via `features::map_esa_worldcover_class`. See the
     `[features]` block in each bake spec under `tools/bakes/`.
  2. **Slope override, middle layer.** The baker promotes any vertex
     whose local slope exceeds the cliff threshold to
     `FeatureClass::Cliff`, overriding the ESA class so gameplay-
     relevant rock faces read visually distinct regardless of what
     the 10 m source raster classified them as.
  3. **OSM highway overlay, top layer.** When `[osm] roads = true`
     is set in the bake spec, `simn_terrain::osm` fetches OSM
     `highway=*` ways inside the map's WGS84 bbox from the Overpass
     API via `curl` (JSON response cached per-bbox alongside the
     SRTM/WorldCover cache so re-bakes reuse it). Each way is
     classified by `classify_highway` - trail classes (`path` /
     `footway` / `bridleway` / `cycleway` / `steps` / `pedestrian`)
     always resolve to `Trail`; otherwise the `surface=*` tag
     overrides the highway default, so a `residential` road tagged
     `surface=dirt` bakes as `UnpavedRoad`. Each way is projected
     back into the map's UTM frame via `wgs84_to_utm_zone_n` and
     rasterized as a distance-to-segment brush with per-class widths:
     8 m for `PavedRoad`, 5 m for `UnpavedRoad`, 2.5 m for `Trail`
     (intentionally wider than real-world carriageway so features
     read at our 2 m sampling). Precedence rules applied during
     rasterization: never paint over `Water` (bridges appear in OSM
     but "road clips through water" reads worse than "road across
     river"); `UnpavedRoad` never overrides `PavedRoad`; `Trail`
     never overrides any road.

  `build_mesh_instance` prefers `Heightmap::sample_feature(x, z)`
  whenever the map carries features, and falls back to the slice-1
  slope + elevation heuristic only when `features.r8` is absent.
  Road/trail classes render as dark asphalt / tan / lighter-tan
  vertex tints respectively via `classify_feature_color`. Slices 4–5
  layer OSM water features / flood fill and a textured splatmap
  shader on top.
- **Visual skirt around the terrain mesh:** `build_mesh_instance`
  emits a `(W+2) × (H+2)` grid where the outer ring is offset 1500 m
  outward and dropped 50 m below the adjacent edge, hiding the hard
  cliff at the map boundary when the camera looks past the playfield.
  Render-only - collision and the `HeightMapShape3D` extent are
  unchanged.
- **First real DEM-backed map: Corbett.** 5000 m E-W × 3500 m N-S
  rectangle following the Columbia Gorge corridor. Baked from NASA
  SRTM 1-arcsec source (~30 m native, bilinearly resampled to the
  canonical 2 m grid) via the `bake_corbett` example in `simn-terrain`
  - a pure-Rust pipeline that inverse-projects UTM → WGS84 (zone 10N
  is the canonical projection for the Columbia Gorge spine; endgame
  Columbia Plateau maps east of -120° use 11N) and samples the SRTM
  tile at each target vertex; no GDAL dependency.
  Elevation range 3–277 m (Columbia River valley to bluff top).
  Asset lives at `godot/assets/terrain/corbett/` (LFS), scene at
  `godot/scenes/maps/corbett.tscn` using the minimal `real_map.gd`
  (no dev-aid rulers/rings), region id `corbett` (5) in
  `RegionGraph::default_test_graph`. Until a proper region picker
  lands, a solo run named starting with "Corbett" auto-loads the
  map - `GameSession._starting_region_for_run` detects the slug.
  The next eastward map (Rooster Rock / Crown Point / Latourell) is
  reserved for map 2.

**Not landed yet (later work units):**
- Map 2 (eastward from Corbett - Crown Point / Latourell Falls)
- USGS 3DEP 1 m LIDAR upgrade (sharper detail than SRTM's ~30 m)
- Blender hand-carve authoring round-trip (chokepoints, POI pads,
  Rule-Two fault mouths)
- Parity test harness (Rust sampler vs. Godot `HeightMapShape3D` raycast)
- Player Y-snap on move (currently only NPCs and bases are clamped;
  player position is whatever the Godot character controller produces)
- Slope-aware base placement at world_seed time (currently bases place
  on a flat XZ grid then get Y-snapped, so very steep cells are valid)
- Heightmap-based LOS provider for the headless server
- Splatmap / biome blending (visuals only, not parity-sensitive)
- Chunked terrain for the 1 m full-resolution upgrade (current target
  is 2 m monolithic until gameplay proves 1 m is worth the engineering)

## Why this ordering

Each later unit depends on the Rust sampler being correct. If Unit 1
ships with bad interpolation math, every parity test and every
gameplay wiring has to chase that back up. By landing Rust-only tests
first with a synthetic fixture, we prove the math in isolation before
any scene-integration work.
