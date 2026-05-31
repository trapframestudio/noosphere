#!/usr/bin/env -S blender --background --python
"""**DEPRECATED — kept for reference only.**

Replaced (2026-05-11) by the in-Godot impostor baker:
`godot/tools/imposter_baker.gd` + `godot/shaders/imposter_bake_*`.

**Why deprecated**: this Cycles+Principled-BSDF flow tried to bake
the close-tier shader's wrap-diffuse + warm transmission + sky-bias
emission into the impostor PNG using Blender lights, which never
matched Godot's `tree_dynamic.gdshader` (different tonemap, different
math). The new pipeline bakes UNLIT albedo + view-space normals
inside Godot and lets the runtime `tree_cluster.gdshader` do the
lighting against the live sun direction — required by the dynamic
weather + time-of-day system, which would otherwise see the impostors
locked to whatever sun direction was set at bake time.

This file is kept ONLY as a reference for:
  - the species list (`IMPOSTORS` tuple) → ported into the new
    baker's `bake_glb_paths` / `bake_output_names` defaults
  - the ImageMagick post-processing math (`crop_to_silhouette`) →
    re-implemented in `imposter_baker.gd::_trim_and_resize` using
    `Image.get_used_rect` / `Image.resize`
  - the LOD-filter heuristic (`import_glb`) → re-implemented in
    `imposter_baker.gd::_hide_secondary_lods`

Do not run. See `docs/book/src/walkthroughs/distant-trees.md` for
the current pipeline.

Original docstring follows:

----

Bake tree impostor billboards from real GLB assets.

Imports each configured GLB into headless Blender, frames an ortho
side-view camera on the tree's bounding box, and renders to a
512×1024 RGBA PNG at::

    godot/assets/textures/foliage/<output_name>.png

The output is consumed by `TreeClusterScatter.impostor_texture_paths`
(see `godot/scripts/foliage/tree_cluster_scatter.gd`). The cluster
system places y-axis-billboarded quads at 600-2400 m and randomly
samples one of N variants per cell — so we only need a handful of
representative impostors that match the dominant species in the
biome (NOT one per pine variant).

Replaces the previous procedural baker (cone trunk + stacked frond
rings) which produced silhouettes that didn't match the real trees
in the world. This one renders the actual asset's geometry +
textures so the distant impostors mirror the close-tier trees.

**Run from repo root**::

    blender --background --python scripts/bake_conifer_impostor.py

Add new impostor variants by appending to `IMPOSTORS` below.
"""
from __future__ import annotations

import math
import sys
from dataclasses import dataclass
from pathlib import Path

import bpy

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
OUTPUT_DIR = REPO_ROOT / "godot" / "assets" / "textures" / "foliage"

# 512×1024 = portrait aspect matching conifer silhouette. The cluster
# system's billboard cards are ~8 m × 18 m world-space, so even at
# 200 m the impostor stays under our texture resolution.
TEX_W = 512
TEX_H = 1024


@dataclass
class Impostor:
    """One baked impostor. `glb_path` is repo-relative; the imported
    asset's bounding box drives ortho framing automatically. `tint`
    is a multiplicative color applied via emission so cluster cells
    get visual variety even with a small set of base impostors."""
    output_name: str
    glb_path: str
    tint: tuple[float, float, float] = (1.0, 1.0, 1.0)


