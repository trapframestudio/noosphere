#!/usr/bin/env python3
"""Build alpha-cutout textures for PolyHaven plant diffuses.

PolyHaven plant assets ship the diffuse as a JPG (no alpha) plus a
separate single-channel ``*_alpha_*.png`` mask that the official
plugin combines into the material. HTerrain's detail shader does
``ALPHA = col.a * COLOR.a; ALPHA_SCISSOR_THRESHOLD = 0.5`` and
expects a single RGBA texture, so we precombine the diff RGB and
the alpha mask into ``*_diff_alpha_*.png`` next to the JPG.

Two modes:
  * **Official alpha mask** — if a sibling ``*_alpha_*.png`` exists
    (PolyHaven ships one for every plant model), use it directly.
    This gives the cutout the artist intended.
  * **Luma derivation fallback** — if no alpha mask is present,
    derive one from channel-max luminance with a soft threshold.
    Useful when only the JPG is on hand. Threshold sampling on
    grass_medium_01: ~83% of pixels sit below 32/255 (background),
    so threshold=24 with a 16-step ramp gives a clean mask.

Usage::

    python scripts/generate_plant_alpha.py \\
        godot/assets/models/plants/grass_medium_01_4k.gltf \\
        godot/assets/models/plants/grass_medium_02_4k.gltf

Or pass a parent dir to process every ``*_4k.gltf`` bundle inside it::

    python scripts/generate_plant_alpha.py godot/assets/models/plants/

Existing combined PNGs are skipped unless ``--force`` is passed.
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

from PIL import Image


# PolyHaven CDN pattern for the artist-authored alpha mask. The slug
# is the bundle's folder name minus `_<res>.gltf` (e.g.
# ``grass_medium_01_4k.gltf`` → slug ``grass_medium_01``,
# resolution ``4k``).
POLYHAVEN_ALPHA_URL = (
    "https://dl.polyhaven.org/file/ph-assets/Models/png/{res}/{slug}/"
    "{slug}_alpha_{res}.png"
)


# Channel-max threshold below which a pixel is treated as background.
# Sampled grass_medium_01 diffuse: ~83% of pixels have channel-max < 32
# (the dark background) and the grass blades sit in the 32–223 range,
# so a threshold of 24 with a 16-step soft edge gives a clean cutout
# without nibbling the blade tips.
ALPHA_THRESHOLD = 24
ALPHA_RAMP_WIDTH = 16


def _alpha_from_mask(mask_path: Path, target_size: tuple[int, int]) -> Image.Image:
    """Load PolyHaven's `_alpha_*.png` mask, normalize to 8-bit `L`,
    resize to match the diffuse if needed (PolyHaven ships matching
    resolutions but we don't depend on it).
    """
    mask = Image.open(mask_path)
    if mask.mode == "I;16":
        # 16-bit grayscale → 8-bit. Pillow's `.convert("L")` from
        # `I;16` saturates anything >= 256, which on a clean alpha
        # mask collapses the full opaque half of the histogram to a
        # single 255. Take the high byte directly so the mask scales
        # smoothly across the soft edge.
        raw = mask.tobytes()
        downsampled = bytes(raw[i] for i in range(1, len(raw), 2))
        mask = Image.frombytes("L", mask.size, downsampled)
    elif mask.mode != "L":
        mask = mask.convert("L")
    if mask.size != target_size:
        mask = mask.resize(target_size, Image.Resampling.BILINEAR)
    return mask


def _alpha_from_luma(rgb: Image.Image) -> Image.Image:
    """Fallback: derive alpha from channel-max luminance with a soft
    threshold. Pillow's per-pixel Python access is slow at 4K, so
    operate on the raw bytes."""
    w, h = rgb.size
    raw = rgb.tobytes()
    alpha = bytearray(w * h)
    lo = ALPHA_THRESHOLD
    hi = ALPHA_THRESHOLD + ALPHA_RAMP_WIDTH
    span = hi - lo
    for i in range(w * h):
        r = raw[i * 3]
        g = raw[i * 3 + 1]
        b = raw[i * 3 + 2]
        m = r if r > g else g
        if b > m:
            m = b
        if m <= lo:
            alpha[i] = 0
        elif m >= hi:
            alpha[i] = 255
        else:
            alpha[i] = ((m - lo) * 255) // span
    return Image.frombytes("L", (w, h), bytes(alpha))


def build_cutout(jpg_path: Path) -> tuple[Image.Image, str]:
    """Combine `<jpg>` RGB with a sibling `*_alpha_*.<ext>` mask, or
    fall back to luma derivation. Returns the RGBA cutout and a label
    describing which path was taken."""
    rgb = Image.open(jpg_path).convert("RGB")
    # Look for a sibling alpha mask. PolyHaven names it
    # ``<slug>_alpha_<res>.png`` (no `diff_` prefix).
    mask_glob = jpg_path.parent.glob(
        jpg_path.stem.replace("_diff_", "_alpha_").rsplit("_", 1)[0] + "_*.png"
    )
    mask_path = next((p for p in mask_glob if "_alpha_" in p.name), None)
    if mask_path is not None:
        alpha = _alpha_from_mask(mask_path, rgb.size)
        source = f"polyhaven mask: {mask_path.name}"
    else:
        alpha = _alpha_from_luma(rgb)
        source = "luma derivation"
    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha)
    return rgba, source


def fetch_polyhaven_alpha(bundle_dir: Path) -> Path | None:
    """Download PolyHaven's artist-authored alpha mask for this bundle
    if it isn't already on disk. Returns the local path or None on
    failure (caller falls back to luma derivation)."""
    m = re.match(r"^(?P<slug>.+)_(?P<res>\d+k)\.gltf$", bundle_dir.name)
    if not m:
        return None
    slug = m.group("slug")
    res = m.group("res")
    out = bundle_dir / "textures" / f"{slug}_alpha_{res}.png"
    if out.exists():
        return out
    url = POLYHAVEN_ALPHA_URL.format(slug=slug, res=res)
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            if resp.status != 200:
                return None
            data = resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError):
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print(f"  fetched: {out.name} ({len(data)/1024:.0f} KB)")
    return out


def process_bundle(bundle_dir: Path, force: bool, fetch: bool) -> int:
    textures_dir = bundle_dir / "textures"
    if not textures_dir.is_dir():
        return 0
    if fetch:
        fetch_polyhaven_alpha(bundle_dir)
    written = 0
    for jpg in sorted(textures_dir.glob("*_diff_*.jpg")):
        out = jpg.with_name(jpg.stem.replace("_diff_", "_diff_alpha_") + ".png")
        if out.exists() and not force:
            print(f"  skip (exists): {out.relative_to(bundle_dir.parent)}")
            continue
        rgba, source = build_cutout(jpg)
        rgba.save(out, "PNG", optimize=True)
        print(f"  {jpg.name} -> {out.name}  [{source}]")
        written += 1
    return written


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="GLTF bundle dir(s), or a parent containing *_4k.gltf bundles",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Regenerate even if the alpha PNG already exists",
    )
    ap.add_argument(
        "--fetch",
        action="store_true",
        help="Download PolyHaven's official alpha mask from the CDN "
             "if it's not already in the bundle (no-op for already-fetched bundles)",
    )
    args = ap.parse_args()

    bundles: list[Path] = []
    for p in args.paths:
        if not p.exists():
            print(f"missing: {p}", file=sys.stderr)
            return 2
        if p.is_dir() and (p / "textures").is_dir():
            bundles.append(p)
        elif p.is_dir():
            bundles.extend(sorted(p.glob("*_4k.gltf")))
        else:
            print(f"not a bundle dir: {p}", file=sys.stderr)
            return 2

    total = 0
    for bundle in bundles:
        print(f"{bundle}")
        total += process_bundle(bundle, args.force, args.fetch)
    print(f"wrote {total} alpha PNG(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
