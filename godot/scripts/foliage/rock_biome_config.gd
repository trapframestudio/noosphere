@tool
class_name RockBiomeConfig
extends Resource

## Maps a biome ID (matching the foliage scatter's enum) to a
## weighted list of rock species that scatter into that biome.
## Mirrors `TreeBiomeConfig` for rocks: lower densities than ground
## cover, separate species pool, no canopy/wind concerns.

## Biome enum value (0=Forest, 1=Grassland, 2=Cropland, 3=Bare,
## 4=Road). Same encoding the splatmap uses.
@export_range(0, 4, 1) var biome: int = 0

## Total rocks per square meter for this biome at full density.
## The scatter sums per-species densities; this field is a
## convenience baseline for tuning. Reasonable values:
##   - Bare / rocky : 0.05 (one rock per ~20 m²; visibly stony)
##   - Forest       : 0.005 (occasional boulder, deer-trail rocks)
##   - Grassland    : 0.01 (small stones across field)
##   - Cropland/Road: 0 (cleared)
## Note: this is informational; per-species `cluster_strength`
## means actual placement count varies along the noise field.
@export_range(0.0, 1.0, 0.001) var rocks_per_sq_m: float = 0.01

## Paths to RockSpecies `.tres` files that scatter into this biome.
## Stored as paths instead of `Array[Resource]` to dodge the Godot
## 4.6.2 inspector crash on Resource swaps inside arrays — same
## workaround as `TreeBiomeConfig` and `BiomeSpeciesConfig`.
@export var rock_paths: Array[String] = []

## Per-species relative density (rocks per square meter). The
## scatter sums these for the biome's effective density and uses
## each as a Bernoulli weight. Length must match `rock_paths`.
##
## Mix small + large within one biome: e.g. forest = [0.004
## pebble, 0.0008 small_boulder, 0.0001 standing_boulder] gives
## a ground that reads as "a few stones, occasional boulder".
@export var rock_densities: PackedFloat32Array = PackedFloat32Array()
