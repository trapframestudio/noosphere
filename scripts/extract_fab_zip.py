#!/usr/bin/env python3
"""Extract a Fab/Megascans zip into the project asset tree.

Fab zips ship in three shapes:
  * **Plant model**: gltf + bin + Textures/<id>_<res>_<channel>.png with
    Billboard variants. Output → ``godot/assets/models/plants/<slug>/``.
  * **Texture card** (alpha-cutout for HTerrainDetailLayer billboard
    quads): textures only, with `B-O.png` (RGB+alpha) + N + ORM. Plant
    silhouettes meant to be slapped on flat planes. Output →
    ``godot/assets/textures/plants/<slug>/``.
  * **Ground tiling texture**: textures only, B + N + ORM (no alpha).
    Output → ``godot/assets/textures/terrain/<slug>/``.

The script reads the bundle's `<id>.json` metadata to find the asset's
real name (Megascans uses opaque IDs like `wdvlditia` in filenames),
optionally downsamples textures, and lays them out under a stable
slug-based directory.

Usage::

    # Extract a model bundle, downsample textures to 1K
    python scripts/extract_fab_zip.py --type model --target 1k \\
        asset_downloads/Fab/Models/lady_fern_wdvlditia_ue_mid.zip

    # Extract a ground tiling texture, downsample to 2K
    python scripts/extract_fab_zip.py --type ground --target 2k \\
        asset_downloads/Fab/forest_floor_vktfeilaw_2k_ue_mid.zip

    # Extract a plant texture card (1K plenty for billboards)
    python scripts/extract_fab_zip.py --type card --target 1k \\
        asset_downloads/Fab/uncut_grass_oeeb70_4k_ue_high.zip

The slug is derived from the zip filename (everything before the first
8-12 character random ID).
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parent.parent

ASSET_DESTS = {
    "model":  PROJECT_ROOT / "godot/assets/models/plants",
    "card":   PROJECT_ROOT / "godot/assets/textures/plants",
    "ground": PROJECT_ROOT / "godot/assets/textures/terrain/megascans",
}

RES_TIERS = {"1k": 1024, "2k": 2048, "4k": 4096, "8k": 8192}


def derive_slug(zip_path: Path) -> str:
    """Strip the trailing `_<8-12-char-id>_<res>_ue_<tier>.zip` to get a
    stable human-readable slug. Falls back to the full stem if the
    filename doesn't match the expected pattern."""
    stem = zip_path.stem  # without .zip
    # Drop common Megascans suffixes one at a time
    stem = re.sub(r"_ue_(low|mid|high|raw)$", "", stem, flags=re.I)
    stem = re.sub(r"_(\d+k)$", "", stem, flags=re.I)
    # Drop a trailing 8–14 char Megascans ID (alphanumeric, often ends in 'a' or '2')
    stem = re.sub(r"_[a-z0-9]{6,16}$", "", stem)
    return stem.lower().replace(" ", "_")


def downsample_to(img_path: Path, target_px: int) -> None:
    """Downsample in place if the image is bigger than target_px."""
    img = Image.open(img_path)
    long_edge = max(img.size)
    if long_edge <= target_px:
        return
    scale = target_px / long_edge
    new_size = (max(1, round(img.size[0] * scale)),
                max(1, round(img.size[1] * scale)))
    img.resize(new_size, Image.Resampling.LANCZOS).save(img_path, optimize=True)


def extract_model(zip_path: Path, dest: Path, target_px: int) -> None:
    """Plant/tree model: keep gltf + bin + Textures/ + standard/.

    The zip contains two glTF variants:
    - `<id>_tier_N.gltf` at the root: Unreal-specific export with UE
      material extensions. Imports into Godot but with rendering
      quirks (separate alpha-cutout chains, etc).
    - `standard/<id>_tier_N_nonUE.gltf`: standard-conformant glTF that
      Godot reads cleanly. **This is what FoliageSpecies references**
      (e.g. `ribbon_grass.tres` →
      `plants_fab/ribbon_grass/standard/tbdpec3r_tier_3_nonUE.gltf`).
    Keep both — root gltf for compatibility, standard/ for production.
    """
    with tempfile.TemporaryDirectory(prefix="fab_") as tmp:
        tmp_dir = Path(tmp)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(tmp_dir)

        dest.mkdir(parents=True, exist_ok=True)
        for f in tmp_dir.iterdir():
            if f.is_file() and f.suffix in (".gltf", ".bin", ".json"):
                shutil.copy2(f, dest / f.name)

        # standard/ — copy whole subdir so the non-UE glTF variants
        # are available for FoliageSpecies references.
        std_src = tmp_dir / "standard"
        if std_src.is_dir():
            std_dst = dest / "standard"
            std_dst.mkdir(exist_ok=True)
            for f in std_src.iterdir():
                if f.is_file():
                    shutil.copy2(f, std_dst / f.name)

        # Textures — downsample as we copy.
        tex_src = tmp_dir / "Textures"
        if tex_src.is_dir():
            tex_dst = dest / "Textures"
            tex_dst.mkdir(exist_ok=True)
            for t in tex_src.iterdir():
                if t.is_file():
                    out = tex_dst / t.name
                    shutil.copy2(t, out)
                    if t.suffix.lower() in (".png", ".jpg"):
                        downsample_to(out, target_px)


def extract_card(zip_path: Path, dest: Path, target_px: int) -> None:
    """Plant texture card: just the Textures/ folder, downsampled.
    Discard the placeholder gltf (typically a flat quad)."""
    with tempfile.TemporaryDirectory(prefix="fab_") as tmp:
        tmp_dir = Path(tmp)
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(tmp_dir)

        dest.mkdir(parents=True, exist_ok=True)
        tex_src = tmp_dir / "Textures"
        if not tex_src.is_dir():
            print(f"  no Textures/ dir in {zip_path.name}", file=sys.stderr)
            return
        for t in tex_src.iterdir():
            if t.is_file():
                out = dest / t.name
                shutil.copy2(t, out)
                if t.suffix.lower() in (".png", ".jpg"):
                    downsample_to(out, target_px)


def extract_ground(zip_path: Path, dest: Path, target_px: int) -> None:
    """Ground tiling texture: same shape as a card, no alpha needed."""
    extract_card(zip_path, dest, target_px)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("zips", nargs="+", type=Path)
    ap.add_argument(
        "--type",
        choices=["model", "card", "ground"],
        required=True,
    )
    ap.add_argument(
        "--target",
        choices=list(RES_TIERS.keys()),
        default="2k",
        help="Downsample textures to this resolution (default 2k)",
    )
    ap.add_argument(
        "--slug",
        help="Override derived slug (useful when the auto-derive misses)",
    )
    ap.add_argument(
        "--output-dir",
        type=Path,
        help="Override the type-default output directory. Useful for "
             "Fab plants which want plants_fab/ rather than plants/.",
    )
    args = ap.parse_args()

    target_px = RES_TIERS[args.target]
    base_dest = args.output_dir if args.output_dir else ASSET_DESTS[args.type]

    for z in args.zips:
        if not z.exists():
            print(f"missing: {z}", file=sys.stderr)
            continue
        slug = args.slug or derive_slug(z)
        dest = base_dest / slug
        print(f"\n=== {z.name} → {dest.relative_to(PROJECT_ROOT)} ===")
        if args.type == "model":
            extract_model(z, dest, target_px)
        elif args.type == "card":
            extract_card(z, dest, target_px)
        else:
            extract_ground(z, dest, target_px)
        # Report final size
        total = sum(p.stat().st_size for p in dest.rglob("*") if p.is_file())
        print(f"  size: {total / 1024 / 1024:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
