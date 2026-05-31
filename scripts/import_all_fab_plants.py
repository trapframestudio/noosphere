#!/usr/bin/env python3
"""Batch-extract every Fab/Megascans plant model under
``asset_downloads/Fab/Models/`` into ``godot/assets/models/plants_fab/``.

Convention:
- Plant LOD: extract from ``*_ue_low.zip`` (tier 3 mesh + 1 K textures).
  Lowest poly count + smallest textures, ideal for ground-cover scatter
  where instance counts dominate frame time.
- Trees / large shrubs: extract from ``*_ue_mid.zip`` (tier 2 mesh + 2 K
  textures) — the player gets close, more polys + bigger textures
  read better. The "tree" / "shrub" prefix list below is the trigger.

Idempotent: skips slugs whose ``plants_fab/<slug>/`` directory already
exists. Safe to re-run after adding new zips to the downloads folder.

Usage::

    python3 scripts/import_all_fab_plants.py
        # Extracts every unimported plant. Reports a summary.

    python3 scripts/import_all_fab_plants.py --dry-run
        # Print what would happen without touching disk.

    python3 scripts/import_all_fab_plants.py --force
        # Re-extract even if the slug folder already exists. Useful
        # after upstream zip changes.

USD-format trees (``tree_*_usd.zip``, ``shrub_*_usd.zip``) are skipped —
they need a Blender pipeline to convert to glTF and that's a separate
job. This script handles UE/glTF zips only.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
FAB_MODELS = PROJECT_ROOT / "asset_downloads" / "Fab" / "Models"
PLANTS_FAB_DIR = PROJECT_ROOT / "godot" / "assets" / "models" / "plants_fab"
EXTRACT_SCRIPT = PROJECT_ROOT / "scripts" / "extract_fab_zip.py"

# Slug substrings that get bumped to mid-LOD + 2K textures rather
# than the default low-LOD + 1K. Currently empty — perf testing
# (2026-04-28) showed bushes at tier_2 (mid LOD) tanked frame rate
# below 20 fps when scattered at biome density. Tier_3 plus 1K is
# the sweet spot for ground-cover scatter where instance counts
# dominate. Re-add specific slugs here when an asset clearly needs
# more polys / detail (hero shrubs in close cinematic shots).
BIG_PLANT_KEYWORDS: tuple[str, ...] = ()


def derive_slug(zip_path: Path) -> str:
    """Mirror of `extract_fab_zip.derive_slug` — kept here so we can
    decide before invoking the extractor whether the slug's already on
    disk."""
    stem = zip_path.stem
    stem = re.sub(r"_ue_(low|mid|high|raw)$", "", stem, flags=re.I)
    stem = re.sub(r"_(\d+k)$", "", stem, flags=re.I)
    stem = re.sub(r"_[a-z0-9]{6,16}$", "", stem)
    return stem.lower().replace(" ", "_")


def is_big_plant(slug: str) -> bool:
    return any(kw in slug for kw in BIG_PLANT_KEYWORDS)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Print actions without invoking the extractor.",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Re-extract even if the slug folder already exists.",
    )
    args = ap.parse_args()

    if not FAB_MODELS.exists():
        print(f"missing: {FAB_MODELS}", file=sys.stderr)
        return 1

    # We pick low.zip for plants (1K), mid.zip for big plants (2K).
    # high.zip (4K, tier_1) is overkill for game use and ignored.
    candidates: list[tuple[Path, str, str]] = []  # (zip_path, slug, tier)
    skipped_existing: list[str] = []
    skipped_usd: list[str] = []

    for zip_path in sorted(FAB_MODELS.glob("*.zip")):
        name = zip_path.name
        # USD trees/shrubs need a different pipeline.
        if name.endswith("_usd.zip"):
            skipped_usd.append(name)
            continue
        slug = derive_slug(zip_path)
        big = is_big_plant(slug)
        # Take low for plants, mid for big plants. Skip non-matching
        # tiers so we don't double-process.
        wanted_tier = "_ue_mid" if big else "_ue_low"
        if wanted_tier not in name:
            continue
        target = "2k" if big else "1k"
        candidates.append((zip_path, slug, target))

    if not candidates:
        print("no candidate zips found")
        return 0

    print(f"found {len(candidates)} candidate plant zip(s)")
    if skipped_usd:
        print(f"  ({len(skipped_usd)} USD zip(s) skipped — use Blender pipeline)")

    n_extracted = 0
    n_skipped = 0
    for zip_path, slug, target in candidates:
        dest = PLANTS_FAB_DIR / slug
        if dest.exists() and not args.force:
            skipped_existing.append(slug)
            n_skipped += 1
            continue
        cmd = [
            sys.executable,
            str(EXTRACT_SCRIPT),
            "--type", "model",
            "--target", target,
            "--output-dir", str(PLANTS_FAB_DIR),
            "--slug", slug,
            str(zip_path),
        ]
        print(f"\n→ {slug} ({target})")
        if args.dry_run:
            print(f"  would run: {' '.join(cmd)}")
            continue
        result = subprocess.run(cmd, check=False)
        if result.returncode != 0:
            print(f"  ! extraction failed for {slug} (exit {result.returncode})")
            continue
        n_extracted += 1

    print()
    print(f"=== summary ===")
    print(f"  extracted: {n_extracted}")
    print(f"  skipped (already present): {n_skipped}")
    if skipped_existing:
        print(f"    {', '.join(skipped_existing[:8])}"
              + ("..." if len(skipped_existing) > 8 else ""))
    if skipped_usd:
        print(f"  skipped (USD format, needs Blender): {len(skipped_usd)}")
        print(f"    {', '.join(s.replace('.zip', '') for s in skipped_usd[:6])}"
              + ("..." if len(skipped_usd) > 6 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
