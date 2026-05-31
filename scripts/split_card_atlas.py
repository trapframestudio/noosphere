#!/usr/bin/env python3
"""Split a Megascans Billboard atlas PNG into N individual cards.

Megascans plant model bundles ship a `Billboard_B-O.png` flat
billboard atlas — but the atlas packs multiple variant billboards
into one image. Slapping the whole atlas on a quad shows several
silhouettes per instance, which is wrong (and visible). The atlases
don't reliably auto-detect because variants overlap, so the per-asset
counts here come from manual visual inspection.

Cards are saved as `<basename>_split_<i>.png` siblings.

Usage::

    # Apply per-asset counts from the SLUG_SPLIT_COUNTS table below
    python scripts/split_card_atlas.py godot/assets/textures/plants/

    # Force a specific count regardless of asset
    python scripts/split_card_atlas.py --splits 6 path/to/atlas.png
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image


# Per-asset variant counts — derived from manual visual inspection of
# each atlas. Update this table when adding new plant cards.
SLUG_SPLIT_COUNTS: dict[str, int] = {
    "lady_fern":        6,
    "beech_fern":       6,
    "wild_grass":       4,
    "kikuyu_grass":     4,
    "ribbon_grass":     4,
    "field_poppy":      4,
    "yellow_archangel": 4,
}
DEFAULT_SPLITS = 4


def split_atlas(path: Path, splits: int) -> int:
    img = Image.open(path)
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    w, h = img.size
    if w % splits != 0:
        print(f"  WARN: {path.name} width {w} not divisible by {splits}", file=sys.stderr)
    strip_w = w // splits
    written = 0
    stem = path.stem  # without .png
    for i in range(splits):
        x0 = i * strip_w
        crop = img.crop((x0, 0, x0 + strip_w, h))
        out = path.with_name(f"{stem}_split_{i}.png")
        crop.save(out, "PNG", optimize=True)
        written += 1
    return written


def find_atlases(target: Path) -> list[Path]:
    if target.is_file():
        return [target]
    if target.is_dir():
        return sorted(target.rglob("*Billboard_B-O.png"))
    return []


def splits_for(atlas: Path, override: int | None) -> int:
    """If --splits was passed, use that. Otherwise look up the asset
    by its containing folder name in SLUG_SPLIT_COUNTS."""
    if override is not None:
        return override
    slug = atlas.parent.name
    return SLUG_SPLIT_COUNTS.get(slug, DEFAULT_SPLITS)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument(
        "--splits", type=int, default=None,
        help="Force this many strips for every atlas; "
             "default is to look up the count in SLUG_SPLIT_COUNTS",
    )
    ap.add_argument(
        "--force", action="store_true",
        help="Overwrite existing split files",
    )
    args = ap.parse_args()

    targets: list[Path] = []
    for p in args.paths:
        targets.extend(find_atlases(p))
    if not targets:
        print("no atlases found", file=sys.stderr)
        return 2

    total = 0
    for atlas in targets:
        # Skip if already a split output to avoid recursion
        if "_split_" in atlas.name:
            continue
        n_splits = splits_for(atlas, args.splits)
        first_split = atlas.with_name(f"{atlas.stem}_split_0.png")
        if first_split.exists() and not args.force:
            print(f"  skip (exists): {atlas.name}")
            continue
        n = split_atlas(atlas, n_splits)
        print(f"  {atlas.name} → {n} strips ({atlas.parent.name})")
        total += n
    print(f"wrote {total} split file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
