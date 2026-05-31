# POI / Region / Transition Authoring

Hand-placed nodes that mark world content for the offline NPC graph,
faction systems, and inter-map transitions. All three are `@tool`
Node3D subclasses under `godot/scripts/world/` — drop them into a
scene from the Add Node dialog ("PoiMarker", "RegionMarker",
"MapTransition") and configure via the inspector.

This is the authoring surface for [npc-traversal-plan.md](../planning/npc-traversal-plan.md)
§4. The bake tool that consumes these nodes is designed but not yet
built; until it ships, the nodes sit in scenes as future-data without
any runtime effect (other than `MapTransition3D`'s scene swap, which
works today).

## When to use which

| Node | Use for | Footprint |
|---|---|---|
| `RegionMarker3D` | Naming a chunk of space ("cascade_locks", "outpost_west_interior"). Becomes a `RegionId` in the offline graph. | Volumetric — drop a `CollisionShape3D` child to define the bounds. |
| `PoiMarker3D` | A single point: a faction base, an NPC anchor, or any of the 13 point-of-interest kinds (cache, ruin, trader, door, loot container, quest hook, vehicle spawn, etc.). | Point — uses the node's transform position. |
| `MapTransition3D` | Player-trigger volume that swaps to another map scene. | Volumetric — `CollisionShape3D` defines the trigger zone. |
| `EncounterTrigger3D` | Volumetric trigger that fires an encounter (combat / ambush / scripted event / dialog / cutscene) when a player enters. | Volumetric — `CollisionShape3D` defines the trigger zone. |
| `FaultZone3D` | Localized hazard field (gravity / electric / chemical / thermal / psy / radiation) plus shard-spawn ring around it. NPCs hunt shards in the orbit. | Volumetric — `CollisionShape3D` defines the hazard zone; `shard_spawn_radius_m` defines the wider shard ring. |

Quick decision tree: if it has a footprint and represents a *space*,
use `RegionMarker`. If it's a *thing* at a point, use `PoiMarker`. If
it's a doorway between maps, use `MapTransition`.

## RegionMarker3D

Coarse per-map region for the offline graph. Today (terrain-only
maps), drop **one** per `.tscn` with `region_id = "<map_id>"` wrapping
the playable extent. When buildings arrive, add interior
`RegionMarker3D`s (`region_id = "cascade_locks_outpost_a_interior"`
etc.) to subdivide.

| Property | Default | Notes |
|---|---|---|
| `region_id` | `""` | Stable snake_case identifier. Required. Must be unique within the scene. |
| `region_kind` | `exterior` | `exterior` / `interior` / `transition`. Drives offline-tier behaviour hints. |
| `tags` | `{}` | Free-form metadata. Bake tool serializes verbatim. |

The configuration warnings catch: empty `region_id`, missing
`CollisionShape3D` child, sibling-id collision.

## PoiMarker3D

A single point of interest. The `kind` enum spans every authored POI
category currently in the codebase or planning docs:

- **`BASE_*`** — faction-claimable bases. Mirrors `simn-sim::BaseKind`
  exactly: `BASE_CHECKPOINT`, `BASE_OUTPOST`, `BASE_SAFEHOUSE`,
  `BASE_HEADQUARTERS`, `BASE_RESEARCH_POST`, `BASE_CAMP_SITE`. Set
  `faction` to assign ownership.
- **`ANCHOR_*`** — NPC behaviour hints from npc-traversal-plan §4:
  `ANCHOR_SPAWN` (materialization spawn point), `ANCHOR_PATROL` (loop
  waypoint), `ANCHOR_SLEEP` (rest position).
- **Generic landmarks** — `LANDMARK`, `CACHE`, `RUIN`, `TRADER`,
  `DOOR`, `LOOT_CONTAINER`, `QUEST_HOOK`, `VEHICLE_SPAWN`.
  Placement first; sim mechanic later. `CACHE` is hand-placed unique
  loot (story / quest items); `LOOT_CONTAINER` is a procedural loot
  spawn point. `DOOR` is for in-scene room-to-room portals (full
  cross-scene transitions go on `MapTransition3D`).
  *(Faults graduated to the volumetric `FaultZone3D` node — see
  below — since hazard zone + shard spawn ring are inherently
  volumetric.)*

| Property | Default | Notes |
|---|---|---|
| `poi_id` | `""` | Stable identifier; becomes the offline-graph poi key. Required. |
| `kind` | `LANDMARK` | See above. |
| `faction` | `NONE` | Only meaningful for `BASE_*`. NONE = unowned / neutral. |
| `tags` | `{}` | Free-form metadata. |
| `contested` | `false` | Participates in the rotating-ownership system. Only meaningful for `BASE_*` kinds. See "Contested bases" below. |
| `contest_tier` | `1` | Strategic importance 1–4. Drives attack cadence + garrison size + capture reward (sim impl pending). Only meaningful when `contested = true`. |
| `show_debug_visual` | `true` | Color-coded sphere + Label3D billboard in the editor. Off in builds. |