# One impostor per active tree species in `biome_forest_trees.tres`
# (currently 14 unique silhouettes — Doug Fir size variants share
# textures so we bake one per size tier rather than per species
# variant). Each entry produces `<output_name>.png` consumed by
# `TreeClusterScatter.impostor_texture_paths`. The cluster scatter
# picks one path per cell at random for visual variety.
IMPOSTORS: tuple[Impostor, ...] = (
    # --- Pure3D Pine pack (8 variants, distinct silhouettes) ---
    Impostor(output_name="pine_p3d_mature_lush_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_18m_fresh.glb"),
    Impostor(output_name="pine_p3d_mature_twiggy_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_20m_twiggy.glb"),
    Impostor(output_name="pine_p3d_mature_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_16m.glb"),
    Impostor(output_name="pine_p3d_medium_lush_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_15m_fresh.glb"),
    Impostor(output_name="pine_p3d_medium_twiggy_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_12m_twiggy.glb"),
    Impostor(output_name="pine_p3d_small_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_9m.glb"),
    Impostor(output_name="pine_p3d_young_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_4m.glb"),
    Impostor(output_name="pine_p3d_sapling_impostor",
        glb_path="godot/assets/models/plants_cgtrader/morepines/"
            "Pine_2m_twiggy.glb"),
    # --- UE-extracted CG pines (3 distinct standalone trees) ---
    Impostor(output_name="pine_cg_large_impostor",
        glb_path="godot/assets/models/plants_cgtrader/pines/"
            "pine_06.glb"),
    Impostor(output_name="pine_cg_medium_impostor",
        glb_path="godot/assets/models/plants_cgtrader/pines/"
            "pine_03.glb"),
    Impostor(output_name="pine_cg_small_impostor",
        glb_path="godot/assets/models/plants_cgtrader/pines/"
            "pine_07.glb"),
    # --- Fab Doug Fir (3 size tiers — variants share textures so
    # one impostor per size is enough) ---
    Impostor(output_name="doug_fir_large_impostor",
        glb_path="godot/assets/models/plants_fab/tree_douglas_fir/"
            "large_1.glb"),
    Impostor(output_name="doug_fir_medium_impostor",
        glb_path="godot/assets/models/plants_fab/tree_douglas_fir/"
            "medium_1.glb"),
    Impostor(output_name="doug_fir_small_impostor",
        glb_path="godot/assets/models/plants_fab/tree_douglas_fir/"
            "small_1.glb"),
)


def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.film_transparent = True


def import_glb(glb_path: Path) -> tuple[float, float, float, float]:
    """Import a GLB and return (height, width, center_x, center_z)
    of the combined mesh bbox in world space. Caller uses these to
    frame the ortho camera."""
    bpy.ops.import_scene.gltf(filepath=str(glb_path))
    # Collect all imported MESH objects + compute world-space bbox.
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise RuntimeError(f"no meshes imported from {glb_path}")
    # Filter out the LOD1/LOD2/LOD3 meshes if multiple LODs are
    # present — render the highest-quality silhouette. We detect by
    # name: anything containing `_LOD` and ending in a non-zero digit
    # gets dropped. Single-LOD assets pass through untouched.
    primary: list[bpy.types.Object] = []
    for o in meshes:
        n = o.name
        idx = n.rfind("_LOD")
        if idx >= 0 and idx + 4 < len(n) and n[idx + 4].isdigit():
            if n[idx + 4] != "0":
                continue
        primary.append(o)
    if not primary:
        primary = meshes  # fallback: render whatever's there
    # Hide non-primary objects so they don't get rendered.
    for o in meshes:
        if o not in primary:
            o.hide_render = True
    # Compute combined world-space AABB from transformed vertex
    # positions. Avoid `o.bound_box` because gltf importers can leave
    # bound_box reflecting mesh-local extents without parent
    # rotation/translation applied — for assets where the per-LOD
    # node has translation (Doug Fir LOD1 at z=-10 etc.), bound_box
    # produces an asymmetric AABB that frames the camera off-center.
    import mathutils
    min_x = min_y = min_z = float("inf")
    max_x = max_y = max_z = float("-inf")
    for o in primary:
        m = o.matrix_world
        for v in o.data.vertices:
            wc = m @ v.co
            if wc.x < min_x: min_x = wc.x
            if wc.x > max_x: max_x = wc.x
            if wc.y < min_y: min_y = wc.y
            if wc.y > max_y: max_y = wc.y
            if wc.z < min_z: min_z = wc.z
            if wc.z > max_z: max_z = wc.z
    # In Blender world (Z-up), height = Z extent. The glTF importer
    # converts Y-up glTF → Z-up Blender automatically.
    height = max_z - min_z
    width = max(max_x - min_x, max_y - min_y)
    cx = (min_x + max_x) * 0.5
    cy = (min_y + max_y) * 0.5
    return height, width, cx, cy


def apply_tint(tint: tuple[float, float, float]) -> None:
    """Multiply the tint into every imported material's base color.
    Used to differentiate impostor variants without re-baking the
    underlying meshes — same geometry, different color signal."""
    if tint == (1.0, 1.0, 1.0):
        return
    for mat in bpy.data.materials:
        if not mat.use_nodes or mat.node_tree is None:
            continue
        for node in mat.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED":
                bc = node.inputs["Base Color"]
                if not bc.is_linked:
                    # No texture — multiply the default value.
                    cur = bc.default_value
                    bc.default_value = (
                        cur[0] * tint[0],
                        cur[1] * tint[1],
                        cur[2] * tint[2],
                        cur[3])


