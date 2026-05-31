#!/usr/bin/env python3
"""Stage 1k PolyHaven ground-cover bundles into the Godot project.

Companion to ``onboard_polyhaven_trees.py`` but simpler:
the user's 1k zips on Desktop are already clean PolyHaven CDN
downloads (relative ``textures/<file>`` URIs, no Blender re-export
required). We just need to:

  1. Filter the zip catalog down to *ground cover* — small plants,
     flowers, grasses, ferns, mosses. Trees, saplings, and shrubs
     are excluded; they are handled by a separate scatter system.
  2. Unzip each into ``godot/assets/models/plants_1k/<slug>_1k.gltf/``.
  3. Defensively patch any ``/tmp/.../textures/<file>`` URIs back to
     relative ``textures/<file>`` (no-op on clean zips, safety net for
     re-onboarded ones).

Usage::

    python scripts/onboard_ground_cover_1k.py
    python scripts/onboard_ground_cover_1k.py --force
    python scripts/onboard_ground_cover_1k.py --src ~/some/other/folder
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import zipfile
from pathlib import Path


SOURCE_DIR_DEFAULT = Path.home() / "Desktop" / "models-optimize" / "unoptimized"
DEST_DIR = Path("godot/assets/models/plants_1k")


# Curated ground-cover slugs (matches available 1k zips). Trees,
# saplings, shrubs (>50cm), large indoor plants, and southern-African
# species we already evaluated and rejected are excluded.
GROUND_COVER_SLUGS: list[str] = [
    "celandine_01",
    "crystalline_iceplant",
    "dandelion_01",
    "fern_02",
    "flower_empodium",
    "flower_gazania",
    "flower_heliophila",
    "flower_stinkkruid",
    "flower_ursinia",
    "grass_bermuda_01",
    "grass_medium_01",
    "grass_medium_02",
    "moss_01",
    "nettle_plant",
    "othonna_cerarioides",
    "periwinkle_plant",
    "weed_plant_02",
]


def _patch_gltf_uris(gltf_path: Path) -> None:
    """Rewrite any ``"<anything>/textures/<file>"`` URIs to
    ``"textures/<file>"``. Idempotent.

    Same defensive fix as the trees onboarder. Clean PolyHaven zips
    already have relative URIs; the rewrite is a no-op on those.
    """
    text = gltf_path.read_text()
    new = re.sub(
        r'"uri"(\s*):(\s*)"[^"]*?/textures/([^"]+)"',
        r'"uri"\1:\2"textures/\3"',
        text,
    )
    if new != text:
        gltf_path.write_text(new)
        print(f"  patched URIs in {gltf_path.name}")


def _stage_one(zip_path: Path, dest_dir: Path, force: bool) -> bool:
    if dest_dir.exists():
        if force:
            shutil.rmtree(dest_dir)
        else:
            print(f"  skip (exists): {dest_dir.name}")
            return False
    dest_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest_dir)
    # Find the .gltf manifest inside dest_dir (top-level file).
    gltfs = list(dest_dir.glob("*.gltf"))
    if len(gltfs) != 1:
        print(f"  warning: expected 1 .gltf in {dest_dir.name}, found {len(gltfs)}",
              file=sys.stderr)
    for g in gltfs:
        _patch_gltf_uris(g)
    total = sum(p.stat().st_size for p in dest_dir.rglob("*") if p.is_file())
    print(f"  staged {dest_dir.name} ({total / 1024 / 1024:.1f} MB)")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--src", type=Path, default=SOURCE_DIR_DEFAULT,
                    help="Folder of *_1k.gltf.zip bundles "
                         "(default: ~/Desktop/models-optimize/unoptimized)")
    ap.add_argument("--force", action="store_true",
                    help="Re-stage even if dest dir exists")
    ap.add_argument("slugs", nargs="*",
                    help="Subset of slugs to onboard "
                         "(default: full ground-cover list)")
    args = ap.parse_args()

    if not args.src.is_dir():
        print(f"source dir not found: {args.src}", file=sys.stderr)
        return 2

    targets = GROUND_COVER_SLUGS
    if args.slugs:
        targets = [s for s in GROUND_COVER_SLUGS if s in args.slugs]
        if not targets:
            print(f"no matching slugs in catalog: {args.slugs}", file=sys.stderr)
            return 2

    DEST_DIR.mkdir(parents=True, exist_ok=True)
    staged = 0
    missing: list[str] = []
    for slug in targets:
        zip_path = args.src / f"{slug}_1k.gltf.zip"
        if not zip_path.is_file():
            missing.append(slug)
            continue
        dest = DEST_DIR / f"{slug}_1k.gltf"
        print(f"\n=== {slug} ===")
        if _stage_one(zip_path, dest, args.force):
            staged += 1

    print(f"\nStaged {staged} bundle(s) into {DEST_DIR}")
    if missing:
        print(f"Missing zips (skipped): {', '.join(missing)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
