# Worldgen - OSM Ingest - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-23
**Scope:** an offline ingest pipeline that consumes OpenStreetMap (or Overture Maps) building data for a selected region and emits a canonical, engine-agnostic worldgen artifact that `simn-godot` loads at scene build time to spawn per-building scene objects anchored to `simn-terrain`. Companion to the existing `../walkthroughs/terrain.md`, and a consumer of `destruction-plan.md` (buildings are destructibles), `physics-tiering-plan.md` (building physics tier), and the future World Ledger (`world-ledger-plan.md`, persistent per-building state).

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**OSM gives us layout, not assets.** The goal is not photoreal city reproduction. It's to get *plausible urban structure* - footprint polygons, rough heights, block topology - into Noosphere cheaply, so that any region we want to set a scenario in can have a believable city without hand-placing every building. Art fidelity comes from our own material/prefab library applied to OSM-derived geometry, not from the source data.

Consequence: the ingest pipeline is a *data transform*, not an asset pipeline. It emits **structured footprint + attribute records**, not meshes. Meshing happens at runtime in `simn-godot` using the same material and roof-generation code we'd use for hand-authored buildings. This keeps a single rendering path.

---

## 2. What This System Does / Does Not Do

**Does:**

- Pull a bounded region of OSM/Overture data (by bbox or polygon).
- Resolve each building to a canonical record: footprint polygon, base elevation, roof shape, height, material hints, OSM id, tags.
- Bake auxiliary layers we care about: road centerlines, water polygons, railway, named landmarks.
- Emit one versioned binary artifact per region, checked in or downloaded at build time.
- Spawn queryable per-building scene nodes at runtime with colliders, visuals, and stable IDs for sim/journal use.

**Does not:**

- Generate interiors. OSM doesn't have them. Hand-authored for story-critical buildings; procedural later if ever.
- Produce photoreal geometry. No window/door detail, no façade textures pulled from imagery.
- Replace hand-authoring for landmarks. See §13.
- Ship at runtime in the shipping game. The offline tool runs in the dev pipeline; only the baked artifact ships.
- Handle terrain heightfields. Ground is `simn-terrain`'s job; worldgen *reads* terrain to anchor buildings.

---

## 3. Crate Layout

New workspace member: `crates/simn-worldgen`. Engine-agnostic, no `godot` dep.

```
crates/simn-worldgen/
├── Cargo.toml                  # deps: osmpbf, geo, serde, bincode, ron,
│                               #       tracing, anyhow, xxhash-rust, reqwest (feature = "fetch")
├── assets/
│   └── overpass_queries/       # reusable Overpass QL snippets
└── src/
    ├── lib.rs                  # public data types re-exported for simn-godot
    ├── bin/
    │   └── ingest.rs           # CLI: `cargo run -p simn-worldgen --bin ingest -- ...`
    ├── sources/
    │   ├── mod.rs
    │   ├── overpass.rs         # Overpass API fetch (bbox / polygon)
    │   ├── pbf.rs              # Geofabrik regional .osm.pbf reader
    │   └── overture.rs         # Overture parquet reader (future)
    ├── resolve.rs              # tag → height / roof / material resolution
    ├── layers.rs               # building, road, water, rail, landmark extraction
    ├── bake.rs                 # emit canonical WorldgenArtifact (bincode)
    ├── records.rs              # canonical types (see §5)
    └── terrain_probe.rs        # read simn-terrain heightfield to anchor building base
```

`simn-godot` gains a dep on `simn-worldgen` (types only, no fetching code compiled into the shipping dylib). The ingest binary is dev-time only.

---

## 4. Data Source - Recommendation

Three candidates, picked one primary and one secondary:

| Source                        | Schema quality | Height coverage | Fetch ergonomics       | License             |
|-------------------------------|----------------|-----------------|------------------------|---------------------|
| **Overpass API** (live OSM)   | Raw OSM tags   | Spotty          | HTTP, rate-limited     | ODbL                |
| **Geofabrik regional PBF**    | Raw OSM tags   | Spotty          | Bulk download          | ODbL                |
| **Overture Maps** (parquet)   | Normalized     | Merged OSM + MS | Cloud / S3             | CDLA-Permissive 2.0 |