Warnings fire on: empty `poi_id`, faction set on non-`BASE_*` kind
(likely a mistake), `BASE_*` kind with `faction = NONE` (loadable, but
unintentional for an outpost), `contested = true` on a non-`BASE_*`
kind (only bases participate in contestation), `contest_tier > 1`
with `contested = false` (tier is only consumed when contested).

### Contested bases

A `BASE_*` POI with `contested = true` opts into the rotating-
ownership system: factions can take, hold, and lose control through
attacks. The `faction` field is the *starting / canonical* owner;
runtime ownership flips as attacks resolve and is reset to the
authored faction at world re-seed.

`contest_tier` (1–4) drives the contestation tick:

| Tier | Reading | Expected impact |
|---|---|---|
| 1 | minor checkpoint / camp | low attack cadence, small garrison, low capture reward |
| 2 | standard outpost | moderate cadence, normal garrison |
| 3 | important outpost / hub | frequent attacks, larger garrison, meaningful reward |
| 4 | major faction asset | constant pressure, strong garrison, decisive capture reward |

**TODO(sim):** the contestation tick itself doesn't exist yet. The
markers are authoring intent; once `simn-sim` ships the contestation
system, it will scan `poi_markers` for `contested = true` BASE_*
nodes and maintain a `ContestedBase` component per the table above.
Tracked alongside the `npc-traversal-plan.md` consumers — unblocked
once the faction-AI planner exists.

### Faction enum drift detection

