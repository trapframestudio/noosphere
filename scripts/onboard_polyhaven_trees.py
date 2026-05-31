#!/usr/bin/env python3
"""Fetch + decimate PolyHaven tree models for game-ready use.

PolyHaven plant models ship the same .bin geometry across every
resolution tier (1k/2k/4k/8k differ only in textures). Their pine_tree_01
.bin is 905 MB — millions of triangles intended for offline rendering,
not scatter-instanced game forests. This script:

  1. Fetches the gltf bundle from PolyHaven's CDN.
  2. Runs Blender headlessly to apply the Decimate modifier on every
     mesh in the bundle, ratio configured per asset.
  3. Re-exports as a self-contained gltf bundle into
     ``godot/assets/models/plants/<slug>_4k.gltf/``, replacing the heavy
     .bin with one ~50–200× smaller while keeping the textures intact.

The decimated bundle plugs into ``tree_scatterer.gd``'s SPECIES paths
unchanged — the gltf manifest still references the same texture
filenames. Re-run with ``--force`` to regenerate (e.g. after tuning a
ratio).

Usage::

    python scripts/onboard_polyhaven_trees.py
    python scripts/onboard_polyhaven_trees.py --force pine_tree_01

Tunable per-asset ratios live in ``TREES`` below.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path


# Per-asset decimation config. `ratio` is Blender's Decimate modifier
# ratio (0..1, lower = fewer polys). PolyHaven trees come in at
# millions of polys; ratio=0.005 → ~140k polys/variant which renders
# at ~60 fps with 5k instances on modern hardware. Saplings are
# already smaller so use a higher ratio to preserve silhouette.
# Pacific Northwest conifers + sapling tier. `tree_small_02` was
# evaluated and rejected — it's Burkea africana (Wild Syringa), a
# southern African species that visually doesn't fit a Cascades /
# gorge setting.
TREES: list[dict] = [
    {"slug": "pine_tree_01",         "res": "4k", "ratio": 0.005},
    {"slug": "fir_tree_01",          "res": "4k", "ratio": 0.005},
    {"slug": "pine_sapling_medium",  "res": "4k", "ratio": 0.01},
    {"slug": "fir_sapling",          "res": "4k", "ratio": 0.01},
]


# Where decimated bundles land in the project tree.
ASSET_ROOT = Path("godot/assets/models/plants")


# PolyHaven's API + CDN reject requests with default urllib UA — set
# a real browser-style header for every fetch.
HTTP_HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; noosphere-onboarder/1)"}


def _http_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers=HTTP_HEADERS)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def _http_download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers=HTTP_HEADERS)
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def fetch_bundle(slug: str, res: str, dest: Path) -> None:
    """Download PolyHaven gltf bundle into `dest` (created if missing)."""
    api = f"https://api.polyhaven.com/files/{slug}"
    print(f"  fetching manifest {api}")
    data = json.loads(_http_get(api))
    if "gltf" not in data or res not in data["gltf"]:
        raise RuntimeError(f"no gltf/{res} variant for {slug}")
    g = data["gltf"][res]["gltf"]
    dest.mkdir(parents=True, exist_ok=True)

    # Main .gltf manifest
    url = g["url"]
    name = url.rsplit("/", 1)[1]
    print(f"  GET {name} ({g['size']/1024:.0f} KB)")
    _http_download(url, dest / name)

    # Includes (.bin + textures)
    for inc_path, inc in g.get("include", {}).items():
        local = dest / inc_path
        local.parent.mkdir(parents=True, exist_ok=True)
        size_mb = inc["size"] / 1024 / 1024
        print(f"  GET {inc_path} ({size_mb:.1f} MB)")
        _http_download(inc["url"], local)


# Sub-script Blender executes to do the decimation. Runs headless;
# stdout/stderr surface back through subprocess.
BLENDER_DECIMATE = r"""
import bpy
import sys

# Blender splits args on `--`; everything after is ours.
argv = sys.argv[sys.argv.index("--") + 1:]
in_gltf, out_gltf, ratio = argv[0], argv[1], float(argv[2])

# Clean factory defaults so leftover scene state doesn't pollute the export.
bpy.ops.wm.read_factory_settings(use_empty=True)

bpy.ops.import_scene.gltf(filepath=in_gltf)

before_total = 0
after_total = 0
for obj in list(bpy.context.scene.objects):
    if obj.type != 'MESH':
        continue
    before = len(obj.data.polygons)
    before_total += before
    mod = obj.modifiers.new(name="Decimate", type='DECIMATE')
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)
    after = len(obj.data.polygons)
    after_total += after
    print(f"  {obj.name}: {before} -> {after} polys", flush=True)

print(f"  TOTAL: {before_total} -> {after_total} polys "
      f"({100.0 * after_total / max(1, before_total):.2f}%)", flush=True)

