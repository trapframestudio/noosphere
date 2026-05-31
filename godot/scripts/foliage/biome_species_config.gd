@tool
class_name BiomeSpeciesConfig
extends Resource

## Biome → list of `FoliageSpecies` with relative weights.
##
## The scatter system samples the splatmap at each candidate position,
## decides which biome dominates, then picks a species from that
## biome's list weighted by `FoliageSpecies.weight`.

## Biome id matches the splatmap channel layout (canonical source: the
## `splatmap_a/b.rgba8` bake output from `simn-terrain`):
##   0 = Forest      (splat[0].r)
##   1 = Grassland   (splat[0].g)
##   2 = Cropland    (splat[0].a)
##   3 = Bare        (splat[1].r)
##
## Water (splat[0].b), BuiltUp (splat[1].g), Cliff (splat[1].b),
## Snow (splat[1].a) suppress foliage — no biome config needed.
##
## Roads (any of splat[2].r/g/b — paved/unpaved/trail) get the
## `ROAD = 4` slot. If a `BiomeSpeciesConfig` with `biome = ROAD`
## is in the scatter's config list, road pixels populate from it
## (use a low `plants_per_sq_m` for trail-side scrub). If no ROAD
## config is present, road pixels suppress foliage as before.
enum BiomeId {
	FOREST = 0,
	GRASSLAND = 1,
	CROPLAND = 2,
	BARE = 3,
	ROAD = 4,
}

@export var biome: BiomeId = BiomeId.FOREST

## Target density in **plants per square meter** for this biome —
## the master knob, the field a future in-game density slider would
## drive. A tile lying entirely in this biome ends up with roughly
## `plants_per_sq_m × tile_area × density_multiplier` instances,
## regardless of how `species_densities` is configured.
##
## The scatterer sizes per-tile candidate count off the maximum
## value across all biome configs, then Bernoulli-filters per
## candidate by `biome.plants_per_sq_m / max_plants_per_sq_m`.
##
## Set to 0 to fall back to the legacy "sum of `species_densities`
## drives total" behaviour — useful for quick prototyping when you
## want each entry to carry its absolute target instead of being a
## relative weight.
##
## Reference values:
##   Forest floor (ferns/moss):     3.0 – 5.0
##   Grassland / meadow:            4.0 – 8.0
##   Cropland (sparse weeds):       0.8 – 1.5
##   Bare ground (scrub):           0.2 – 0.6
@export_range(0.0, 12.0, 0.05) var plants_per_sq_m: float = 3.0

## Paths to `FoliageSpecies` `.tres` files placed in this biome.
##
## **Why path strings instead of `Array[FoliageSpecies]`:** Godot
## 4.6.2's inspector segfaults when swapping a Resource reference in
## an exported array (`Object was freed while a signal is being
## emitted` → `EditorInspector::_changed_callback` invalid →
## segfault). Strings avoid the bug entirely. Drag a species `.tres`
## from the FileSystem dock onto an array entry to fill the path,
## or type/paste a `res://resources/foliage/species/<name>.tres`
## reference manually. The scatter `load()`s each path once at
## first build and caches the resulting `FoliageSpecies`.
@export var species_paths: Array[String] = []

## Per-species **relative weights** in this biome, index-aligned
## with `species_paths`. Entry N is the relative weight for the
## species at `species_paths[N]`.
##
## When this array's length matches `species_paths.length` and
## `plants_per_sq_m > 0`:
##   - The biome total stays at `plants_per_sq_m` exactly — these
##     entries DO NOT sum to a density.
##   - The species RNG distribution mirrors the entry ratios —
##     a fern at 2.0 and a moss at 0.5 puts 80 % of placements on
##     fern and 20 % on moss, regardless of absolute values.
##   - You can author entries as "intuitive plants/m² targets"
##     (e.g. fern=0.8, moss=0.2) and they still work — only the
##     ratio matters.
##
## Legacy mode — when `plants_per_sq_m == 0` and this array is
## populated, the scatter uses the *sum* of these entries as the
## biome total. Use for quick prototyping; flip back to the master
## knob (set `plants_per_sq_m`) once tuned.
##
## When this array is empty (or length mismatches), per-species
## share falls back to `FoliageSpecies.weight`.
@export var species_densities: PackedFloat32Array = PackedFloat32Array()