**Primary source: Overture Maps.** The `buildings` theme has already merged OSM footprints with Microsoft's height-enriched dataset and normalized the schema. Fewer custom fallbacks needed. CDLA-Permissive is simpler than ODbL for our purposes.

**Secondary source: Overpass for top-up.** When Overture is stale or missing a feature class we want (e.g. a specific railway tag we care about for scenario work), fall back to a targeted Overpass query for that sub-layer only. Geofabrik PBF is the Overpass alternative for offline/large-region ingest - same data, bulk file instead of live query.

Both sources share the OSM tag vocabulary once parsed, so the downstream pipeline is source-agnostic past `sources::*`.

---

## 5. Canonical Types

```rust
// crates/simn-worldgen/src/records.rs

pub struct WorldgenArtifact {
    pub version: u32,                 // bincode-with-version
    pub region: RegionMetadata,
    pub buildings: Vec<BuildingRecord>,
    pub roads: Vec<RoadRecord>,
    pub water: Vec<WaterRecord>,
    pub rails: Vec<RailRecord>,
    pub landmarks: Vec<LandmarkRecord>,
}

pub struct RegionMetadata {
    pub name: String,                 // human-readable ("pripyat_center")
    pub origin_latlon: (f64, f64),    // projection anchor
    pub bbox_min: Vec2,               // local (x,z) meters
    pub bbox_max: Vec2,
    pub source: SourceTag,            // Overture | Overpass | Pbf
    pub source_timestamp: i64,        // unix seconds - for reproducibility
    pub terrain_revision: u64,        // simn-terrain heightfield fingerprint
}

pub struct BuildingRecord {
    pub stable_id: u64,               // see §9
    pub osm_id: Option<i64>,          // for traceback / re-ingest
    pub footprint: Vec<Vec2>,         // CCW outer ring, local meters
    pub holes: Vec<Vec<Vec2>>,        // inner rings (courtyards)
    pub base_elevation_m: f32,        // from terrain probe at centroid
    pub min_height_m: f32,            // building:min_level*3 or min_height
    pub height_m: f32,                // resolved via §6 priority ladder
    pub height_source: HeightSource,  // Tag | Levels | Heuristic | Default
    pub roof: RoofRecord,
    pub material_hint: MaterialHint,  // mapping into our prefab material library
    pub tags: CompactTagSet,          // condensed subset of OSM tags we care about
}

pub struct RoofRecord {
    pub shape: RoofShape,             // Flat | Gabled | Hipped | Pyramidal | Dome | Skillion | Onion
    pub height_m: f32,
    pub orientation_deg: f32,         // for gabled / skillion
    pub material_hint: MaterialHint,
}

pub enum MaterialHint {
    Panelka, Brick, Concrete, WoodFrame, CorrugatedMetal,
    Industrial, Glass, Stone, Unknown,
}

pub struct RoadRecord {
    pub centerline: Vec<Vec2>,
    pub class: RoadClass,             // Motorway..Residential..Track..Path
    pub lanes: u8,
    pub width_m: f32,
    pub surface: SurfaceHint,
}

pub struct LandmarkRecord {
    pub stable_id: u64,
    pub osm_id: Option<i64>,
    pub name: String,                 // "Duga radar", "Rostov arena"
    pub kind: LandmarkKind,           // Military | Industrial | Religious | Memorial | ...
    pub position: Vec2,
    pub override_prefab: Option<String>,  // hand-authored scene path if present
}
```

Bincode with a leading `version: u32` and a small migration table in `bake.rs` for forward compatibility. RON mirror for debugging (`--emit-ron` on the ingest CLI); bincode is the ship format.

---

## 6. Height Resolution - Priority Ladder

Mapper-provided height coverage is uneven. Resolution falls through a fixed ladder, recording which rung fired so we can audit quality:

1. `height=*` tag (explicit meters) → `HeightSource::Tag`
2. `building:levels=*` × 3.0 m + `roof:height=*` → `HeightSource::Levels`
3. Heuristic by `building=*` class:
   - `apartments` → 4 levels × 3 m = 12 m (post-Soviet panelka default: 5 levels × 3 m = 15 m, gated by region tag)
   - `industrial` / `warehouse` → 8 m
   - `commercial` / `retail` → 6 m
   - `house` → 1 level × 3 m = 3 m + 2 m gabled roof
   - `church`, `cathedral` → 15 m + 10 m roof
   - ... (table lives in `resolve.rs`, overridable per-region via a RON file)
   - → `HeightSource::Heuristic`
