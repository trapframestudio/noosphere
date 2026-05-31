#!/usr/bin/env python3
"""Mirror PolyHaven CC0 model assets (glTF) into the project's plant
asset library.

Same shape as ``fetch_polyhaven_textures.py`` but for `type=models`.
Downloads everything in selected categories (default: trees + plants
+ pine_forest collection + ground cover + flowers + grass) at the
chosen resolution, max 2K per the user's "no bigger than 2K" rule.

Output: ``godot/assets/models/plants/<slug>_<resolution>.gltf/`` —
matches the existing PolyHaven plant directory convention.

Resumable: an asset folder is skipped if its manifest already
exists and is non-empty.

Usage::

    python3 scripts/fetch_polyhaven_models.py
    python3 scripts/fetch_polyhaven_models.py --resolution 1k --limit 5  # smoke test
    python3 scripts/fetch_polyhaven_models.py --categories trees
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = PROJECT_ROOT / "godot" / "assets" / "models" / "plants"
API = "https://api.polyhaven.com"
UA = "noosphere-asset-fetcher/1.0 (+https://github.com/getboxie/noosphere)"

# Tree / plant / nature categories worth pulling for PNW foliage.
DEFAULT_CATEGORIES = (
    "trees",
    "plants",
    "ground cover",
    "flowers",
    "grass",
    "nature",
    "potted plants",
    "rocks",
    "collection: pine_forest",
    "collection: verdant_trail",
)


@dataclass
class FetchStats:
    downloaded: int = 0
    skipped: int = 0
    no_gltf: int = 0
    failed: list[tuple[str, str]] = None

    def __post_init__(self) -> None:
        if self.failed is None:
            self.failed = []


def http_json(url: str, retries: int = 3) -> dict:
    last: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
            last = e
            time.sleep(1.5 ** attempt)
    raise RuntimeError(f"GET {url}: {last}")


def http_bytes(url: str, retries: int = 3) -> bytes:
    last: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except (urllib.error.URLError, TimeoutError) as e:
            last = e
            time.sleep(1.5 ** attempt)
    raise RuntimeError(f"GET {url}: {last}")


def md5_ok(data: bytes, expected: str | None) -> bool:
    if not expected:
        return True
    return hashlib.md5(data).hexdigest().lower() == expected.lower()


def download_include(target: Path, url: str, expected_md5: str | None) -> int:
    if target.exists() and target.stat().st_size > 0:
        return 0
    blob = http_bytes(url)
    if not md5_ok(blob, expected_md5):
        raise RuntimeError(f"md5 mismatch for {url}")
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".part")
    tmp.write_bytes(blob)
    tmp.rename(target)
    return len(blob)


def fetch_asset(slug: str, out_root: Path, resolution: str,
                workers: int) -> tuple[str, int]:
    """Download one asset. Returns (status, total_bytes)."""
    folder = out_root / f"{slug}_{resolution}.gltf"
    manifest_path = folder / f"{slug}_{resolution}.gltf"

    if manifest_path.exists() and manifest_path.stat().st_size > 0:
        return "skip", 0

    files = http_json(f"{API}/files/{slug}")
    gltf_node = files.get("gltf", {}).get(resolution, {}).get("gltf")
    if not gltf_node:
        # Fall back ONLY to smaller resolutions — never exceed what
        # was requested. Some assets ship 8K/4K only and would
        # otherwise silently download massive textures (e.g.
        # pine_tree_01 at "1k" would have grabbed 4K = 913 MB).
        # Caller asked for a cap; honor it.
        order = ["1k", "2k", "4k", "8k"]
        if resolution not in order:
            return "no-gltf", 0
        max_idx = order.index(resolution)
        for fallback in order[:max_idx][::-1]:  # try smaller first
            cand = files.get("gltf", {}).get(fallback, {}).get("gltf")
            if cand:
                gltf_node = cand
                break
        if not gltf_node:
            return "no-gltf-at-or-below", 0

    folder.mkdir(parents=True, exist_ok=True)
    includes = gltf_node.get("include", {})
    total_bytes = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futures = {
            ex.submit(
                download_include,
                folder / rel,
                meta["url"],
                meta.get("md5"),
            ): rel
            for rel, meta in includes.items()
        }
        for fut in concurrent.futures.as_completed(futures):
            rel = futures[fut]
            try:
                total_bytes += fut.result()
            except Exception as e:
                return f"fail:include:{rel}:{e}", total_bytes

    manifest_blob = http_bytes(gltf_node["url"])
    if not md5_ok(manifest_blob, gltf_node.get("md5")):
        return "fail:manifest-md5", total_bytes
    tmp = manifest_path.with_suffix(".gltf.part")
    tmp.write_bytes(manifest_blob)
    tmp.rename(manifest_path)
    total_bytes += len(manifest_blob)
    return "ok", total_bytes


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--out", type=Path, default=DEFAULT_OUT,
                   help=f"Output root (default: {DEFAULT_OUT})")
    p.add_argument("--resolution", default="2k",
                   choices=["1k", "2k", "4k", "8k"],
                   help="Texture resolution. User asked max 2K.")
    p.add_argument("--limit", type=int, default=None,
                   help="Cap number of assets (smoke test)")
    p.add_argument("--delay", type=float, default=1.0,
                   help="Seconds between assets (rate-limit politeness)")
    p.add_argument("--workers", type=int, default=4,
                   help="Concurrent include downloads per asset")
    p.add_argument("--categories", nargs="+", default=list(DEFAULT_CATEGORIES),
                   help="PolyHaven categories to pull from")
    p.add_argument("--only", nargs="+", default=None,
                   help="Restrict to these slugs (overrides --categories)")
    args = p.parse_args()

    out_root: Path = args.out.resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    print("listing models from PolyHaven…", flush=True)
    all_models = http_json(f"{API}/assets?type=models")

    if args.only:
        wanted = set(args.only)
        slugs = sorted(s for s in all_models if s in wanted)
    else:
        wanted_cats = set(c.lower() for c in args.categories)
        slugs = sorted(
            slug for slug, info in all_models.items()
            if any(c.lower() in wanted_cats for c in info.get("categories", []))
        )
    if args.limit:
        slugs = slugs[: args.limit]

    print(f"{len(slugs)} model(s), resolution={args.resolution}, "
          f"out={out_root}", flush=True)
    if slugs:
        print("  " + ", ".join(slugs[:8])
              + (" …" if len(slugs) > 8 else ""), flush=True)

    stats = FetchStats()
    total_bytes = 0
    for i, slug in enumerate(slugs, 1):
        time.sleep(args.delay)
        try:
            status, n = fetch_asset(slug, out_root, args.resolution, args.workers)
        except KeyboardInterrupt:
            print("\ninterrupted; partial assets resume on next run")
            break
        except Exception as e:
            stats.failed.append((slug, str(e)))
            print(f"  [{i}/{len(slugs)}] {slug}: FAIL ({e})", file=sys.stderr)
            continue
        total_bytes += n
        if status == "ok":
            stats.downloaded += 1
            print(f"  [{i}/{len(slugs)}] {slug}: {n / 1_048_576:.1f} MB",
                  flush=True)
        elif status == "skip":
            stats.skipped += 1
        elif status == "no-gltf":
            stats.no_gltf += 1
            print(f"  [{i}/{len(slugs)}] {slug}: no glTF in any size")
        else:
            stats.failed.append((slug, status))
            print(f"  [{i}/{len(slugs)}] {slug}: {status}", file=sys.stderr)

    print(f"\n=== summary ===")
    print(f"  downloaded: {stats.downloaded} ({total_bytes / 1_048_576:.1f} MB)")
    print(f"  skipped (already on disk): {stats.skipped}")
    if stats.no_gltf:
        print(f"  no glTF available: {stats.no_gltf}")
    if stats.failed:
        print(f"  failed: {len(stats.failed)}")
        for slug, msg in stats.failed[:5]:
            print(f"    {slug}: {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
