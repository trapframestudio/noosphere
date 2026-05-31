# Terrain3D Nav-Paint Walkthrough

Designer-facing recipe for telling the sim "NPCs cannot enter this
cell" or "NPCs *can* enter this cell, ignore the slope/water gate."
Shipped in **iteration 5-13 Phase A** (see
[`planning/sim-iteration-5-13-plan.md`](../planning/sim-iteration-5-13-plan.md)).

The Phase 1 nav grid (`crates/simn-sim/src/nav.rs::GridNavQuery`)
decides per-cell passability from slope and `FeatureClass` —
`Cliff` / `Water` / steep terrain → blocked, everything else →
walkable. That gets us 90% of the way there, but two design cases
need a manual override:

- **False negative.** A slope or `Cliff` cell the designer wants
  walkable anyway (goat path, ford, scripted route).
- **False positive.** Geometrically open terrain that's intentionally
  off-limits (fenced compound interior, ravine bottom, story-critical
  no-go).

Both are handled by painting two Terrain3D slots and clicking
**Sync to Canonical**. The sim's `Heightmap` picks up the painted
overrides on next region attach; A* immediately routes around the
new blocks (or through the new walkable corridors).

## The contract in one paragraph

`godot/assets/terrain/<map_id>/nav_mask.r8` is a per-cell byte
grid alongside `heightmap.r32` and `features.r8`. Each byte is
one of:

- `0` — `NavOverride::Default` (defer to slope + feature class)
- `1` — `NavOverride::ForceBlocked`
- `2` — `NavOverride::ForceWalkable`

The Terrain3D exporter writes this file on **Sync to Canonical**.
The sim's `Heightmap::load` reads it on map load.
`GridNavQuery::from_heightmap` consults it per cell during the
build:

- `ForceBlocked` → the cell is impassable regardless of slope.
- `ForceWalkable` → the cell is passable regardless of slope, water,
  or cliff classification.
- `Default` → the existing slope + feature-class logic decides.

`#[serde(default)]` on the metadata fields means every existing
map's `terrain.toml` parses unchanged; absent file = no overrides.

## The painting recipe

1. Open the map scene in Godot (e.g.
   `godot/scenes/maps/cascade_locks.tscn`).
2. Select the `Terrain3D` node. Switch to the paint tool.
3. Pick **slot 14 ("nav_block")** in the texture palette. Paint over
   cells NPCs must *not* enter — fence interiors, ravine bottoms,
   story-critical no-go zones. Default brush, any nonzero weight
   counts.
4. Pick **slot 15 ("nav_walkable")** to paint over cells NPCs must
   enter regardless of slope/water — goat paths up cliffs, fords
   across streams, scripted routes.
5. Click **Sync to Canonical** on the `Terrain3DBaker` node.
   `Terrain3DExporter::export_canonical` writes `nav_mask.r8` and
   updates `terrain.toml` with `nav_mask_format_version = 1` +
   the freshly-computed `nav_mask_blake3`.
6. Restart the sim (or detach + reattach the region from the dev
   panel). `Heightmap::load` picks up the new mask;
   `attach_region_terrain` rebuilds `GridNavQuery` honoring the
   overrides. Online NPCs reroute on the next tick.

**If both slot 14 and slot 15 are painted on the same cell, block
wins** (safer default for AI behavior; matches the sim's
`apply_obstacles` merge rule in Phase B).

## Verifying the overrides took

Three ways to confirm the paint flowed through:

1. **`terrain.toml` digest.** After Sync, `nav_mask_blake3` should
   be non-empty. If it's still `""`, the exporter didn't write the
   file — check the Godot output log for `Terrain3DExporter:`
   error lines.
2. **`Sim::nav_traversability`**. The bridge exposes a flat
   `Vec<bool>` snapshot of the nav grid (one bool per cell, row-
   major). Painted blocks show up as `false` cells in the
   corresponding region; painted walkable overrides show up as
   `true` cells even on cliff-classified terrain.
3. **In-engine path query.** Call `SimHost.path_in_region(region,
   from, to, style)` from GDScript across the painted block. Paths
   that crossed the area before now detour around it.

## Known v1 limitations

These are explicit design decisions for iteration 5-13's first
slice; follow-ups are tracked in the iteration plan.

- **One-way paint round-trip.** The exporter writes `nav_mask.r8`,
  but the loader does *not* re-stamp Terrain3D slot 14 / 15 from
  canonical when re-seeding a region's `.res` files. The loader's
  existing `_variant_for` noise pass already assigns slots 14 and
  15 to decoration variants (`nordic_moss`, `mine_rock_wall`);
  co-opting them for nav needs a visual-asset pass that's out of
  scope for the v1 code change. **Workaround:** keep your
  `regions/*.res` files. Deleting them and re-seeding from
  canonical loses painted nav overrides; you'll need to repaint.
- **No live rebuild.** `GridNavQuery` only rebuilds on
  `attach_region_terrain`. After Sync to Canonical, you have to
  detach + reattach the region (or restart the sim) for the new
  overrides to take effect.
- **No debug-viz differentiation.** `Sim::nav_traversability`
  shows the merged result. There's no per-cell color split between
  "default-walkable" and "force-walkable", or between "feature-
  blocked" and "force-blocked." Same goes for the in-editor
  Terrain3D painter — slot 14/15 visually look like
  `nordic_moss` / `mine_rock_wall` until designers swap in
  distinct nav-paint textures via the asset list.

## Related

- [`planning/sim-iteration-5-13-plan.md`](../planning/sim-iteration-5-13-plan.md) — the full iteration plan, including the POI obstacle stamping (Phase B) and the offline waypoint graph (Phase C) that compose with this designer paint layer.
- [`planning/npc-traversal-plan.md`](../planning/npc-traversal-plan.md) — the broader Phase 2 split: outdoor designer overrides (this page) + indoor `NavigationRegion3D` / `Area3D` (still planning-only).
- [`walkthroughs/terrain3d.md`](terrain3d.md) — the wider Terrain3D pipeline this paint flow piggybacks on.
- [`architecture/crate-guide.md`](../architecture/crate-guide.md) — `Heightmap::nav_override_at`, `GridNavQuery::cell_override`, and the `nav_mask.r8` file format spec.
