#!/usr/bin/env python3
"""Recenter every mesh in a .glb so each mesh's AABB center is at (0, 0, 0).

The problem: when a Blender scene with multiple objects laid out across
a flat plane is exported via the GLTF "Selected Objects" pipeline with
``apply_transform=True``, each object's WORLD transform gets baked into
its mesh vertices. The result is meshes whose vertex centroids sit
several meters from the local origin — fine when each is rendered as a
separate node with its own transform, but FATAL for our MultiMesh
pipeline where the mesh is rendered at the per-instance Transform3D
without a per-mesh node offset. The baked layout offset becomes a
silent translation that puts every rock several meters from where the
scatter expects it.

This script reads a .glb, computes each POSITION accessor's centroid
from its `min`/`max` metadata, subtracts that centroid from every
vertex of that accessor, updates the accessor's `min`/`max`, and writes
the modified file back. Vertex normals + UV + tangents are unaffected
by translation, so we only touch the POSITION accessors.

Usage:
    python3 scripts/recenter_glb_meshes.py path/to/rock_pack.glb [--dry-run]

The output overwrites the input file unless `--dry-run` is set.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import struct
import sys


def parse_glb(path: pathlib.Path) -> tuple[dict, bytearray, int]:
    """Return (gltf_json, bin_chunk_bytes, json_chunk_offset)."""
    data = path.read_bytes()
    if data[:4] != b"glTF":
        raise ValueError(f"{path}: not a binary glTF file")
    version = struct.unpack_from("<I", data, 4)[0]
    if version != 2:
        raise ValueError(f"{path}: glTF version {version} not supported")
    total_len = struct.unpack_from("<I", data, 8)[0]
    if total_len != len(data):
        raise ValueError(f"{path}: header length {total_len} != file size {len(data)}")
    # Chunk 0: JSON
    j_len = struct.unpack_from("<I", data, 12)[0]
    j_type = data[16:20]
    if j_type != b"JSON":
        raise ValueError(f"{path}: first chunk type {j_type!r}, expected JSON")
    gltf_json = json.loads(data[20 : 20 + j_len])
    # Chunk 1 (optional): BIN
    bin_off = 20 + j_len
    bin_data = bytearray()
    if bin_off < total_len:
        b_len = struct.unpack_from("<I", data, bin_off)[0]
        b_type = data[bin_off + 4 : bin_off + 8]
        if b_type != b"BIN\x00":
            raise ValueError(f"{path}: second chunk type {b_type!r}, expected BIN")
        bin_data = bytearray(data[bin_off + 8 : bin_off + 8 + b_len])
    return gltf_json, bin_data, 20 + j_len


def write_glb(path: pathlib.Path, gltf_json: dict, bin_data: bytes) -> None:
    """Write a glTF + BIN to a binary .glb."""
    j_bytes = json.dumps(gltf_json, separators=(",", ":")).encode("utf-8")
    # Pad each chunk to 4-byte alignment per GLTF spec.
    j_pad = (4 - len(j_bytes) % 4) % 4
    j_bytes_padded = j_bytes + b" " * j_pad
    b_pad = (4 - len(bin_data) % 4) % 4
    bin_padded = bytes(bin_data) + b"\x00" * b_pad
    total = 12 + 8 + len(j_bytes_padded) + (8 + len(bin_padded) if bin_padded else 0)
    with path.open("wb") as f:
        # Header
        f.write(b"glTF")
        f.write(struct.pack("<I", 2))
        f.write(struct.pack("<I", total))
        # JSON chunk
        f.write(struct.pack("<I", len(j_bytes_padded)))
        f.write(b"JSON")
        f.write(j_bytes_padded)
        # BIN chunk
        if bin_padded:
            f.write(struct.pack("<I", len(bin_padded)))
            f.write(b"BIN\x00")
            f.write(bin_padded)


def recenter_pack(path: pathlib.Path, dry_run: bool) -> int:
    """Recenter every mesh's vertices so its AABB center is (0,0,0). Returns count."""
    gltf, bin_data, _ = parse_glb(path)
    accessors = gltf.get("accessors", [])
    buffer_views = gltf.get("bufferViews", [])
    nodes_by_mesh: dict[int, dict] = {}
    for n in gltf.get("nodes", []):
        if "mesh" in n:
            nodes_by_mesh[n["mesh"]] = n

    touched = 0
    for mi, m in enumerate(gltf.get("meshes", [])):
        node_name = nodes_by_mesh.get(mi, {}).get("name", f"mesh#{mi}")
        for prim in m.get("primitives", []):
            pos_acc_idx = prim.get("attributes", {}).get("POSITION")
            if pos_acc_idx is None:
                continue
            acc = accessors[pos_acc_idx]
            mn = acc.get("min")
            mx = acc.get("max")
            if not mn or not mx or len(mn) != 3 or len(mx) != 3:
                print(f"  SKIP {node_name}: no min/max metadata", file=sys.stderr)
                continue
            cx = (mn[0] + mx[0]) * 0.5
            cy = (mn[1] + mx[1]) * 0.5
            cz = (mn[2] + mx[2]) * 0.5
            if abs(cx) < 1e-5 and abs(cy) < 1e-5 and abs(cz) < 1e-5:
                continue  # already centered
            # Translate the accessor's vertices in the BIN.
            bv_idx = acc["bufferView"]
            bv = buffer_views[bv_idx]
            bv_off = bv.get("byteOffset", 0)
            count = acc["count"]
            byte_off_in_bv = acc.get("byteOffset", 0)
            stride = bv.get("byteStride", 12)  # f32 vec3 = 12 bytes default
            base = bv_off + byte_off_in_bv
            for i in range(count):
                vi = base + i * stride
                vx = struct.unpack_from("<f", bin_data, vi)[0] - cx
                vy = struct.unpack_from("<f", bin_data, vi + 4)[0] - cy
                vz = struct.unpack_from("<f", bin_data, vi + 8)[0] - cz
                struct.pack_into("<fff", bin_data, vi, vx, vy, vz)
            # Update accessor min/max metadata.
            acc["min"] = [mn[0] - cx, mn[1] - cy, mn[2] - cz]
            acc["max"] = [mx[0] - cx, mx[1] - cy, mx[2] - cz]
            print(
                f"  RECENTER {node_name}: shifted by "
                f"({-cx:+.3f}, {-cy:+.3f}, {-cz:+.3f})  "
                f"new y_range=[{acc['min'][1]:+.3f}, {acc['max'][1]:+.3f}]"
            )
            touched += 1

    if touched > 0 and not dry_run:
        write_glb(path, gltf, bin_data)
        print(f"\nWrote {path} ({touched} primitives recentered).")
    elif touched == 0:
        print(f"\n{path}: already centered, no changes.")
    else:
        print(f"\n[dry-run] {path}: would recenter {touched} primitives.")
    return touched


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", type=pathlib.Path)
    ap.add_argument("--dry-run", action="store_true",
                    help="Print changes without writing")
    args = ap.parse_args()
    total = 0
    for p in args.paths:
        if not p.exists():
            print(f"ERROR: {p} does not exist", file=sys.stderr)
            return 1
        print(f"--- {p} ---")
        total += recenter_pack(p, args.dry_run)
    print(f"\nTotal: {total} primitives recentered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
