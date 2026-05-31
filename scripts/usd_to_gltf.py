#!/usr/bin/env python3
"""Convert Fab USD tree/shrub zips to glTF via Blender.

Fab's USD-format zips (``tree_*_usd.zip``, ``shrub_*_usd.zip``) ship
each variant as a standalone ``.usd`` crate plus an optional
``_Foliage.usd`` and per-variant ``_DynamicWind.json``. They contain
mesh + material data but their textures usually live external — UE
expected to resolve them from the project. Without those textures
the imported model is geometry-only with placeholder material slots.

For our needs that's still useful: the **trunk geometry** + branch
silhouette of a real Fab tree dropped into the foliage scatter is a
massive upgrade over PolyHaven plant cards or the Megascans
billboard impostors. Materials get filled in by hand later.

This script:
  1. Extracts a Fab USD zip into a temp dir
  2. For each ``Tree_*_Version_*.usd`` (variants), invokes Blender
     headless to import the USD and export glTF
  3. Drops the converted glTFs under
     ``godot/assets/models/plants_fab/<slug>/`` mirroring the same
     layout the UE-format zips end up in (``standard/<id>_tier_3_nonUE.gltf``
     equivalent — we use ``Version_<X>.gltf`` since USD doesn't
     have the tier nomenclature)
  4. ``_Foliage.usd`` is a per-tree shared foliage atlas and is
     imported into ``foliage.gltf`` per slug

Usage::

    python3 scripts/usd_to_gltf.py asset_downloads/Fab/Models/tree_baltic_pine_saplings_01.zip
    python3 scripts/usd_to_gltf.py --all
    python3 scripts/usd_to_gltf.py --all --dry-run

Requires Blender 3.0+ with the USD importer (built-in since 3.0).
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from textwrap import dedent

PROJECT_ROOT = Path(__file__).resolve().parent.parent
FAB_MODELS = PROJECT_ROOT / "asset_downloads" / "Fab" / "Models"
PLANTS_FAB_DIR = PROJECT_ROOT / "godot" / "assets" / "models" / "plants_fab"
BLENDER = shutil.which("blender") or "/usr/bin/blender"


def derive_slug(zip_path: Path) -> str:
    """Mirror of `extract_fab_zip.derive_slug` for USD zips. Drops
    `_usd` suffix + the optional date stamp."""
    stem = zip_path.stem
    stem = re.sub(r"_usd$", "", stem, flags=re.I)
    stem = re.sub(r"_\d{2,4}$", "", stem)
    return stem.lower().replace(" ", "_")


# Inline Blender script. Imports a single USD, exports glTF, exits.
# Blender's `--python-expr` can take a one-shot string — we pass the
# whole script via `--python-text` would require a file, so use
# `--python-expr` with a here-string for cleanliness.
BLENDER_SCRIPT = dedent("""
    import bpy, sys, math
    args = sys.argv[sys.argv.index('--') + 1:]
    src_usd, dst_gltf = args
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=src_usd)

    # Fab USDs use UE conventions: Z-up + cm-units. Blender's USD
    # importer preserves whatever 'upAxis' metadata says (Y or Z),
    # but the per-instancer transforms inside Tree_*_Foliage.usd
    # carry their own rotations that the glTF Y-up flag doesn't
    # apply to. Force the whole import flat onto a single empty,
    # rotate -90° around X to convert Z-up → Y-up at the model
    # level, then apply transforms before export so glTF gets it
    # in canonical Y-up orientation regardless of the USD layer
    # this came from.
    if bpy.context.scene.objects:
        # Make every imported object a child of a single empty so
        # one rotation flips the whole tree.
        bpy.ops.object.select_all(action='SELECT')
        bpy.ops.object.empty_add(type='PLAIN_AXES', location=(0, 0, 0))
        root = bpy.context.active_object
        for obj in bpy.context.scene.objects:
            if obj is root:
                continue
            if obj.parent is None:
                obj.parent = root
                obj.matrix_parent_inverse.identity()
        # USD Z-up → glTF Y-up: rotate -90° around X.
        root.rotation_euler = (math.radians(-90.0), 0.0, 0.0)
        # Apply so the rotation bakes into vertex data and glTF
        # doesn't need to write a node transform that Godot might
        # interpret oddly.
        bpy.ops.object.select_all(action='DESELECT')
        for obj in list(bpy.context.scene.objects):
            obj.select_set(True)
        bpy.context.view_layer.objects.active = root
        bpy.ops.object.transform_apply(
            location=False, rotation=True, scale=False)

    bpy.ops.export_scene.gltf(
        filepath=dst_gltf,
        export_format='GLTF_SEPARATE',
        export_apply=True,
        export_yup=False,  # we already rotated
    )
    print('OK')