def force_alpha_clip() -> None:
    """Flip every imported material from HASHED to CLIP blend mode.
    Godot's gltf importer brings MASK materials in as HASHED in
    Blender 5.x — that renders alpha-cutout with stochastic dithering
    which EEVEE Next's bake interprets as solid semi-transparent
    coverage (impostor PNGs come out as opaque green rectangles
    instead of clean leaf-card silhouettes). CLIP discards
    fully-transparent pixels with hard cutoff at `alpha_threshold`,
    producing the clean alpha edges the impostor billboard expects."""
    n_flipped = 0
    for mat in bpy.data.materials:
        if hasattr(mat, "blend_method") and mat.blend_method != "OPAQUE":
            mat.blend_method = "CLIP"
            mat.alpha_threshold = 0.5
            n_flipped += 1
    if n_flipped:
        print(f"  [alpha] flipped {n_flipped} materials → CLIP")


def setup_camera(height: float, width: float, cx: float,
        cy: float, base_z: float) -> None:
    """Set up an ortho side-view camera framed on the tree. Camera
    looks down +X (Blender world). Ortho_scale = max(height, width)
    + small margin to avoid clipping fronds. Camera height = mid-
    height of the tree so the silhouette is centered vertically in
    the render."""
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    # Blender's ortho_scale = the LARGER world-space view extent
    # (the vertical extent here, since TEX_H > TEX_W). The smaller
    # dim is `ortho_scale * (TEX_W / TEX_H)`. To frame the tree:
    #   vertical fit: ortho_scale >= height * margin
    #   horizontal fit: ortho_scale * (TEX_W / TEX_H) >= width *
    #                   margin → ortho_scale >= width * margin *
    #                   (TEX_H / TEX_W)
    # Pick whichever is more constraining. Without this, wide trees
    # like Doug Fir (5.3m wide × 9.3m tall) get cropped on the left/
    # right and the tree wraps to the image edge — visible as a
    # bottom-left fully-opaque corner in the impostor PNG.
    aspect_h_over_w = TEX_H / TEX_W
    scale_for_height = height * 1.05
    scale_for_width = width * 1.15 * aspect_h_over_w
    cam_data.ortho_scale = max(scale_for_width, scale_for_height)
    cam = bpy.data.objects.new("cam", cam_data)
    # Place camera 50 m away on -Y, looking +Y at the tree. Height =
    # vertical center of the tree.
    cam.location = (cx, cy - 50.0, base_z + height * 0.5)
    cam.rotation_euler = (math.pi * 0.5, 0.0, 0.0)
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam


def setup_lighting() -> None:
    """Flatter lighting: weak sun + strong ambient + opposing fill
    light. The cluster shader is `unshaded` (no per-frame lighting),
    so any contrast we bake in is *baked* — there's no scene light
    to compensate. Earlier bakes used a single strong sun which
    produced bright sun-lit edges and pitch-black canopy interior
    (the impostor reads as a high-contrast silhouette against the
    sky, but the close-tier trees in front of it are evenly lit by
    the scene's directional + ambient + back-light shader, so the
    impostor's shadow side looks wrong-darker than its close-tier
    neighbors).
    To match the close-tier look we want roughly hemispheric lighting:
      - weak directional sun for SHAPE (reads as canopy form, not as
        shadow contrast)
      - strong ambient to lift the shadow side
      - opposing fill from below-back to brighten the shadowed
        underside of the canopy (mimicking sky bounce + ground bounce)"""
    # Modest directional sun + low ambient. The impostor shader is
    # `unshaded` so all canopy color comes from the bake — too
    # bright a bake makes impostors look "blown out" against
    # close-tier trees; too dim and they read as black holes in the
    # forest. These values landed in a usable range after a long
    # iteration: dim impostors that dropped behind close-tier
    # brightness slightly, but not so dim they vanished. The user
    # plans to manually replace these baked PNGs with hand-tuned
    # versions; this baker is left in a "good enough as a starting
    # point" state.
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 1.5
    sun_data.color = (1.0, 0.97, 0.92)
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (
        math.radians(-55.0), math.radians(20.0), 0.0)
    bpy.context.scene.collection.objects.link(sun)
    world = bpy.context.scene.world
    if world is None:
        world = bpy.data.worlds.new("world")
        bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg is not None:
        bg.inputs["Color"].default_value = (0.5, 0.55, 0.5, 1.0)
        bg.inputs["Strength"].default_value = 0.8