4. Default fallback → 4 m → `HeightSource::Default`

Per-region overrides are explicit: a region config RON can declare "this bbox uses Soviet panelka defaults" and shift the heuristic table. No global fudge factors; the ladder must be auditable.

`resolve.rs` emits warnings for (a) heuristic-rung buildings whose footprint area is > 2000 m² (large buildings should have real heights), and (b) roof shape absent on any building with `height > 20`. Ingest reports print these counts for a region.

---

## 7. Terrain Integration

Buildings anchor to `simn-terrain`'s canonical heightfield. The ingest binary reads the same heightmap bytes the game loads (currently `godot/scenes/<scene>/*.r16` or equivalent - follow `simn-terrain::TerrainMaps::ground_at`).

**Anchoring rule:** a building's `base_elevation_m` is `ground_at(centroid)`. Walls extrude from `max(ground_at(vertex))` for each footprint vertex to `base_elevation_m + height_m`, so a building on a slope doesn't "float" on the uphill side or "bury" on the downhill side. Mesh is generated with a skirt from `base_elevation_m - slope_depth` to `base_elevation_m` filled with terrain-matching material so slopes read cleanly. `slope_depth` is computed per building from max-min vertex elevation.

**Terrain revision guard:** the artifact records `terrain_revision` (xxh3 of heightfield bytes). If the terrain heightfield is re-baked, all artifacts touching that region are invalidated and must be re-ingested. `simn-godot` refuses to load an artifact whose revision doesn't match the loaded terrain and logs a `godot_error!` with the regeneration command.

This is the same extent-convention rule that bit us (2026-04-23, see CLAUDE.md Critical Rules): `(W-1)*spacing`, not `W*spacing`. The worldgen sampler and the Godot-side sampler must share the terrain probe code, not reimplement it. `simn-worldgen::terrain_probe` delegates to `simn-terrain` primitives; no duplicate math.

---

## 8. Offline Ingest Pipeline

```
                   ┌─────────────────────┐
                   │  region config RON  │  (bbox, sources, overrides)
                   └──────────┬──────────┘
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
      ┌──────────┐      ┌──────────┐      ┌──────────┐
      │ Overture │      │ Overpass │      │   PBF    │
      │  fetch   │      │  fetch   │      │   read   │
      └─────┬────┘      └─────┬────┘      └─────┬────┘
            └─────────────────┼─────────────────┘
                              ▼
                    ┌──────────────────┐
                    │  layers::extract │  building/road/water/rail/landmark
                    └────────┬─────────┘
                             ▼
                    ┌──────────────────┐
                    │  resolve::heights│  §6 ladder
                    └────────┬─────────┘
                             ▼
                    ┌──────────────────┐
                    │ terrain_probe    │  anchor to simn-terrain
                    └────────┬─────────┘
                             ▼
                    ┌──────────────────┐
                    │   bake::emit     │  WorldgenArtifact (bincode)
                    └────────┬─────────┘
                             ▼
                  godot/worldgen/<region>.wga
```

CLI:

```bash
cargo run -p simn-worldgen --bin ingest -- \
    --region godot/worldgen/configs/pripyat_center.ron \
    --out    godot/worldgen/pripyat_center.wga
```

Region config RON captures everything needed for reproducibility:

```ron
// godot/worldgen/configs/pripyat_center.ron
WorldgenRegionConfig(
    name: "pripyat_center",
    bbox: (51.3950, 30.0900, 51.4200, 30.1150),  // lat/lon min/max
    source: Overture(release: "2026-03-12"),
    fallback_source: Some(Overpass),
    terrain_scene: "godot/scenes/pripyat_center.tscn",
    heuristic_preset: PostSovietPanelka,
    overrides: {
        // OSM id → forced override (rare; prefer fixing upstream in OSM)
        "123456789": HeightOverride(height_m: 78.0),
    },
)
```

Artifacts live in `godot/worldgen/*.wga` and are checked in (binary, small - see §11).

