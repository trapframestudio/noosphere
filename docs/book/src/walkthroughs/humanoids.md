# Humanoids: sim → dummy → damage

This walkthrough traces the end-to-end path for NPC humanoids in
Noosphere, from the authoritative sim tick to the click-to-fire
debug weapon that damages a specific body part. It connects the
four independent pieces the `humanoid-dummies` slice landed so a
new contributor can find the relevant code for any step along the
way.

Reference files (worktree-relative):
- `crates/simn-sim/src/systems/npc_spawn.rs` - NPC component bundle
- `crates/simn-sim/src/world/mod.rs` - `Sim::apply_damage_to_npc_part`, `NpcView`
- `crates/simn-sim/src/delta.rs` - `WorldDelta::SetNpcBodyPart`
- `crates/simn-godot/src/sim/mod.rs` - `#[func] damage_npc_part`, `npcs_in_region`
- `crates/simn-godot/src/los.rs` - collision-layer contract
- `godot/scripts/layers.gd` - GDScript bitmask constants
- `godot/scenes/humanoid_dummy.tscn` - segmented body + per-part colliders
- `godot/scripts/humanoid_dummy.gd` - LOD + collider gating
- `godot/scripts/weapon_raycast.gd` - hit resolver
- `godot/scripts/game_session.gd` - NPC roster polling + dummy lifecycle
- `godot/scripts/player.gd` - LMB fire binding

## 1. Sim authority: NPC with BodyParts

Every NPC entity in `simn-sim` now carries a `BodyParts` component
alongside the pre-existing `Health` aggregate. `npc_spawn` attaches
`BodyParts::new_full()` in the spawn bundle; `NpcSpawned` replay
does the same so journal replay rebuilds the per-part state; and
`spawn_serialized` falls back to `BodyParts::new_full()` for NPCs
loaded from pre-migration snapshots that predate the component.

`Health.current` is maintained as a mirror of
`min(BodyParts.head, BodyParts.torso)` on every per-part mutation.
That keeps `npc_death_check` working unchanged - it still gates
death on `Health.current <= 0` - while per-part HP becomes the
addressable source of truth.

The per-part mutation entry points are:
- `Sim::apply_damage_to_npc_part(id, part, amount)` - subtract HP,
  clamp to `[0, max]`, journal `WorldDelta::SetNpcBodyPart`.
- `Sim::heal_npc_part(id, part, amount)` - mirror for healing.

The probabilistic NPC-vs-NPC combat model in
`systems/npc_combat.rs` drains `BodyParts.torso` directly (no
journal - recovered from the next snapshot, matching the behavior
that existed before the migration), and on above-threshold torso
hits also spawns an ephemeral Bleed wound for bleed-drain.

NPCs carry `Wounds` + `ActiveEffects` and participate in the full
per-tick wound pipeline (`apply_bleed_damage`, `tick_infection`,
`age_and_heal_wounds`, `tick_necrosis`). Above-threshold damage
through `Sim::apply_damage_to_npc_part` spawns a Bleed + journals
`NpcWoundAdded`. The seven treatment methods mirror the player API
(`Sim::apply_bandage_npc` / `apply_tourniquet_npc` /
`remove_tourniquet_npc` / `apply_disinfectant_npc` /
`apply_stitch_npc` / `apply_wound_pack_npc` /
`apply_antibiotics_npc`) and each journal a parallel
`NpcWoundTreatmentChanged` or `NpcEffectApplied`. Bridge
`#[func]`s expose them to GDScript; no caller wires them up yet,
but the symmetric surface is ready for NPC AI self-treatment or
player medic actions. The `npcs_in_region` view dict also surfaces
a per-NPC `wounds` array matching the player state schema.

## 2. Bridge: `npcs_in_region` carries per-part HP

`simn-godot`'s `SimHost` polls the sim every physics tick and
exposes `npcs_in_region(region_name: String) -> Array` to GDScript.
Each entry is a `Dictionary` with the schema documented in
`docs/book/src/api/sim-host.md` - relevant keys here:

- `id: int` - stable `NpcId`, used to route damage back.
- `pos: Vector3`, `yaw: float` - transform for the dummy.
- `health: float` - aggregate `min(head, torso)` mirror.
- `body_parts: Dictionary` - per-part current HP, keys
  `"head"` / `"torso"` / `"left_arm"` / `"right_arm"` / `"left_leg"` /
  `"right_leg"`. Omitted only for pre-migration NPCs that haven't
  re-spawned yet.

