# Ground Cover Foliage

Tile-based ground-cover scatter with GPU view-cone density culling.
First foliage system to actually ship since the previous attempts were
removed in PR #131; see [Foliage & Tree Scattering](../planning/foliage-plan.md)
for what came before.

Tree scattering is **out of scope here** - trees and larger plants will
get their own system with proper LOD/impostor work later. This walkthrough
covers grass, ferns, flowers, mosses, weeds: anything roughly knee-high or
shorter.

## What it does

The player carries an invisible cone of dense foliage in front of them
that thins out toward the periphery and is sparse behind. Anything
beyond a tunable radius is invisible, so per-frame draw calls scale
with view direction rather than world area.

Concretely:

- Plants are placed deterministically per square tile (default 16 m).
  The same `(tile_x, tile_z)` always produces the same plants, so an
  area you walked through once is identical when you come back.
- Each tile bakes once (when the player crosses into its active radius)
  and stays in memory until the player leaves. When the player moves
  more than `rebuild_threshold_m` (default 4 m), the active tile set
  is recomputed: tiles outside the radius are freed, new tiles are
  baked.
- Per-instance random rolls are written to the `MultiMesh` custom-data
  slot. The vertex shader reads `player_cam_pos` and `player_cam_forward`
  globals each frame, computes a density curve at each instance's world
  position, and culls the instance (collapses to a degenerate vertex)
  if its roll exceeds the local density. CPU work is O(tiles_crossed),
  not O(visible_instances).

## Density curve

In the XZ plane, for each instance:

1. Compute `dot = dot(normalize(to_instance_xz), camera_forward_xz)`.
2. `dot ≥ gc_cone_full_cos` (default cos 45° ≈ 0.707) → density 1.0.
3. `dot ≥ gc_cone_periph_cos` (default cos 110° ≈ -0.342) → linear
   ramp from `gc_density_periph` (default 0.5) at the peripheral
   boundary up to 1.0 at the front-cone boundary.
4. Beyond the peripheral boundary → `gc_density_rear` (default 0.2).

Then a per-direction radius gate:
- `radius = mix(gc_radius_rear, gc_radius_front, (dot + 1) * 0.5)`
- `dist > radius` → density forced to 0.

All eight tunables live as `[shader_globals]` in `project.godot` and
can be overridden per-scene via `RenderingServer.global_shader_parameter_set`
(this is what player-side rifle scopes will do - narrow `gc_cone_full_cos`
toward 1.0 and bump `gc_radius_front` while aiming).

## Pieces

```
godot/scripts/foliage/
  foliage_species.gd        Resource: mesh + scale range + weight per species
  biome_species_config.gd   Resource: biome id + density mul + species list
  ground_cover.gd           @tool Node3D: tile management + per-tile bake

godot/shaders/
  ground_cover_dynamic.gdshader   PBR + view-cone cull + reused wind globals

godot/assets/models/plants_1k/
  17 PolyHaven 1k-tier ground-cover gltfs (modelled geometry, JPG textures)

godot/scenes/test/
  cascade_locks_test.tscn         Demo scene: Terrain3D + Player + scatter
```

## How biome lookup works

`GroundCoverScatter` reads the canonical bake artifacts directly from
disk, by `map_id`:

```
res://assets/terrain/<map_id>/
  terrain.toml         dimensions, spacing_m, vert_min_m, vert_max_m
  heightmap.r16        u16-LE elevation, normalized
  splatmap_a.rgba8     R Forest | G Grassland | B Water | A Cropland
  splatmap_b.rgba8     R Bare   | G BuiltUp   | B Cliff | A Snow
  road_density.rgba8   R Paved  | G Unpaved   | B Trail | A unused
```

For each candidate placement, the scatterer:
1. Resolves world XZ → splatmap pixel (centered terrain, `(W-1)*spacing`
   extent - same convention the renderer uses).
2. Suppresses if water / built / cliff / snow / road weight is above
   ~30–40%.
3. Picks the dominant remaining biome (Forest/Grassland/Cropland/Bare).
4. Looks up the biome's `BiomeSpeciesConfig` and weighted-samples a
   species.
5. Bilinearly samples the heightmap for Y, applies per-instance
   scale + yaw jitter, writes the transform.