The `Faction` and `BASE_*` lists in `poi_marker.gd` mirror
`simn-sim::Faction::ALL` and `simn-sim::BaseKind::ALL` in declaration
order. Drift is caught by
[`crates/simn-sim/tests/poi_enum_sync.rs`](https://github.com/anthropic/noosphere/blob/main/crates/simn-sim/tests/poi_enum_sync.rs)
at build time — workflow when adding a faction:

1. Add the variant to `crates/simn-sim/src/faction.rs`'s `Faction`
   enum AND its `Faction::ALL` const.
2. Run `cargo test -p simn-sim --test poi_enum_sync`.
3. Test fails with a side-by-side diff naming the missing GDScript
   variant. Add it to `poi_marker.gd`'s `enum Faction`.
4. Re-run the test → green. Same workflow for `BaseKind`.

## MapTransition3D

Player-trigger volume that loads another scene and places the player
at a named spawn marker in the target.

| Property | Default | Notes |
|---|---|---|
| `target_scene` | `""` | `@export_file("*.tscn")`. Required. |
| `target_spawn_node_name` | `""` | Name of a node in the target to spawn at. Resolved via `find_child` on scene-load. |
| `fade_seconds` | `0.6` | Fade-out duration before scene swap. 0 = instant. |
| `trigger_groups` | `["player"]` | Bodies in any of these groups trigger the transition. |

The scene-load uses `change_scene_to_file`. The target spawn lookup
hands off via `Engine.set_meta(&"map_transition_spawn_target", ...)`
so the destination scene's session script can read and apply it on
`_ready`. Wiring that read on the target side is owned by
`game_session.gd` (or its successor) — not this node.

Warnings fire on: empty `target_scene`, missing scene file on disk,
no `CollisionShape3D` child, empty `trigger_groups`.

### Single-fire guard

Once triggered, a `MapTransition3D` sets `_fired = true` to prevent
re-entry during the fade-out window. The flag resets when the node
goes through `_exit_tree` (i.e. when the scene unloads), so coming
back to the same map and re-entering the volume works as expected.

## EncounterTrigger3D

Volumetric trigger for encounters — combat / ambush / scripted event
/ dialog / cutscene — that fire when a body in `trigger_groups`
enters. Volumetric (not a `PoiMarker3D` Kind) because encounters
cover space, not a single point.

| Property | Default | Notes |
|---|---|---|
| `encounter_id` | `""` | Stable identifier the dispatcher routes on. Required. |
| `encounter_kind` | `COMBAT` | `COMBAT` / `AMBUSH` / `SCRIPTED_EVENT` / `DIALOG` / `CUTSCENE`. Categorical hint for the dispatcher. |
| `trigger_groups` | `["player"]` | Bodies in any of these groups fire the trigger. |
| `fires_once` | `true` | Single-shot vs recurring. One-shots can be reset via `reset_fired_flag()` for editor / debug iteration. |
| `tags` | `{}` | Free-form metadata for the dispatcher (combat table, ambush composition, dialog id, etc.). |

The node emits an `encounter_triggered(encounter_id, encounter_kind,
body)` signal on activation. Wiring that signal to an actual
encounter dispatcher is downstream — until the dispatcher exists,
the signal fires into the void and the trigger is a placement
contract for future systems.

**TODO(sim):** wire `encounter_triggered` into the encounter
dispatcher when it lands. Until then, encounter behaviour data
lives in `tags`; once the typed dispatcher data model exists,
fold those tags into typed exports.

## FaultZone3D

Localized hazard field with a shard-spawn ring. Volumetric
because the hazard zone, the shard orbit, and the NPC interest
radius all have extent — collapsing them onto a point would force
every consumer (damage tick, shard spawn, NPC hunt) to invent its
own radius from `tags`.

| Property | Default | Notes |
|---|---|---|
| `fault_id` | `""` | Stable identifier for the fault + shard systems. Required. |
| `fault_kind` | `GRAVITY` | `GRAVITY` / `ELECTRIC` / `CHEMICAL` / `THERMAL` / `PSY` / `RADIATION`. Drives damage type, visual effect, and default shard pool. |
| `shard_spawn_radius_m` | `8.0` | Wider radius (meters) where shards manifest. Typically 1.5–3× the hazard footprint. NPC interest radius even when `shard_pool` is empty. |
| `shard_pool` | `""` | Tag key into the shard loot table. Empty = use `fault_kind`'s default pool. |
| `danger_tier` | `1` | 1 (mild) – 4 (lethal). Drives damage scale, shard rarity, NPC bravery threshold. |
| `respawn_seconds` | `600.0` | Seconds between charge cycles. 0 = one-shot / hand-set; positive = recurring. |
| `tags` | `{}` | Free-form metadata for the shard-spawn / hunt systems. |

The hazard footprint comes from the `CollisionShape3D` child (sphere
for typical faults, box for "wall of acid" / linear hazards). The
debug visual shows a translucent sphere at the *shard* spawn
radius — the hazard zone is already drawn by Godot's collision-shape
gizmo, so the shard ring is what needs an additional hint.

**TODO(sim):** wire two consumers when the fault system lands.
- **Damage tick** walks `get_overlapping_bodies()` per fault,
  applies damage scaled by `danger_tier` + `fault_kind`. Per-kind
  effects (gravity throw, electric stun, chemical DoT, etc.) live
  in the damage system.
- **Shard spawn / NPC hunt** scans `fault_zones` group on a
  slow tick, schedules manifests via `respawn_seconds`, and
  broadcasts hunt-interest events to NPCs filtered by faction
  bravery vs `danger_tier`. NPCs path to a point sampled in the
  `[hazard, shard_spawn_radius_m]` ring (the shard orbit) and
  grab on contact.

## Volume vs point — the authoring contract

Five kinds of placement exist in this directory; the rule is:

- If the thing has a **footprint** that gameplay needs to
  distinguish (you're inside / outside / damaged-by-it / queryable
  by NPCs as "I'm in this volume"), it's a **volumetric** node:
  `RegionMarker3D`, `MapTransition3D`, `EncounterTrigger3D`,
  `FaultZone3D`, `ProceduralExclusionZone`.
- If the thing is a **logical record at a position** (a faction
  base, an NPC anchor, a container, a door pivot), it's a
  **`PoiMarker3D`** Kind.

Edge cases:
- A faction base has a footprint, but the *base record* (kind +
  faction + contestation state) is logically a point at a canonical
  anchor. If you need the base's *territory* for sim queries, place
  a companion `RegionMarker3D` and tag them together. Don't conflate
  the two roles in one node.
- Same for ruins: `Kind::RUIN` is the anchor; use `RegionMarker3D`
  with `region_kind=interior` for the volumetric "you're inside the
  ruin" concern.

This separation keeps the offline-graph bake tool simple — it walks
each group once, doesn't disambiguate dual-purpose nodes.

## What these feed into (future)

- **Offline-graph bake tool** (`npc-traversal-plan.md` §6). Walks
  `region_markers` and `poi_markers` groups across all `.tscn` files,
  validates, and emits a `region-graph.bin` artifact for `simn-sim`.
- **NPC materialization** (`tier-transition-plan.md` + traversal §7).
  When a player gets close to an offline NPC's region, the bridge
  uses `ANCHOR_SPAWN` markers (or a random navmesh point as fallback)
  to place the entity online without spawning inside walls.
- **Faction territorial control.** `BASE_*` markers with `faction`
  ownership feed the territorial-control layer of `simn-sim`.
- **Contestation tick.** `BASE_*` with `contested = true` rotate
  ownership on attack-resolve cycles tuned by `contest_tier`.
- **Encounter dispatcher.** `EncounterTrigger3D`'s
  `encounter_triggered` signal feeds the encounter system (combat /
  ambush / scripted event / dialog / cutscene routing).
- **Fault + shard systems.** `FaultZone3D` group queries
  drive the damage tick, shard manifest scheduling, and NPC
  shard-hunt interest broadcasts.

Until those consumers exist, the markers are inert authoring data
(except `MapTransition3D`'s scene swap, which works today). That's
intentional — placing them now means the scenes are ready when the
consumers land.