`SimHost` also exposes `damage_npc_part(npc_id, part, amount)` and
`heal_npc_part(...)` for the weapon hit path to call.

## 3. View layer: humanoid dummy scene

`godot/scenes/humanoid_dummy.tscn` replaces the old capsule pill.
The root is an `AnimatableBody3D` (kinematic - its transform is
set from sim position each frame, no physics integration). Six
per-part `MeshInstance3D` nodes live under a `Body` container, and
six `CollisionShape3D` nodes hang directly off the root (they must
be direct children of the `CollisionObject3D` to register).

Each `CollisionShape3D` carries a `body_part` string metadata
(`"head"`, `"torso"`, `"left_arm"`, `"right_arm"`, `"left_leg"`,
`"right_leg"`). Weapon raycasts read this metadata to resolve which
sim-side `BodyPart` took the hit.

The dummy's `collision_layer` is `Layers.NPC_HITBOX` (bit 2 = 4)
at near-LOD; at mid / far LOD the script clears
`collision_layer = 0` so physics doesn't track hitboxes for
dummies the player can't accurately aim at anyway. LOD tiers
(`humanoid_dummy.gd`):

- **Near** (<100m): full segmented body visible, colliders live.
- **Mid** (100–250m): billboard quad, colliders off.
- **Far** (>250m): hidden, colliders off. `game_session`'s
  `NPC_DRAW_DISTANCE_M = 300` culls entirely beyond ~300m.

`GameSession._sync_npc_dummies` polls `SimHost.npcs_in_region(...)`
at 20 Hz, spawns new dummies as NPCs enter draw range, updates
existing dummy transforms, and frees dummies whose NPC left the
region or drifted past the cull. Position interpolation between
sync frames is done in the dummy's own `_process` - smooth at
render rate, independent of the 20 Hz sync cadence.

## 4. Layer contract: humanoids don't occlude themselves

The three collision layers in play:

| Bit | Constant           | Role                                                |
|----:|--------------------|-----------------------------------------------------|
| 0   | `Layers.SOLID`     | World geometry - walls, buildings, terrain, rock.   |
| 1   | `Layers.CONCEALMENT` | Foliage, smoke, cloth - partial LOS attenuation.  |
| 2   | `Layers.NPC_HITBOX` | All humanoid bodies (player + NPC dummies).        |

Two masks fall out of those:

- `LOS_QUERY_MASK` (Rust side) = `SOLID | CONCEALMENT`. NPC
  perception raycasts deliberately exclude bit 2 so humanoids
  never occlude sight lines to other humanoids. This is the
  invariant that makes the whole layer scheme work.
- `Layers.WEAPON_HIT_MASK` = `SOLID | CONCEALMENT | NPC_HITBOX`.
  Bullets stop on world, bushes, or humanoids.
- `Layers.PLAYER_MOVE_MASK` = `SOLID | NPC_HITBOX`. The player
  stops on world geometry and on NPC dummies, but walks through
  CONCEALMENT.

The numeric bits are authored in `.tscn` files as raw literals;
call sites in GDScript / Rust go through the named constants. Keep
`godot/scripts/layers.gd` and `crates/simn-godot/src/los.rs` in
sync - the docstring at the top of `los.rs` is the single source
of truth for the semantic contract.

## 5. Weapon fire → body-part damage

Once the mouse is captured (first click captures), LMB fires the
weapon equipped at the player's active slot. Weapons are items
defined in `crates/simn-sim/data/items.toml` (e.g. `pistol_makarov`,
`rifle_aks74`, `shotgun_saiga`); each carries a `weapon_config`
block with caliber / damage / range / fire_interval / spread.
Player equips one to the `primary` / `secondary` / `sidearm` paper-
doll slot. `Q` / `E` cycle the active slot, `R` reloads (pulls the
best-loaded matching-caliber mag from pockets). The HUD bottom-
right shows the active weapon's name + `<loaded>/<capacity>` ammo.
The flow:

1. Gate on `_fire_cooldown_s <= 0.0`. LMB spam is rate-limited to
   the weapon's `fire_interval_s`.