---

## 9. Stable IDs

Same scheme as `world-ledger-plan.md` §6 so that per-building persistent state (damage, looting, destruction) keys cleanly into the future World Ledger.

For OSM-derived buildings:

```rust
pub fn stable_id_from_osm(region_name: &str, osm_id: i64) -> u64 {
    let region_hash = xxh3_64(region_name.as_bytes());
    (region_hash & 0xFFFF_FFFF_0000_0000) | ((osm_id as u64) & 0x0000_0000_FFFF_FFFF)
}
```

Region-namespaced so the same OSM id in two artifacts can't collide. `osm_id` negative (relation-derived) is shifted into the positive u32 space with a fixed offset; collisions with real `osm_id` values are hash-detectable at ingest time (ingest fails loudly rather than silently renumbering).

For landmarks with `override_prefab` set, the stable_id persists even if we later switch the building from OSM-extruded to hand-authored - so Ledger state (damage, looted containers) survives the upgrade.

---

## 10. Runtime - Godot Integration

`simn-godot` gains a `WorldgenLoader` class (one gdext `GodotClass`), called once at scene load:

```rust
#[godot_api]
impl WorldgenLoader {
    #[func] fn load_artifact(&mut self, path: GString) -> i32 { ... }
    #[func] fn building_count(&self) -> i32 { ... }
    #[func] fn building_by_id(&self, stable_id: i64) -> Variant { ... }
    #[func] fn buildings_in_radius(&self, origin: Vector3, r: f32) -> PackedInt64Array { ... }
    #[signal] fn building_spawned(stable_id: i64);
}
```

Spawning is batched: `load_artifact` streams the bincode, then an internal scheduler spawns N buildings per frame until the spatial index is populated. Each building becomes a `StaticBody3D` with:

- One `CollisionShape3D` per building part (convex decomposition of the extruded polygon, baked in `bake.rs` to avoid runtime decomposition).
- One `MeshInstance3D` with a material picked by `MaterialHint` from the prefab library.
- A groups tag `"osm_building"` plus the stable_id set as a metadata property.
- A `Destructible` component (see `destruction-plan.md`) wired up with HP defaults from `MaterialHint`.

GDScript side, a thin scene script exposes signals for gameplay: `building_entered(id)`, `building_exited(id)`, built off Area3D sensors when we need them (not every building, only story-relevant ones).

Road, water, rail, and landmark layers are separate spawners - roads emit `PathFollow3D`-friendly curves for NPC navigation (tie-in to future sim-brain work), water emits decals, landmarks spawn either their `override_prefab` scene or a procedural placeholder.

---

## 11. Storage, LOD, and Spatial Index

Artifact size, back-of-envelope: a dense 1 km² urban region might hold ~5,000 buildings × ~150 bytes per record ≈ 750 KB. Plus roads, water, rail, landmarks - call it ~1.5 MB / km² worst case. That's fine to check in per region at the sizes we care about. Lines-of-communication-class regions (20 km × 20 km, mostly rural) stay under 50 MB.

**Spatial index:** a flat grid over the bbox with ~128 m cells, built post-load, mapping cell → `Vec<stable_id>`. `buildings_in_radius` and the online/offline tier transition both use it.

**LOD:**

- **Online tier (near players):** full mesh + collision, per §10.
- **Offline tier (distant / server-only):** no mesh, no colliders. Buildings persist as `BuildingRecord` rows in memory for AI knowledge (LOS checks, "is this cell occluded?", patrol pathing). The ECS carries them as components without a Godot visual. Transition online on player proximity.
- **Middle LOD (future):** impostor billboards generated at bake time for distant visual silhouettes. Parked until we know the visual budget.

This ties into `physics-tiering-plan.md`: buildings are Tier 2 (static collision) when online, not instanced at all when offline.

---

## 12. Determinism and Reproducibility

A worldgen artifact is reproducible from:

- The region config RON (checked in).
- The OSM/Overture source at the timestamp recorded in `RegionMetadata.source_timestamp`.
- The terrain heightfield at the fingerprint recorded in `RegionMetadata.terrain_revision`.

