#!/usr/bin/env python3
"""Generate TrashSpecies .tres files from a curation manifest.

Usage::

    python scripts/generate_trash_species_tres.py \\
        --manifest scripts/trash_species_manifest.json \\
        --models-dir godot/assets/models/trash \\
        --out-dir godot/resources/foliage/trash

The manifest is a JSON list of entries, each describing one species the
scatter should place. Schema::

    {
      "name": "bottle_a",                  # filename stem (no extension)
      "glb": "bottles/bottle_a.glb",       # path under models-dir
      "tier": "physics_wind",              # static | physics | physics_wind
      "is_anchor": false,                  # hero / pile species
      "size_multiplier": 0.5,
      "scale_min": 0.85, "scale_max": 1.15,
      "physics_mass": 0.4,                  # kg, only used for physics tier
      "wind_susceptibility": 0.0,           # 0-1, only used for physics_wind
      "paved_weight": 1.0, "unpaved_weight": 0.5, "trail_weight": 0.2,
      "satellite_anchor_boost": 3.0,
      "satellite_anchor_radius": 2.5,
      "road_edge_boost": 2.5,
      "terrain_curvature_boost": 1.0,
      "terrain_alignment_factor": 0.0,
      "max_render_distance_m": 60,
      "random_tilt_deg": 8.0
    }

Tier presets fill in sensible defaults so most entries only need to
override the unique fields. Generated .tres files use stable UIDs
derived from the species name (md5-prefix) so re-running the script
doesn't churn UIDs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


# Tier defaults — applied unless the manifest entry overrides.
TIER_DEFAULTS = {
    "static": {
        "physics_enabled": False,
        "physics_mass": 0.0,
        "wind_susceptibility": 0.0,
        "terrain_alignment_factor": 0.7,
        # Static items are tiny / light / friction-bound (cigarettes,
        # ash, matchboxes) — they realistically stay put on moderate
        # slopes.
        "max_slope_deg": 38.0,
    },
    "physics": {
        "physics_enabled": True,
        "physics_mass": 0.3,
        "wind_susceptibility": 0.0,
        "terrain_alignment_factor": 0.0,  # let physics settle the rotation
        # Heavy cylindrical items (bottles, cans, food cans) — these
        # would visibly roll on a 30° slope. Cap conservatively.
        "max_slope_deg": 22.0,
    },
    "physics_wind": {
        "physics_enabled": True,
        "physics_mass": 0.05,
        "wind_susceptibility": 1.0,
        "terrain_alignment_factor": 0.0,
        # Light wind-blown items (paper, masks, chips bags) — bendy /
        # foldy enough to catch on irregularities, can stay on
        # steeper-than-physics slopes but still less than tiny static.
        "max_slope_deg": 30.0,
    },
}


# Universal defaults (fields with the same value across all tiers).
COMMON_DEFAULTS = {
    "scale_min": 0.85,
    "scale_max": 1.15,
    "size_multiplier": 1.0,
    "random_yaw": True,
    "random_tilt_deg": 8.0,
    "albedo_modulation": (1.0, 1.0, 1.0, 1.0),
    "physics_radius": 0.0,
    "physics_height": 0.0,
    "physics_authority": 0,
    "paved_weight": 1.0,
    "unpaved_weight": 0.4,
    "trail_weight": 0.1,
    "builtup_weight": 0.0,
    "bare_weight": 0.0,
    "spawn_in_zones": True,
    "max_render_distance_m": 60,
    "is_anchor": False,
    "satellite_anchor_boost": 0.0,
    "satellite_anchor_radius": 2.5,
    "road_edge_boost": 0.0,
    "terrain_curvature_boost": 0.0,
    "lay_down_pretilt_deg": 0.0,
    "max_slope_deg": 30.0,
}


def stable_uid(name: str) -> str:
    """Generate a stable UID from the species name. Format matches
    Godot's `uid://` 13-char base32-ish style, but determinism > format
    fidelity — Godot accepts any unique string after `uid://`.
    """
    h = hashlib.md5(name.encode("utf-8")).hexdigest()
    return f"uid://{h[:13]}"


def render_tres(name: str, glb_path: str, params: dict) -> str:
    """Render a TrashSpecies .tres file as a string."""
    uid = stable_uid(name)
    color = params["albedo_modulation"]
    color_str = f"Color({color[0]}, {color[1]}, {color[2]}, {color[3]})"

    bool_str = lambda b: "true" if b else "false"

    tres = f"""[gd_resource type="Resource" script_class="TrashSpecies" format=3 uid="{uid}"]

