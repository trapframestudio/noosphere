#!/usr/bin/env python3
"""Pack our 16 terrain texture sources into Terrain3D's expected
channel layout:

  *_alb_ht.png   RGBA: RGB = albedo,    A = height / displacement
  *_nrm_rgh.png  RGBA: RGB = normal_GL, A = roughness

Output goes to ``godot/assets/textures/terrain/_terrain3d_packed/<slot>/``
at a common 2048x2048 resolution. The ``terrain3d_assets_pnw.tres``
references the packed files; the original `_diff` / `_nor_gl` /
`_rough` / `_ORM` source files stay where they are (used by the Rust
``TerrainNode`` shader path which has its own samplers).

For layers that lack a real height/displacement source (most
PolyHaven + Megascans bundles), the height channel is generated from
albedo luminance — same fallback ``Terrain3DUtil.luminance_to_height``
uses. AmbientCG bundles (slots 4 / 5 / 8 / 15) and Megascans
``military_trenches_dirt_fine`` (slot 9) have real ``_Displacement`` /
``_H`` maps and use them.

Usage::

    python scripts/pack_terrain3d_textures.py
    python scripts/pack_terrain3d_textures.py --target 2k
    python scripts/pack_terrain3d_textures.py --slot 0  # one layer at a time
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent / "godot"
TEX_ROOT = ROOT / "assets/textures/terrain"
OUT_ROOT = TEX_ROOT / "_terrain3d_packed"

# Per-slot manifest. Each entry is the bundle dir + the four source
# names. `height` may be None — in that case the packer falls back to
# albedo luminance. `rough_orm` is True if the listed roughness file
# is actually an ORM/ARM pack (rough lives in the green channel) vs.
# a pure single-channel grayscale roughness.
SLOTS = [
    # 0 Forest — Megascans forest_floor
    dict(slot=0, name="forest_floor",
         bundle="megascans/forest_floor",
         albedo="T_sfjmafua_8K_B.png",
         normal="T_sfjmafua_8K_N.png",
         height=None,
         rough="T_sfjmafua_8K_ORM.png", rough_orm=True),
    # 1 Grassland — Megascans wild_grass
    dict(slot=1, name="wild_grass",
         bundle="megascans/wild_grass",
         albedo="T_sfknaeoa_8K_B.png",
         normal="T_sfknaeoa_8K_N.png",
         height=None,
         rough="T_sfknaeoa_8K_ORM.png", rough_orm=True),
    # 2 Water (placeholder) — PolyHaven aerial_ground_rock
    dict(slot=2, name="water_placeholder",
         bundle="aerial_ground_rock_4k.gltf/textures",
         albedo="aerial_ground_rock_diff_4k.jpg",
         normal="aerial_ground_rock_nor_gl_4k.jpg",
         height=None,
         rough="aerial_ground_rock_rough_4k.jpg", rough_orm=False),
    # 3 Cropland — PolyHaven brown_mud_02
    dict(slot=3, name="brown_mud_02",
         bundle="brown_mud_02_4k.gltf/textures",
         albedo="brown_mud_02_diff_4k.jpg",
         normal="brown_mud_02_nor_gl_4k.jpg",
         height=None,
         rough="brown_mud_02_rough_4k.jpg", rough_orm=False),
    # 4 Bare — AmbientCG Ground073 (full set incl. Displacement)
    dict(slot=4, name="ground073",
         bundle="Ground073_4K-PNG",
         albedo="Ground073_4K-PNG_Color.png",
         normal="Ground073_4K-PNG_NormalGL.png",
         height="Ground073_4K-PNG_Displacement.png",
         rough="Ground073_4K-PNG_Roughness.png", rough_orm=False),
    # 5 BuiltUp — AmbientCG Concrete026
    dict(slot=5, name="concrete026",
         bundle="Concrete026_4K-PNG",
         albedo="Concrete026_4K-PNG_Color.png",
         normal="Concrete026_4K-PNG_NormalGL.png",
         height="Concrete026_4K-PNG_Displacement.png",
         rough="Concrete026_4K-PNG_Roughness.png", rough_orm=False),
    # 6 Cliff — Megascans mine_rock_wall
    dict(slot=6, name="mine_rock_wall",
         bundle="megascans/mine_rock_wall",
         albedo="T_uebmddyn_8K_B.png",
         normal="T_uebmddyn_8K_N.png",
         height=None,
         rough="T_uebmddyn_8K_ORM.png", rough_orm=True),
    # 7 Snow — PolyHaven snow_02
    dict(slot=7, name="snow_02",
         bundle="snow_02_4k.gltf/textures",
         albedo="snow_02_diff_4k.jpg",
         normal="snow_02_nor_gl_4k.jpg",
         height=None,
         rough="snow_02_rough_4k.jpg", rough_orm=False),
    # 8 PavedRoad — AmbientCG Asphalt010
    dict(slot=8, name="asphalt010",
         bundle="Asphalt010_4K-PNG",
         albedo="Asphalt010_4K-PNG_Color.png",
         normal="Asphalt010_4K-PNG_NormalGL.png",
         height="Asphalt010_4K-PNG_Displacement.png",
         rough="Asphalt010_4K-PNG_Roughness.png", rough_orm=False),
    # 9 UnpavedRoad — Megascans military_trenches_dirt_fine (has _H)
    dict(slot=9, name="trenches_dirt_fine",
         bundle="megascans/military_trenches_dirt_fine",
         albedo="T_yd0keak_2k_B.png",
         normal="T_yd0keak_2k_N.png",
         height="T_yd0keak_2k_H.png",
         rough="T_yd0keak_2k_ORM.png", rough_orm=True),
    # 10 Trail — Megascans mossy_rocky_ground
    dict(slot=10, name="mossy_rocky_ground",
         bundle="megascans/mossy_rocky_ground",
         albedo="T_vcrkeeb_8K_B.png",
         normal="T_vcrkeeb_8K_N.png",
         height=None,
         rough="T_vcrkeeb_8K_ORM.png", rough_orm=True),
    # 11 Cliff variant — PolyHaven mossy_rock
    dict(slot=11, name="mossy_rock",
         bundle="mossy_rock_4k.gltf/textures",
         albedo="mossy_rock_diff_4k.jpg",
         normal="mossy_rock_nor_gl_4k.jpg",
         height=None,
         rough="mossy_rock_rough_4k.jpg", rough_orm=False),
    # 12 Grass-rock transition — Megascans rocky_steppe
    dict(slot=12, name="rocky_steppe",
         bundle="megascans/rocky_steppe",
         albedo="T_ulgmbhwn_8K_B.png",
         normal="T_ulgmbhwn_8K_N.png",
         height=None,
         rough="T_ulgmbhwn_8K_ORM.png", rough_orm=True),
    # 13 Leafy/weed variant — Megascans mossy_grass
    dict(slot=13, name="mossy_grass",
         bundle="megascans/mossy_grass",
         albedo="T_vd3mebls_8K_B.png",
         normal="T_vd3mebls_8K_N.png",
         height=None,
         rough="T_vd3mebls_8K_ORM.png", rough_orm=True),
    # 14 Mossy variant — Megascans nordic_moss
    dict(slot=14, name="nordic_moss",
         bundle="megascans/nordic_moss",
         albedo="T_se4rwei_8K_B.png",
         normal="T_se4rwei_8K_N.png",
         height=None,
         rough="T_se4rwei_8K_ORM.png", rough_orm=True),
    # 15 Light cliff variant — AmbientCG Rock028
    dict(slot=15, name="rock028",
         bundle="Rock028_4K-PNG",
         albedo="Rock028_4K-PNG_Color.png",
         normal="Rock028_4K-PNG_NormalGL.png",
         height="Rock028_4K-PNG_Displacement.png",
         rough="Rock028_4K-PNG_Roughness.png", rough_orm=False),
]

TARGET_SIZES = {"1k": 1024, "2k": 2048, "4k": 4096}


def load_rgb(path: Path, size: int) -> Image.Image:
    img = Image.open(path).convert("RGB")
    if img.size != (size, size):
        img = img.resize((size, size), Image.LANCZOS)
    return img


def luminance(img: Image.Image) -> Image.Image:
    return img.convert("L")


def channel(img: Image.Image, ch: str) -> Image.Image:
    return img.split()[{"R": 0, "G": 1, "B": 2}[ch]]


def normalize_to_full_range(gray: Image.Image) -> Image.Image:
    """Stretch a grayscale band so its values use the full 0–255 range.

    Real displacement maps for flat surfaces (Asphalt010, Ground073)
    barely deviate from white; their alpha histogram is essentially
    a single value. Godot's texture importer reads that as "no
    useful alpha" and downgrades the texture from BC3/BC7 (RGBA) to
    BC1 (RGB-only). When other textures in the same Terrain3DAssets
    list keep RGBA, the format mismatch crashes the
    `_update_texture_files` step:

        Texture ID N albedo format: 17 doesn't match format of first
        texture: 19. They must be identical.

    Stretching the alpha band to full range fixes the importer
    heuristic AND gives the parallax/height shader more usable
    bits to read against."""
    histo = gray.histogram()
    used = [i for i, v in enumerate(histo) if v > 0]
    if not used:
        return gray
    lo, hi = used[0], used[-1]
    total = sum(histo)
    dominant = max(histo)
    if dominant / total > 0.95:
        # >95% of pixels share a single value (e.g. Asphalt010's flat
        # displacement, Ground073's near-constant), so any linear
        # stretch still leaves Godot reading the result as
        # essentially-constant alpha and downgrading to RGB-only.
        # Caller falls back to luminance; signal with `None`.
        return None  # type: ignore[return-value]
    if hi - lo >= 200:
        # Already spans most of the range; keep the original
        # absolute values rather than re-stretching tiny noise.
        return gray
    # Linear remap [lo, hi] → [0, 255]; preserves relative
    # displacement, just amplifies the contrast.
    scale = 255.0 / max(hi - lo, 1)
    return gray.point(lambda v, lo=lo, scale=scale: int(round((v - lo) * scale)))


def pack_albedo_height(albedo: Image.Image, height: Image.Image | None) -> Image.Image:
    r, g, b = albedo.split()
    if height is not None:
        a = normalize_to_full_range(height.convert("L"))
        if a is None:
            # Source displacement is degenerate (uniform); fall back
            # to luminance like the no-source-height case.
            a = luminance(albedo)
    else:
        a = luminance(albedo)
    return Image.merge("RGBA", (r, g, b, a))


def pack_normal_roughness(normal: Image.Image, rough: Image.Image, orm: bool) -> Image.Image:
    r, g, b = normal.split()
    a = channel(rough, "G") if orm else rough.convert("L")
    # Same constant-alpha-detection trap as in `pack_albedo_height`:
    # smooth surfaces (mine rock, snow) ship roughness textures with
    # very low variance, and Godot's importer downgrades the result
    # to RGB-only. Normalize to keep the roughness channel useful AND
    # the imported format uniform across the asset list. If the
    # source is truly degenerate (rare for roughness), fall back to
    # luminance of the normal map — better than constant alpha.
    a_norm = normalize_to_full_range(a)
    if a_norm is None:
        a_norm = luminance(normal)
    return Image.merge("RGBA", (r, g, b, a_norm))


def write_import_sidecar(png_path: Path, normal_map: bool) -> None:
    """Mirrors `addons/terrain_3d/menu/channel_packer_import_template.txt`,
    plus our common-size cap (`process/size_limit=2048`) so source size
    can vary without breaking the sampler array stack."""
    src_path = png_path.relative_to(ROOT)
    sidecar = png_path.with_suffix(png_path.suffix + ".import")
    nm_flag = "2" if normal_map else "0"
    sidecar.write_text(
        f"""[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://{src_path}"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map={nm_flag}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=2048
detect_3d/compress_to=1
""")


def pack_one(slot: dict, target_size: int) -> tuple[Path, Path]:
    bundle = TEX_ROOT / slot["bundle"]
    out_dir = OUT_ROOT / slot["name"]
    out_dir.mkdir(parents=True, exist_ok=True)

    albedo = load_rgb(bundle / slot["albedo"], target_size)
    normal = load_rgb(bundle / slot["normal"], target_size)
    rough = load_rgb(bundle / slot["rough"], target_size)
    height = load_rgb(bundle / slot["height"], target_size) if slot["height"] else None

    alb_ht = pack_albedo_height(albedo, height)
    nrm_rgh = pack_normal_roughness(normal, rough, slot["rough_orm"])

    alb_ht_path = out_dir / f"{slot['name']}_alb_ht.png"
    nrm_rgh_path = out_dir / f"{slot['name']}_nrm_rgh.png"
    # `optimize=True` shaves 5-15% on the kind of high-frequency
    # detail textures we have here; cost is negligible at pack time.
    alb_ht.save(alb_ht_path, optimize=True)
    nrm_rgh.save(nrm_rgh_path, optimize=True)
    write_import_sidecar(alb_ht_path, normal_map=False)
    write_import_sidecar(nrm_rgh_path, normal_map=True)

    return alb_ht_path, nrm_rgh_path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target", choices=list(TARGET_SIZES), default="2k",
                    help="Output edge length (default: 2k)")
    ap.add_argument("--slot", type=int, default=None,
                    help="Pack only this slot id (0..15); default: all")
    args = ap.parse_args()

    size = TARGET_SIZES[args.target]
    targets = [s for s in SLOTS if args.slot is None or s["slot"] == args.slot]
    if not targets:
        print(f"no matching slot {args.slot}", file=sys.stderr)
        return 2

    print(f"packing {len(targets)} layer(s) at {size}x{size}")
    for s in targets:
        print(f"  slot {s['slot']:2}  {s['name']}", flush=True)
        alb_ht, nrm_rgh = pack_one(s, size)
        ab_mb = alb_ht.stat().st_size / 1024 / 1024
        nr_mb = nrm_rgh.stat().st_size / 1024 / 1024
        print(f"           {alb_ht.name}  {ab_mb:.1f} MB")
        print(f"           {nrm_rgh.name}  {nr_mb:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
