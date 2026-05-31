#!/usr/bin/env -S blender --background --python
"""Generate ``godot/assets/models/trees/tree_cluster_pack.glb``.

A "cluster" is a static mesh containing N (default 10) cross-billboard
quads arranged in a small radius (~25 m). Each quad is a vertical
plane that the cluster shader will texture with a procedural conifer
silhouette. Multiple cross-billboards at varied positions within one
cluster mesh provide PARALLAX as the camera moves — that's what kills
the "flat sticker" look of single-quad billboards.

Why pre-bake instead of building at runtime:
- One MMI per cluster variant renders ALL placed clusters as one
  draw call with GPU instancing.
- Static mesh = zero runtime cost beyond the per-instance transform.
- Per-cluster geometry is identical across instances; placement
  variation comes from per-instance MMI transforms (yaw, scale,
  position) AND the per-quad random arrangement INSIDE the cluster.

Six cluster variants ship by default. The scatter picks one per cell
via per-position hash so adjacent cells get different cluster shapes
even with the same species.

**Run from repo root**::

    blender --background --python scripts/generate_tree_cluster_pack.py

Bundled Blender ships with NumPy. No external deps required.
"""
from __future__ import annotations

import sys
import math
import random
from dataclasses import dataclass
from pathlib import Path

import bpy
import bmesh
import mathutils

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
OUTPUT_PATH = REPO_ROOT / "godot" / "assets" / "models" / "trees" / "tree_cluster_pack.glb"

# Number of cross-billboards per cluster. 8-12 is the sweet spot:
# enough variety/parallax to read as a clump, few enough verts to
# instance cheaply (each cross-billboard = 2 quads = 12 verts, so 10
# quads = 120 verts per cluster).
QUADS_PER_CLUSTER = 10
# Cluster radius — quads are placed within this disk around origin.
# 25m matches typical "you can pick out a single tree" distance for
# our 800-2200m cluster band.
CLUSTER_RADIUS_M = 25.0
# Per-quad height variation. Real PNW conifers are 15-30m tall; we
# vary within a cluster so trees aren't all identical height.
QUAD_HEIGHT_MIN = 14.0
QUAD_HEIGHT_MAX = 26.0
# Per-quad width as fraction of height. Conifers taper, so width
# ~30% of height is typical.
QUAD_WIDTH_FRACTION = 0.3

NUM_VARIANTS = 6
SEED_BASE = 7300


@dataclass
class ClusterVariant:
    name: str
    seed: int
    quad_count: int = QUADS_PER_CLUSTER


VARIANTS = tuple(
    ClusterVariant(f"cluster_v{i}", seed=SEED_BASE + i * 100)
    for i in range(NUM_VARIANTS)
)


def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build_cluster(variant: ClusterVariant) -> bpy.types.Object:
    """Build one cluster mesh with `variant.quad_count` cross-billboards
    at random positions / rotations / sizes within ``CLUSTER_RADIUS_M``.

    Cross-billboard = two perpendicular quads (XY plane + YZ plane).
    Both share the same world position and dimensions; the pair gives
    visible silhouette from any horizontal angle without requiring
    runtime camera-facing.
    """
    rng = random.Random(variant.seed)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UV")

    for _ in range(variant.quad_count):
        # Random position within disk (rejection-sample for uniform).
        while True:
            px = (rng.random() * 2.0 - 1.0) * CLUSTER_RADIUS_M
            pz = (rng.random() * 2.0 - 1.0) * CLUSTER_RADIUS_M
            if px * px + pz * pz <= CLUSTER_RADIUS_M * CLUSTER_RADIUS_M:
                break
        # Per-quad height + width.
        h = rng.uniform(QUAD_HEIGHT_MIN, QUAD_HEIGHT_MAX)
        w = h * QUAD_WIDTH_FRACTION * rng.uniform(0.85, 1.15)
        hw = w * 0.5
        # Random Y-axis rotation per quad so the cross-billboard pair
        # isn't always axis-aligned.
        yaw = rng.uniform(0.0, math.pi * 2.0)
        rot = mathutils.Matrix.Rotation(yaw, 4, "Y")
        center = mathutils.Vector((px, 0.0, pz))

        # Cross-billboard plane A (extends along local X, height in Y)
        verts_a = [
            mathutils.Vector((-hw, 0.0, 0.0)),
            mathutils.Vector((hw, 0.0, 0.0)),
            mathutils.Vector((hw, h, 0.0)),
            mathutils.Vector((-hw, h, 0.0)),
        ]
        # Plane B perpendicular to A (along local Z)
        verts_b = [
            mathutils.Vector((0.0, 0.0, -hw)),
            mathutils.Vector((0.0, 0.0, hw)),
            mathutils.Vector((0.0, h, hw)),
            mathutils.Vector((0.0, h, -hw)),
        ]
        for verts in (verts_a, verts_b):
            world_verts = [center + (rot @ v) for v in verts]
            bm_verts = [bm.verts.new(v) for v in world_verts]
            face = bm.faces.new(bm_verts)
            # UVs: x in {0, 1} = left/right, y in {0, 1} = bottom/top.
            uv_coords = [(0, 0), (1, 0), (1, 1), (0, 1)]
            for loop, uv in zip(face.loops, uv_coords):
                loop[uv_layer].uv = uv

    bm.normal_update()

    mesh = bpy.data.meshes.new(variant.name + "_mesh")
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new(variant.name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def main() -> int:
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    reset_scene()

    print(f"[generate_tree_cluster_pack] writing {OUTPUT_PATH}")
    print(f"[generate_tree_cluster_pack] {len(VARIANTS)} variants × "
          f"{QUADS_PER_CLUSTER} cross-billboards = "
          f"{QUADS_PER_CLUSTER * 2 * 4} verts per cluster")

    objs = []
    for variant in VARIANTS:
        obj = build_cluster(variant)
        v_count = len(obj.data.vertices)
        print(f"  {variant.name}: {v_count} verts")
        objs.append(obj)

    # Select all variant objects for export.
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objs:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]

    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT_PATH),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="NONE",
        export_animations=False,
        export_skins=False,
        export_morph=False,
    )

    size_kb = OUTPUT_PATH.stat().st_size / 1024
    print(f"[generate_tree_cluster_pack] wrote {OUTPUT_PATH} ({size_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    if "--" in sys.argv:
        sys.argv = [sys.argv[0]] + sys.argv[sys.argv.index("--") + 1:]
    sys.exit(main())
