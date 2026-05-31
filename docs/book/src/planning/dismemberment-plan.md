# Dismemberment & Reactive IK - Planning Doc

**Status:** step 1 (NPC body-part unification + `LimbState` substrate) landed 2026-05-07 (PR #147). Caliber-driven `WoundKind`, reactive IK, and dismemberment visuals still planning.
**Last updated:** 2026-05-09
**Scope:** how characters respond physically to gunshots and explosions (reactive IK), and how limb severing integrates with the existing wound pipeline. Companion to `../mechanics/damage-and-healing.md` (the landed wound system this extends), `../walkthroughs/tactical-ai.md` (NPC combat future), and `weapons-plan.md` (caliber/energy inputs).

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**Gore is caliber-driven, not a global dial.** What happens when a bullet hits a body is a deterministic function of caliber class, impact energy, hit location, and range. A shotgun slug at mid-range makes a large entry hole. A point-blank shotgun to the elbow severs. A .338 Lapua to the head gibs. A 9mm at 80m does a small wound. The same rules apply to every character - player, NPC, mutant - with no global "gore level" flag.

Consequence: damage feels physically grounded. Players learn the weapon behaviors; weapons develop individual identity through their terminal effects; dismemberment is a meaningful mechanical event, not a randomized spectacle.

**Separate from gore: reactive IK.** A hit that doesn't sever should still produce a physical reaction - the arm pulls back along the impact vector, the torso rocks from a blast, the head snaps when a bullet grazes it. This is not an authored animation; it's a transient IK goal applied over the active animation. Cheap, endlessly varied, and it solves the "combinatorial explosion of hit-reaction animations" problem outright.

---

## 2. Scope vs the Existing Wound System

The existing wound pipeline (`../mechanics/damage-and-healing.md`) is landed and sophisticated:

- Per-body-part HP (6 parts) — currently **player-only**.
- `Wound` instances with severity, treatment state (Untreated/Disinfected/Bandaged/Stitched/Tourniquet/WoundPacked/Healed), bleeding, infection, necrosis.
- Aggregate `Health` mirrored from `min(head, torso)`.

**Decided 2026-05-05: NPCs use the same body-part wound pipeline as players** (online tier only — offline tier collapses to `HealthClass` per [`offline-tier-plan.md`](offline-tier-plan.md)). Today NPCs only carry the aggregate `Health` component; they need to gain `BodyParts` + `Wounds` + the full wound tick pipeline to participate in this plan. Combat applies hit to specific body parts via the projectile collision system in [`physical-combat-plan.md`](physical-combat-plan.md) §4. Limb-zeroing semantics: a zeroed arm or leg becomes `Severed` (per §3 below), which **disables the limb and triggers bleed but does not kill the NPC** — head and torso are the only mortal zones. This makes "shoot the legs to disable + chase the bleed-out" a real tactical option for both players and NPCs.

**This plan doesn't change the wound pipeline itself.** What it adds:

1. A `LimbState` field on each of the six body parts, expressing whether the limb is `Intact`, `Wounded` (has open wounds), or `Severed`.
2. A `WoundKind` classification that distinguishes wound visuals/severity semantics (`WoundSmall`, `WoundLarge`, `SlugHole`, `BuckshotScatter`, `Sever`, `HeadGib`).
3. A server-side `resolve_wound_kind` function that maps hit inputs (caliber, energy, location) to a wound kind.
4. Client-side reactive IK and dismemberment visuals driven by the wound kind.

Everything else - bleed rates, treatment flows, infection, drugs - stays exactly the same.

---

## 3. `LimbHp` Extension of `BodyParts`

Current (landed):

```rust
pub struct BodyParts {
    pub head:  f32,
    pub torso: f32,
    pub l_arm: f32,
    pub r_arm: f32,
    pub l_leg: f32,
    pub r_leg: f32,
}
```

Proposed:

```rust
pub struct BodyParts {
    pub head:  LimbHp,
    pub torso: LimbHp,
    pub l_arm: LimbHp,
    pub r_arm: LimbHp,
    pub l_leg: LimbHp,
    pub r_leg: LimbHp,
}

pub struct LimbHp {
    pub current: f32,
    pub max:     f32,
    pub state:   LimbState,
}

#[repr(u8)]
pub enum LimbState {
    Intact  = 0,
    Wounded = 1,   // has open wounds; maintained by existing wound system
    Severed = 2,   // limb gone - cannot be healed back
}
```

### 3.1 Migration

- Existing `f32` field becomes `LimbHp.current`.
- `max` seeded from `MedConfig::per_part_max_hp` (default 100 across the board, per-part tuning later).
- `state` starts at `Intact`; transitions to `Wounded` when the wound system spawns a wound on the part; transitions to `Severed` only via `WoundKind::Sever` or `HeadGib`.
- Existing `limb_disabled(part)` returns true if `state == Severed` OR `current == 0.0` (backward-compatible).
- WorldDelta variants that mutate `BodyParts` extend to carry `state` alongside HP. Journal replay handles old journals by defaulting `state = Intact` at load.

### 3.2 Coarse ECS vs fine visual

The ECS tracks one state per major part (arm as a whole). The **client** chooses which specific sever prop to spawn based on the impact point (shoulder / elbow / wrist for an arm sever; hip / knee / ankle for a leg sever). Authoritative state is coarse; presentation is fine-grained.

Why: finer ECS granularity would inflate state for little gameplay return. Gameplay asks "can this player use their left arm?" and "is the left arm severed?". Both answered by one state enum.

---

## 4. `WoundKind` and the Replication Channel

```rust
#[repr(u8)]
pub enum WoundKind {
    WoundSmall       = 0,  // small entry/exit wound; existing Bleed severity 1-2
    WoundLarge       = 1,  // large wound; existing Bleed severity 3-4
    SlugHole         = 2,  // shotgun slug entry
    BuckshotScatter  = 3,  // shotgun buckshot pattern
    Sever            = 4,  // limb severed at joint
    HeadGib          = 5,  // head destroyed
}
```

On every projectile/explosion hit that lands on a character, the server resolves a `WoundKind` and emits a `HitEvent`:

```rust
pub struct HitEvent {
    pub entity:           Entity,
    pub body_part:        BodyPart,
    pub wound_kind:       WoundKind,
    pub hit_point:        Vec3,        // world space
    pub hit_dir:          Vec3,        // world space, unit-length
    pub impact_energy_j:  u32,
}
```

`HitEvent` replicates on the **gameplay-critical channel** (see `physics-tiering-plan.md` §6) - reliable, every peer, always delivered. Client-side reactive IK and dismemberment visuals spawn from this event deterministically; no additional replication for debris, stump caps, or severed prop physics.

---

## 5. `resolve_wound_kind` Mapping

Pure function, server-authoritative, deterministic. Lives in `simn-sim/src/systems/damage.rs`.

```rust
pub struct HitInput {
    pub body_part:       BodyPart,
    pub caliber_class:   CaliberClass,
    pub impact_energy_j: u32,
    pub pellet_spread:   Option<PelletSpread>,
    pub is_joint_area:   bool,         // hit within joint radius
    pub is_point_blank:  bool,         // range < 1.5m
}

pub fn resolve_wound_kind(hit: &HitInput) -> WoundKind {
    // 1. Head gib - full-power rifle or anti-materiel to head
    if matches!(hit.body_part, BodyPart::Head)
        && matches!(hit.caliber_class,
                    CaliberClass::FullPowerRifle | CaliberClass::AntiMateriel)
    {
        return WoundKind::HeadGib;
    }

    // 2. Sever - energy threshold against joint hitboxes
    //    (any weapon, just needs enough energy at a joint)
    if hit.is_joint_area
        && hit.impact_energy_j >= joint_sever_threshold(hit.body_part)
    {
        return WoundKind::Sever;
    }

    // 3. Shotgun-specific
    if let Some(spread) = &hit.pellet_spread {
        return match spread {
            PelletSpread::Slug            => WoundKind::SlugHole,
            PelletSpread::Buckshot { .. } => WoundKind::BuckshotScatter,
            PelletSpread::Birdshot { .. } => WoundKind::WoundSmall,
        };
    }

    // 4. Generic caliber-based size
    if hit.impact_energy_j >= 2500 {
        WoundKind::WoundLarge
    } else {
        WoundKind::WoundSmall
    }
}

fn joint_sever_threshold(bp: BodyPart) -> u32 {
    match bp {
        BodyPart::NeckJoint               => 3500,
        BodyPart::Wrist | BodyPart::Ankle => 1200,
        BodyPart::Elbow | BodyPart::Knee  => 2200,
        BodyPart::Shoulder | BodyPart::Hip => 3200,
        _                                  => u32::MAX,
    }
}
```

### 5.1 Caliber classes

```rust
pub enum CaliberClass {
    Pistol,           // 9mm, .45 ACP
    PDW,              // 4.6x30, 5.7x28
    Intermediate,     // 5.45x39, 5.56x45, 7.62x39
    FullPowerRifle,   // .308, 7.62x54R
    Magnum,           // .338 Lapua
    AntiMateriel,     // .50 BMG, 14.5x114
    Shotgun,          // always pairs with PelletSpread
}
```

Full caliber roster and energy values live in `weapons-plan.md`.

### 5.2 `is_joint_area` determination

The client-side raycast hit point is tested against joint capsule volumes on the hit character. If the hit is within the capsule, `is_joint_area = true`. This is client-determined but trusted by the server - the client's raycast already went through server validation (weapon ownership, range, LOS) for the hit itself; the joint-area flag is a cosmetic qualifier within an already-validated hit.

Joint vocabulary (on the shared humanoid rig):

- Head/torso boundary: `NeckJoint`
- Arm: `Shoulder`, `Elbow`, `Wrist`
- Leg: `Hip`, `Knee`, `Ankle`

### 5.3 Integration with existing wound spawning

The existing `apply_damage_to_part` flow today spawns `Wound` instances on damage ≥10. Extension:

- `resolve_wound_kind` runs first, producing a `WoundKind`.
- `WoundSmall` / `WoundLarge` / `SlugHole` / `BuckshotScatter` / `Birdshot`-style results → spawn a `Wound` with severity mapped from `WoundKind` (e.g., `WoundSmall` → severity 1-2; `WoundLarge` → severity 3-4; `SlugHole` → severity 4-5). Existing wound pipeline takes over.
- `WoundKind::Sever` → set `body_part.state = LimbState::Severed`, cap limb HP at 0, emit gameplay-critical `DismemberEvent`.
- `WoundKind::HeadGib` → set head state `Severed`, aggregate health to 0 (character death), emit `DismemberEvent`.

Severing a limb doesn't also spawn a wound - the limb is gone; there's nothing to treat. (Open question: do we want a "cauterized stump" wound for the HP drain from blood loss? Leaning no - the shock and death gate already handle the outcome. A living character with a severed arm is the game's worst-night-of-your-life scenario; they have other things to deal with.)

---

## 6. Reactive IK

Purely client-side cosmetic. Server replicates the `HitEvent`; every client runs its own reaction locally on the target character.

### 6.1 Skeleton modifier stack

Uses Godot's modern IK pipeline (`SkeletonModifier3D` subclasses, not deprecated `SkeletonIK3D`). On every humanoid, the stack runs in this order after AnimationTree pose evaluation, before `PhysicalBoneSimulator3D`:

1. **Foot planting modifier** - raycasts per foot, offsets leg chain to ground.
2. **Head / spine look-at modifier** - aim convergence within a cone during combat.
3. **Reactive IK modifiers** - one per limb group (head, torso, l_arm, r_arm, l_leg, r_leg). Transient hit-reaction goals. Normally inactive.
4. **Weapon-hand IK modifier** - off-hand grip on weapon socket.

Exact node-class names track Godot version. Design is against the modifier pipeline; if a specific release renames a subclass, the stack shape is unchanged.

### 6.2 Reaction algorithm (GDScript)

```gdscript
# ReactiveIKController.gd - attached to the character's Skeleton3D
func on_hit(event: HitEvent) -> void:
    var group := _body_part_to_limb_group(event.body_part)
    var scalar := _impulse_scalar(event.impact_energy_j)  # maps J to a magnitude
    var impulse := event.hit_dir.normalized() * scalar
    impulse = _clamp_magnitude(impulse, group.max_impulse)

    var goal_offset := _impulse_to_ik_offset(group, impulse)
    var modifier := _modifiers[group]
    modifier.apply_transient_goal(
        goal_offset,
        group.attack_ms,
        group.hold_ms,
        group.decay_ms
    )

    if event.impact_energy_j > group.stagger_threshold_j:
        _animation_tree.set("parameters/Alive/Stagger/request",
            AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

    if event.wound_kind in [WoundKind.SEVER, WoundKind.HEAD_GIB]:
        _apply_dismember(event)  # see §7
        return  # dismemberment supersedes reaction
```

### 6.3 Tuning table (starting values, playtest-tunable)

| Group | max_impulse | stagger_threshold_j | attack_ms | hold_ms | decay_ms |
|-------|-------------|----------------------|-----------|---------|----------|
| head  | 0.15 m      | 2,000                | 60        | 40      | 200      |
| torso | 0.25 m      | 4,000                | 80        | 60      | 300      |
| l_arm | 0.30 m      | 1,500                | 70        | 50      | 250      |
| r_arm | 0.30 m      | 1,500                | 70        | 50      | 250      |
| l_leg | 0.20 m      | 3,000                | 90        | 60      | 280      |
| r_leg | 0.20 m      | 3,000                | 90        | 60      | 280      |

All values live in a TOML config at `godot/data/reactive_ik.toml` for hot iteration without a Rust rebuild.

### 6.4 Explosion reactions

Explosions emit `HitEvent`s with direction derived from (blast origin → character center of mass) and `impact_energy_j` derived from overpressure × distance. The reactive IK path is identical; it just applies to torso with higher magnitude and kicks a head modifier for the same duration. Characters killed outright by the blast skip reactive IK and go to ragdoll (§8).

### 6.5 Weapon-hand vs reactive IK conflict

Reactive IK on an arm takes priority over weapon-hand IK during the attack + hold window. During decay, weapon-hand IK re-asserts and lerps the hand back to grip. Visually: the NPC loses their grip briefly from an arm hit, then re-orients. Looks right; no special authoring needed.

---

## 7. Dismemberment Visuals

On `DismemberEvent` (emitted server-side on Sever or HeadGib):

### 7.1 Mesh-hide via shader discard

No runtime mesh cutting. The character's single skinned mesh is authored with a per-limb vertex-group bitmask baked into a vertex attribute. A uniform on the character's material controls which bits are discarded.

```glsl
// Fragment
// uniform: uint hidden_limb_mask
// attribute: uint limb_id  (0..14, from vertex group)

void fragment() {
    if ((hidden_limb_mask & (1u << limb_id)) != 0u) {
        discard;
    }
}
```

On sever: set the corresponding bit.

### 7.2 Severed-limb prop spawn

Pre-authored detached limb scenes per archetype. Selection is by `(archetype, limb, sever_point)` - e.g., `SeveredLimb_male_lean_l_arm_elbow.tscn`.

```
godot/scenes/characters/severed/
├── SeveredLimb_male_lean_l_arm_shoulder.tscn
├── SeveredLimb_male_lean_l_arm_elbow.tscn
├── SeveredLimb_male_lean_l_arm_wrist.tscn
├── ... (one per archetype × limb × sever point)
```

Archetypes: `male_lean`, `male_bulk`, `female_lean`, `female_bulk`, `mutant_echo`, `mutant_merged`, `mutant_attuned`.

Scene structure:

```
SeveredLimb (RigidBody3D)
├── MeshInstance3D (the limb mesh, with gear if applicable)
├── CollisionShape3D
└── Gear/                     (optional - bracer, glove, sleeve)
```

On spawn:

1. Transform set to the sever joint's world pose at the moment of severing.
2. Impulse applied: `hit_dir * impact_energy_j * 1.5` + small random angular kick.
3. Lives for 30–90s depending on proximity to active players, then despawns.
4. Not replicated. Deterministic from `DismemberEvent` - every client spawns the same thing.

### 7.3 Stump cap spawn

A cylindrical cap mesh with dark-red material at the matching `stump_*` socket on the remaining body. Hides the raw vertex-group edge.

```
godot/scenes/characters/stumps/
├── StumpCap_shoulder.tscn
├── StumpCap_elbow.tscn
├── StumpCap_wrist.tscn
├── StumpCap_hip.tscn
├── StumpCap_knee.tscn
├── StumpCap_ankle.tscn
└── StumpCap_neck.tscn
```

One shared cap per joint type; material variation per archetype is optional.

### 7.4 Blood burst + decal

Short-lived `GPUParticles3D` at the stump socket (0.6s). A blood decal pool under the eventual resting position of the severed limb (via a ground raycast). Decals persist until region-offline.

### 7.5 HeadGib specifics

Same path, but:

- `SeveredLimb_*_head_neck.tscn` is the detached head prop.
- Stump cap at neck is the same as a `WoundKind::Sever` at the `NeckJoint`.
- Character goes to ragdoll (§8) because HeadGib → aggregate HP = 0 → death.
- Optional: head gib spawns additional meat chunk debris (3-5 small fragments).

---

## 8. Ragdoll Transition

On character death (existing `is_alive() == false` trigger):

1. `AnimationTree.active = false`.
2. Snapshot current skeleton pose to physical bones.
3. Enable `PhysicalBoneSimulator3D`.
4. Apply final impulse at the killing-blow's hit point (from the terminal `HitEvent`) so the body falls consistently with the hit.
5. After 8s of rest (angular velocity below threshold across all bones), bake the pose into a static skinned mesh; disable `PhysicalBoneSimulator3D`.
6. Corpse enters the Ledger as a loot container (see `loot-and-economy-plan.md`) with a `CorpseRecord` that includes the baked pose blob and `dismember_mask` (bitfield of `LimbState` × 6 limbs).

Ragdoll is Tier 2 physics during its active period. Budget-scaled per peer like any Tier 2 body - though gameplay-critical enough that the priority weight should be bumped (death of an NPC you were fighting is gameplay-critical, not cosmetic).

---

## 9. Authoring Requirements

### 9.1 Shared humanoid rig

**Non-negotiable: all humanoid characters retarget to one shared skeleton.** It's what makes animation, reactive IK, dismemberment, and ragdoll share authoring cost across the roster.

Per-archetype meshes skin to this rig. Archetypes differ in body proportions (adjusted via bone scales in the retargeting config), clothing, and whether they carry non-human geometry (mutant archetypes).

### 9.2 Vertex groups

Mandatory per-character-mesh vertex groups (finer than ECS body parts, used purely for sever visuals):

- `head`, `neck`
- `torso`
- `upper_arm_l`, `forearm_l`, `hand_l`
- `upper_arm_r`, `forearm_r`, `hand_r`
- `thigh_l`, `shin_l`, `foot_l`
- `thigh_r`, `shin_r`, `foot_r`

Each vertex group is assigned a unique `limb_id` (0–14) baked into a vertex attribute.

### 9.3 Stump sockets

Empty Node3Ds under `AttachPoints/` on every character scene:

- `stump_neck`
- `stump_shoulder_l`, `stump_elbow_l`, `stump_wrist_l`
- `stump_shoulder_r`, `stump_elbow_r`, `stump_wrist_r`
- `stump_hip_l`, `stump_knee_l`, `stump_ankle_l`
- `stump_hip_r`, `stump_knee_r`, `stump_ankle_r`

Positioned to match the respective joints on the bind pose.

### 9.4 Severed-limb props

For each archetype: 14 pre-modeled severed-limb scenes (one per combination of limb × sever point). Pre-poseable - the rigid-body hit uses the world transform of the joint at sever time, so the detached mesh can be authored in a canonical pose.

Gear layers (coat cuffs, gloves, pads) that were on the limb ride on the severed prop as child meshes.

### 9.5 Gib mesh library

Shared across archetypes: a small pool of generic flesh/bone fragment meshes used by `HeadGib` and explosion blast gore. Not per-archetype.

---

## 10. Tests

### 10.1 Unit tests (`simn-sim::damage`)

- `resolve_wound_kind_head_full_power_gibs` - full-power rifle to head → HeadGib.
- `resolve_wound_kind_joint_high_energy_severs` - 4000 J to elbow → Sever.
- `resolve_wound_kind_joint_low_energy_doesnt_sever` - 900 J to elbow → WoundSmall.
- `resolve_wound_kind_shotgun_slug_slughole` - Shotgun with Slug pellet spread → SlugHole.
- `resolve_wound_kind_shotgun_buckshot_scatter` - Shotgun with Buckshot pellet spread → BuckshotScatter.
- `resolve_wound_kind_generic_fallback_sizing` - 3000 J to torso → WoundLarge.
- `sever_sets_limb_state` - `Sever` result flips `body_parts.l_arm.state` to `Severed`.
- `head_gib_kills` - `HeadGib` result flips head to `Severed` and `Health.current == 0`.
- `severed_limb_counts_as_disabled` - `limb_disabled(part)` returns true when `state == Severed`.

### 10.2 Integration tests

- **Sever persists across restart.** Damage an NPC's arm to `Severed`, shutdown, restart - limb state preserved; on materialization the NPC appears with the arm missing.
- **Existing wound flow unchanged for non-sever hits.** All existing wound tests pass after the `LimbHp` migration.
- **DismemberEvent is reliable.** Peer A and peer B both see the sever regardless of their physics-tier degradation state.

---

## 10.5. Landed in step 1 (2026-05-07)

The first chunk of this plan is on main: the per-limb state substrate that the rest of the work builds on. Specifically:

- **`LimbState` enum** in `simn-sim/src/components.rs` — `Intact / Wounded / Severed`, default `Intact`.
- **`LimbStates` component** — sibling to `BodyParts`, six states (one per body part) with `mark_wounded(part)`, `mark_severed(part)`, and `recompute_from_wounds(&Wounds)` helpers. Serializable but transient (rebuilt on snapshot load from existing `Wounds`).
- **`Wounds` + `BodyParts` are now NPC-too** (the doc-comment claim; the wound tick pipeline in `systems/wounds.rs` was already cross-entity, but this PR confirms it and updates the docs). Players AND NPCs spawn with the full set of wound components.
- **State transitions hooked at every wound-spawn site** (`Sim::apply_damage_to_part`, `Sim::apply_damage_to_npc_part`, `npc_combat::npc_combat`, journal-replay `WoundAdded` / `NpcWoundAdded`) and at the heal sweep (`age_and_heal_wounds` calls `recompute_from_wounds` after the `Healed`-retain).
- **`Sim::sever_limb_for_test`** — test-only sever: flips `LimbStates` to `Severed`, zeroes `BodyParts` slot, recomputes aggregate `Health.current = vital_min`. Production sever (caliber-driven `WoundKind::Sever`) lands later with the projectile + weapons-plan work.

**Not yet landed (still planning):**

- The `LimbHp { current, max, state }` shape change on `BodyParts` itself. The current PR keeps `BodyParts` as six `f32`s and adds `LimbStates` as a sibling component, which gets the state substrate in place without churning every callsite that reads HP. The integrated `LimbHp` shape can come with the per-part `max` work.
- `WoundKind` taxonomy beyond `Bleed`. `resolve_wound_kind`, `HitEvent`, the `is_joint_area` / `impact_energy_j` inputs, and the caliber → wound-kind table — all wait on `weapons-plan.md` to lock its `CaliberClass` enum.
- Reactive IK, dismemberment visuals, ragdoll transition. All client-side; await the `simn-godot` reactive-IK controller PR.

**Test coverage** (`simn-sim/tests/limb_state.rs`, 12 tests):

- fresh player / NPC start all `Intact`
- sub-threshold damage doesn't flip state
- above-threshold damage flips part to `Wounded`
- multiple wounds on same part stay `Wounded`
- bandage + tick past heal timer → wound dropped → state back to `Intact`
- other limbs stay `Intact` while one is `Wounded`
- sever flips state + zeroes HP; head sever drops aggregate health to 0; arm sever doesn't kill
- sever overrides `Wounded`; severed limb doesn't downgrade when its wounds clear
- real combat path (npc_combat → wound-add) writes the limb state through

## 11. Gore Dial - Explicit Non-Goal

There is no `gore_level` config setting. The rules produce what they produce - caliber-appropriate, location-appropriate, energy-appropriate. A .22 to a leg is a wound; a .338 to a neck at point-blank is a sever. This is the design.

What *is* configurable (operator-side):

- **Dismemberment visual detail**: number of gib mesh fragments for HeadGib, decal pool size, particle intensity. A low-spec server can dial these down; the authoritative state is unchanged.

What's **not** configurable:

- Whether sever happens. Whether HeadGib happens. Whether a wound is `Small` vs `Large`.

Rationale: a caliber-driven model only works if the rules apply consistently. A "gore off" setting would either hide outcomes (confusing - the enemy fell but I can't see why) or change game rules per client (inconsistent). Neither is acceptable for a co-op shooter where both players need to agree on what's happening.

---

## 12. Open Questions

- **Weapon-hand IK during decay.** Current plan: weapon-hand re-asserts during the decay window. Playtest may show this looks jarring - the gun snaps back while the arm is still recovering. Alternative: soften the decay curve so hand and arm realign together. Needs visual testing.
- **Sever probability vs determinism.** Is severing fully deterministic from hit inputs, or is there a small random factor? Currently deterministic. A small RNG roll (e.g., 80% chance of sever at threshold) would make gameplay less predictable in a "good" way. Open.
- **Players getting severed.** Do players go through the same dismemberment path as NPCs? Yes - same rules, same visuals. But a player with a severed arm has gameplay implications (no two-handed weapons, reduced sprint) the existing wound system doesn't yet gate. Needs integration with movement/aim systems when those land.
- **Torso "sever" handling.** A chest-cavity-vaporizing hit from an anti-materiel rifle at the torso is effectively sever-tier damage but there's no joint to sever at. Currently just kills (HP to 0) with a big `WoundLarge` wound. Acceptable? Or add a `TorsoObliteration` WoundKind? Leaning acceptable - the animation / effect through ragdoll + blood is already distinct.
- **Explosive dismemberment rules.** Currently explosions route through the same `resolve_wound_kind` with their computed energy and direction. Should proximity to a frag grenade apply multiple `HitEvent`s across different body parts (simulating shrapnel)? That'd naturally produce multiple severs in a way that feels right. Worth prototyping.
- **Reactive IK under latency.** A hit event that arrives 200ms late on a laggy peer - does the reaction still play, or skip? Play it, with a shortened attack to catch up. Needs playtest.
- **Mutant archetypes with non-humanoid bodies.** The Experiments / Merged / some Attuned mutants may not have 6 standard body parts. The damage model on the ECS side is still 6-part (works fine - "head" can be whatever the dominant target zone is) but the visual rig and sever props need archetype-specific authoring. Each non-humanoid gets its own reactive-IK tuning and sever prop set.
- **Dismemberment for Wanderers as noncombatants.** A lore-sensitive point: Wanderers aren't combat mutants; dismembering them should be possible (same rules) but may need to feel distinct from combat gore. Pure visual call; no rule change.

---

## 13. Cross-References

- `../mechanics/damage-and-healing.md` - landed wound pipeline this extends.
- `../walkthroughs/sim.md` - `BodyParts` ECS component, mutation paths.
- `physics-tiering-plan.md` - `HitEvent` and `DismemberEvent` use the gameplay-critical replication channel.
- `weapons-plan.md` - `CaliberClass`, `PelletSpread`, and projectile energy inputs that feed `resolve_wound_kind`.
- `../walkthroughs/tactical-ai.md` - NPC combat AI future that will drive aim and hit location.
- `world-ledger-plan.md` - `corpse_state.dismember_mask` preserves sever state on corpses.
- `../architecture/crate-guide.md` - `simn-sim` gets `resolve_wound_kind`; `simn-godot` gets the reactive-IK controller and dismemberment visuals.