2. Call `SimHost.fire_weapon(steam_id, slot_id)`. The sim looks up
   the weapon's `weapon_config` from the `ItemDef`, decrements one
   round from the loaded magazine, journals `WorldDelta::WeaponFired`,
   and returns `{ ok, weapon_config, remaining_rounds, error }`.
   On dry-click (empty mag / no mag) `ok=false` and the client
   doesn't raycast.
3. With the returned `weapon_config`, build a ray from
   `camera.global_position` forward with `_apply_spread` applying a
   uniform-random yaw + pitch in `[-spread_deg, spread_deg]`.
   Range is the weapon's `range_m`.
4. Call `WeaponRaycast.resolve_hit(space, origin, direction,
   max_dist, [player.get_rid()])`. The player excludes itself so
   it never shoots through its own capsule.
5. The resolver does a `PhysicsDirectSpaceState3D.intersect_ray`
   against `Layers.WEAPON_HIT_MASK` and, if the hit is a humanoid
   dummy, reads:
   - `npc_id` - a script property on the dummy root, set by
     `configure(view)` when the dummy is spawned.
   - `body_part` - read off the struck `CollisionShape3D`'s
     metadata via the `shape_find_owner` →
     `shape_owner_get_owner` chain on the hit's `shape` index.
6. If both are populated, the player calls
   `SimHost.damage_npc_part(npc_id, body_part, weapon_config.damage)`.
7. The sim drains the matching pool, journals a
   `WorldDelta::SetNpcBodyPart`, and - if damage is above the
   wound threshold - also spawns a Bleed wound + journals
   `NpcWoundAdded`. The aggregate `Health.current` mirror updates.
8. On the next tick, `npc_death_check` sees `Health.current <= 0`
   if head or torso hit 0 and journals `WorldDelta::NpcDied`.

Head shots kill ~2× faster than torso shots because head and
torso both gate death and neither pool protects the other. Limb
shots don't kill on their own - limbs at 0 flip `limb_disabled`
but stay off the death gate (consistent with the player damage
model).

## Verification

With two NPCs in a test map:
1. Approach within 100m so near-LOD is active (segmented body
   visible, colliders on bit 2).
2. Press `Tab` to show debug labels; watch the per-NPC HP tag.
3. Walk into a dummy - you should be blocked, not pass through.
4. Click once to capture the mouse, then click again to fire. The
   console prints `[fire] npc=<id> part=<part> dmg=25.0`. The
   target's debug label drops the corresponding pool; aggregate
   `health` mirrors `min(head, torso)`.
5. Four head shots (4 × 25 = 100) kills via `npc_death_check`.
   Torso takes the same; limbs will never kill on their own.
6. Step behind a solid wall - NPCs lose aggro within the next
   perception tick (exposure = 0).
7. Step into a CONCEALMENT prop (if the test map has one) - NPCs
   may or may not aggro depending on the `exposure_required`
   threshold × `concealment_visibility` scalar.

## What's not yet done

- **NPC AI self-treatment.** An NPC taking a heavy hit doesn't
  decide to bandage itself. The treatment API is in place; a later
  slice wires it up via the tactical-AI / sim-brain layer.
- **Player-to-NPC medical.** A medic-class player can't yet
  bandage a downed ally NPC. The API supports it; gameplay-side
  wiring (action dispatch + ammo/item consumption) lands later.
- **Projectile physics, audio, and trace visuals.** Phase 1 weapons
  (items in `items.toml` + reload + `fire_weapon`) landed the
  data-driven skeleton; projectile simulation + ballistic drop
  (Phase 2), attachment slot-tag data graph (`sim-iteration-5-12`
  Phase 4C), and parts condition + jams v1 (`sim-iteration-5-12`
  Phase 4D) are live. Runtime stat aggregation across attachments
  and the per-part condition roster are the remaining
  `weapons-plan.md` debts.
- **NPC-vs-NPC aimed body-part targeting.** `sim-iteration-5-12`
  Phase 4A v2 made hit resolution geometric — projectile sweep
  against humanoid hitboxes lands on head / torso / limbs based
  on aim + cone-of-fire jitter. Previously all dice damage went
  to the torso.
- **Humanoid animation / IK / directional facing beyond yaw.**
  Dummies are T-pose-ish posed geometry only.
