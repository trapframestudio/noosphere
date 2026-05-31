# Destruction - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-23
**Scope:** how buildings, base fortifications, and world props take damage and persist across sessions. Hybrid granularity - cheap for the vast majority of world content, detailed for things players care about defending. Companion to `physics-tiering-plan.md` (tier promotion on transition), `world-ledger-plan.md` (where state is stored), and internal design notes (Squalls as a refresh mechanic).

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**Server owns an enum, client owns the spectacle.** No physics voxel destruction, no Chaos-style geometry collections. Destructibles transition between a small number of authored states; the state is authoritative and cheap to replicate; the debris that flies when a state transition happens is Tier 2 physics that scales per-peer.

Consequence: the game can feature meaningful destruction throughout the world without a per-object simulation budget, and base defense can be tactical (specific sections matter) without requiring every rural shack to track individual walls.

---

## 2. Three Classes of Destructible

| Class         | Granularity        | States                                        | Persistence      | Examples                                             |
|---------------|--------------------|-----------------------------------------------|------------------|------------------------------------------------------|
| Prop          | Whole object       | `Intact`, `Damaged`, `Destroyed`              | One row when non-Intact | Crates, barrels, furniture, fences               |
| WorldBuilding | Whole building     | `Intact`, `Scarred`, `Breached`, `Ruined`     | One row when non-Intact | Abandoned houses, ruins, generic structures      |
| BaseSection   | Per-section        | `Intact`, `Damaged`, `Destroyed`              | One row per section when non-Intact | Walls, roof panels, doors, fortification pieces  |

**Hybrid granularity matches asymmetric importance.** Player bases and hub fortifications (`BaseSection`) deserve the authoring and persistence cost of per-section state. Random world ruins (`WorldBuilding`) get a cheap whole-building state. Props (`Prop`) get a simple three-state machine.

### 2.1 Why not uniform section-level everywhere?

Considered and rejected:

- 10× the row count in the Ledger for buildings the player never interacts with.
- 10× the authoring work for decorative ruins that don't reward it.
- NavMesh baking cost explodes.

The hybrid split gives us what matters (tactical base defense) at 1/10th the cost of going fully granular.

---

## 3. ECS Representation

New components in `crates/simn-sim/src/components/destructible.rs`:

```rust
pub struct Destructible {
    pub stable_id:        u64,
    pub prefab_id:        u16,
    pub class:            DestructibleClass,
    pub state:            DestructibleState,
    pub hp:               f32,
    pub max_hp:           f32,
    pub squall_behavior: SquallBehavior,
}

#[repr(u8)]
pub enum DestructibleClass { Prop = 0, WorldBuilding = 1, BaseSection = 2 }

#[repr(u8)]
pub enum DestructibleState {
    Intact    = 0,
    Damaged   = 1,  // Prop / BaseSection
    Scarred   = 1,  // WorldBuilding (shares discriminant with Damaged deliberately)
    Destroyed = 2,  // Prop / BaseSection
    Breached  = 2,  // WorldBuilding
    Ruined    = 3,  // WorldBuilding only
}

#[repr(u8)]
pub enum SquallBehavior {
    Reset       = 0,  // Squall scrubs the row, defaults reassert
    Preserve    = 1,  // Squall ignores - hub states, player bases
    DamageRoll  = 2,  // Squall rolls stochastic damage against current state
}

// Composition relationship for player bases
pub struct BaseSectionOf(pub BaseId);
```

Destructibles are ECS entities with standard `Position` + `InRegion` + `InFaction` (for hub ownership) siblings. The `Destructible` component is what makes them damageable.

### 3.1 Migration-safe with existing `Base`

The existing `Base { kind: BaseKind }` component (Checkpoint, Outpost, Safehouse, Headquarters, ResearchPost, CampSite) stays as-is. `Base` is a *faction-authority* marker; player-built base composition (when it lands) uses `Destructible` + `BaseSectionOf` siblings on separate entities.

The two don't conflict. An NPC-held Outpost has a `Base` component and a `Health` pool (existing). A player crew's fortified position has a `PlayerBase` component (new, with `BaseId`) and a set of child entities each with `Destructible` + `BaseSectionOf(base_id)`.

---

## 4. Damage Flow

### 4.1 Input: hit events from the damage model

The existing damage pipeline (see `../mechanics/damage-and-healing.md`) terminates today in `apply_damage_to_part` / `apply_damage` on players / NPCs. Destructibles get a parallel event channel:

```rust
pub struct DestructibleHitEvent {
    pub entity:       Entity,
    pub damage:       f32,
    pub hit_point:    Vec3,
    pub hit_dir:      Vec3,
    pub source:       DamageSource,
}

pub enum DamageSource {
    Projectile { caliber_class: CaliberClass, impact_energy_j: u32 },
    Explosion  { radius_m: f32, overpressure_kpa: f32 },
    Melee      { kind: MeleeKind },
    Environmental { kind: EnvironmentalKind },  // fire, fall, Squall
}
```

