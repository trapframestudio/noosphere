#!/usr/bin/env python3
"""Derive per-species `albedo_modulation` defaults for foliage species.

For each `FoliageSpecies` `.tres` under `godot/resources/foliage/species/`,
this script:

1. Looks up which biome `.tres` files reference it.
2. For each referenced biome, finds the matching terrain texture(s) the
   biome would visually overlap with (per the loader's slot mapping).
3. Computes the mean colour of those textures.
4. Weighted-averages biome colours by per-species density (when set in
   `species_densities`) — species shared across biomes get a blend.
5. Luminance-normalizes the result to mean ~1.0 brightness so applying
   it as `ALBEDO *= modulation` *shifts hue* without darkening.
6. Rewrites the `albedo_modulation = Color(...)` line in each species
   `.tres`.

Usage:
    python3 scripts/derive_foliage_modulation.py
        # Updates all species .tres files in place.

    python3 scripts/derive_foliage_modulation.py --dry-run
        # Print the derived values without writing.

The output values are *defaults* — hand-tune per species in the
inspector if a particular plant should pull more / less toward its
biome palette.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image
import numpy as np


REPO_ROOT = Path(__file__).resolve().parent.parent
SPECIES_DIR = REPO_ROOT / "godot" / "resources" / "foliage" / "species"
BIOMES_DIR = REPO_ROOT / "godot" / "resources" / "foliage" / "biomes"
PACKED_DIR = REPO_ROOT / "godot" / "assets" / "textures" / "terrain" / "_terrain3d_packed"


# Biome name → list of slot folder names whose albedo_ht.png we sample.
# The slot folders mirror `terrain3d_assets_pnw.tres`. Biomes with multi-
# slot variants (cliff, road) are intentionally narrowed to the slots
# that read most as "the ground beneath foliage" — variant overlays
# (rocky_steppe, mossy_rock) are skipped because foliage doesn't grow
# on them visibly.
BIOME_SLOTS = {
    # forest biome — forest_floor base, with brown_mud_02 nearby
    "forest": ["forest_floor"],
    "grassland": ["wild_grass"],
    "cropland": ["brown_mud_02"],
    "bare": ["ground073"],
    "road": ["mossy_rocky_ground", "trenches_dirt_fine"],  # trail / unpaved
}

# Biomes whose ground colour should NOT influence species modulation.
# These biomes still scatter foliage, but the underlying texture (asphalt,
# packed dirt, gravel) doesn't read as a natural plant habitat — tinting
# foliage toward those colours just dirties the plants. Species that
# grow ONLY in an excluded biome get the default identity modulation;
# species shared across excluded + non-excluded biomes are weighted by
# the non-excluded biomes alone.
EXCLUDED_BIOMES = {"road"}

# Species that should keep their asset's native colour rather than
# being tinted toward the biome floor. Trees + tall shrubs read as
# distinct objects against the ground (not a continuous canopy with
# the terrain), so dragging them toward the brown forest floor
# strips the natural green from needles/leaves and makes them look
# dead. Match by substring; matched species get identity modulation
# (Color(1, 1, 1, 1)).
EXCLUDED_SPECIES_KEYWORDS = (
    "sapling", "_tree", "tree_", "stump", "trunk",
    "elderberry", "raspberry",
)


def texture_mean_color(slot_name: str) -> np.ndarray | None:
    """Return mean RGB (0..1) of a terrain slot's albedo+height PNG.

    None if the file isn't there. The alpha channel of the packed PNGs
    is height — ignored.
    """
    path = PACKED_DIR / slot_name / f"{slot_name}_alb_ht.png"
    if not path.exists():
        print(f"  ! missing texture: {path}", file=sys.stderr)
        return None
    img = Image.open(path).convert("RGB")
    arr = np.asarray(img, dtype=np.float32) / 255.0
    return arr.reshape(-1, 3).mean(axis=0)


def luminance(rgb: np.ndarray) -> float:
    """Rec. 709 luminance."""
    return float(np.dot(rgb, np.array([0.2126, 0.7152, 0.0722])))


def parse_biome_tres(path: Path) -> tuple[str, list[tuple[str, float]]]:
    """Return (biome_key, [(species_filename, density)]).

    The biome key matches a key in BIOME_SLOTS. Density list is
    index-aligned with `species_paths` from the .tres.
    """
    text = path.read_text()
    biome_key = path.stem  # forest, grassland, ...
    # Pull species_paths array
    paths_match = re.search(
        r"species_paths\s*=\s*Array\[String\]\(\[([^\]]+)\]\)",
        text, re.S)
    if not paths_match:
        return biome_key, []
    raw_paths = paths_match.group(1)
    # findall, not per-line search — Godot collapses the species_paths
    # array onto a single line after editing the biome resource in
    # the inspector, so a per-line `re.search` only catches the first
    # path. findall handles either layout.
    species_filenames = re.findall(
        r'"res://resources/foliage/species/([^"]+)\.tres"',
        raw_paths,
    )
    # Pull species_densities (optional)
    dens_match = re.search(
        r"species_densities\s*=\s*PackedFloat32Array\(([^)]*)\)", text)
    densities = []
    if dens_match:
        nums = re.findall(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?",
                          dens_match.group(1))
        densities = [float(n) for n in nums]
    # Pad with default 1.0 when species_densities is shorter / absent.
    while len(densities) < len(species_filenames):
        densities.append(1.0)
    return biome_key, list(zip(species_filenames, densities))


def derive_modulation(species_filename: str,
                      species_in_biomes: dict[str, float],
                      biome_mean_colors: dict[str, np.ndarray],
                      strength: float) -> np.ndarray:
    """Compute the per-species albedo modulation.

    `species_in_biomes` maps biome_key → total density across all biomes.
    The result is a luminance-normalized hue shift toward the
    weighted-mean biome colour, blended with white by `strength`.

    `strength` controls how much of the normalized biome hue is mixed
    in (0.0 = no-op identity, 1.0 = full normalized hue, >1.0 = push
    past the biome hue — useful when foliage textures are already
    heavily tinted in the biome direction and you want to over-correct).
    """
    weighted = np.zeros(3, dtype=np.float32)
    total_w = 0.0
    for biome_key, density in species_in_biomes.items():
        if biome_key in EXCLUDED_BIOMES:
            continue
        color = biome_mean_colors.get(biome_key)
        if color is None or density <= 0.0:
            continue
        weighted += color * density
        total_w += density
    if total_w <= 0.0:
        return np.array([1.0, 1.0, 1.0], dtype=np.float32)
    avg_color = weighted / total_w
    # Luminance-normalize so the modulation has Rec.709 luminance 1.0
    # — preserves the species's brightness while shifting hue.
    lum = luminance(avg_color)
    if lum <= 0.001:
        return np.array([1.0, 1.0, 1.0], dtype=np.float32)
    normalized = avg_color / lum
    # Mix toward `normalized` by `strength`. strength=0 → identity (1,1,1),
    # strength=1 → pure normalized hue.
    softened = ((1.0 - strength) * np.array([1.0, 1.0, 1.0])
                + strength * normalized)
    return softened.astype(np.float32)


def update_species_tres(path: Path,
                        modulation: np.ndarray,
                        dry_run: bool) -> bool:
    """Rewrite the `albedo_modulation = Color(...)` line in a species .tres.

    Returns True if the file was changed (or would be in dry-run).
    """
    text = path.read_text()
    new_line = (f"albedo_modulation = Color"
                f"({modulation[0]:.4f}, {modulation[1]:.4f}, "
                f"{modulation[2]:.4f}, 1)")
    pattern = re.compile(r"^albedo_modulation\s*=\s*Color\([^)]+\)\s*$",
                         re.M)
    if pattern.search(text):
        new_text = pattern.sub(new_line, text)
    else:
        # Insert after the last existing field in the [resource] block.
        # Falls between `mesh_scene_path` and the closing — append to end.
        if not text.endswith("\n"):
            text += "\n"
        new_text = text + new_line + "\n"
    if new_text == text:
        return False
    if not dry_run:
        path.write_text(new_text)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="Print derived modulation values without writing.")
    parser.add_argument("--strength", type=float, default=1.0,
                        help="Hue-shift strength. 0=no-op, 1=full normalized "
                             "biome hue (default), >1=overshoot.")
    args = parser.parse_args()

    # Step 1: compute mean colour per biome (from terrain slot textures).
    print("Sampling terrain textures...")
    biome_mean_colors: dict[str, np.ndarray] = {}
    for biome_key, slot_names in BIOME_SLOTS.items():
        colors = []
        for slot in slot_names:
            c = texture_mean_color(slot)
            if c is not None:
                colors.append(c)
        if colors:
            mean = np.mean(np.stack(colors, axis=0), axis=0)
            biome_mean_colors[biome_key] = mean
            print(f"  {biome_key:<10} from {slot_names} → "
                  f"({mean[0]:.3f}, {mean[1]:.3f}, {mean[2]:.3f})")
        else:
            print(f"  ! no textures found for biome {biome_key}",
                  file=sys.stderr)

    # Step 2: walk biome .tres files to map species → biomes.
    print("\nMapping species to biomes...")
    species_to_biomes: dict[str, dict[str, float]] = {}
    for biome_path in sorted(BIOMES_DIR.glob("*.tres")):
        biome_key, species_list = parse_biome_tres(biome_path)
        if biome_key not in BIOME_SLOTS:
            print(f"  ! unknown biome key: {biome_key}", file=sys.stderr)
            continue
        for species_filename, density in species_list:
            species_to_biomes.setdefault(species_filename, {})
            species_to_biomes[species_filename][biome_key] = (
                species_to_biomes[species_filename].get(biome_key, 0.0)
                + density)

    # Step 3: derive modulation per species and update .tres.
    print("\nDeriving modulations:")
    n_changed = 0
    import numpy as _np  # local alias to avoid touching imports above
    for species_path in sorted(SPECIES_DIR.glob("*.tres")):
        species_filename = species_path.stem
        biomes = species_to_biomes.get(species_filename, {})
        if not biomes:
            print(f"  {species_filename:<22} (unused — skipped)")
            continue
        if any(kw in species_filename for kw in EXCLUDED_SPECIES_KEYWORDS):
            mod = _np.array([1.0, 1.0, 1.0], dtype=_np.float32)
            print(f"  {species_filename:<22} (tree-tier — identity)")
            if update_species_tres(species_path, mod, args.dry_run):
                n_changed += 1
            continue
        mod = derive_modulation(species_filename, biomes, biome_mean_colors,
                                args.strength)
        biomes_str = ", ".join(f"{k}:{v:.1f}" for k, v in biomes.items())
        print(f"  {species_filename:<22} ({biomes_str}) → "
              f"({mod[0]:.3f}, {mod[1]:.3f}, {mod[2]:.3f})")
        if update_species_tres(species_path, mod, args.dry_run):
            n_changed += 1

    if args.dry_run:
        print(f"\nDry run — would update {n_changed} species .tres files.")
    else:
        print(f"\nUpdated {n_changed} species .tres files.")
        print("Reopen the editor (or hit Rebuild tiles) to apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
