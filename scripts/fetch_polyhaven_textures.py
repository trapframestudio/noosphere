#!/usr/bin/env python3
"""Mirror PolyHaven CC0 textures (GLTF format) into a local asset library.

Output layout matches the existing godot/assets/textures/terrain/*_4k.gltf/
convention: each asset becomes a folder containing the .gltf manifest, the
.bin, and a textures/ subfolder with the JPG maps.

  <out>/<category>/<slug>_<resolution>.gltf/
    <slug>_<resolution>.gltf
    <slug>.bin
    textures/
      <slug>_diff_<resolution>.jpg
      <slug>_nor_gl_<resolution>.jpg
      ...

Resumable: an asset folder is skipped if its manifest already exists and is
non-empty. Failed include downloads are retried on the next run because the
manifest is written last.

Polite by default: 1s delay between API calls, sequential per-asset, with a
small thread pool downloading the include files of a single asset.
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

API = "https://api.polyhaven.com"
UA = "noosphere-asset-fetcher/1.0 (+https://github.com/getboxie/noosphere)"

# First match wins. Specific materials beat broad classifiers; "floor" /
# "wall" / "outdoor" / "man made" are catch-alls used last; "uncategorized"
# is the bucket of last resort. Names match PolyHaven's `categories` field
# verbatim (lowercased) — verify against /assets?type=textures before
# adding new ones, or the rule silently never fires.
CATEGORY_PRIORITY: list[str] = [
    # specific materials
    "wood", "bark",
    "metal",
    "brick", "cobblestone",
    "concrete", "plaster-concrete", "plaster",
    "marble", "rock",
    "tiles", "paving", "asphalt", "road", "gravel",
    "fabric", "leather", "plastic", "rubber",
    "snow", "sand", "soil", "mud", "grass", "dirt", "moss",
    "roofing", "food", "liquid",
    # broad surface classifiers
    "terrain", "natural",
    "floor", "wall",
    "indoor", "outdoor", "man made",
]


def slug_to_folder_name(category: str) -> str:
    return category.replace(" ", "_").lower()


def pick_category(asset_categories: list[str]) -> str:
    norm = {c.lower() for c in asset_categories}
    for cat in CATEGORY_PRIORITY:
        if cat in norm:
            return slug_to_folder_name(cat)
    return "uncategorized"


@dataclass
class FetchStats:
    downloaded: int = 0
    skipped: int = 0
    failed: list[tuple[str, str, str]] = None  # (slug, kind, msg)

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


def fetch_asset(slug: str, info: dict, out_root: Path, resolution: str,
                workers: int) -> tuple[str, int]:
    """Download one asset. Returns (status, total_bytes).

    status: "ok" | "skip" | "no-gltf" | "fail:<reason>"
    """
    cat = pick_category(info.get("categories", []))
    folder = out_root / cat / f"{slug}_{resolution}.gltf"
    manifest_path = folder / f"{slug}_{resolution}.gltf"

    if manifest_path.exists() and manifest_path.stat().st_size > 0:
        return "skip", 0

    files = http_json(f"{API}/files/{slug}")
    gltf_node = files.get("gltf", {}).get(resolution, {}).get("gltf")
    if not gltf_node:
        # Some assets only ship larger sizes; try the next-larger one.
        for fallback in ("8k", "4k", "2k", "1k"):
            if fallback == resolution:
                continue
            cand = files.get("gltf", {}).get(fallback, {}).get("gltf")
            if cand:
                gltf_node = cand
                break
        if not gltf_node:
            return "no-gltf", 0

    folder.mkdir(parents=True, exist_ok=True)

    # Includes first, manifest last so a partial run is resumable.
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
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True,
                   help="Output root (e.g. asset-library/textures)")
    p.add_argument("--resolution", default="4k",
                   choices=["1k", "2k", "4k", "8k"])
    p.add_argument("--limit", type=int, default=None,
                   help="Cap number of assets (for smoke tests)")
    p.add_argument("--delay", type=float, default=1.0,
                   help="Seconds between assets (rate-limit politeness)")
    p.add_argument("--workers", type=int, default=4,
                   help="Concurrent include downloads per asset")
    p.add_argument("--only", nargs="+", default=None,
                   help="Restrict to these slugs")
    args = p.parse_args()

    out_root: Path = args.out.resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    print(f"asset list -> {API}/assets?type=textures", flush=True)
    assets = http_json(f"{API}/assets?type=textures")
    slugs = sorted(assets.keys())
    if args.only:
        wanted = set(args.only)
        slugs = [s for s in slugs if s in wanted]
    if args.limit:
        slugs = slugs[: args.limit]
    print(f"{len(slugs)} textures, resolution={args.resolution}, "
          f"workers={args.workers}, delay={args.delay}s", flush=True)

    stats = FetchStats()
    total_bytes = 0
    for i, slug in enumerate(slugs, 1):
        info = assets[slug]
        time.sleep(args.delay)
        try:
            status, n = fetch_asset(slug, info, out_root,
                                    args.resolution, args.workers)
        except KeyboardInterrupt:
            print("\ninterrupted; partial assets will resume on next run")
            return 130
        except Exception as e:
            status = f"fail:asset:{e}"
            n = 0

        cat = pick_category(info.get("categories", []))
        if status == "ok":
            stats.downloaded += 1
            total_bytes += n
            print(f"[{i}/{len(slugs)}] ok    {cat}/{slug} "
                  f"({n / 1_048_576:.1f} MiB)", flush=True)
        elif status == "skip":
            stats.skipped += 1
            print(f"[{i}/{len(slugs)}] skip  {cat}/{slug}", flush=True)
        else:
            stats.failed.append((slug, status, ""))
            print(f"[{i}/{len(slugs)}] FAIL  {cat}/{slug} :: {status}",
                  flush=True)

    print()
    print(f"done: {stats.downloaded} downloaded "
          f"({total_bytes / 1_073_741_824:.2f} GiB), "
          f"{stats.skipped} skipped, {len(stats.failed)} failed")
    if stats.failed:
        print("first failures:")
        for slug, kind, _ in stats.failed[:20]:
            print(f"  {slug}: {kind}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
