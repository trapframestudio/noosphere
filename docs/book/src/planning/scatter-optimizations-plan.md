# Scatter Optimizations — Backlog

Optimizations identified during the scatter-stack audit (2026-05-05) that
were *not* taken in the same pass as items 1–7. Park here so the next
profiling-driven optimization sweep has a known shortlist to triage.

Items 1–7 (gated `player_cam_pos` pushes, conditional normal-map fetch,
guarded `_grade_greens` in foliage shaders, hoisted wind-tick RNG, biome-
aware candidate counting in ground cover, `chunk_size_m = 1024` default
on `tree_cluster_scatter`, dropped dead `_species_mesh_offsets`) shipped
together. The remaining items earn their place here because the gain is
either modest, the implementation is invasive, or both — none of them
should be picked up speculatively. Reach for them when profiling shows
the relevant hot path actually mattering.

## 8. Shared `TileStreamer` across scatters

**Symptom.** `ground_cover.gd`, `tree_scatter.gd`, `rock_scatter.gd`,
`trash_scatter.gd` each maintain their own per-tile streaming + shadow-
refresh state with the same camera-radius semantics, the same
`rebuild_threshold_m` movement gate, and the same active-radius circle.
Every scatter independently iterates `_baked_tiles` per frame for shadow
refresh and bake-queue draining.

**Trigger to act.** Profile shows tile-iteration overhead (the
`_refresh_shadows` + `_drain_bake_queue` pair) eating measurable per-
frame cost. Today each scatter's iteration is well-tuned — gated by
camera movement, sorted by distance, capped flips per frame — and the
tile counts are bounded (~80 active tiles per scatter at default
radii). At those sizes, dedup'ing the bookkeeping is a wash.

**Sketch.** Extract a `TileStreamer` Node3D that owns the per-tile
lifecycle (spawn, despawn, shadow-state, collision-state) and accepts
per-scatter tile-build callbacks. Each scatter registers as a *consumer*
of tile events (`on_tile_enter`, `on_tile_leave`, `on_shadow_state_change`)
rather than running its own streaming loop. The streamer becomes the
single source of truth for "which tiles are active" + "which subset is
in shadow / collision range".

**Cost.** Real refactor (~1–2 days). High coupling to existing per-
scatter idioms (each has its own bake queue, prewarm cursor, force-
fresh flag). Worth it only if measurements demand it.

**Cross-cutting concern.** A unified streamer also unblocks shared
prewarm policy ("the player is moving fast — drain bake queues
aggressively across all scatters") and shared shadow-flip budget
("limit total `cast_shadow` flips across scatters per frame so a tile
boundary crossing doesn't churn the directional shadow map").

## 9. GPU-side per-instance frustum culling

**Symptom.** Inside an in-frustum MMI, every instance's vertex shader
runs whether or not its actual geometry is on-screen. Today's per-MMI
chunking (1024 m supercells) keeps wasted work bounded — typical
visible chunks: ~10 ground-cover tiles + ~5–8 distant-tree chunks per
variant + ~6–8 close-tree tiles — but a partially-on-screen chunk still
runs all of its instances through the vertex shader.

**Trigger to act.** Profile shows distant-impostor or dense ground-cover
vertex-shader cost dominating, OR Cascade Locks isn't the largest map
we ship and a 4× larger map turns "10 visible chunks" into "40 visible
chunks" with bounded-but-wasteful in-chunk work.

**Sketch.** Compute-shader pre-pass per scatter:
- Read per-instance world-XZ + AABB extent from a storage buffer.
- Test each instance's footprint against the camera frustum planes.
- Write the pass mask + a packed `IndirectDrawArgs` (instance count) to
  a second buffer.
- Renderer dispatches the indirect draw — only surviving instances are
  rasterized.

Pattern is well-known (UE Nanite-cluster cull, Frostbite "World
Position Streaming"); Godot 4.5+ exposes the GPU buffer infra.

**Cost.** ~3–5 days incl. shader work + scatter integration. Way more
infra than today's CPU per-MMI cull justifies. Park behind real
profiling data on a real workload.

**Bonus.** Same compute pass can drive per-instance LOD selection
(write a chosen-LOD index into a third buffer, dispatch per-LOD
indirect draws). Replaces the current vertex-shader collapse trick
in `tree_dynamic.gdshader` with a real GPU LOD switch.

## 10. Tree shader `cull_disabled` cost

**Symptom.** `tree_dynamic.gdshader` runs `render_mode cull_disabled`
because every tree species in the project (Doug Fir, Sketchfab pine
pack, Sketchfab birch pack) authors leaf cards as single-faced quads.
Without cull_disabled, the canopy shows from above but vanishes when
viewed from below. Cost: ~1.3× fragment work on every leaf pixel
(2× before alpha-scissor cuts the transparent areas, but stacked
leaves are mostly transparent so realized cost is closer to 1.3×).

**Trigger to act.** Profile shows fragment-shader cost on the tree
shader as a top item AND the artist team lands an asset pipeline that
guarantees double-sided geometry at import time (per-surface flip-faces
or duplicated-and-flipped vertex data baked into the gltf).

**Sketch.** Per-asset import sidecar that flips face winding on leaf-
card surfaces; flip back to single-sided rendering in the shader.
Previous attempt at this didn't pan out — neither the .glb materials
nor the import sidecars expose a per-surface cull flag we can flip
cleanly, and runtime `Mesh.flip_faces`-equivalent API doesn't exist
for `ArrayMesh` in Godot 4.6.

**Cost.** Asset pipeline work (Blender-side pre-export step, or a
post-import Godot-side script) plus shader edit. The asset pipeline
is the long pole — every species needs the duplication baked in once.

**Realistic alternative.** Live with the 1.3× cost. The standard pipeline
fragment work for foliage is dominated by the lighting block (custom
`light()` with wrap diffuse + transmission), not the alpha-test path.
At today's measurements this is unlikely to be a top-three GPU item.

## Out of scope (intentional non-fixes)

These came up during the audit but aren't worth tracking even as future
work:

- **Per-frame `_resolve_terrain3d()` calls.** The first call resolves
  the node; subsequent calls early-return on the `is_instance_valid`
  cache. Cost: one null check per scatter per frame.
- **Per-frame `_xz()` Vec3→Vec2 helper.** Inline the constructor and
  you save a function call. Godot's GDScript JIT already handles this
  trivially.
- **`_get_editor_camera()` walks the editor viewport hierarchy.** Only
  fires in editor preview mode, not at runtime. Editor perf is not the
  game's perf budget.