Weapons systems (future, see `weapons-plan.md`) and explosion systems emit these events when their raycasts / overlap queries hit a `Destructible`.

### 4.2 System: `apply_destructible_damage`

```rust
pub fn apply_destructible_damage(
    mut q:      Query<&mut Destructible>,
    mut events: EventReader<DestructibleHitEvent>,
    mut deltas: ResMut<PendingDeltas>,
    ledger:     Res<WorldLedger>,
    clock:      Res<SimClock>,
) {
    for ev in events.read() {
        let Ok(mut d) = q.get_mut(ev.entity) else { continue };
        if is_terminal(d.state, d.class) { continue; }

        d.hp = (d.hp - ev.damage).max(0.0);
        let new_state = compute_state(d.class, d.hp, d.max_hp);

        if new_state != d.state {
            let old_state = d.state;
            d.state = new_state;

            // Journal (authoritative event, replay-critical)
            deltas.push(WorldDelta::DestructibleStateChange {
                stable_id: d.stable_id,
                old_state,
                new_state,
                tick: clock.tick,
            });

            // Ledger (materialized view of state)
            ledger.upsert_world_object(d.stable_id, WorldObjectRecord {
                prefab_id: d.prefab_id,
                class: d.class,
                state: d.state,
                hp: d.hp,
                region_id: /* from query */,
                last_modified: clock.tick,
                metadata: bincode::serialize(/* ... */).unwrap(),
            });

            // Emit gib burst (Tier 2) if state changed to a visible-break state
            if is_visible_break(old_state, new_state) {
                spawn_gib_burst(d.prefab_id, ev.hit_point, ev.hit_dir);
            }
        } else {
            // HP changed but no state transition - still journal the damage
            // as a delta so replay reproduces HP exactly
            deltas.push(WorldDelta::DestructibleDamaged {
                stable_id: d.stable_id,
                new_hp: d.hp,
                tick: clock.tick,
            });
        }
    }
}
```

### 4.3 State thresholds

```rust
fn compute_state(class: DestructibleClass, hp: f32, max_hp: f32) -> DestructibleState {
    let pct = hp / max_hp;
    match class {
        DestructibleClass::Prop => match pct {
            p if p <= 0.0  => DestructibleState::Destroyed,
            p if p <= 0.4  => DestructibleState::Damaged,
            _               => DestructibleState::Intact,
        },
        DestructibleClass::WorldBuilding => match pct {
            p if p <= 0.0  => DestructibleState::Ruined,
            p if p <= 0.25 => DestructibleState::Breached,
            p if p <= 0.6  => DestructibleState::Scarred,
            _               => DestructibleState::Intact,
        },
        DestructibleClass::BaseSection => match pct {
            p if p <= 0.0  => DestructibleState::Destroyed,
            p if p <= 0.4  => DestructibleState::Damaged,
            _               => DestructibleState::Intact,
        },
    }
}
```

Thresholds tunable per prefab via `metadata` overrides. Default table above.

---

## 5. Stable IDs

See `world-ledger-plan.md` §6 for the canonical ID scheme. Summary:

- **Scene-placed destructibles** get `stable_id = (xxh3_64(scene_path) << 32) | placement_hash(u32)`. `placement_hash` is authored at scene-export time by a GDScript tool script that walks the tree.
- **Player-placed** (dynamic base sections) get `uuid_v7` truncated to u64 at construction time.
- Optional `stable_id_override` export on the gdext component pins an ID through scene renames.

Stable IDs survive server restarts, client patches, and minor scene edits. They are load-bearing for the entire Ledger architecture.

---

## 6. Godot Scene Template

Each destructible is authored as a scene with state variants already in place. No runtime mesh generation, no authored "destroy animation."

```
Destructible (StaticBody3D)
├── CollisionShape3D_Intact     (enabled only when state == Intact)
├── CollisionShape3D_Damaged    (enabled only when state == Damaged / Scarred)
├── CollisionShape3D_Destroyed  (enabled only when state == Destroyed / Ruined)
├── MeshInstance3D_Intact
├── MeshInstance3D_Damaged
├── MeshInstance3D_Destroyed
├── GibBurstPrefab              (PackedScene ref, instantiated on state change)
├── SFX_Impact                  (AudioStreamPlayer3D, non-terminal hits)
├── SFX_Destroy                 (AudioStreamPlayer3D, state change to Destroyed)
└── DestructibleComponent       (gdext node from simn-godot)
      stable_id:         u64
      prefab_id:         u16
      max_hp:            f32
      damage_threshold:  f32
      destroy_threshold: f32
      squall_behavior:  u8        // enum
      class:             u8        // enum
```

