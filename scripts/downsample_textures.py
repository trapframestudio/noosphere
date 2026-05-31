#!/usr/bin/env python3
"""Downsample 4K/8K textures into 2K/1K variants.

Megascans / Fab assets often ship at 4K or 8K only — heavy for game
use, especially on tiling ground textures where mipmapping would
discard the extra resolution anyway. This walks a directory tree,
finds PNGs/JPGs at >= the source-resolution threshold, and writes
downsampled siblings with the new resolution suffix.

Heuristics:
  * Filename suffix `_4K`, `_8K`, `_2K` (case-insensitive) → take
    that as the source resolution.
  * Fallback to actual image dimensions if no suffix.
  * Output filename swaps the suffix (e.g. `_4K.png` → `_2K.png`).
  * Alpha is preserved when present (RGBA → RGBA).
  * Lanczos resampling for diff/ORM (sharp), bilinear for normals
    (would be ideal to re-normalize but we YAGNI it for v1; PIL's
    Lanczos on an unpacked normal map produces visible artifacts at
    edges, but it's still much closer than pre-mipmap 4K rendering
    would be on a 1080p screen).

Usage::

    python scripts/downsample_textures.py --target 2k path/to/dir
    python scripts/downsample_textures.py --target 1k --replace path/to/dir
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image


RES_TIERS = {"1k": 1024, "2k": 2048, "4k": 4096, "8k": 8192}
RES_RE = re.compile(r"_([1248]k)(?=[_.])", re.IGNORECASE)


def detect_resolution(path: Path) -> tuple[int, str | None]:
    """Return (longest-edge-pixels, suffix-tier-or-None) for a texture."""
    m = RES_RE.search(path.name)
    suffix = m.group(1).lower() if m else None
    img = Image.open(path)
    return max(img.size), suffix


def output_path(path: Path, target_tier: str, replace: bool) -> Path:
    """Pick the output filename for a downsampled variant."""
    if replace:
        # Replace in place — keep the same name, content shrinks.
        return path
    m = RES_RE.search(path.name)
    if m:
        return path.with_name(
            path.name[: m.start() + 1]
            + target_tier.upper()
            + path.name[m.end():]
        )
    # No suffix in name — append `_<tier>` before the extension.
    return path.with_name(f"{path.stem}_{target_tier.upper()}{path.suffix}")


def downsample_one(path: Path, target_px: int, target_tier: str, replace: bool) -> bool:
    """Returns True if a new file was written."""
    img = Image.open(path)
    w, h = img.size
    long_edge = max(w, h)
    if long_edge <= target_px:
        return False
    scale = target_px / long_edge
    new_size = (max(1, round(w * scale)), max(1, round(h * scale)))
    out = output_path(path, target_tier, replace)
    if out.exists() and out != path and not replace:
        return False  # already downsampled
    # Lanczos for sharp resampling. Preserves alpha.
    resampled = img.resize(new_size, Image.Resampling.LANCZOS)
    resampled.save(out, optimize=True)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="Directories or individual files to process",
    )
    ap.add_argument(
        "--target",
        choices=list(RES_TIERS.keys()),
        default="2k",
        help="Target resolution tier (default: 2k)",
    )
    ap.add_argument(
        "--replace",
        action="store_true",
        help="Replace originals in place instead of writing siblings",
    )
    args = ap.parse_args()
    target_px = RES_TIERS[args.target]

    files: list[Path] = []
    for p in args.paths:
        if p.is_dir():
            files.extend(sorted(p.rglob("*.png")))
            files.extend(sorted(p.rglob("*.jpg")))
        elif p.is_file():
            files.append(p)
        else:
            print(f"missing: {p}", file=sys.stderr)
            return 2

    written = 0
    for f in files:
        try:
            if downsample_one(f, target_px, args.target, args.replace):
                written += 1
                print(f"  {f.name} → {args.target}")
        except (OSError, Image.DecompressionBombError) as e:
            print(f"  {f.name}: SKIPPED ({e})", file=sys.stderr)

    print(f"wrote {written} downsampled file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
