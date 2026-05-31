#!/usr/bin/env python3
"""Generate `FoliageSpecies` `.tres` files for every Fab plant model
under ``godot/assets/models/plants_fab/`` that doesn't already have
one.

Each generated `.tres`:
- Points `mesh_scene_path` at the `standard/<id>_tier_N_nonUE.gltf`
  Godot reads cleanly (the root `.gltf` has UE-specific extensions).
- Picks tier_3 (low LOD) when present, else tier_2 (mid).
- Sets reasonable defaults (weight 1.0, scale 0.85..1.15, no
  modulation). Hand-tune in the inspector after generation.

Idempotent: skips slugs whose `<slug>.tres` already exists. Use
``--force`` to regenerate.

Usage::

    python3 scripts/generate_fab_species_tres.py
    python3 scripts/generate_fab_species_tres.py --dry-run
    python3 scripts/generate_fab_species_tres.py --force
"""

from __future__ import annotations

import argparse
import re
import sys
import uuid
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PLANTS_FAB_DIR = PROJECT_ROOT / "godot" / "assets" / "models" / "plants_fab"
SPECIES_DIR = PROJECT_ROOT / "godot" / "resources" / "foliage" / "species"


# Format mirrors the existing hand-authored species .tres files
# (e.g. wild_grass_fab.tres). The `uid://...` is the Godot resource
# UID — we generate a fresh one per file.
TEMPLATE = """[gd_resource type="Resource" script_class="FoliageSpecies" format=3 uid="uid://{uid}"]

[ext_resource type="Script" uid="uid://11aqicdismte" path="res://scripts/foliage/foliage_species.gd" id="1_script"]

[resource]
resource_name = "Species: {slug} (Fab)"
script = ExtResource("1_script")
mesh_scene_path = "{mesh_path}"
scale_min = 0.85
scale_max = 1.15
size_multiplier = 1.0
alpha_luminance_cutoff = 0.05
albedo_modulation = Color(1, 1, 1, 1)
"""


def find_standard_gltf(plant_dir: Path) -> str | None:
    """Return the `res://...` path to the best glTF for this plant.

    Two layout shapes:
    - Fab UE export (most plants): ``standard/<id>_tier_N_nonUE.gltf``
      where N is 1=high, 2=mid, 3=low. Prefer tier_3 for ground cover.
    - USD → glTF conversion (the `tree_*` and `shrub_*` slugs we
      run through `usd_to_gltf.py`): no `standard/` subdir, multiple
      Version_X.gltf or <Name>_Version_X.gltf per plant. Prefer the
      smallest one (Version_D / D for sapling-y; otherwise the
      smallest by file size). For trees the Foliage.gltf is the
      shared atlas — usually huge and not what we want as the
      visible mesh, so de-prioritize it.
    """
    std = plant_dir / "standard"
    if std.is_dir():
        for tier in (3, 2, 1):
            for gltf in std.glob(f"*_tier_{tier}_nonUE.gltf"):
                rel = gltf.relative_to(PROJECT_ROOT / "godot")
                return f"res://{rel.as_posix()}"
    # USD-converted shape: pick the smallest .gltf at the plant_dir
    # root that ISN'T `Foliage.gltf` (which is usually a huge atlas).
    candidates = [
        g for g in plant_dir.glob("*.gltf")
        if "Foliage" not in g.name and "foliage" not in g.name
    ]
    if not candidates:
        candidates = list(plant_dir.glob("*.gltf"))
    if not candidates:
        return None
    smallest = min(candidates, key=lambda g: g.stat().st_size)
    rel = smallest.relative_to(PROJECT_ROOT / "godot")
    return f"res://{rel.as_posix()}"


def godot_uid() -> str:
    """Generate a Godot-style UID. Godot's UIDs are encoded base64 of
    a hash; we just emit a short random string in the same shape.
    Godot will accept any string; collisions are vanishingly rare."""
    # 13 lower-alphanum chars to match the typical Godot UID width.
    raw = uuid.uuid4().hex
    out = re.sub(r"[^a-z0-9]", "", raw.lower())[:13]
    return out or "fallback00000"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if not PLANTS_FAB_DIR.exists():
        print(f"missing: {PLANTS_FAB_DIR}", file=sys.stderr)
        return 1

    n_written = 0
    n_skipped_existing = 0
    n_skipped_no_gltf = 0
    SPECIES_DIR.mkdir(parents=True, exist_ok=True)

    for plant_dir in sorted(PLANTS_FAB_DIR.iterdir()):
        if not plant_dir.is_dir():
            continue
        slug = plant_dir.name
        out_path = SPECIES_DIR / f"{slug}.tres"
        if out_path.exists() and not args.force:
            n_skipped_existing += 1
            continue
        mesh_path = find_standard_gltf(plant_dir)
        if mesh_path is None:
            print(f"  ! no standard/<id>_tier_N_nonUE.gltf in {slug}",
                  file=sys.stderr)
            n_skipped_no_gltf += 1
            continue
        text = TEMPLATE.format(
            uid=godot_uid(),
            slug=slug,
            mesh_path=mesh_path,
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
    if n_skipped_no_gltf:
        print(f"  skipped (no nonUE gltf): {n_skipped_no_gltf}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