The `DestructibleComponent` gdext node:

1. On `_ready`, registers itself with `SimHost` by `stable_id`. The sim resolves current state from the Ledger (or defaults to Intact).
2. Subscribes to state-change notifications for its stable_id.
3. On state change, toggles the appropriate mesh/collision variant, instantiates `GibBurstPrefab` if transitioning to a visible-break state.
4. Plays SFX on any state change.

Template-driven authoring: a base scene with script that auto-wires visibility/collision by state. Artists swap in three mesh variants and set thresholds.

### 6.1 WorldBuilding with 4 states

Same template with four mesh/collision variants (`_Intact`, `_Scarred`, `_Breached`, `_Ruined`). The extra state is why this class gets a dedicated case in `compute_state`.

### 6.2 BaseSection composition

A player base scene is a parent `Node3D` containing many `Destructible` children, each tagged as `BaseSection` with a `BaseSectionOf` sibling pointing at the parent's `BaseId`. Each section is its own entity with its own HP and state.

No structural integrity cascading - a destroyed wall doesn't collapse a roof. Base defense is about specific sections, not physical plausibility.

---

## 7. Physics-Tier Interaction

Destructibles are almost always **Tier 0** (static baked collider). Key behaviors:

- **Intact state**: Tier 0. Collider and mesh for Intact variant active. Zero physics sim cost.
- **State transition**: the `Destructible` entity itself stays Tier 0; only the swapped-in state's mesh/collider becomes active. But the *gib burst* spawns N Tier 2 chunks with impulses radiating from the hit point.
- **Gib chunks**: Tier 2 for their motion period (~1s), then settle to Tier 1, then despawn as Tier 4 (after ~10–30s). Never persisted - the state transition is the persistent fact; the debris is ephemeral.
- **Destroyed/Ruined state**: still Tier 0, now with destroyed-state collider and mesh. Nav exclusion lifts (see §8) so NPCs can path through.

**Gib burst count** scales with Tier 2 pressure:

```rust
let desired = prefab.gib_count;
let headroom = (tier2_ceiling - current_tier2_count).max(0);
let actual = desired.min(headroom / 2);  // leave some headroom for subsequent events
```

On a slammed server mid-Squall, gib bursts naturally thin out. Still satisfying because the state transition itself is broadcast reliably.

See `physics-tiering-plan.md` for the full tier definitions and budget management.

---

## 8. Navigation

NavMesh is baked per region at map-author time with all destruction states in mind:

- **WorldBuilding**: bake navmesh with the `Ruined` state geometry (most permissive - interior walkable). At runtime, apply a nav-exclusion overlay tied to the non-Ruined states. Result: an Intact building has its interior marked impassable; a Breached or Scarred building still has the exclusion (maybe shrunk); a Ruined building has the exclusion lifted.
- **BaseSection**: bake with all sections `Destroyed`. Apply per-section exclusions tied to section state. A standing wall excludes a thin strip; a destroyed wall lifts its exclusion and the nav flows through.
- **Prop**: props don't affect navmesh - too small. Individual prop colliders are used for raycast/collision but navmesh routes around prop cells at bake time, unchanged.

**No runtime navmesh rebuilds.** Exclusion overlays are a runtime filter, not a recompile.

Trade-off: NPC pathing through mid-transition geometry (a Scarred building with half a roof gone) may look slightly suboptimal. Acceptable - the NPCs still path through the allowed space; they just don't get a new shortcut that the half-broken geometry would permit.

---

## 9. Replication

Destructible state is **gameplay-critical** (see `physics-tiering-plan.md` §6). Replication:

- `DestructibleStateChange` broadcasts reliably to all peers on the gameplay-critical channel. Not priority-budgeted. Always delivered, always in order.
- `DestructibleDamaged` (HP changes below the state-transition threshold) replicates at a lower rate - batched, best-effort, every ~1s. Cosmetic only; the client uses HP to choose whether to show the "smoldering" particle intensity etc.
- Gib chunks replicate through the Tier 2 priority system. Peer on fiber sees all chunks fly; peer on congested Wi-Fi sees a handful. Both peers see the state transition.

This means even a peer in degraded-physics mode still sees the state change correctly - the building collapsed for them too, there's just no cinematic debris.

---

## 10. Interaction with Squalls

`SquallBehavior` tag on each destructible class drives Squall-refresh behavior (see `world-ledger-plan.md` §11 and internal design notes):

| Behavior      | Action on Squall end                                                      |
|---------------|---------------------------------------------------------------------------|
| `Reset`       | Ledger row deleted; state reverts to Intact                               |
| `Preserve`    | Row untouched                                                             |
| `DamageRoll`  | Stochastic damage roll scaled by Squall severity; state may transition    |