This is intentionally **decoupled from any terrain node**. The same
data files drive the renderer (Terrain3D plugin or `TerrainNode`), the
sim layer's ground sampling, and now foliage. If the terrain bake
moves to a different rendering backend, foliage doesn't care.

## Authoring

To add a species:
1. Stage the gltf bundle under `godot/assets/models/plants_1k/<slug>_1k.gltf/`
   (run `python scripts/onboard_ground_cover_1k.py <slug>` if it's in the
   user's catalog of 1k zips).
2. Create a `FoliageSpecies` resource (in the inspector or as a `.tres`
   under `godot/resources/foliage/`), assign the gltf as `mesh_scene`,
   tune `scale_min` / `scale_max` / `weight` / `size_multiplier`.
3. Add it to a `BiomeSpeciesConfig.species` list.

The test scene wires its species + biomes inline as sub-resources for
self-containment; production maps should prefer `.tres` files so the
configs are reusable across maps.

## Performance

Default tuning on a 4 km map:

- Front cone (45° half-angle, 60 m radius) ≈ 9 forward tiles × 24
  candidates × ~50% biome+density gate = ~110 visible instances.
- Periphery (45°–110°, 50 % density) ≈ another ~80 instances.
- Rear (110°–180°, 20 % density) ≈ ~30 instances.

Total ~200 visible instances per frame. PolyHaven 1k plant meshes are
1–10k polys each, so 0.5–2 M tris in the worst case - well in budget on
a mid-range GPU. Shadow casting is `OFF` per MMI (alpha cards × shadow
cascades was the dominant cost in the previous tree attempt).

## Editor preview

`GroundCoverScatter.editor_preview` (off by default) makes the scatter
run continuously inside the Godot editor: the active tile set tracks
the editor's 3D viewport camera, the same view-cone globals are
pushed each frame from the editor camera's position + forward, and
flying around with WASD/middle-mouse rebuilds tiles as you cross
boundaries.

The baked MMIs in editor mode are deliberately **not** marked as
scene members - they exist as transient runtime children only, so
saving the scene won't inflate the .tscn with placement data. Toggle
the export off to tear them down.

This means the same scatter system is what you see while authoring,
playtesting, and shipping - no separate "editor preview vs. runtime"
code paths to drift.

## Tunables (inspector)

`GroundCoverScatter`:
- `tile_size_m` - square tile edge. 16 m is a good balance of
  cull-tightness vs. rebuild churn.
- `placements_per_tile` - candidates before biome/density filtering.
- `active_radius_m` - must be ≥ `gc_radius_front` plus a half-tile.
- `rebuild_threshold_m` - player movement before recompute.
- `density_multiplier` - global multiplier. Drop to 0 to hide foliage
  for benchmarking.
- `seed` - change to re-shuffle placements deterministically.

`BiomeSpeciesConfig.density` - per-biome multiplier, applied before the
view-cone curve. Lets Bare/Cropland be visibly sparser than Forest
without touching individual species weights.

## Camera bridge

`player.gd:_push_camera_to_shader_globals` runs every physics tick and
writes:

```gdscript
RenderingServer.global_shader_parameter_set("player_cam_pos", camera.global_position)
RenderingServer.global_shader_parameter_set("player_cam_forward", -camera.global_transform.basis.z)
```

That's the entire CPU cost of view-cone modulation on the player side.

## What's next

- **Tree + sapling system** - separate scatter, octahedral impostor
  bake. Out of scope for this walkthrough; see
  [foliage-plan](../planning/foliage-plan.md) for the perf research.
- **Scope/aim integration** - temporarily narrow `gc_cone_full_cos` and
  bump `gc_radius_front` while a scoped weapon is up. Plumbed in but
  unused; weapon-side trigger is TBD.
- **Exclusion volumes** - the `Area3D`-based carve-out design from the
  removed scatterers is documented in
  [foliage exclusion memory](../../../../../home/jon/.claude/projects/-home-jon-Development-projects-noosphere/memory/project_foliage_exclusion_design.md);
  port when hand-detailing starts producing collisions.
- **Species library expansion** - current 17 species are PolyHaven 1k.
  Adding Megascans plants requires the Z-up→Y-up + base-pivot
  conversion documented in the foliage plan.
