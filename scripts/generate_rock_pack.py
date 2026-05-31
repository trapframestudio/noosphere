#!/usr/bin/env -S blender --background --python
"""Generate ``godot/assets/models/rocks/rock_pack.glb``.

Six base rock shapes × three LODs each = 18 MeshInstance3Ds packed
into a single .glb. Naming convention matches the existing tree
LOD parser (``<base_name>_LOD<N>``), so ``RockScatter`` reuses the
same ``_parse_lod_level`` + per-LOD MMI dispatch as ``TreeScatter``.

**Why procedurally generated**: scanned rock meshes (Polyhaven,
Megascans) are 50 K – 2 M verts apiece — way overkill for scatter
rendering at MultiMesh density. We need ~150 verts at LOD0,
~50 at LOD1, ~16 at LOD2. Procedurally generating an icosphere +
simplex noise displace + decimate gives that target poly count
trivially, and the shape variety comes from random seeds + per-
shape param tweaks (elongation, jaggedness, taper).

**Reproducibility**: deterministic seeds — re-running this script
produces byte-identical .glb output. CI / contributors can
regenerate without diff churn.

**Run from repo root**::

    blender --background --python scripts/generate_rock_pack.py

Bundled Blender (4.x) ships with NumPy. No external deps required.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

import bpy
import bmesh
import mathutils

# ---------------------------------------------------------------------------
# Output path — resolves to repo-rooted godot/assets/models/rocks/rock_pack.glb
# regardless of cwd. The script is intended to be run from the repo root, but
# this lets it work from anywhere.
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
OUTPUT_PATH = REPO_ROOT / "godot" / "assets" / "models" / "rocks" / "rock_pack.glb"

# Decimate ratios. The icosphere starts at 162 verts at subdivisions=3,
# 642 at subdivisions=4 (Blender 5.x convention). We build at subdivisions=4
# and decimate down per LOD: 642 × 0.30 ≈ 193, × 0.10 ≈ 64, × 0.04 ≈ 26.
LOD_DECIMATE_RATIOS = (0.30, 0.10, 0.04)  # → ~190, ~64, ~25 verts
LOD_NAMES = ("LOD0", "LOD1", "LOD2")
ICO_SUBDIVISIONS = 4


@dataclass
class RockShape:
    """Procedural-rock parameters, one per base shape in the pack."""

    name: str
    seed: int
    # Anisotropic scale BEFORE noise displacement — lets us produce flat
    # slabs (z=0.4), tall pillars (y=1.6), elongated boulders (x=1.8),
    # etc. without changing the noise field.
    pre_scale: tuple[float, float, float] = (1.0, 1.0, 1.0)
    # Noise displacement strength along each axis, applied per-vertex
    # via simplex noise sampled at the vertex's normal direction.
    noise_strength: float = 0.35
    # Frequency of the simplex noise — higher = more bumps per radian
    # = jagged surface; lower = smooth boulder.
    noise_frequency: float = 1.6
    # Number of octaves for fractal noise. 2 octaves gives one big
    # shape + one small detail layer.
    noise_octaves: int = 2
    # Squash along Y after displacement — values < 1 flatten the rock
    # to look settled on the ground (gravity-pose). 0.65 = good
    # default for small-medium rocks; 1.0 = full sphere for boulders.
    settle_squash: float = 0.7


# Six base shape categories × `VARIANTS_PER_SHAPE` sub-variants per
# category = 18 base shapes total (× 3 LODs each = 54 mesh instances).
# Sub-variants reuse the parent's `pre_scale` / `noise_*` parameters
# but offset the seed by 100, 200, ... → genuinely different geometry
# (different noise field) while staying recognisably the same shape
# family. Variant names follow `<shape>_v<i>` (e.g. `rock_round_v0`,
# `rock_round_v1`, `rock_round_v2`). The scatter parser treats every
# `<species_prefix>_v\d+` as a sub-variant of the species and picks
# one per-instance via stable world-XZ hash, so a single RockSpecies
# transparently uses all 3 sub-variants of its shape.
VARIANTS_PER_SHAPE: int = 3
SHAPE_CATEGORIES: tuple[RockShape, ...] = (
    # Round low boulder — the workhorse. Rounded, settled, modest
    # noise. Ideal for small/medium rocks.
    RockShape("rock_round", seed=1001, pre_scale=(1.0, 0.9, 1.0),
              noise_strength=0.28, noise_frequency=1.4, settle_squash=0.7),
    # Jagged angular shard — looks like a fresh fracture. Higher
    # noise frequency + strength for sharper edges.
    RockShape("rock_jagged", seed=1002, pre_scale=(1.1, 1.0, 0.9),
              noise_strength=0.45, noise_frequency=2.4, settle_squash=0.85),
    # Flat slab — wider on X and Z, squashed on Y. Like a tablet
    # of rock that fell off a cliff face.
    RockShape("rock_slab", seed=1003, pre_scale=(1.5, 0.45, 1.3),
              noise_strength=0.2, noise_frequency=1.2, settle_squash=0.6),
    # Tall pillar — vertical orientation, like a standing stone.
    # Less common; use sparingly via species density.
    RockShape("rock_pillar", seed=1004, pre_scale=(0.8, 1.6, 0.85),
              noise_strength=0.3, noise_frequency=1.8, settle_squash=1.0),
    # Elongated football — wider on X. Useful for clusters where
    # you want directional flow.
    RockShape("rock_oblong", seed=1005, pre_scale=(1.7, 0.85, 0.9),
              noise_strength=0.25, noise_frequency=1.5, settle_squash=0.7),
    # Cluster blob — a bumpy non-uniform shape that reads like
    # multiple rocks fused together. Higher octaves, more chaos.
    RockShape("rock_cluster", seed=1006, pre_scale=(1.3, 1.1, 1.2),
              noise_strength=0.4, noise_frequency=1.9, noise_octaves=3,
              settle_squash=0.75),
)


def expand_variants(categories: tuple[RockShape, ...],
                    variants_per_shape: int) -> tuple[RockShape, ...]:
    """Expand each shape category into N sub-variants with offset seeds.

    Sub-variant naming: `<base_name>_v<i>` for i in [0, N). The seed
    offset is `i * 100` so noise fields differ between variants.
    Setting `variants_per_shape = 1` (or omitting the loop) reproduces
    the original 6-shape pack.
    """
    out: list[RockShape] = []
    for cat in categories:
        for i in range(variants_per_shape):
            out.append(RockShape(
                name=f"{cat.name}_v{i}",
                seed=cat.seed + i * 100,
                pre_scale=cat.pre_scale,
                noise_strength=cat.noise_strength,
                noise_frequency=cat.noise_frequency,
                noise_octaves=cat.noise_octaves,
                settle_squash=cat.settle_squash,
            ))
    return tuple(out)


SHAPES: tuple[RockShape, ...] = expand_variants(
    SHAPE_CATEGORIES, VARIANTS_PER_SHAPE)


def reset_scene() -> None:
    """Clear the default scene so the .glb export only contains our rocks."""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def fractal_noise(p: mathutils.Vector, frequency: float, octaves: int,
                  seed: int) -> float:
    """Sum simplex noise octaves at decreasing amplitude / increasing
    frequency. Returns roughly [-1, 1].

    `mathutils.noise.noise()` is Blender's bundled simplex implementation;
    seed influences the offset so each shape gets a unique field.
    """
    total = 0.0
    amplitude = 1.0
    freq = frequency
    norm = 0.0
    # Seed-derived offset so different RockShape.seed values give
    # different patterns even at the same frequency.
    offset = mathutils.Vector((seed * 0.731, seed * 1.137, seed * 0.519))
    for _ in range(octaves):
        sample = (p * freq) + offset
        # mathutils.noise.noise returns [-1, 1] for a Vector input.
        total += mathutils.noise.noise(sample) * amplitude
        norm += amplitude
        amplitude *= 0.5
        freq *= 2.0
    return total / norm if norm > 0.0 else 0.0


def build_base_mesh(shape: RockShape) -> bpy.types.Object:
    """Create a fresh icosphere → noise-displace → squash → return the object."""
    # Start with a high-res icosphere; we'll decimate down per LOD.
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=ICO_SUBDIVISIONS,
                                          radius=1.0)
    obj = bpy.context.active_object
    obj.name = shape.name + "_BASE"
    mesh = obj.data

    bm = bmesh.new()
    bm.from_mesh(mesh)

    # Pre-scale the sphere along each axis (anisotropic) BEFORE noise
    # displacement so the noise field follows the squashed/elongated
    # shape rather than producing a noised sphere then squashing.
    for v in bm.verts:
        v.co.x *= shape.pre_scale[0]
        v.co.y *= shape.pre_scale[1]
        v.co.z *= shape.pre_scale[2]

    # Noise-displace each vertex along its outward normal (= radial
    # direction from origin since this is an icosphere).
    for v in bm.verts:
        if v.co.length < 1e-5:
            continue
        radial = v.co.normalized()
        # Sample noise field at the vertex position. Push outward by
        # `noise_strength * sample`. Ensure non-negative scaling so
        # the rock doesn't invert itself.
        sample = fractal_noise(v.co, shape.noise_frequency,
                               shape.noise_octaves, shape.seed)
        push = 1.0 + sample * shape.noise_strength
        v.co += radial * (push - 1.0)

    # Settle squash — flatten on Y so the rock looks gravity-posed
    # (settled flat-side-down on the ground).
    if shape.settle_squash != 1.0:
        for v in bm.verts:
            v.co.y *= shape.settle_squash

    # Smooth normals so the lit surface looks rocky-smooth, not faceted
    # (faceted = low-poly look at LOD0 too, even before decimate).
    # Per-edge normals get split during decimate so LOD1/LOD2 will
    # naturally read as more faceted.
    bm.normal_update()

    # UV unwrap — sphere projection. Rocks have noisy textures; seam
    # artifacts at the projection back-side are invisible.
    bmesh.ops.transform(bm, matrix=mathutils.Matrix.Identity(4),
                        verts=bm.verts)

    bm.to_mesh(mesh)
    bm.free()

    # Switch to edit mode briefly to do the sphere UV unwrap (the
    # bmesh API doesn't expose UV unwrap directly).
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.sphere_project()
    bpy.ops.object.mode_set(mode='OBJECT')

    # Recompute normals (smooth shading by default; the visual roughness
    # comes from the displaced geometry, not faceted normals).
    bpy.ops.object.shade_smooth()
    return obj


def build_lod(base_obj: bpy.types.Object, shape: RockShape,
              lod_idx: int) -> bpy.types.Object:
    """Duplicate the base mesh and apply a Decimate modifier per the LOD ratio.

    Returns the new object with the decimated mesh + a name following
    the ``<base>_LOD<N>`` convention the scatter expects.
    """
    bpy.ops.object.select_all(action='DESELECT')
    base_obj.select_set(True)
    bpy.context.view_layer.objects.active = base_obj
    bpy.ops.object.duplicate()
    dup = bpy.context.active_object
    dup.name = f"{shape.name}_{LOD_NAMES[lod_idx]}"

    # Apply a Decimate modifier at the LOD's ratio. COLLAPSE mode
    # gives smooth-but-lossy reduction; angle limit (alternative)
    # would preserve hard edges, but rocks don't have those.
    decimate = dup.modifiers.new(name="Decimate", type='DECIMATE')
    decimate.decimate_type = 'COLLAPSE'
    decimate.ratio = LOD_DECIMATE_RATIOS[lod_idx]
    bpy.ops.object.modifier_apply(modifier=decimate.name)

    return dup


def main() -> int:
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    reset_scene()

    print(f"[generate_rock_pack] writing {OUTPUT_PATH}")
    print(f"[generate_rock_pack] {len(SHAPES)} shapes × {len(LOD_NAMES)} LODs")

    base_objects: list[bpy.types.Object] = []
    lod_objects: list[bpy.types.Object] = []

    for shape in SHAPES:
        base = build_base_mesh(shape)
        base_objects.append(base)
        for lod_idx in range(len(LOD_NAMES)):
            lod = build_lod(base, shape, lod_idx)
            vert_count = len(lod.data.vertices)
            print(f"  {lod.name}: {vert_count} verts")
            lod_objects.append(lod)

    # Strip the base meshes — we only export the LOD MIs.
    for base in base_objects:
        bpy.data.objects.remove(base, do_unlink=True)

    # Select all LOD objects for export.
    bpy.ops.object.select_all(action='DESELECT')
    for obj in lod_objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = lod_objects[0]

    # Export as .glb (binary glTF). Materials excluded — the scatter
    # assigns its own ShaderMaterial per species at load time, so
    # baking placeholder materials into the .glb just wastes bytes.
    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT_PATH),
        export_format='GLB',
        use_selection=True,
        export_apply=True,
        export_materials='NONE',
        export_animations=False,
        export_skins=False,
        export_morph=False,
    )

    size_kb = OUTPUT_PATH.stat().st_size / 1024
    print(f"[generate_rock_pack] wrote {OUTPUT_PATH} ({size_kb:.1f} KB)")

    # Recenter every mesh so its AABB center is exactly at (0, 0, 0).
    # The noise displacement step leaves vertices slightly off-center
    # (~10 cm) — harmless on its own, but the scatter places rocks
    # assuming an at-origin centroid, so any drift in the source mesh
    # appears as a per-instance translation in world space and the
    # rocks render where the math doesn't expect them. Run as a
    # post-export pass so the recenter logic lives in ONE place
    # (`scripts/recenter_glb_meshes.py`) and applies equally to the
    # hand-imported `rock_pack_extra.glb`.
    import subprocess
    here = Path(__file__).resolve().parent
    recenter = here / "recenter_glb_meshes.py"
    print(f"[generate_rock_pack] recentering meshes via {recenter.name}")
    subprocess.check_call(
        [sys.executable, str(recenter), str(OUTPUT_PATH)],
        stdout=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    # Blender passes "--" between its own args and ours; we don't take
    # any user args yet, but skip past the marker for forward compat.
    if "--" in sys.argv:
        sys.argv = [sys.argv[0]] + sys.argv[sys.argv.index("--") + 1:]
    sys.exit(main())