[ext_resource type="Script" path="res://scripts/foliage/trash_species.gd" id="1_script"]

[resource]
resource_name = "Trash: {name}"
script = ExtResource("1_script")
mesh_scene_path = "res://assets/models/trash/{glb_path}"
scale_min = {params["scale_min"]}
scale_max = {params["scale_max"]}
size_multiplier = {params["size_multiplier"]}
random_yaw = {bool_str(params["random_yaw"])}
random_tilt_deg = {params["random_tilt_deg"]}
albedo_modulation = {color_str}
physics_enabled = {bool_str(params["physics_enabled"])}
physics_mass = {params["physics_mass"]}
physics_radius = {params["physics_radius"]}
physics_height = {params["physics_height"]}
physics_authority = {params["physics_authority"]}
wind_susceptibility = {params["wind_susceptibility"]}
paved_weight = {params["paved_weight"]}
unpaved_weight = {params["unpaved_weight"]}
trail_weight = {params["trail_weight"]}
builtup_weight = {params["builtup_weight"]}
bare_weight = {params["bare_weight"]}
spawn_in_zones = {bool_str(params["spawn_in_zones"])}
max_render_distance_m = {params["max_render_distance_m"]}
is_anchor = {bool_str(params["is_anchor"])}
satellite_anchor_boost = {params["satellite_anchor_boost"]}
satellite_anchor_radius = {params["satellite_anchor_radius"]}
road_edge_boost = {params["road_edge_boost"]}
terrain_curvature_boost = {params["terrain_curvature_boost"]}
terrain_alignment_factor = {params["terrain_alignment_factor"]}
lay_down_pretilt_deg = {params["lay_down_pretilt_deg"]}
max_slope_deg = {params["max_slope_deg"]}
"""
    return tres


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--models-dir", required=True, type=Path,
                        help="Directory containing the .glb files (used to verify each entry has a real model)")
    parser.add_argument("--out-dir", required=True, type=Path,
                        help="Directory to write .tres files into")
    parser.add_argument("--clean", action="store_true",
                        help="Remove existing .tres files in out-dir before writing")
    args = parser.parse_args()

    if not args.manifest.exists():
        print(f"Manifest not found: {args.manifest}", file=sys.stderr)
        return 1

    entries = json.loads(args.manifest.read_text())
    if not isinstance(entries, list):
        print("Manifest must be a JSON list of entries", file=sys.stderr)
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)

    if args.clean:
        for f in args.out_dir.glob("*.tres"):
            f.unlink()
            print(f"  removed {f.name}")

    written = 0
    skipped = 0
    species_paths_array: list[str] = []
    for entry in entries:
        name = entry["name"]
        tier = entry.get("tier", "static")
        if tier not in TIER_DEFAULTS:
            print(f"  ! {name}: unknown tier {tier}", file=sys.stderr)
            skipped += 1
            continue
        glb_path = entry["glb"]
        full_glb = args.models_dir / glb_path
        if not full_glb.exists():
            print(f"  ! {name}: glb missing — {full_glb}", file=sys.stderr)
            skipped += 1
            continue
        # Compose params: common defaults <- tier defaults <- entry overrides
        params = dict(COMMON_DEFAULTS)
        params.update(TIER_DEFAULTS[tier])
        for k, v in entry.items():
            if k in ("name", "glb", "tier"):
                continue
            params[k] = v
        # Anchors generally want larger scales + larger anchor radii.
        if params["is_anchor"] and params["satellite_anchor_radius"] == COMMON_DEFAULTS["satellite_anchor_radius"]:
            params["satellite_anchor_radius"] = 3.5
        out_path = args.out_dir / f"{name}.tres"
        out_path.write_text(render_tres(name, glb_path, params))
        written += 1
        species_paths_array.append(f'"res://resources/foliage/trash/{name}.tres"')
        print(f"  ✓ {name} ({tier})")

    print()
    print(f"Wrote {written} | Skipped {skipped}")
    print()
    print("species_paths array (paste into the TrashScatter node):")
    print(f"Array[String]([{', '.join(species_paths_array)}])")
    return 0


if __name__ == "__main__":
    sys.exit(main())
