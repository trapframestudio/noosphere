@tool
class_name TreeBiomeConfig
extends Resource

## Maps a biome ID (matching the foliage scatter's enum) to a
## weighted list of tree species that scatter into that biome.
## Mirrors `BiomeSpeciesConfig` for ground cover but with tree-tier
## defaults: way lower densities, separate species pool.

## Biome enum value (0=Forest, 1=Grassland, 2=Cropland, 3=Bare,
## 4=Road). Same encoding the splatmap uses.
@export_range(0, 4, 1) var biome: int = 0

## Trees per square meter for this biome at full density. Forest is
## typically ~0.005 (5 trees per 1000 m² = sparse mature canopy);
## grassland ~0.001 (occasional grove tree); bare/road ~0.
@export_range(0.0, 0.5, 0.001) var trees_per_sq_m: float = 0.005

## Paths to TreeSpecies `.tres` files that scatter into this biome.
## Stored as paths instead of `Array[Resource]` to dodge the Godot
## 4.6.2 inspector crash on Resource swaps inside arrays — same
## workaround as `BiomeSpeciesConfig`.
@export var tree_paths: Array[String] = []

## Per-species relative density (trees per square meter). The
## scatter sums these for the biome's effective density and uses
## each as a Bernoulli weight. Length must match `tree_paths`.
@export var tree_densities: PackedFloat32Array = PackedFloat32Array()
