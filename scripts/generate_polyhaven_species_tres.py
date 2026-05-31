#!/usr/bin/env python3
"""Generate `FoliageSpecies` `.tres` files for PolyHaven model assets.

Walks ``godot/assets/models/plants/<slug>_<res>.gltf/`` and writes a
species `.tres` per slug pointing at the smallest available resolution
(prefers 1K → 2K → 4K). Skips slugs whose `.tres` already exists.

Filters to "useful for ground cover" by default — saplings, shrubs,
ground-cover plants, dead trunks. Skips tiny rocks / large mature
trees / generic decoration unless ``--all`` is passed.

Usage::

    python3 scripts/generate_polyhaven_species_tres.py
    python3 scripts/generate_polyhaven_species_tres.py --dry-run
    python3 scripts/generate_polyhaven_species_tres.py --force
    python3 scripts/generate_polyhaven_species_tres.py --all  # include rocks etc.
"""

from __future__ import annotations

import argparse
import re
import sys
import uuid
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PLANTS_DIR = PROJECT_ROOT / "godot" / "assets" / "models" / "plants"
SPECIES_DIR = PROJECT_ROOT / "godot" / "resources" / "foliage" / "species"

TEMPLATE = """[gd_resource type="Resource" script_class="FoliageSpecies" format=3 uid="uid://{uid}"]

[ext_resource type="Script" uid="uid://11aqicdismte" path="res://scripts/foliage/foliage_species.gd" id="1_script"]

[resource]
resource_name = "Species: {slug} (PolyHaven)"
script = ExtResource("1_script")
mesh_scene_path = "{mesh_path}"
scale_min = {scale_min}
scale_max = {scale_max}
size_multiplier = 1.0
alpha_luminance_cutoff = 0.05
albedo_modulation = Color(1, 1, 1, 1)
"""

# Wider scale variance for tree/shrub-tier — sapling-to-mature spread.
TREE_KEYWORDS = ("sapling", "shrub", "_tree", "tree_", "stump", "trunk",
                 "roots", "root_", "wild_rooibos", "searsia", "quiver_tree",
                 "leipoldtia", "pachira", "island_tree")


def pick_gltf(slug_dir_root: str) -> tuple[str, str] | None:
    """Find the smallest-resolution glTF for `slug` and return
    (slug, mesh_path). Returns None if nothing usable."""
    # PolyHaven layout: <slug>_<res>.gltf/<slug>_<res>.gltf
    for res in ("1k", "2k", "4k"):
        candidate = PLANTS_DIR / f"{slug_dir_root}_{res}.gltf"
        if candidate.is_dir():
            inner = candidate / f"{slug_dir_root}_{res}.gltf"
            if inner.exists():
                rel = inner.relative_to(PROJECT_ROOT / "godot")
                return slug_dir_root, f"res://{rel.as_posix()}"
    return None


def is_tree_tier(slug: str) -> bool:
    return any(kw in slug for kw in TREE_KEYWORDS)


def list_polyhaven_slugs() -> set[str]:
    """Distinct base slugs in plants/ — strips trailing `_<res>.gltf`."""
    slugs: set[str] = set()
    for entry in PLANTS_DIR.iterdir():
        if not entry.is_dir():
            continue
        m = re.match(r"^(.+)_(?:1|2|4|8)k\.gltf$", entry.name)
        if m:
            slugs.add(m.group(1))
    return slugs


def godot_uid() -> str:
    raw = uuid.uuid4().hex
    return re.sub(r"[^a-z0-9]", "", raw.lower())[:13]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--all", action="store_true",
                    help="Include slugs that aren't tree/shrub-tier "
                         "(by default we only emit species for "
                         "saplings/shrubs/dead/etc.).")
    args = ap.parse_args()

    if not PLANTS_DIR.exists():
        print(f"missing: {PLANTS_DIR}", file=sys.stderr)
        return 1
    SPECIES_DIR.mkdir(parents=True, exist_ok=True)

    n_written = 0
    n_skipped_existing = 0
    n_skipped_filter = 0

    for slug in sorted(list_polyhaven_slugs()):
        if not args.all and not is_tree_tier(slug):
            n_skipped_filter += 1
            continue
        out_path = SPECIES_DIR / f"{slug}.tres"
        if out_path.exists() and not args.force:
            n_skipped_existing += 1
            continue
        picked = pick_gltf(slug)
        if picked is None:
            print(f"  ! no glTF for {slug}", file=sys.stderr)
            continue
        _, mesh_path = picked
        # Tree-tier gets wider scale variance for natural sapling/
        # mature feel.
        scale_min = 0.6 if is_tree_tier(slug) else 0.85
        scale_max = 1.6 if is_tree_tier(slug) else 1.15
        text = TEMPLATE.format(
            uid=godot_uid(),
            slug=slug,
            mesh_path=mesh_path,
            scale_min=scale_min,
            scale_max=scale_max,
        )
        if args.dry_run:
            print(f"would write: {out_path.relative_to(PROJECT_ROOT)}")
            print(f"  mesh: {mesh_path}")
        else:
            out_path.write_text(text)
            print(f"wrote: {out_path.relative_to(PROJECT_ROOT)}")
        n_written += 1

    print()
    print("=== summary ===")
    print(f"  written: {n_written}")
    print(f"  skipped (existing): {n_skipped_existing}")
    if n_skipped_filter:
        print(f"  skipped (not tree-tier; pass --all to include): {n_skipped_filter}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