Re-running `ingest` against the same inputs must yield a byte-identical `.wga` file. Tests (§15) enforce this. Determinism matters because these artifacts participate in save compatibility - a saved game references `stable_id`s that must resolve to the same buildings on reload.

Source snapshots: for Overture, we pin the release. For Overpass (live), the ingest records the query timestamp and caches the raw response into `godot/worldgen/cache/<region>_<timestamp>.osm.xml` alongside the artifact, so re-ingest from cache is deterministic even if upstream OSM changes.

---

## 13. Landmark Override Workflow

Story-critical buildings (main quest locations, faction HQs, puzzle spaces) are hand-authored in Godot as ordinary scenes. The override hooks in at two points:

1. **Tag-based:** a landmark RON file lists `(osm_id, scene_path)` pairs. During ingest, any matched building gets `landmark.override_prefab = Some(scene_path)` and its `BuildingRecord` omitted from the generic buildings list (to prevent double-spawn).
2. **Runtime fallback:** if the scene file in `override_prefab` is missing, `WorldgenLoader` falls back to procedural extrusion and logs a `godot_warn!`. This keeps the world loadable through art-pipeline churn.

The stable_id survives the transition - a building can start life as OSM-extruded for blockout, gain a hand-authored scene mid-development, and retain its Ledger state (damage, loot rolls) across the upgrade.

---

## 14. Licensing and Attribution

- **Overture (CDLA-Permissive 2.0):** attribution required in the shipping game's credits ("Built with Overture Maps data © Overture Maps Foundation"). No copyleft on the game.
- **OSM (ODbL):** if Overpass or PBF is used, attribution required ("Includes OpenStreetMap data © OpenStreetMap contributors"). Produced meshes/scenes are "Produced Works" under ODbL - no share-alike obligation on the game binary. ODbL obligations apply only if we redistribute a derivative *database*; redistributing `.wga` artifacts does count, so if we ship artifacts they must carry the ODbL notice and the source attribution file.
- **Attribution page:** a runtime credits scene reads `docs/book/src/credits-data.md` (or equivalent) so attributions stay in one place and update with the artifacts.

---

## 15. Phasing / Rollout

Each phase is its own PR. No phase is "task complete" until the mechanics doc (or walkthrough, once graduating) lands alongside the code.

**Phase 0 - Exploration (no commit required):** pick one small test region (~1 km² - a Pripyat sub-block makes a good test; dense and height-rich in OSM). Hand-craft a target artifact by any means; use it to validate the `WorldgenArtifact` data shape.

**Phase 1 - Crate + canonical types:** land `simn-worldgen` with `records.rs`, `bake.rs`, and a stub ingest binary that reads a hand-crafted RON and emits bincode. No real source fetch yet. Tests cover serialization round-trip. Docs: `crate-guide.md` entry.

**Phase 2 - Overture fetch + resolution ladder:** `sources::overture.rs` + `resolve.rs`. Single-region end-to-end ingest (RON config → `.wga`). Tests cover the height ladder on fixture data.

**Phase 3 - Godot loader, minimal:** `WorldgenLoader` gdext class, spawns `StaticBody3D` per building with extruded mesh + box collider (no convex decomposition yet). Single region loads in Godot, colliders work against player capsule. Mechanics doc: `mechanics/world-buildings.md` (or rolled into an existing chapter).

**Phase 4 - Terrain anchoring:** `terrain_probe.rs`, skirt geometry, slope handling. Buildings stop floating/burying. Matches the `(W-1)*spacing` convention.

**Phase 5 - Roof shapes + material hints:** parametric flat/gabled/hipped/pyramidal roofs, `MaterialHint` → prefab material mapping. Pripyat panelka preset applied.

**Phase 6 - Landmark override:** per §13. Tested by overriding one Pripyat landmark to a hand-authored scene.

**Phase 7 - Offline tier integration:** ties into the online/offline sim tiers. Distant regions carry `BuildingRecord` in memory without Godot visuals, used for LOS/AI.

**Phase 8 - Overpass fallback + PBF source:** secondary sources for completeness.

**Phase 9 - Destructible integration:** buildings opt into `Destructible` per `destruction-plan.md`. Ledger persistence per `world-ledger-plan.md`.

