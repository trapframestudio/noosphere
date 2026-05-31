#!/usr/bin/env python3
"""Downsample rock PBR textures from 4K AmbientCG packs to 1K / 2K variants.

The procedural rock scatter (`godot/scripts/foliage/rock_scatter.gd`) uses
three texture-resolution tiers, matched to rock physical size:

* **1k** — small rocks (Tier 0/1: pebble + ankle/knee). Rendered at < 5 m
  apparent screen size most of the time; 1024² is more than enough.
* **2k** — medium rocks (Tier 2: knee/waist boulders). Closer interaction
  range, bigger silhouette; 2048² holds detail.
* **4k** — large rocks + clusters (Tier 3: standing-cover boulders). Player
  pressed against them while in cover; full-resolution source preserved.

For the **4K tier** we point the rock species directly at the existing
``godot/assets/textures/terrain/Rock0XX_4K-PNG/`` source PNGs — no copy
needed, saves ~6 GB of duplicated LFS data. This script writes only the
1k and 2k variants into ``godot/assets/textures/rocks/Rock0XX/{1k,2k}/``.

**Channels extracted per rock**:

* ``color.png``     — RGBA albedo
* ``normal.png``    — OpenGL-tangent normal (Godot's expected convention)
* ``roughness.png`` — grayscale L

We skip ``Displacement`` (no parallax in scatter shader), ``AmbientOcclusion``
(can be packed later if needed), and ``NormalDX`` (DirectX variant; we always
use NormalGL in Godot).

**Reproducibility**: Pillow's Lanczos resampling is deterministic for the
same source bytes + same Pillow version. Re-running the script produces
byte-identical output → no diff churn for LFS. Skipping logic via mtime
check (`--force` to re-do everything).

**Run from repo root**::

    python3 scripts/downsample_rock_textures.py
    python3 scripts/downsample_rock_textures.py Rock020 Rock060  # subset
    python3 scripts/downsample_rock_textures.py --all            # all 14
    python3 scripts/downsample_rock_textures.py --force          # ignore mtime

Requires: Pillow (``pip install Pillow``).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("error: Pillow required. Install with: pip install Pillow",
          file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "godot" / "assets" / "textures" / "terrain"
OUTPUT_DIR = REPO_ROOT / "godot" / "assets" / "textures" / "rocks"

# Default curated set — six visually distinct rocks selected to back the six
# procedural shapes in `rock_pack.glb`. Override via positional args or --all.
DEFAULT_ROCKS = ("Rock020", "Rock028", "Rock035", "Rock050", "Rock060", "Rock064")

# (channel_suffix_in_source, output_filename). NormalGL → normal because the
# scatter shader assumes Godot's default OpenGL tangent-space convention.
CHANNEL_MAP = (
    ("Color", "color.png"),
    ("NormalGL", "normal.png"),
    ("Roughness", "roughness.png"),
)

VARIANTS = (("1k", 1024), ("2k", 2048))


def discover_all_rocks() -> list[str]:
    """Find every Rock0XX_4K-PNG dir in the source tree."""
    rocks: list[str] = []
    for entry in sorted(SOURCE_DIR.iterdir()):
        if entry.is_dir() and entry.name.startswith("Rock") \
                and entry.name.endswith("_4K-PNG"):
            # Strip the suffix so the user passes "Rock020", not the full dir.
            rocks.append(entry.name.removesuffix("_4K-PNG"))
    return rocks


def needs_rebuild(src: Path, dst: Path) -> bool:
    """True if dst is missing or older than src."""
    if not dst.exists():
        return True
    return src.stat().st_mtime > dst.stat().st_mtime


def downsample_one(rock_id: str, force: bool) -> int:
    """Process every channel × variant for one rock. Returns # files written."""
    src_dir = SOURCE_DIR / f"{rock_id}_4K-PNG"
    if not src_dir.is_dir():
        print(f"  skip {rock_id}: source dir not found at {src_dir}")
        return 0

    written = 0
    for channel, out_name in CHANNEL_MAP:
        src_path = src_dir / f"{rock_id}_4K-PNG_{channel}.png"
        if not src_path.is_file():
            print(f"  warn {rock_id}/{channel}: source PNG missing, skipping")
            continue

        # Lazy-load: only open the source if we need to write at least one
        # variant. Saves a bunch of decode time on cached re-runs.
        src_img: Image.Image | None = None

        for variant_name, size_px in VARIANTS:
            dst_dir = OUTPUT_DIR / rock_id / variant_name
            dst_path = dst_dir / out_name

            if not force and not needs_rebuild(src_path, dst_path):
                continue

            if src_img is None:
                src_img = Image.open(src_path)

            dst_dir.mkdir(parents=True, exist_ok=True)
            # LANCZOS is the gold standard for high-quality downscale; PIL's
            # implementation is deterministic per Pillow version. The source is
            # always 4096²; downscale to size_px² in one shot (no intermediate
            # mip levels — we let Godot generate runtime mipmaps from this).
            resized = src_img.resize((size_px, size_px), Image.Resampling.LANCZOS)
            # `optimize=True` runs an extra pass to find the best zlib settings;
            # ~5-10% smaller PNGs, slow but worth it for committed assets.
            resized.save(dst_path, format="PNG", optimize=True)
            kb = dst_path.stat().st_size // 1024
            print(f"  {rock_id}/{variant_name}/{out_name}: {kb} KB")
            written += 1

        if src_img is not None:
            src_img.close()

    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("rocks", nargs="*",
                        help="Rock IDs to process (e.g. Rock020). "
                             "Default: curated set of 6.")
    parser.add_argument("--all", action="store_true",
                        help="Process every Rock0XX_4K-PNG dir found.")
    parser.add_argument("--force", action="store_true",
                        help="Rewrite all variants even if up-to-date.")
    args = parser.parse_args()

    if args.all:
        rocks = discover_all_rocks()
    elif args.rocks:
        rocks = list(args.rocks)
    else:
        rocks = list(DEFAULT_ROCKS)

    print(f"[downsample_rock_textures] {len(rocks)} rocks → "
          f"{len(VARIANTS)} variants × {len(CHANNEL_MAP)} channels")
    print(f"[downsample_rock_textures] source: {SOURCE_DIR}")
    print(f"[downsample_rock_textures] output: {OUTPUT_DIR}")

    total_written = 0
    for rock_id in rocks:
        print(f"{rock_id}:")
        total_written += downsample_one(rock_id, args.force)

    print(f"[downsample_rock_textures] wrote {total_written} files "
          f"({len(rocks) * len(VARIANTS) * len(CHANNEL_MAP)} total slots; "
          f"others were up-to-date)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
