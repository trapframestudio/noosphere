#!/usr/bin/env python3
"""Extract every mesh asset from Superhive's TrashKit.blend as a .glb.

Run with::

    blender --background --python scripts/extract_trashkit.py -- \\
        --src asset_downloads/Superhive/TrashKit_BLENDER_1.2/TrashKit.blend \\
        --dst godot/assets/models/trash/extracted

The extractor walks every collection in the source .blend, finds mesh
objects that look like leaf assets (i.e. not the geometry-nodes scaffolding,
not the lighting / camera rig), and exports each one as a standalone
.glb with embedded textures. Output filenames are
``<collection>__<object_name>.glb`` so the scatter triage step can sort
by category easily.

This is meant to run once per kit refresh. The output GLBs are NOT
committed wholesale — the curation step picks the scatter-suitable
subset and copies them into ``godot/assets/models/trash/`` proper.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import bpy


# Collections we DO NOT export — scaffolding, not trash assets, or
# handled by other systems (grass via ground_cover, geometry-node
# scaffolding, lighting / camera rigs).
SKIP_COLLECTIONS = {
    "Master Collection",
    "RenderCollection",
    "Scene Collection",
    "Lighting",
    "Cameras",
    "Work",
    "_TrashKIt + GeoNodes",
    "Grass_Assets",
    "trashkit_geonodes",
}

# Per-collection name remapping for cleaner filenames. Actual
# collection names from the .blend (snake_case _Assets suffixes).
COLLECTION_RENAME = {
    "Bags_Assets": "bags",
    "Barrels_Assets": "barrels",
    "Base_Trash_Assets": "base",
    "Bottles_Assets": "bottles",
    "Boxes_Assets": "boxes",
    "Buckets_Assets": "buckets",
    "Cans_Assets": "cans",
    "Cans_Paint_Assets": "cans_paint",
    "Container_Debris": "container_debris",
    "GarbageBin_Big_Metal": "bin_big_metal",
    "GarbageBin_Metal": "bin_metal",
    "GarbageBins_Plastic": "bin_plastic",
    "Generic_Trash_Assets": "generic",
    "Pallets_Wood": "pallets",
    "Prefabs_Large_Assets": "prefab_lg",
    "Prefabs_Medium_Assets": "prefab_md",
    "Prefabs_SmallTrash_Assets": "prefab_sm",
    "Rubble_Assets": "rubble",
    "Smokables_Assets": "smokables",
    "Tires_Assets": "tires",
    "Wood_Splinter_Assets": "wood",
}


SAFE_NAME_RE = re.compile(r"[^a-zA-Z0-9_\-]+")


def safe_name(s: str) -> str:
    """Sanitize a name for use in a filename."""
    s = s.strip().lower()
    s = SAFE_NAME_RE.sub("_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def collection_path(coll: bpy.types.Collection,
                    parent_chain: list[str] | None = None) -> list[str]:
    """Return collection name chain from root (excluding the scene-level
    'Master Collection' / 'Scene Collection')."""
    chain = list(parent_chain or [])
    chain.append(coll.name)
    return chain


def walk_collections(coll: bpy.types.Collection,
                     out: list[tuple[bpy.types.Collection, list[str]]],
                     chain: list[str] | None = None) -> None:
    """Depth-first walk; emit (collection, name-chain) pairs."""
    next_chain = collection_path(coll, chain)
    out.append((coll, next_chain))
    for child in coll.children:
        walk_collections(child, out, next_chain)


def is_leaf_mesh(obj: bpy.types.Object) -> bool:
    """A leaf mesh is a real geometry-bearing mesh object — skip lights,
    cameras, empties, armatures, etc.; skip mesh objects that have zero
    polygons (occasionally placeholders / proxies)."""
    if obj.type != "MESH":
        return False
    if obj.data is None:
        return False
    if len(obj.data.polygons) == 0:
        return False
    return True


def find_leaf_collection(obj: bpy.types.Object) -> str | None:
    """Return the deepest collection name `obj` is a member of, falling
    back to the immediate parent chain. Returns None if the object lives
    in a skipped collection."""
    cols = obj.users_collection
    if not cols:
        return None
    for c in cols:
        if c.name in SKIP_COLLECTIONS:
            continue
        return c.name
    return None


def export_glb(obj: bpy.types.Object, out_path: Path) -> bool:
    """Export a single object as .glb with external texture URIs.

    Textures are written once to a sibling `textures/` directory shared
    across all GLBs (Blender naming-collision logic dedupes), so 60
    GLBs that all reference the same Trash atlas don't each carry a
    5 MB embedded copy.

    `export_keep_originals=True` requires the textures to live on disk
    somewhere the exporter can reach. We unpack `bpy.data.images` to a
    temp directory once before the first export and reuse for all.
    """
    # Hide everything else; un-hide just `obj`.
    saved_visibility = {}
    for o in bpy.data.objects:
        saved_visibility[o.name] = (o.hide_viewport, o.hide_render, o.hide_select)
        o.hide_viewport = True
        o.hide_render = True
        o.hide_select = False
    obj.hide_viewport = False
    obj.hide_render = False
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    out_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        bpy.ops.export_scene.gltf(
            filepath=str(out_path),
            export_format="GLB",
            use_selection=True,
            export_yup=True,
            export_apply=True,
            export_materials="EXPORT",
            # Embed textures inside each GLB. Tried `export_keep_originals=True`
            # for shared external textures but the .blend has them packed and
            # the unpack-then-move pipeline was finicky. Trade ~5 MB/GLB
            # disk for self-contained models — only ~50 of these end up in
            # godot/ after curation, total ~250 MB. Acceptable for LFS.
            export_image_format="AUTO",
            export_animations=False,
            export_skins=False,
            export_morph=False,
            export_extras=False,
            export_lights=False,
            export_cameras=False,
        )
        ok = True
    except Exception as exc:
        print(f"  FAIL {obj.name}: {exc}", file=sys.stderr)
        ok = False
    # Restore visibility so subsequent exports can find their objects.
    for name, vis in saved_visibility.items():
        o = bpy.data.objects.get(name)
        if o is None:
            continue
        o.hide_viewport, o.hide_render, o.hide_select = vis
    return ok


def _unused_unpack_textures_to(textures_dir: Path) -> None:
    """Unpack every packed image in the .blend file to `textures_dir`.

    TrashKit packs all textures inside the .blend; without unpacking,
    `export_keep_originals=True` produces GLBs with zero image
    references because the exporter can't resolve any on-disk path.

    Uses `image.unpack(method='WRITE_LOCAL')` to write each packed
    image to the .blend's local `textures/` directory; we then move
    them into our target dir.
    """
    textures_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    failed = 0
    for img in bpy.data.images:
        # Skip render results, viewer nodes, generated procedurals.
        if img.source not in {"FILE", "SEQUENCE"}:
            continue
        if img.size[0] == 0 and img.size[1] == 0:
            continue
        if not img.packed_file and img.filepath:
            # Already on disk; copy into our textures dir.
            existing = Path(bpy.path.abspath(img.filepath))
            if existing.exists():
                # Use the existing file's name; downstream GLBs reference
                # its path verbatim.
                continue
        try:
            # Pre-set filepath to inside our target dir so unpack writes
            # there directly. Sanitize name to avoid spaces / colons.
            safe = safe_name(Path(img.name).stem)
            if not safe:
                continue
            ext = ".png"
            nm_lower = img.name.lower()
            if nm_lower.endswith((".jpg", ".jpeg")) or img.file_format == "JPEG":
                ext = ".jpg"
            elif nm_lower.endswith(".webp") or img.file_format == "WEBP":
                ext = ".webp"
            target = textures_dir / f"{safe}{ext}"
            img.filepath_raw = f"//{target.relative_to(textures_dir.parent)}"
            if img.packed_file:
                img.unpack(method="WRITE_LOCAL")
                # WRITE_LOCAL writes next to the .blend, not where we want.
                # Move it.
                blend_dir = Path(bpy.data.filepath).parent
                written = blend_dir / "textures" / Path(img.filepath_raw).name
                if written.exists() and written != target:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    written.replace(target)
                # Update the image's filepath to the new location so the
                # GLB exporter writes the correct relative URI.
                img.filepath = str(target)
                img.filepath_raw = str(target)
            n += 1
        except Exception as exc:
            failed += 1
            print(f"  warn: couldn't unpack image {img.name}: {exc}",
                  file=sys.stderr)
    print(f"Unpacked {n} textures to {textures_dir} (failed: {failed})")


def main() -> int:
    # Strip Blender's own argv before our '--'.
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", required=True, type=Path,
                        help="Source .blend file")
    parser.add_argument("--dst", required=True, type=Path,
                        help="Output directory for individual .glb files")
    parser.add_argument("--dry-run", action="store_true",
                        help="List what would be exported, no writes")
    args = parser.parse_args(argv)

    if not args.src.exists():
        print(f"Source .blend not found: {args.src}", file=sys.stderr)
        return 1

    # Load the source file.
    bpy.ops.wm.open_mainfile(filepath=str(args.src))
    print(f"Loaded {args.src}")

    # Gather collection chain info for nice filenames.
    obj_to_collection: dict[str, str] = {}
    for coll in bpy.data.collections:
        if coll.name in SKIP_COLLECTIONS:
            continue
        for o in coll.objects:
            if o.name not in obj_to_collection:
                obj_to_collection[o.name] = coll.name

    # Iterate every mesh object.
    leaves = [o for o in bpy.data.objects if is_leaf_mesh(o)]
    print(f"Found {len(leaves)} mesh objects in source")

    # Sort by collection then name for stable output ordering.
    def sort_key(o: bpy.types.Object) -> tuple[str, str]:
        c = obj_to_collection.get(o.name, "")
        return (c, o.name)

    leaves.sort(key=sort_key)

    exported = 0
    skipped = 0
    by_category: dict[str, int] = {}
    for obj in leaves:
        coll_name = obj_to_collection.get(obj.name)
        if coll_name is None or coll_name in SKIP_COLLECTIONS:
            skipped += 1
            continue
        cat = COLLECTION_RENAME.get(coll_name, safe_name(coll_name))
        name = safe_name(obj.name)
        out_path = args.dst / cat / f"{name}.glb"
        if args.dry_run:
            print(f"  would export {coll_name}/{obj.name} -> {out_path}")
            exported += 1
            by_category[cat] = by_category.get(cat, 0) + 1
            continue
        ok = export_glb(obj, out_path)
        if ok:
            exported += 1
            by_category[cat] = by_category.get(cat, 0) + 1
            print(f"  ✓ {coll_name}/{obj.name} -> {out_path.relative_to(args.dst.parent)}")
        else:
            skipped += 1

    print()
    print(f"Exported {exported} | Skipped {skipped}")
    print("By category:")
    for cat in sorted(by_category.keys()):
        print(f"  {cat:12s} {by_category[cat]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
