#!/usr/bin/env -S blender --background --python
"""Convert CGTrader RockyPineForest FBX assets to Godot-ready GLBs.

Generalizes the pine-only converter to all asset categories the pack
ships: pines, ferns, grass clusters, rocks, ground debris (called
"needle clusters" on the UE side), landscape patches, and the
background mountain.

The pack ships geometry as FBX (extracted from
`uploads_files_3640871_RockyPineForest_FBX.rar`) and ships its
textures + UE materials embedded in the Unreal project (extracted
from `uploads_files_3640871_RockyPineForest_01+4.27.rar`). The FBX
files reference textures by basename only (no path), so Blender's FBX
importer can't find them automatically. We bridge that with `umodel`
(UE Viewer): it dumps every material's texture references to a `.mat`
text file alongside PNG copies of the textures themselves. This
script then reads each `.mat` file to figure out which umodel-
extracted PNGs to bind to which Principled BSDF input.

Pre-flight extraction (one-time setup):

    # 1. extract the FBX rar
    mkdir -p /tmp/cgtrader_extract
    unar -o /tmp/cgtrader_extract/forest_biome \\
      "$REPO/asset_downloads/CGTrader/Models/Forest Biome/uploads_files_3640871_RockyPineForest_FBX.rar"

    # 2. extract the UE 4.27 project
    unar -o /tmp/cgtrader_extract/forest_biome_unreal \\
      "$REPO/asset_downloads/CGTrader/Models/Forest Biome/uploads_files_3640871_RockyPineForest_01+4.27.rar"

    # 3. build umodel (one-time)
    git clone https://github.com/gildor2/UEViewer.git /tmp/UEViewer
    (cd /tmp/UEViewer && ./build.sh)

    # 4. dump all UE static-mesh materials + textures
    find /tmp/cgtrader_extract/forest_biome_unreal/Content/Rocky_Pine_Forest \\
      -name 'SM_*.uasset' ! -path '*/Demo_ThirdPersonBP/*' ! -path '*/Maps/*' \\
      -print0 | xargs -0 -P 4 -I {} /tmp/UEViewer/umodel \\
      -path=/tmp/cgtrader_extract/forest_biome_unreal \\
      -export -png -out=/tmp/umodel_textures -game=ue4.27 {}

Run conversion:

    blender --background --python scripts/convert_cgtrader_assets.py
    blender --background --python scripts/convert_cgtrader_assets.py -- pines ferns

(Bare run = all categories; explicit list = only those.)
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import bpy

SRC_DIR = Path("/tmp/cgtrader_extract/forest_biome/RockyPineForest_FBX")
TEX_DIR = Path("/tmp/umodel_textures")
REPO_ROOT = Path(__file__).resolve().parent.parent
DST_ROOT = REPO_ROOT / "godot" / "assets" / "models" / "plants_cgtrader"

MAX_TEX_SIZE_DEFAULT = 1024
"""Default max texture edge length on export. Pack ships at 2-4K but
foliage rarely covers >50 px on screen; 1024 is plenty for tree
canopies / fern fronds / grass cards. Categories that override this
(rocks, mountains) keep more pixels for surfaces the player walks
right up to."""


@dataclass
class Category:
    """One asset category to convert. The naming patterns are flexible
    enough to handle every variation in the pack (pines have LOD0..3
    + Bill_Imp, ferns have LOD0..2 with PP suffix, rocks are single-
    LOD, debris has LOD0 as bare-no-suffix, etc.)."""
    name: str
    """Subdir name under SRC_DIR + DST_ROOT."""
    fbx_subdir: str | None = None
    """Subdir of SRC_DIR for FBX files. None → same as `name`."""
    variants: list[str] = field(default_factory=list)
    """Asset basenames (e.g. `pine_03`, `fern_01`, `rock_01`)."""
    lods: list[int | None] = field(default_factory=lambda: [None])
    """LOD levels to import; `None` = no LOD suffix in filename."""
    lod_suffix: str = "_LOD{lod}"
    """Format string for LOD suffix. `{lod}` is replaced with the LOD
    int. Some assets append `_PP` (PivotPainter) — see lod_extra."""
    lod_extra: str = ""
    """Extra suffix after LOD (e.g. `_PP` for pines + ferns)."""
    mat_search_dirs: list[str] = field(default_factory=list)
    """Globs (relative to TEX_DIR) of dirs containing `.mat` files
    for this category. Variant name is substituted for `{variant}`."""
    foliage: bool = False
    """If True, materials default to alphaMode=MASK (alpha-cutout
    foliage). Else default OPAQUE. Material-name pattern check still
    overrides per-material (e.g. `Trunk` materials inside a foliage
    asset stay OPAQUE)."""
    material_aliases: dict[str, str] = field(default_factory=dict)
    """Map of FBX material name (lowercased, .NNN suffix stripped) →
    UE `.mat` basename without extension. Use this when the FBX uses
    arbitrary names like `lambert1` or `grass_cluster_01_mtl` that
    don't match the UE material naming convention. Supports
    `{vN}` placeholder for variant number. Empty string value =
    skip wiring (e.g. `colMat` collision proxies)."""
    max_tex_size: int = 0
    """Per-category texture size cap. 0 = use MAX_TEX_SIZE_DEFAULT
    (1024). Set higher for assets the player gets close to (rocks,
    mountains)."""
    image_format: str = "JPEG"
    """`JPEG` or `AUTO`. AUTO writes PNG for images with alpha (leaf
    / branch cards) and JPEG for opaque images (trunk, rock, soil) —
    so categories where surface detail matters (rocks, mountains)
    get lossless PNG for opaque maps without bloating the foliage
    cards. JPEG-only is fine for assets where compression artifacts
    disappear behind alpha cutout."""
    obj_source: bool = False
    """Source files are .obj instead of .fbx. Used for old / non-UE
    packs that only ship Wavefront geometry."""
    import_scale: float = 1.0
    """Uniform scale applied at import. Use when the source file is
    in non-meter units — the more-pines OBJ pack uses centimeters,
    so 0.01 brings it into meters."""
    alpha_cutoff: float = 0.5
    """`alphaCutoff` written into MASK-mode materials. Default 0.5
    is the glTF spec default and right for hard-edged cutouts. Lower
    (0.2-0.3) for textures whose leaf-card edges are anti-aliased
    with intermediate alpha values — the more-pines pack ships at
    alpha ~83/255 in the leaf body, so 0.5 clips most pixels and
    leaves the canopy nearly black."""
    texture_dir: str = ""
    """Override TEX_DIR for this category — point at a non-umodel
    texture directory (e.g. an OBJ pack's `textures/` folder).
    Empty = use the global TEX_DIR."""
    direct_material_textures: dict = field(default_factory=dict)
    """Per-material direct texture mapping (no UE .mat parsing).
    Use when the source is a non-UE pack: each FBX/OBJ material name
    maps to a dict of {slot: texture-basename}. Slots match
    Principled BSDF inputs: basecolor, normal, alpha. Substitutions
    in basenames: `{variant_suffix}` is the part after the variant
    base (e.g. `_fresh`, `_twiggy`, `` for default — used to pick
    leaf-variant textures per pine height/style). Example:
        {"pine_needles_fresh": {"basecolor": "pine-leaf-fresh-diff",
                                "normal":   "pine-leaf-fresh-norm"}}
    """


CATEGORIES: dict[str, Category] = {
    "pines": Category(
        # Standalone-trunk variants only. The on-rock variants
        # (pine_01, 02, 04, 05) and the sapling (pine_08) were
        # dropped because they rely on UE PivotPainter master
        # materials whose alpha-cutout / triplanar projection
        # behaviors don't translate cleanly through FBX→glTF —
        # roots / rocks / fallen needles ended up as floating
        # bark slabs even with the cube-projection + per-asset
        # opacity-mask wiring. Pure3D Pine pack (`morepines`
        # category) covers the missing size variety with cleanly
        # alpha-channeled TGA leaf cards.
        name="pines",
        fbx_subdir="pine_{vn}",
        variants=["pine_03", "pine_06", "pine_07"],
        lods=[0, 1, 2, 3],
        lod_extra="_PP",
        mat_search_dirs=[
            "Rocky_Pine_Forest/Pines/Pine_{vN}/Materials",
            "Rocky_Pine_Forest/Pines/Pine_{vN}/Materials/PivotPainter",
            "Rocky_Pine_Forest/Pines/tex_Shared",
        ],
        material_aliases={
            "colmat": "",  # collision proxy — skip wiring
        },
        foliage=True,
    ),
    "ferns": Category(
        name="ferns",
        fbx_subdir="fern_{vn}",  # fern_01, fern_02
        variants=["fern_01", "fern_02"],
        lods=[0, 1, 2],
        lod_extra="_PP",
        mat_search_dirs=[
            "Rocky_Pine_Forest/Ferns/Fern_{vN}/Materials",
            "Rocky_Pine_Forest/Ferns/Fern_{vN}/Materials/PivotPainter",
        ],
        material_aliases={
            "fern_01_mat": "M_Fern_01_PP",
            "fern_02_mat": "M_Fern_02_PP",
        },
        foliage=True,
    ),
    "grass": Category(
        name="grass",
        fbx_subdir="grass",
        variants=[f"grass_cluster_0{i}" for i in (1, 2, 3)],
        lods=[0, 1, 2],
        mat_search_dirs=[
            "Rocky_Pine_Forest/Scatter_Meshes/Grass/Materials",
        ],
        material_aliases={
            "grass_cluster_01_mtl": "M_Grass_01",
            "grass_cluster_02_mtl": "M_Grass_01",
            "grass_cluster_03_mtl": "M_Grass_01",
        },
        foliage=True,
    ),
    "rocks": Category(
        name="rocks",
        fbx_subdir="rocks",
        variants=[
            "rock_01", "rock_02", "rock_03",
            "small_rock_01", "small_rock_02", "small_rock_03",
        ],
        lods=[None],
        mat_search_dirs=[
            "Rocky_Pine_Forest/Rocks/Materials",
        ],
        # `lambert1` is the default Maya material name — both rock
        # variants ship with it but reference different UE materials.
        # Per-variant resolution happens in `_resolve_mat_alias`.
        material_aliases={
            "lambert1": "M_Medium_Rocks",  # overridden for small_rock_*
        },
        max_tex_size=2048,
        image_format="AUTO",
        foliage=False,
    ),
    "ground_debris": Category(
        name="ground_debris",
        fbx_subdir="forest_ground_debris",
        variants=[f"forest_ground_debris_0{i}" for i in range(1, 8)],
        # LOD0 has NO suffix, LOD1/LOD2 do — handled by special-case
        # in _format_lod_filename.
        lods=[0, 1, 2],
        mat_search_dirs=[
            "Rocky_Pine_Forest/Scatter_Meshes/Needle_clusters/Materials",
        ],
        material_aliases={
            "debris_atlas_01": "M_Needle_Cluster",
        },
        foliage=True,
    ),
    "landscape_patches": Category(
        name="landscape_patches",
        fbx_subdir="landscape_patch",
        variants=["patch_with_debris_01"],
        lods=[0, 1, 2, 3],
        mat_search_dirs=[
            "Rocky_Pine_Forest/Landscape_Patches/Materials",
        ],
        material_aliases={
            "colmat": "",
            "debris_01_mtl": "M_Crackd_Soil_Debris",
            "patch_01_mtl": "M_Cracked_Soil",
        },
        foliage=False,
    ),
    "morepines": Category(
        # CGTrader "more pines" pack — Pure3D Shop pines, OBJ format.
        # 14 standalone pines (2-20m), 3 variants each: default,
        # `_fresh` (lush), `_twiggy` (sparser canopy). Materials are
        # `pine_trunk`, `pine_branch`, `pine_needles` (or
        # `pine_needles_fresh` on _fresh variants). Textures wire
        # directly via `direct_material_textures` — no .mat parsing.
        name="morepines",
        # Absolute path — sits inside the repo's asset_downloads
        # tree, NOT in the /tmp FBX-rar extract directory.
        fbx_subdir=str(REPO_ROOT
            / "asset_downloads/CGTrader/Models/more pines/_.obj"),
        import_scale=0.01,  # OBJ ships in cm; convert to meters.
        # Pure3D leaf TGAs are anti-aliased — interior pixels of
        # leaf bodies have alpha as low as ~80/255 (verified). 0.5
        # cutoff clips most of them out and the canopy renders
        # almost solid black; 0.2 keeps the leaves visible while
        # still cutting the (alpha=0) background.
        alpha_cutoff=0.2,
        variants=[
            "Pine_4m", "Pine_7m", "Pine_9m", "Pine_16m",
            "Pine_2m_twiggy", "Pine_3m_twiggy", "Pine_7m_twiggy",
            "Pine_12m_twiggy", "Pine_20m_twiggy",
            "Pine_3m_fresh", "Pine_7m_fresh", "Pine_9m_fresh",
            "Pine_15m_fresh", "Pine_18m_fresh",
        ],
        lods=[None],
        obj_source=True,
        texture_dir="/tmp/morepines_tex",
        direct_material_textures={
            "pine_trunk": {
                "basecolor": "pine-trunk-diff",
                "normal":   "pine-trunk-norm",
            },
            "pine_branch": {
                "basecolor": "pine-branch-diff",
                "normal":   "pine-branch-norm",
            },
            # `_twiggy` / default variants — leaf texture chosen
            # via `{leaf_suffix}` substitution in
            # `_wire_material_from_mat`.
            "pine_needles": {
                "basecolor": "pine-leaf{leaf_suffix}-diff",
                "normal":   "pine-leaf{leaf_suffix}-norm",
            },
            # `_fresh` variants use a dedicated material name.
            "pine_needles_fresh": {
                "basecolor": "pine-leaf-fresh-diff",
                "normal":   "pine-leaf-fresh-norm",
            },
        },
        foliage=True,
    ),
    "mountains": Category(
        name="mountains",
        fbx_subdir="background_mountains",
        variants=["background_mountain_01"],
        lods=[None],
        mat_search_dirs=[
            "Rocky_Pine_Forest/Background_Mountains/Materials",
        ],
        material_aliases={
            "backmount_01": "M_Background_Mountain_01",
        },
        max_tex_size=2048,
        image_format="AUTO",
        foliage=False,
    ),
}


# Globals filled at startup once per run.
_TEX_INDEX: dict[str, Path] = {}
"""basename (lowercase, no ext) → absolute PNG path. Built from
`TEX_DIR.rglob('*.png')`."""


# ---- helpers -----------------------------------------------------


def _png_has_alpha(path: Path) -> bool:
    """True iff PNG at `path` has an alpha channel. Reads the IHDR
    chunk directly because Blender normalizes loaded images to 4
    channels regardless of source."""
    try:
        with path.open("rb") as f:
            header = f.read(26)
        if header[:8] != b"\x89PNG\r\n\x1a\n":
            return False
        return header[25] in (4, 6)
    except (OSError, IndexError):
        return False


def _build_texture_index(extra_dirs: list[Path] | None = None) -> None:
    _TEX_INDEX.clear()
    roots = [TEX_DIR]
    if extra_dirs:
        roots.extend(extra_dirs)
    for root in roots:
        if not root.exists():
            continue
        for png in root.rglob("*.png"):
            # Skip dummies — they're solid 1x1 placeholders and would
            # match generic `_BC` lookups if we had a name collision.
            if "/Dummies/" in str(png):
                continue
            _TEX_INDEX[png.stem.lower()] = png
    print(f"[index] {len(_TEX_INDEX)} textures")


def _parse_mat_file(mat_path: Path) -> list[str]:
    """Return ordered list of texture basenames referenced by this
    `.mat` file, dummies stripped."""
    refs: list[str] = []
    with mat_path.open() as f:
        for line in f:
            line = line.strip()
            if "=" not in line:
                continue
            _, name = line.split("=", 1)
            name = name.strip()
            if not name or "dummy" in name.lower():
                continue
            refs.append(name)
    return refs


def _classify_texture(tex_name: str) -> str | None:
    """Map a UE texture basename to a Principled BSDF slot. Returns
    one of {"basecolor", "normal", "orm", "roughness", "sss",
    "alpha"} or None if the texture is irrelevant (PivotPainter wind
    data, ColorVariation, blend masks for material mixing, etc.)."""
    n = tex_name.lower()
    # Skip non-PBR utility textures.
    if any(skip in n for skip in (
        "_pivotpos", "_xvector", "_normalizedhier", "_parentindex",
        "_xextentd", "_colorvar", "_uniformclouds", "rgb_mask",
    )):
        return None
    # Material-blend masks (snow over rock, moss over rock, grass
    # over mountain) — these aren't alpha cutouts, they're shader-
    # internal mixing weights. Skip; we can't replicate the multi-
    # layer blend in standard glTF.
    if any(blend in n for blend in (
        "snow_mask", "moss_mask", "grass_mask", "_blend_mask",
    )):
        return None
    if n.endswith("_n") or n.endswith("_normal"):
        return "normal"
    if n.endswith("_orm") or n.endswith("_orh") or n.endswith("_ormh"):
        return "orm"
    if n.endswith("_sss") or n.endswith("_subsurface"):
        return "sss"
    if (n.endswith("_bc") or n.endswith("_bc_v2") or n.endswith("_color")
            or n.endswith("_color_v2") or n.endswith("_diffuse")
            or n.endswith("_albedo") or n.endswith("_basecolor")):
        return "basecolor"
    if (n.endswith("_roughness") or n.endswith("_rough")
            or n.endswith("_r")):
        return "roughness"
    # Per-asset opacity cutout masks (`T_pine_NN_roots_mask`,
    # `T_pine_NN_branches_mask`). These are the alpha-cutout source
    # for the corresponding geometry — without wiring them, root /
    # twig cards render as solid bark slabs.
    if (n.endswith("_opacity") or n.endswith("_alpha")
            or n.endswith("_mask")):
        return "alpha"
    return None


_SKIP_MAT = object()
"""Sentinel returned by _resolve_mat_alias when a material is
explicitly aliased to the empty string (collision proxy etc.).
Distinguishes "no alias" (None) from "alias = skip"."""


def _resolve_mat_alias(short_name: str, variant: str, cat: Category):
    """Look up category's `material_aliases` for the FBX material name.
    Returns the alias mat-basename (with placeholders substituted), or
    `_SKIP_MAT` if alias is "" (collision skip), or None if no alias."""
    alias = cat.material_aliases.get(short_name)
    if alias is None:
        return None
    if alias == "":
        return _SKIP_MAT
    # Per-variant override for rocks: small_rock_* uses M_Small_Rocks.
    if cat.name == "rocks" and variant.startswith("small_"):
        alias = "M_Small_Rocks"
    vn = variant.split("_")[-1]
    return alias.replace("{vN}", vn).replace("{vn}", vn) \
        .replace("{variant}", variant)


def _find_mat_for_material(
    material_name: str,
    variant: str,
    cat: Category,
):
    """Find the umodel `.mat` file matching this Blender material
    name. Returns a Path, `_SKIP_MAT` (caller should skip), or None
    (no match found, caller falls back to flat-color material)."""
    short = material_name.split(".")[0].lower()
    # Strip Blender's `.NNN` duplicate suffix.
    vn = variant.split("_")[-1]  # "pine_03" → "03"
    vN = vn.upper() if not vn.isdigit() else vn
    candidate_dirs: list[Path] = []
    for d in cat.mat_search_dirs:
        d_resolved = d.replace("{variant}", variant) \
            .replace("{vn}", vn) \
            .replace("{vN}", vN)
        candidate_dirs.append(TEX_DIR / d_resolved)
    # 1. Explicit alias from category config.
    alias = _resolve_mat_alias(short, variant, cat)
    if alias is _SKIP_MAT:
        return _SKIP_MAT
    if isinstance(alias, str):
        target = alias.lower()
        for d in candidate_dirs:
            if not d.exists():
                continue
            for mat_path in d.glob("*.mat"):
                if mat_path.stem.lower() == target:
                    return mat_path
        # Aliased mat not found — fall through to heuristic. Could
        # also be a typo; printing helps debugging.
        print(f"  [warn] alias {short} → {alias} not found in "
            f"{[str(d) for d in candidate_dirs]}")
    # 2. Heuristic: try common UE naming conventions.
    candidates = [
        f"m_{variant}_{short}_pp",
        f"m_{variant}_{short}",
        f"m_{short}",
        f"m_{short}_{variant}",
        f"m_{variant}_{short}_pp_lod2-3",  # shared LOD2-3 mat
    ]
    for d in candidate_dirs:
        if not d.exists():
            continue
        for mat_path in d.glob("*.mat"):
            if mat_path.stem.lower() in candidates:
                return mat_path
    # 3. Fuzzy fallback: any `.mat` whose stem contains the short name.
    for d in candidate_dirs:
        if not d.exists():
            continue
        for mat_path in d.glob("*.mat"):
            if short in mat_path.stem.lower():
                return mat_path
    return None


def _wire_material_direct(
    mat: bpy.types.Material,
    slot_textures: dict,
) -> bool:
    """Wire a material from a direct {slot: texture-basename} dict.
    Used by non-UE packs (e.g. the "more pines" OBJ pack) that don't
    ship `.mat` files. Slots: basecolor, normal, alpha. The basename
    is looked up in `_TEX_INDEX` (lowercased)."""
    if not mat.use_nodes:
        mat.use_nodes = True
    nt = mat.node_tree
    for node in list(nt.nodes):
        if node.type in {"TEX_IMAGE", "NORMAL_MAP", "SEPARATE_COLOR",
                "SEPARATE_RGB"}:
            nt.nodes.remove(node)
    principled = next(
        (n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        principled = nt.nodes.new("ShaderNodeBsdfPrincipled")
    principled.inputs["Metallic"].default_value = 0.0
    bc_node = None
    if "basecolor" in slot_textures:
        bc_path = _TEX_INDEX.get(slot_textures["basecolor"].lower())
        if bc_path is not None:
            img = bpy.data.images.load(str(bc_path), check_existing=True)
            bc_node = nt.nodes.new("ShaderNodeTexImage")
            bc_node.image = img
            nt.links.new(bc_node.outputs["Color"],
                principled.inputs["Base Color"])
            # Wire BC.a as alpha if the texture has alpha — these
            # packs typically use diff.a as the leaf-card cutout.
            if _png_has_alpha(bc_path):
                nt.links.new(bc_node.outputs["Alpha"],
                    principled.inputs["Alpha"])
                mat.blend_method = "CLIP"
    if "normal" in slot_textures:
        n_path = _TEX_INDEX.get(slot_textures["normal"].lower())
        if n_path is not None:
            img = bpy.data.images.load(str(n_path), check_existing=True)
            img.colorspace_settings.name = "Non-Color"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(tex.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"],
                principled.inputs["Normal"])
    # Separate alpha texture (overrides BC.a).
    if "alpha" in slot_textures:
        a_path = _TEX_INDEX.get(slot_textures["alpha"].lower())
        if a_path is not None:
            img = bpy.data.images.load(str(a_path), check_existing=True)
            img.colorspace_settings.name = "Non-Color"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            nt.links.new(tex.outputs["Color"],
                principled.inputs["Alpha"])
            mat.blend_method = "CLIP"
    return bc_node is not None


def _wire_material_from_mat(
    mat: bpy.types.Material,
    variant: str,
    cat: Category,
) -> bool:
    """Re-wire the material's Principled BSDF from a matching `.mat`
    file. Returns True if any texture was wired."""
    # Direct material→texture mapping path (non-UE packs that don't
    # ship .mat files). Skip the .mat lookup entirely and build
    # by_slot directly from the category's `direct_material_textures`
    # config.
    if cat.direct_material_textures:
        short_low = mat.name.split(".")[0].lower()
        slot_textures = cat.direct_material_textures.get(short_low)
        if slot_textures is None:
            # Try fuzzy: any key that's a prefix of the material name.
            for key, st in cat.direct_material_textures.items():
                if short_low.startswith(key):
                    slot_textures = st
                    break
        if slot_textures is None:
            return False
        # Substitute `{leaf_suffix}` based on the variant name.
        # `_twiggy` → `-twiggy`, `_fresh` → `-fresh`, default → ``.
        # Used by the more-pines pack where one material name
        # (`pine_needles`) maps to different leaf-card textures
        # depending on whether the host pine is a twiggy or default
        # variant.
        if variant.endswith("_twiggy"):
            leaf_suffix = "-twiggy"
        elif variant.endswith("_fresh"):
            leaf_suffix = "-fresh"
        else:
            leaf_suffix = ""
        resolved = {k: v.replace("{leaf_suffix}", leaf_suffix)
            for k, v in slot_textures.items()}
        return _wire_material_direct(mat, resolved)
    mat_file = _find_mat_for_material(mat.name, variant, cat)
    if mat_file is None:
        return False
    if mat_file is _SKIP_MAT:
        # Collision proxy: nuke this material's nodes and replace with
        # a fully-transparent one. Stops it from rendering as a solid
        # blob over the asset.
        if not mat.use_nodes:
            mat.use_nodes = True
        nt = mat.node_tree
        for node in list(nt.nodes):
            if node.type in {"TEX_IMAGE", "NORMAL_MAP",
                    "SEPARATE_COLOR", "SEPARATE_RGB"}:
                nt.nodes.remove(node)
        principled = next(
            (n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if principled is not None:
            principled.inputs["Alpha"].default_value = 0.0
            principled.inputs["Metallic"].default_value = 0.0
        mat.blend_method = "CLIP"
        return True
    refs = _parse_mat_file(mat_file)
    by_slot: dict[str, str] = {}
    for ref in refs:
        slot = _classify_texture(ref)
        if slot is None:
            continue
        ref_low = ref.lower()
        # Prefer "_v2" / "_v3" base color over the original.
        if slot == "basecolor" and slot in by_slot:
            if "_v" in ref_low and "_v" not in by_slot[slot]:
                by_slot[slot] = ref_low
            continue
        by_slot.setdefault(slot, ref_low)
    if not by_slot:
        return False
    if not mat.use_nodes:
        mat.use_nodes = True
    nt = mat.node_tree
    # Drop existing image / normal-map / separate-color nodes.
    for node in list(nt.nodes):
        if node.type in {"TEX_IMAGE", "NORMAL_MAP", "SEPARATE_COLOR",
                "SEPARATE_RGB"}:
            nt.nodes.remove(node)
    principled = next(
        (n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        principled = nt.nodes.new("ShaderNodeBsdfPrincipled")
    # glTF metallicFactor defaults to 1.0 — explicitly zero here so
    # Rocks / Roots / etc. don't render fully metallic when there's
    # no ORM map. ORM connection below will override.
    principled.inputs["Metallic"].default_value = 0.0
    # Base color (alpha wiring is separate — see below).
    if "basecolor" in by_slot:
        bc_path = _TEX_INDEX.get(by_slot["basecolor"])
        if bc_path is not None:
            img = bpy.data.images.load(str(bc_path), check_existing=True)
            bc_tex_node = nt.nodes.new("ShaderNodeTexImage")
            bc_tex_node.image = img
            nt.links.new(bc_tex_node.outputs["Color"],
                principled.inputs["Base Color"])
    # Alpha cutout wiring. Three-tier priority:
    #
    # 1. Explicit `_mask` texture from the .mat file — this is UE's
    #    master-material opacity cutout (e.g. `T_pine_05_roots_mask`).
    #    Always wire when present; it's the artist's authoritative
    #    cutout source.
    #
    # 2. BC's alpha channel for foliage-named materials. Used when no
    #    explicit mask exists (Needles, Branches, Leaves, Fallen).
    #    UE bakes the leaf-card cutout into BC.a for these.
    #
    # 3. Otherwise NO alpha. UE often bakes SSS / detail / vertex-blend
    #    weights into the BC alpha channel of solid surfaces (Roots,
    #    Trunk, Rocks) — wiring those as alpha makes ~half the
    #    geometry vanish at MASK threshold 0.5 (verified: Roots without
    #    its mask was eating chunks of the tree).
    short_low = mat.name.split(".")[0].lower()
    is_foliage_mat = any(p in short_low for p in (
        "needle", "leaf", "leaves", "branch", "fallen", "fern"))
    bc_path = _TEX_INDEX.get(by_slot.get("basecolor", ""))
    if "alpha" in by_slot:
        a_path = _TEX_INDEX.get(by_slot["alpha"])
        if a_path is not None:
            img = bpy.data.images.load(str(a_path), check_existing=True)
            img.colorspace_settings.name = "Non-Color"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            nt.links.new(tex.outputs["Color"],
                principled.inputs["Alpha"])
            mat.blend_method = "CLIP"
    elif is_foliage_mat and bc_path is not None and _png_has_alpha(bc_path):
        # Foliage material + BC has alpha → use BC.a as cutout.
        # Find the existing BC TEX_IMAGE node (loaded above).
        bc_node = next((n for n in nt.nodes if n.type == "TEX_IMAGE"
            and n.image is not None
            and Path(bpy.path.abspath(n.image.filepath)).name == bc_path.name),
            None)
        if bc_node is not None:
            nt.links.new(bc_node.outputs["Alpha"],
                principled.inputs["Alpha"])
            mat.blend_method = "CLIP"
    # Normal.
    if "normal" in by_slot:
        n_path = _TEX_INDEX.get(by_slot["normal"])
        if n_path is not None:
            img = bpy.data.images.load(str(n_path), check_existing=True)
            img.colorspace_settings.name = "Non-Color"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(tex.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"],
                principled.inputs["Normal"])
    # ORM (Occlusion/Roughness/Metallic packed) → G→Roughness only.
    # We DO NOT wire B→Metallic, even though that's the textbook
    # interpretation. UE's MM_Foliage / MM_Layered_Rock master
    # materials repurpose the B channel as a non-metallic mask
    # (vertex blend weight, SSS strength, custom blend layer),
    # not actual metallicness — verified across pine_01_ORM (B=185)
    # and Rock_Jagged_ORM (B=235), neither of which should render
    # as metal. Leaving Metallic input unlinked = stays at the
    # default 0 we set above.
    if "orm" in by_slot:
        orm_path = _TEX_INDEX.get(by_slot["orm"])
        if orm_path is not None:
            img = bpy.data.images.load(str(orm_path), check_existing=True)
            img.colorspace_settings.name = "Non-Color"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            sep = nt.nodes.new("ShaderNodeSeparateColor")
            nt.links.new(tex.outputs["Color"], sep.inputs["Color"])
            nt.links.new(sep.outputs["Green"],
                principled.inputs["Roughness"])
    elif "roughness" in by_slot:
        r_path = _TEX_INDEX.get(by_slot["roughness"])
        if r_path is not None:
            img = bpy.data.images.load(str(r_path), check_existing=True)
            img.colorspace_settings.name = "Non-Color"
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = img
            nt.links.new(tex.outputs["Color"],
                principled.inputs["Roughness"])
    return True


def _force_non_metallic_default(mat: bpy.types.Material) -> None:
    """Set Metallic input default to 0 when not driven by a texture.
    Needed because Blender's FBX importer leaves Metallic at default
    1.0 and glTF inherits that. Tree assets are never metallic."""
    if not mat.use_nodes or mat.node_tree is None:
        return
    principled = next((n for n in mat.node_tree.nodes
        if n.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        return
    if not principled.inputs["Metallic"].is_linked:
        principled.inputs["Metallic"].default_value = 0.0


# ---- import + scene ops -------------------------------------------


def _reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _format_lod_filename(
    variant: str, lod: int | None, cat: Category,
) -> list[str]:
    """Build candidate FBX filenames (without extension) for this
    variant + LOD. Returns a list because some categories have
    irregular naming for LOD0 (e.g. `forest_ground_debris_01.fbx`
    has no LOD suffix at LOD0)."""
    if lod is None:
        return [variant]
    primary = f"{variant}{cat.lod_suffix.format(lod=lod)}{cat.lod_extra}"
    out = [primary]
    # ground_debris special case: LOD0 has NO suffix.
    if cat.name == "ground_debris" and lod == 0:
        out.insert(0, variant)
    return out


def _find_lod_fbx(
    variant: str, lod: int | None, cat: Category,
) -> Path | None:
    fbx_subdir = (cat.fbx_subdir or cat.name)
    vn = variant.split("_")[-1]
    fbx_subdir_resolved = fbx_subdir.replace("{vn}", vn) \
        .replace("{variant}", variant)
    base_dir = SRC_DIR / fbx_subdir_resolved
    extensions = (".obj", ".OBJ") if cat.obj_source else (".fbx", ".FBX")
    for stem in _format_lod_filename(variant, lod, cat):
        for ext in extensions:
            candidate = base_dir / f"{stem}{ext}"
            if candidate.exists():
                return candidate
    return None


_UE_COLLISION_PREFIXES = ("UCX_", "UBX_", "USP_", "UCP_", "UCH_")
"""UE convention prefixes for collision-proxy meshes embedded in FBX
exports: convex hulls, boxes, spheres, capsules. They're invisible
at runtime in UE but get exported as plain geometry by the FBX
exporter. We strip them on import so they don't appear as floating
broken-looking shapes around the actual mesh (rock_01 ships 10
UCX_rock_01_NN convex hulls plus the rock itself)."""


def _import_lod(
    variant: str, lod: int | None, cat: Category,
) -> bpy.types.Object | None:
    src = _find_lod_fbx(variant, lod, cat)
    if src is None:
        suffix = "" if lod is None else f"_LOD{lod}"
        print(f"  [skip] {variant}{suffix}: FBX not found")
        return None
    before = set(bpy.data.objects)
    if cat.obj_source:
        # OBJ ships Y-up by default for many DCCs; keeping import_pack
        # default (which doesn't use bake_space_transform). The
        # `forward_axis`/`up_axis` defaults match the Z-up convention
        # we want post-import.
        bpy.ops.wm.obj_import(filepath=str(src),
            forward_axis="NEGATIVE_Z", up_axis="Y",
            global_scale=cat.import_scale)
    else:
        # bake_space_transform=True puts the mesh upright in Blender.
        # UE-exported FBXs come in rotated 90° around X without this.
        bpy.ops.import_scene.fbx(filepath=str(src),
            bake_space_transform=True)
    new_objs = [o for o in bpy.data.objects if o not in before]
    # Drop UE collision proxy meshes before any further processing.
    collision = [o for o in new_objs if o.type == "MESH"
        and any(o.name.startswith(p) for p in _UE_COLLISION_PREFIXES)]
    if collision:
        for o in collision:
            bpy.data.objects.remove(o, do_unlink=True)
        new_objs = [o for o in new_objs if o not in collision]
    # Bake parent transforms into vertex data BEFORE joining. Different
    # LODs ship with different parent-empty rotations / scales, and
    # joining preserves the active mesh's parent. CLEAR_KEEP_TRANSFORM
    # bakes the world transform into mesh data and unparents.
    bpy.ops.object.select_all(action="DESELECT")
    parented_meshes = [o for o in new_objs
        if o.type == "MESH" and o.parent is not None]
    if parented_meshes:
        for obj in parented_meshes:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = parented_meshes[0]
        bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    new_meshes = [o for o in new_objs if o.type == "MESH"]
    if not new_meshes:
        return None
    bpy.ops.object.select_all(action="DESELECT")
    for obj in new_meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = new_meshes[0]
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    # Apply any leftover scale / rotation / location. Pine LOD0 ships
    # with a 10× scale on its parent empty that the other LODs don't
    # have — without this the LODs render at different sizes.
    bpy.ops.object.transform_apply(
        location=True, rotation=True, scale=True)
    # Leave the mesh in Blender's native Z-up orientation. The glTF
    # exporter's `export_yup=True` will write a per-node -90° X
    # rotation that the consumer (Godot, TreeScatter, FoliageSpecies)
    # composes into mesh global_transform.basis — meshes end up
    # upright in glTF Y-up world. Pre-rotating here would put height
    # along Blender Y, then export_yup would map Blender Y → glTF
    # -Z, leaving every asset visibly tipped on its side.
    lod_label = "" if lod is None else f"_LOD{lod}"
    joined.name = f"{variant}{lod_label}"
    if joined.data is not None:
        joined.data.name = f"{variant}{lod_label}_mesh"
    return joined


def _wire_all_materials(variant: str, cat: Category) -> None:
    n_wired = 0
    for mat in bpy.data.materials:
        if _wire_material_from_mat(mat, variant, cat):
            n_wired += 1
        _force_non_metallic_default(mat)
    print(f"  [mats] wired textures on {n_wired}/{len(bpy.data.materials)}")


def _fix_degenerate_uvs() -> None:
    """Detect meshes whose UV0 collapses to a single point per
    material slot (the FBX artist signals "this material uses
    world-space UVs in UE") and regenerate UVs via cube projection
    so the texture actually tiles across the geometry instead of
    sampling one pixel.

    Without this fix, primitives like Rocks / Roots / Fallen_Needles
    on the on-rock pine variants render as flat dark blobs — the
    wired BC texture samples one corner of the image. UE's
    `MM_Layered_Rock` and `MM_Foliage` master materials don't use
    mesh UVs for these layers; they compute UVs from world XYZ via
    triplanar projection in the shader. Replicating triplanar in
    glTF would need a custom shader per asset; cube projection is
    a pragmatic stand-in that gets the texture visible across the
    surface.

    Detection is name-agnostic — we check every material slot's
    UV span and only project when the slot is genuinely degenerate.
    Safer than maintaining a name allowlist (Fallen_Needles was the
    one I missed first pass)."""
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        mesh = o.data
        if mesh is None or not mesh.uv_layers:
            continue
        # Pull every face's loops + UVs in bulk. We scan EVERY face
        # (not just the first 30) — early-exit triggers false-positive
        # cube projection on branch / foliage cards with mixed UVs
        # (the artist can tag a few specific leaf clusters as world-
        # space while the rest use the leaf atlas). Cube-projecting
        # those wraps leaf textures into stretched broken patches in
        # the canopy. `foreach_get` is the only viable loop here —
        # per-element access via `uv_layer[i].uv.x` is ~100× slower
        # because each attribute crosses a Python<->C boundary.
        uv_layer = mesh.uv_layers.active.data
        n_loops = len(mesh.loops)
        uv_flat = [0.0] * (n_loops * 2)
        uv_layer.foreach_get("uv", uv_flat)
        # poly.material_index is the same for every loop of that
        # poly; build a per-loop slot index by iterating polygons.
        slot_min_u: dict[int, float] = {}
        slot_max_u: dict[int, float] = {}
        slot_min_v: dict[int, float] = {}
        slot_max_v: dict[int, float] = {}
        for poly in mesh.polygons:
            slot_idx = poly.material_index
            for li in poly.loop_indices:
                u = uv_flat[li * 2]
                v = uv_flat[li * 2 + 1]
                if slot_idx not in slot_min_u:
                    slot_min_u[slot_idx] = slot_max_u[slot_idx] = u
                    slot_min_v[slot_idx] = slot_max_v[slot_idx] = v
                else:
                    if u < slot_min_u[slot_idx]: slot_min_u[slot_idx] = u
                    if u > slot_max_u[slot_idx]: slot_max_u[slot_idx] = u
                    if v < slot_min_v[slot_idx]: slot_min_v[slot_idx] = v
                    if v > slot_max_v[slot_idx]: slot_max_v[slot_idx] = v
        slots_to_fix: list[int] = []
        for slot_idx, slot in enumerate(o.material_slots):
            if slot.material is None or slot_idx not in slot_min_u:
                continue
            u_span = slot_max_u[slot_idx] - slot_min_u[slot_idx]
            v_span = slot_max_v[slot_idx] - slot_min_v[slot_idx]
            if u_span < 0.01 and v_span < 0.01:
                slots_to_fix.append(slot_idx)
        if not slots_to_fix:
            continue
        # Regenerate UVs via cube projection on the offending faces.
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="DESELECT")
        bpy.ops.object.mode_set(mode="OBJECT")
        for poly in mesh.polygons:
            poly.select = poly.material_index in slots_to_fix
        bpy.ops.object.mode_set(mode="EDIT")
        # cube_size=2.0 → texture tiles approximately every 2 m,
        # which gives natural-looking rock surfaces across boulder-
        # scale geometry. Tune if rocks come out too tiled / too
        # stretched.
        bpy.ops.uv.cube_project(cube_size=2.0)
        bpy.ops.object.mode_set(mode="OBJECT")
        slot_names = [o.material_slots[i].material.name
            for i in slots_to_fix]
        print(f"    [uv-fix] {o.name}: re-projected {slot_names}")


def _normalize_for_export() -> None:
    """Final-pass cleanup before glTF export. Three jobs:

    (1) Drop FBX-import root EMPTY objects. The mesh hierarchy was
        already collapsed during import (parent_clear + join), so
        these empties are orphaned — but Blender's glTF exporter
        still writes them as nodes with FBX-derived rotations, and
        sometimes adds compensating per-mesh transforms.

    (2) Re-anchor each mesh: shift verts so X+Y are bbox-centered
        and Z is anchored at the BASE (z_min=0). Z is "up" in
        Blender — anchoring at the base means the asset's
        ground-level contact is at z=0, so when scattered at world
        (wx, terrain_y, wz) the asset sits ON the surface instead of
        floating with its centroid at ground level.

    (3) Replace every mesh data-block with a fresh copy via bmesh.
        Blender's glTF exporter has a long-standing bug where it
        writes garbage per-node translations + rotations on joined
        meshes that retain any FBX-import lineage (verified with
        fern_02: LOD0 exports with identity transform, LOD1/LOD2
        export with non-identity translations like (0.485, ...) —
        even though every Blender-side property reads as zero).
        Cloning mesh data through bmesh strips whatever internal
        flag confuses the exporter. Without this step every multi-
        LOD asset has its non-LOD0 meshes rendered offset (visible
        as "disjoint" / "tripled-up" geometry).
    """
    # 1. Drop empties.
    empties = [o for o in bpy.data.objects if o.type == "EMPTY"]
    for o in empties:
        bpy.data.objects.remove(o, do_unlink=True)
    # 2. Re-anchor verts. ALL LODs of one asset must use the SAME
    # anchor (taken from LOD0 — the canonical "original" mesh) — if
    # we anchored each LOD independently, sub-cm bbox differences
    # between simplified LODs would put them at slightly different
    # world Y positions, and the preview / overlapping-LOD render
    # shows the misalignment as detached fringe geometry.
    mesh_objs = [o for o in bpy.data.objects if o.type == "MESH"]
    # Pick LOD0 as the canonical anchor source (or first mesh if no
    # LOD0).
    anchor_obj = next(
        (o for o in mesh_objs if "_LOD0" in o.name), None) or (
        mesh_objs[0] if mesh_objs else None)
    if anchor_obj is not None and anchor_obj.data.vertices:
        xs = [v.co.x for v in anchor_obj.data.vertices]
        ys = [v.co.y for v in anchor_obj.data.vertices]
        zs = [v.co.z for v in anchor_obj.data.vertices]
        anchor_cx = (min(xs) + max(xs)) / 2
        anchor_cy = (min(ys) + max(ys)) / 2
        anchor_cz_min = min(zs)
    else:
        anchor_cx = anchor_cy = anchor_cz_min = 0.0
    for o in mesh_objs:
        if not o.data.vertices:
            continue
        for v in o.data.vertices:
            v.co.x -= anchor_cx
            v.co.y -= anchor_cy
            v.co.z -= anchor_cz_min
        o.location = (0.0, 0.0, 0.0)
        o.rotation_euler = (0.0, 0.0, 0.0)
        o.scale = (1.0, 1.0, 1.0)
    # 3. Fresh-data clone via bmesh + per-LOD X offset. The LOD
    # offset makes the GLB previewer show LOD0/LOD1/LOD2/LOD3 as
    # FOUR separate trees lined up in a row instead of overlapping
    # at the origin (which makes the asset look like a pile of
    # detached cards because LOD silhouettes don't perfectly match).
    # TreeScatter uses `mi.global_transform.basis` (rotation only)
    # — translation is ignored — so the offset doesn't affect the
    # in-game placement. Same convention as the Fab Doug Fir GLBs
    # (LOD1 at z=-10, LOD2 at z=-20).
    import bmesh, re
    old_objs = [o for o in bpy.data.objects if o.type == "MESH"]
    # Compute per-asset X width so LODs spread without overlapping.
    if old_objs and old_objs[0].data.vertices:
        bb_xs = [v.co.x for v in old_objs[0].data.vertices]
        lod_x_step = max(2.0, (max(bb_xs) - min(bb_xs)) * 1.2)
    else:
        lod_x_step = 5.0
    for old in old_objs:
        old_name = old.name
        old_mesh_name = old.data.name
        new_mesh = bpy.data.meshes.new(old_mesh_name + "__fresh")
        bm = bmesh.new()
        bm.from_mesh(old.data)
        bm.to_mesh(new_mesh)
        bm.free()
        # Materials are per-mesh-data; copy them across.
        for m in old.data.materials:
            new_mesh.materials.append(m)
        new_obj = bpy.data.objects.new(old_name + "__fresh", new_mesh)
        bpy.context.scene.collection.objects.link(new_obj)
        bpy.data.objects.remove(old, do_unlink=True)
        # Restore original names (after the old object is deleted so
        # there's no naming collision).
        new_obj.name = old_name
        new_mesh.name = old_mesh_name
        # Offset by LOD index in X.
        m = re.search(r"_LOD(\d+)", new_obj.name)
        if m is not None:
            new_obj.location.x = int(m.group(1)) * lod_x_step


def _downsize_images(max_size: int) -> None:
    for img in bpy.data.images:
        if img.size[0] == 0 or img.size[1] == 0:
            continue
        new_w, new_h = img.size[0], img.size[1]
        while new_w > max_size or new_h > max_size:
            new_w = max(1, new_w // 2)
            new_h = max(1, new_h // 2)
        if (new_w, new_h) != tuple(img.size):
            img.scale(new_w, new_h)


# ---- export + GLB post-processing --------------------------------


FOLIAGE_MATERIAL_PATTERNS = (
    "needle", "leaf", "leaves", "branch", "fallen", "fern",
    "grass", "debris", "patch", "moss",
)
"""Material-name substrings (lowercase) that mark a material as alpha-
cutout foliage. Forces alphaMode=MASK in the GLB regardless of what
Blender wrote. Trunk / Rocks / Roots / etc. don't match and stay
OPAQUE (or MASK if they have an alpha channel — we look at the
linked alpha texture)."""


def _patch_glb_alpha_modes(glb_path: Path, cat: Category) -> None:
    """Two GLB material post-processes:

    (1) Force alphaMode + alphaCutoff per material. Blender 5.x's
        glTF exporter writes BLEND on any material with a connected
        Alpha input regardless of `mat.surface_render_method`, and
        BLEND is wrong for both solid surfaces (rocks → olive blobs)
        and foliage cutouts (sorting artifacts on overlapping cards).
        Foliage → MASK, solid → OPAQUE by material-name pattern.

    (2) Force metallicFactor=0 on every material. None of the assets
        in this pack are actually metal (rock, wood, bark, foliage),
        but Blender's gltf exporter defaults metallicFactor=1 when
        a metallicRoughnessTexture is present — even when our
        Principled BSDF Metallic input isn't linked to the texture's
        B channel. Without this override, rocks + roots look like
        flat dark mirrors instead of textured stone (the surface
        BC color gets dominated by reflection)."""
    with glb_path.open("rb") as f:
        data = f.read()
    if data[:4] != b"glTF":
        return
    json_chunk_len = int.from_bytes(data[12:16], "little")
    json_bytes = data[20:20 + json_chunk_len]
    j = json.loads(json_bytes.rstrip().decode("utf-8"))
    n_mask, n_opaque = 0, 0
    for mat in j.get("materials", []):
        name_low = mat.get("name", "").lower()
        prev_mode = mat.get("alphaMode", "OPAQUE")
        # Trust Blender's choice when it picked MASK or BLEND with
        # an explicit alphaCutoff — that means the source texture had
        # an alpha channel and `_wire_material_from_mat` linked it.
        # We must NOT override to OPAQUE based on material name (that
        # bug was making `Roots` on the on-rock pines render as solid
        # dark cards instead of alpha-cutout root tendrils — UE
        # ships `T_Roots_BC` as RGBA with the cutout in the alpha
        # channel). For BLEND specifically, downgrade to MASK because
        # BLEND causes sorting artifacts on overlapping foliage.
        if prev_mode == "MASK":
            mat["alphaCutoff"] = cat.alpha_cutoff
            n_mask += 1
        elif prev_mode == "BLEND":
            mat["alphaMode"] = "MASK"
            mat["alphaCutoff"] = cat.alpha_cutoff
            n_mask += 1
        else:
            # Blender chose OPAQUE (no alpha link). Honor name-based
            # heuristic: foliage material names default to MASK
            # (handles the case where Blender's gltf exporter
            # accidentally drops the alpha channel on a foliage card).
            is_foliage = any(p in name_low for p in FOLIAGE_MATERIAL_PATTERNS)
            if cat.foliage and not is_foliage:
                solid_patterns = ("trunk", "rock", "root", "wood",
                    "bark", "stone", "soil")
                if not any(p in name_low for p in solid_patterns):
                    is_foliage = True
            if is_foliage:
                mat["alphaMode"] = "MASK"
                mat["alphaCutoff"] = cat.alpha_cutoff
                n_mask += 1
            else:
                mat["alphaMode"] = "OPAQUE"
                mat.pop("alphaCutoff", None)
                n_opaque += 1
        pbr = mat.setdefault("pbrMetallicRoughness", {})
        pbr["metallicFactor"] = 0.0
    new_json = json.dumps(j, separators=(",", ":")).encode()
    pad = (4 - len(new_json) % 4) % 4
    new_json += b" " * pad
    new_chunk_len = len(new_json)
    bin_chunk_start = 20 + json_chunk_len
    bin_chunk = data[bin_chunk_start:]
    total_len = 12 + 8 + new_chunk_len + len(bin_chunk)
    out = bytearray()
    out += b"glTF"
    out += (2).to_bytes(4, "little")
    out += total_len.to_bytes(4, "little")
    out += new_chunk_len.to_bytes(4, "little")
    out += b"JSON"
    out += new_json
    out += bin_chunk
    glb_path.write_bytes(bytes(out))
    print(f"  [glb] alphaMode → {n_mask} MASK, {n_opaque} OPAQUE")


def _export_variant(variant: str, cat: Category) -> Path:
    out_dir = DST_ROOT / cat.name
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{variant}.glb"
    _fix_degenerate_uvs()
    _normalize_for_export()
    max_size = cat.max_tex_size or MAX_TEX_SIZE_DEFAULT
    _downsize_images(max_size)
    bpy.ops.export_scene.gltf(
        filepath=str(out_path),
        export_format="GLB",
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
        export_image_format=cat.image_format,
        export_jpeg_quality=85,
    )
    _patch_glb_alpha_modes(out_path, cat)
    return out_path


# ---- main --------------------------------------------------------


def convert_category(cat: Category) -> int:
    print(f"\n=== {cat.name} ({len(cat.variants)} variants) ===")
    n_done = 0
    for variant in cat.variants:
        print(f"--- {variant} ---")
        _reset_scene()
        any_imported = False
        for lod in cat.lods:
            obj = _import_lod(variant, lod, cat)
            if obj is not None:
                any_imported = True
        if not any_imported:
            print(f"  [skip] no LODs found for {variant}")
            continue
        _wire_all_materials(variant, cat)
        out = _export_variant(variant, cat)
        size_kb = out.stat().st_size / 1024
        print(f"  [done] {out.relative_to(REPO_ROOT)} ({size_kb:.0f} KB)")
        n_done += 1
    return n_done


def main() -> int:
    # CLI args (after `--`): list of category names. Empty = all.
    args = sys.argv[1:]
    if args:
        unknown = set(args) - set(CATEGORIES)
        if unknown:
            print(f"[fatal] unknown categories: {unknown}")
            print(f"        available: {sorted(CATEGORIES)}")
            return 1
        targets = [CATEGORIES[a] for a in args]
    else:
        targets = list(CATEGORIES.values())
    # Only require TEX_DIR / SRC_DIR if at least one target needs them
    # (i.e. uses .mat-based wiring, not direct texture mapping).
    needs_umodel = any(not c.direct_material_textures for c in targets)
    if needs_umodel:
        if not TEX_DIR.exists():
            print(f"[fatal] {TEX_DIR} doesn't exist — run umodel extract")
            return 1
        if not SRC_DIR.exists():
            print(f"[fatal] {SRC_DIR} doesn't exist — extract FBX rar")
            return 1
    # Build the texture index using the union of all selected
    # categories' texture_dir overrides (so non-UE packs find their
    # textures alongside the umodel-extracted PNGs).
    extra_dirs = [Path(c.texture_dir) for c in targets if c.texture_dir]
    _build_texture_index(extra_dirs)
    total = 0
    for cat in targets:
        total += convert_category(cat)
    print(f"\n[summary] converted {total} variants")
    return 0


if __name__ == "__main__":
    # Truncate Blender's own argv. Anything before `--` is Blender's
    # CLI; anything after is ours. Without `--` there are no script
    # args (just Blender invocation flags).
    if "--" in sys.argv:
        sys.argv = [sys.argv[0]] + sys.argv[sys.argv.index("--") + 1:]
    else:
        sys.argv = [sys.argv[0]]
    sys.exit(main())