# `GLTF_SEPARATE` writes .gltf + .bin + textures (we keep originals).
# `export_keep_originals=True` skips re-encoding textures, just refs them.
bpy.ops.export_scene.gltf(
    filepath=out_gltf,
    export_format='GLTF_SEPARATE',
    export_keep_originals=True,
    export_extras=True,
    export_apply=False,
)
"""


def decimate(in_gltf: Path, out_gltf: Path, ratio: float) -> None:
    """Spawn Blender headless, run the decimate sub-script."""
    out_gltf.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".py", delete=False
    ) as f:
        f.write(BLENDER_DECIMATE)
        script = f.name
    try:
        cmd = [
            "blender",
            "--background",
            "--factory-startup",
            "--python", script,
            "--",
            str(in_gltf), str(out_gltf), f"{ratio:.5f}",
        ]
        # Capture so we can filter the noisy startup banner.
        proc = subprocess.run(cmd, capture_output=True, text=True)
        # Blender prints a lot; surface only lines from our sub-script.
        for line in proc.stdout.splitlines():
            if line.startswith("  ") or line.startswith("Saved"):
                print(line)
        if proc.returncode != 0:
            print(proc.stdout, file=sys.stderr)
            print(proc.stderr, file=sys.stderr)
            raise RuntimeError(f"blender decimate failed: rc={proc.returncode}")
    finally:
        Path(script).unlink(missing_ok=True)


def rewrite_gltf_uris_to_local(gltf_path: Path) -> None:
    """Rewrite every `images[*].uri` so it points at the sibling
    `textures/<filename>` directory.

    Blender's gltf exporter (with `export_keep_originals=True`) writes
    URIs that point at wherever the SOURCE textures lived when the
    file was imported — for us that's the `tempfile.TemporaryDirectory`
    used a few lines below, which is gone by the time Godot tries to
    load the gltf. Symptom: every tree renders white because every
    `baseColorTexture` URI 404s. We pre-stage the textures into the
    final bundle's `textures/` subdir, so the only thing missing is
    pointing the URIs at them. This rewrite does that.

    Idempotent: a URI that's already `textures/<filename>` survives
    untouched. Matches anything ending in `/textures/<basename>` so
    the absolute /tmp paths we get from Blender map cleanly.
    """
    text = gltf_path.read_text()
    new = re.sub(
        r'"uri":"[^"]*?/textures/([^"]+)"',
        r'"uri":"textures/\1"',
        text,
    )
    if new != text:
        gltf_path.write_text(new)
        print(f"  rewrote texture URIs → relative in {gltf_path.name}")


def process_tree(cfg: dict, force: bool) -> None:
    slug = cfg["slug"]
    res = cfg["res"]
    ratio = cfg["ratio"]
    final_dir = ASSET_ROOT / f"{slug}_{res}.gltf"
    final_gltf = final_dir / f"{slug}_{res}.gltf"

    if final_dir.exists() and not force:
        print(f"\n=== {slug} (skipped, exists) ===")
        return

    print(f"\n=== {slug} (ratio={ratio}) ===")
    with tempfile.TemporaryDirectory(prefix=f"polyhaven_{slug}_") as tmp:
        tmp_dir = Path(tmp)
        fetch_bundle(slug, res, tmp_dir)
        in_gltf = tmp_dir / f"{slug}_{res}.gltf"

        # Stage textures into the final dir up front so the decimated
        # gltf can reference them by relative path on export.
        textures_src = tmp_dir / "textures"
        textures_dst = final_dir / "textures"
        if textures_src.is_dir():
            textures_dst.mkdir(parents=True, exist_ok=True)
            for t in textures_src.iterdir():
                if t.is_file():
                    shutil.copy2(t, textures_dst / t.name)

        decimate(in_gltf, final_gltf, ratio)

    # Blender's gltf export with `export_keep_originals=True` writes
    # absolute paths to the SOURCE textures (which lived in `tmp_dir`
    # above). Now that tmp_dir is gone, those URIs 404 → trees render
    # white. Rewrite each URI to point at our staged `textures/<file>`
    # sibling instead. Has to happen after `decimate()` returns so the
    # output gltf is on disk.
    rewrite_gltf_uris_to_local(final_gltf)

    # Report final on-disk footprint.
    total = sum(p.stat().st_size for p in final_dir.rglob("*") if p.is_file())
    print(f"  final size: {total / 1024 / 1024:.1f} MB")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "slugs",
        nargs="*",
        help="Subset of tree slugs to process; defaults to all in TREES",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Regenerate even if the bundle already exists",
    )
    args = ap.parse_args()

    targets = TREES
    if args.slugs:
        targets = [t for t in TREES if t["slug"] in args.slugs]
        if not targets:
            print(f"no matching slugs: {args.slugs}", file=sys.stderr)
            return 2

    for t in targets:
        process_tree(t, args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