Default assignments (tunable per prefab):

- Generic props, ambient world furniture: `Reset`
- World buildings in ruins: `DamageRoll` at low severity (already-ruined buildings shrug off), `Preserve` at full ruin
- Hub fortifications: `Preserve`
- Player bases: `DamageRoll` on unfortified sections, `Preserve` on upgraded sections
- Scripted set-pieces: `Preserve`

---

## 11. Tests

### 11.1 Unit tests (`simn-sim::destructibles`)

- `damage_below_threshold_stays_intact` - hit with damage that doesn't cross the threshold; state unchanged; no state-change delta.
- `damage_triggers_state_transition` - hit that crosses threshold emits `DestructibleStateChange` delta and Ledger upsert.
- `destroyed_is_terminal` - further hits on a Destroyed prop are no-ops.
- `prefab_threshold_overrides` - destructibles with custom thresholds transition at those thresholds.
- `squall_reset_behavior` - simulate Squall end; `Reset`-tagged row deleted.
- `squall_damage_roll` - simulate Squall end; `DamageRoll`-tagged destructibles take damage scaled by severity.

### 11.2 Integration tests

- **Destructible state persists across restart.** Damage a prop to `Damaged`, shutdown sim, restart, verify row present and state correct.
- **Journal replay rebuilds Ledger.** Delete world.db, restart - reconciliation from journal tail should reinstate Ledger state up to latest snapshot + journal.
- **Destructible state visible to new peer.** Peer A damages a prop; Peer B joins mid-session; Peer B sees the Damaged state immediately on region entry.

---

## 12. Authoring Workflow

For artists/designers adding a new destructible:

1. Model three mesh variants (`_Intact`, `_Damaged`, `_Destroyed`) in the asset pipeline. For WorldBuilding: four variants.
2. Build collision shapes per variant (usually simpler than render geometry).
3. In Godot, create a scene from the `Destructible.tscn` template; drag in the meshes and collisions; set thresholds on the `DestructibleComponent`.
4. Set `squall_behavior` based on the class conventions (§10).
5. Optionally author a `GibBurstPrefab` - a small PackedScene that spawns N chunks with random impulses. Reusable across prefabs of a material family (wood, metal, concrete).
6. Place the scene in a map. The `placement_hash` is auto-assigned at export time by the tool script.

That's it. No code required per prefab.

---

## 13. Open Questions

- **HP scaling per caliber class.** A .22 LR should not meaningfully damage a concrete bunker section. Do we add a per-prefab "resistance profile" (armor value per damage type) or bake it into the damage-model side? Leaning toward damage-model side - destructibles have one HP pool, the damage model decides what fraction of the incoming damage applies based on caliber vs prefab material tag. Needs a tag vocabulary (wood, sheet-metal, masonry, reinforced-concrete, bunker) in `metadata`.
- **Partial repair.** Can a player repair a Damaged wall back to Intact? Yes, in principle - repair flips state backward, journals the transition. Needs a repair-item system (see `survival-and-crafting-plan.md`).
- **Destructible chained destruction.** If a supporting pillar goes Destroyed, does the roof above it also take damage? Considered and deferred - too tempting to over-engineer. If base defense playtesting wants it, revisit.
- **Per-material gib variants.** Wood building and concrete building probably want different gib chunk meshes. Currently `GibBurstPrefab` is per-prefab; moving to per-material shared prefabs would reduce authoring. Defer until we have >20 prefabs.
- **Mod-defined classes.** Modders may want custom state machines (e.g. 5-stage decay for special vehicle wrecks). Likely need a `Custom { state_count: u8 }` variant of `DestructibleClass` with data-driven thresholds. v0.3.
- **Fire propagation.** Is a Damaged wooden prop flammable? If so, does fire spread to adjacent props? Separate system; probably fits into a larger "environmental effects" plan doc. Defer.

---

## 14. Cross-References

- `physics-tiering-plan.md` - gib bursts are Tier 2, state transitions are gameplay-critical.
- `world-ledger-plan.md` - `world_object_state` table stores destructible rows.
- internal design notes - Squalls trigger the refresh pass that respects `SquallBehavior`.
- `../mechanics/damage-and-healing.md` - existing damage pipeline that destructibles extend.
- `weapons-plan.md` - where projectile → `DamageSource` conversion lives.
- `loot-and-economy-plan.md` - destructibles aren't loot containers themselves, but destroyed containers may spill contents as Tier 3 settled objects.
- `../architecture/crate-guide.md` - `simn-sim` adds the `Destructible` component; `simn-godot` adds the `DestructibleComponent` gdext class; `simn-world` stores the state.