""")


def convert_one(usd_path: Path, gltf_path: Path) -> bool:
    """Run Blender headless to convert one USD to glTF. Returns True
    on success."""
    gltf_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        BLENDER,
        "--background",
        "--factory-startup",
        "--python-expr",
        BLENDER_SCRIPT,
        "--",
        str(usd_path),
        str(gltf_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        print(f"  ! blender failed for {usd_path.name}", file=sys.stderr)
        print(result.stderr[-500:], file=sys.stderr)
        return False
    return gltf_path.exists()


def process_zip(zip_path: Path, dry_run: bool = False, force: bool = False) -> int:
    slug = derive_slug(zip_path)
    dest_dir = PLANTS_FAB_DIR / slug
    # Skip only if dir exists AND has at least one .gltf (incomplete
    # extracts shouldn't lock us out).
    if dest_dir.exists() and any(dest_dir.glob("*.gltf")) and not force:
        print(f"skip {slug} (already extracted)")
        return 0
    print(f"\n=== {slug} from {zip_path.name} ===")
    if dry_run:
        print(f"  would extract + convert into {dest_dir}")
        return 1
    n_converted = 0
    with tempfile.TemporaryDirectory(prefix="fab_usd_") as tmp:
        tmp_path = Path(tmp)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(tmp_path)
        usd_files = sorted(
            list(tmp_path.glob("*.usd")) + list(tmp_path.glob("*.USD"))
        )
        if not usd_files:
            print(f"  ! no .usd files inside {zip_path.name}", file=sys.stderr)
            return 0
        for usd in usd_files:
            # Strip leading "Tree_" / "Shrub_" prefix and suffix to a
            # short name like Version_A, Foliage, etc.
            name = re.sub(r"^(Tree_|Shrub_)?[^_]+_[^_]+_\d+_", "",
                          usd.stem, flags=re.I)
            name = name.replace(" ", "_")
            gltf = dest_dir / f"{name}.gltf"
            print(f"  → {usd.name} → {gltf.name}")
            if convert_one(usd, gltf):
                n_converted += 1
            else:
                print(f"    failed", file=sys.stderr)
    return n_converted


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("zips", nargs="*", type=Path)
    ap.add_argument("--all", action="store_true",
                    help="Process every *_usd.zip in asset_downloads/Fab/Models/")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="Re-extract even if the slug folder already has glTFs.")
    args = ap.parse_args()

    targets: list[Path]
    if args.all:
        targets = sorted(FAB_MODELS.glob("*_usd.zip"))
        # Also pick up tree_*_saplings_*.zip variants if they exist
        targets += sorted(FAB_MODELS.glob("tree_*_saplings_*.zip"))
        # Dedupe + filter to USD
        targets = sorted(set(t for t in targets if t.suffix == ".zip"))
    elif args.zips:
        targets = args.zips
    else:
        ap.error("pass zip paths or --all")
        return 2

    if not Path(BLENDER).exists():
        print(f"blender not found at {BLENDER}", file=sys.stderr)
        return 1

    n_total = 0
    for zip_path in targets:
        n_total += process_zip(zip_path, args.dry_run, args.force)
    print(f"\n=== summary: {n_total} glTF(s) produced ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