def crop_to_silhouette(png_path: Path) -> None:
    """Crop the rendered PNG down to the alpha-filled bbox, resize
    back to TEX_W × TEX_H, and flip vertically.

    **Crop**: without it, sparse trees (Pure3D Pine_18m_fresh: 4 m
    wide × 20 m tall) leave most of the texture transparent and the
    cluster card displays a thin sliver. Cropping makes each tree
    FILL the impostor texture.

    **Vertical flip**: Blender renders with PNG y=0 = image top =
    tree top, but `tree_cluster.gdshader` maps `UV.y=0` to the card's
    GROUND vertex (`vec3(0.0, UV.y * ht, 0.0)` → ground at UV.y=0,
    sky at UV.y=1). Without the flip, UV.y=0 samples PNG row 0 (tree
    top) at the ground — every cluster tree renders inverted. Flip
    the PNG so PNG y=0 = tree base.

    Uses ImageMagick via subprocess to avoid pulling Pillow into the
    Blender Python env."""
    import subprocess
    subprocess.run([
        "magick", str(png_path),
        "-fuzz", "1%",
        "-trim", "+repage",
        "-resize", f"{TEX_W}x{TEX_H}!",
        "-flip",
        # +30 % saturation pulls the green canopy back toward
        # vibrant range; the dim sun + low ambient bake otherwise
        # produces a desaturated gray-green that reads wrong against
        # the close-tier rich-green trees.
        "-modulate", "100,130,100",
        str(png_path),
    ], check=True, capture_output=True)


def render(output_name: str) -> Path:
    scene = bpy.context.scene
    # Cycles instead of EEVEE Next: EEVEE Next renders Blender's
    # `HASHED` blend method (which Blender's gltf importer assigns
    # to alpha-cutout materials) as stochastic dithered transparency
    # — which AA-averages into ~84% opaque coverage and produces
    # solid green rectangles instead of clean leaf silhouettes (the
    # dark rectangles visible in the early bake test). Cycles
    # evaluates the Principled BSDF's Alpha input directly via path
    # tracing — alpha cutoff just works without per-material setup.
    # We render at low samples (16) since the impostor texture only
    # needs a coherent silhouette, not photoreal lighting.
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.cycles.use_denoising = True
    # Cycles film_transparent gates whether the WORLD shows; we set
    # it on the scene render settings (mirror of EEVEE).
    scene.render.film_transparent = True
    scene.render.resolution_x = TEX_W
    scene.render.resolution_y = TEX_H
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    output_path = OUTPUT_DIR / f"{output_name}.png"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(output_path)
    bpy.ops.render.render(write_still=True)
    crop_to_silhouette(output_path)
    return output_path


def main() -> int:
    for imp in IMPOSTORS:
        print(f"[bake_impostor] baking {imp.output_name}")
        reset_scene()
        glb_full = REPO_ROOT / imp.glb_path
        if not glb_full.exists():
            print(f"  [skip] {glb_full} not found")
            continue
        height, width, cx, cy = import_glb(glb_full)
        # The tree's BASE z (lowest world-space vertex) — used to
        # position the camera's vertical center on the tree's
        # mid-height. Same vertex-based approach as `import_glb`'s
        # bbox calc; bound_box is unreliable for parented meshes.
        bbox_min_z = min(
            (o.matrix_world @ v.co).z
            for o in bpy.data.objects if o.type == "MESH"
            and not o.hide_render
            for v in o.data.vertices)
        force_alpha_clip()
        apply_tint(imp.tint)
        setup_camera(height, width, cx, cy, bbox_min_z)
        setup_lighting()
        out_path = render(imp.output_name)
        size_kb = out_path.stat().st_size / 1024
        print(f"  [done] {out_path.relative_to(REPO_ROOT)} "
            f"({size_kb:.1f} KB) — h={height:.1f}m w={width:.1f}m")
    return 0


if __name__ == "__main__":
    if "--" in sys.argv:
        sys.argv = [sys.argv[0]] + sys.argv[sys.argv.index("--") + 1:]
    else:
        sys.argv = [sys.argv[0]]
    sys.exit(main())
