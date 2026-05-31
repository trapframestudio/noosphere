# Interaction Areas

**Drop a scene node, tell NPCs to do a thing there.**

Iteration 5-13 Phase D shipped a designer-placed surface for
"NPCs should occupy this spot and do X" — rest spots, work
benches, guard posts, scavenge piles, anything where the
intent is *go to this exact place and stay a while*. The
authoring layer is a `Node3D` you drop in the editor; the sim
side is a per-region registry the squad planner consults when
scoring objectives.

Complements [Terrain3D Nav-Paint](terrain3d-nav-paint.md) (the
*outdoor* designer layer over walkable terrain) and
[POI authoring](poi-authoring.md) (region landmarks):
nav-paint says where NPCs *can* go, interaction areas say
where they *should* go.

## TL;DR

1. **Add Node → search "InteractionAreaMarker3D"** in your map
   scene.
2. Set `interaction_kind` to `"rest"`, `"work"`,
   `"socialize"`, `"scavenge"`, `"guard_post"`,
   `"patrol_node"`, `"campfire"`, `"workbench"`, or any
   mod-defined string.
3. Set `extents` to the area's XZ footprint half-size, and
   `capacity` to the max concurrent occupants.
4. Optionally pin `faction` (must match a `factions.toml`
   id) and `area_id` (stable per-spot key).
5. Save the scene. On next map load the sim picks them up via
   the `&"interaction_area_markers"` group walk.

## What the sim does with each kind

Phase D3 v1 wires only `"rest"` into NPC behavior — squads
scoring a `Rest` objective prefer a nearby rest area over a
generic base position. The other canonical kinds are
recognized vocabulary slots that will graduate to scored
behaviors in later iterations:

| Kind | Phase D3 behavior | Phase D follow-up plan |
|---|---|---|
| `rest` | Squads pick this over a base when scoring `Rest` and one is within 150 m of the squad centroid. Reservation honors `capacity`. | — |
| `work` | Recognized, low-utility generic visit. | New `SquadObjective::Work` kind. |
| `socialize` | Recognized, low-utility generic visit. | New `SquadObjective::Socialize` kind. |
| `scavenge` | Recognized, low-utility generic visit. | Scavenger-AI objective. |
| `guard_post` | Recognized, low-utility generic visit. | Couples to the existing posted-Guard slot system. |
| `patrol_node` | Recognized, low-utility generic visit. | Chain through these in `SquadObjective::Patrol::route`. |
| `campfire` | Special-case of `rest` for evening / weather (TBD). | — |
| `workbench` | Special-case of `work` for crafting (TBD). | — |
| `(anything else)` | Stored as-is; mod systems can consume the string. | — |

## Authoring details

### Editor gizmo

The marker draws a wire box at `extents * 2` with a billboard
label showing the kind. Box color is keyed off the kind so a
glance at the scene tree tells you the role:

- `rest` = green
- `work` = blue
- `socialize` = warm yellow
- `scavenge` = orange-brown
- `guard_post` = red
- `patrol_node` = purple
- `campfire` = orange
- `workbench` = steel-grey-blue
- unknown = neutral grey

Toggle the gizmo off via `show_debug_visual = false` if you
want the area to live in the scene without cluttering the
viewport.

### `area_id`

Empty `area_id` → the bridge auto-derives
`auto:<region>:<x>_<z>` from integer-rounded XZ. Stable
enough for the sim's `by_id` index across editor reloads, but
*not* stable enough for replication / save references —
production maps should set an explicit snake_case id
(map-prefixed: `"camp_riverbend_rest_1"`).

### `faction`

Empty string = any faction can reserve. Set to a faction id
from `factions.toml` (`pwa`, `looters`, `federal`, …) to
restrict. Unknown strings fall back to "any" with a single
warn at bridge enumeration time — typos surface in the log.

### `capacity`

Max concurrent occupants. Default 1 (one squad slot per
spot). `Sim::reserve_interaction_area` returns `false` past
the cap; the squad planner falls back to the base-position
`Rest` when its preferred area is full.

### `tags`

Free-form `Dictionary[String, String]` passed through the
bridge as a `HashMap<String, String>`. Phase D3 doesn't read
them — they're a future-proofing slot for mod scripts and the
upcoming objective kinds. Use them for things like
`{ "shelter": "covered", "time_of_day": "evening" }` that a
weather-aware rest scorer can pick up.

## Sim side

Stored as `simn_sim::resources::InteractionAreas`
(`Resource`, transient — content-rebuilt from scene markers
on every `Sim::attach_region_interaction_areas`). Three
public APIs are the working surface:

```rust
sim.attach_region_interaction_areas(region_id, areas);
sim.reserve_interaction_area(area_id, Some(faction_id)); // -> bool
sim.release_interaction_area(area_id);                    // -> bool
```

Plus a slice view `sim.interaction_areas_in_region(region)`
for tests + squad-planner scoring.

The Godot bridge `#[func] attach_region_interaction_areas`
parses `Array<Dictionary>` and ships everything; the
GDScript caller in `real_map.gd` / `test_map.gd` walks the
`&"interaction_area_markers"` group on map load.

## Events

Two `WorldEventKind` variants land on the world-event bus:

- `InteractionStarted { npc_id, area_id, kind }` — fired on
  first arrival per `(npc_id, area_id)` pair (deduped via a
  resource-side `started` set so a slow-walking squad doesn't
  spam the queue every tick of contact).
- `InteractionEnded { npc_id, area_id }` — fired by the
  squad planner for every NPC that was Started at the area
  when the objective gets replaced.

Both events carry a 0 m audible radius and `Audience::Anyone`
— they flow through the bus to PDA / replication consumers
without poisoning nearby squad blackboards. PDA toast wiring
lands separately; the events are bus-deliverable today.

## Limitations (Phase D3 v1)

- **Only `"rest"` drives behavior.** Other kinds are
  vocabulary slots — the planner doesn't score them yet.
- **Reservations are sim-side only.** The marker scene tree
  doesn't know how many squads have a slot reserved. Restart
  → marker scene is the source of truth for placement, but
  occupancy resets to zero (no snapshot persistence).
- **PDA toasts not wired yet.** The events are emitted on
  the bus, but the PDA log subscription bridging
  `InteractionStarted/Ended` to player-visible toasts is a
  separate follow-up.
- **No NPC-leaves-extents detection.** Ended fires on
  objective swap, not on an NPC physically walking out of
  the area's extents mid-Rest. If a downstream consumer
  needs that, add the leave detection in `tick_npc_goals`
  next to the Started emit.

See `docs/book/src/planning/sim-iteration-5-13-plan.md`
"Phase D" for the design decisions, and
`docs/book/src/architecture/crate-guide.md` for the
implementation-level notes.