Once Phase 3 ships, this plan doc graduates partially: `mechanics/world-buildings.md` starts holding the player-facing contract, this plan retains the forward-looking content. At Phase 9 the plan graduates to `walkthroughs/worldgen-osm.md` and this file is deleted.

---

## 16. Testing

### 16.1 Unit tests (`simn-worldgen`)

- `WorldgenArtifact` bincode round-trip preserves every field.
- Height resolution ladder: fixture buildings with tag / levels / heuristic / default inputs all produce the expected `height_m` and `height_source`.
- Stable ID: `stable_id_from_osm` is deterministic, collision-free over a fixture dataset of 10k OSM ids, region-namespaced (same osm_id, different region → different stable_id).
- Terrain probe: fixture heightfield + footprint → expected `base_elevation_m`, `min_vertex_elevation_m`. Matches `simn-terrain::TerrainMaps::ground_at` (delegation test, not reimplementation).
- Ingest determinism: given identical inputs, two ingest runs produce byte-identical `.wga` output.

### 16.2 Integration tests (with `simn-godot`)

- `WorldgenLoader::load_artifact` on a 100-building fixture spawns exactly 100 `StaticBody3D`s in the expected groups.
- `buildings_in_radius` matches a brute-force check against the fixture.
- Terrain revision mismatch: swap the terrain heightfield and verify the loader refuses the artifact with an informative error.
- Override fallback: artifact references a missing scene; loader falls back to procedural extrusion and emits the expected warning.

### 16.3 Manual validation

- Visually inspect a baked region in the Godot editor.
- Player capsule movement over anchored terrain doesn't clip into buildings, and buildings don't float on slopes (the reason §7 exists).

---

## 17. Open Questions

- **Footprint decimation.** Raw OSM polygons can be 30+ vertices on what's effectively a rectangle. Do we run a Visvalingam-Whyatt pass at bake time? How aggressive? Probably yes; open question on tolerance.
- **Holes (courtyards).** Extrusion mesh with inner rings works; does Godot's trimesh collider accept the CSG output cleanly, or do we need convex decomposition per wall segment? Test in Phase 3.
- **Cross-scene boundaries.** If a region is split across multiple scenes (streaming), do buildings at the seam get split, duplicated, or canonicalized? Probably a seam-resolver layer after the spatial index. Defer past Phase 7.
- **OSM multipolygon relations.** OSM encodes complex buildings (stadiums, malls) as `relation`s with outer/inner members. `sources::overture` smooths most of this; `sources::overpass` needs a relation assembler. Defer to Phase 8.
- **Road mesh vs decal.** Are roads full mesh ribbons with navmesh integration, or are they visual decals on terrain with NPC navigation reading the centerlines directly? Leaning decal + centerline, matches offline-tier philosophy, but Phase 7 will decide.
- **Landmark glTF source.** For hand-authored landmarks, where do assets come from - full original art, or licensed/CC-BY models from Sketchfab/Smithsonian (noted in the earlier database discussion)? Decision per-landmark.
- **Data refresh cadence.** OSM updates continuously; artifacts are checked-in. Do we schedule periodic re-ingest (e.g. monthly) to catch new mapping, or only re-ingest on explicit request? Tooling should make re-ingest cheap so cadence is a policy, not a capability gap.
- **Cities outside OSM-rich regions.** If a scenario calls for an area with thin OSM coverage (rural Rostov, back-country Cascades), the heuristic ladder dominates. Quality is floor-limited. Acceptable for blockout; may need scenario-specific hand-touch-up.
- **Legal review on CDLA + ODbL mixing.** Phase 8 introduces both. Need to confirm with counsel once we're closer to shipping whether the two-source attribution model is clean or if we should commit to Overture-only in the shipping build.

---

## 18. Cross-References

- `../walkthroughs/terrain.md` - heightfield that buildings anchor to.
- `destruction-plan.md` - buildings are destructibles once Phase 9 lands.
- `physics-tiering-plan.md` - buildings are Tier 2 online, culled offline.
- `world-ledger-plan.md` - persistent per-building state keys on the stable_id scheme in §9.
- `ecosystem-plan.md` - urban areas constrain creature spawning graphs.
- `../mechanics/world-buildings.md` (future) - the player-facing contract for urban areas, lands with Phase 3.
