# Physical Combat — Planning Doc

**Status:** stub — design intent captured, no implementation yet
**Last updated:** 2026-05-05
**Scope:** server-authoritative physical-projectile combat for online tier; dice-roll combat for offline tier. NPCs and players share one combat path. Body-part hit resolution drives the unified wound pipeline. Online combat consumes [`combat-los-plan.md`](combat-los-plan.md) as a query primitive but is not the same system; LOS is a side-channel for AI perception, projectile collision is the actual damage resolver.

Companions: [`combat-los-plan.md`](combat-los-plan.md) (LOS query primitive used by aggro), [`weapons-plan.md`](weapons-plan.md) (per-round ballistics, parts wear), [`dismemberment-plan.md`](dismemberment-plan.md) (limb-zeroing semantics), [`offline-tier-plan.md`](offline-tier-plan.md) (dice combat for unobserved regions), [`cover-system-plan.md`](cover-system-plan.md) (cover decisions consume LOS but are not the LOS system), [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 1-2 work).

This is a living design doc.

---

## 1. Why this exists

The existing `npc_combat` system in `crates/simn-sim/` rolls hit chance off distance bands and applies damage to torso. It's a placeholder. Player weapons already use the existing `Projectile` ECS component with `BallisticsConfig` (gravity, air density). Unifying NPC combat onto the same projectile system gives:

- **One combat path.** No divergence between player-fires-at-NPC and NPC-fires-at-player resolution.
- **Cover is automatic.** Bullets stop at walls without a separate LOS query for combat; physics IS the damage gate.
- **Body-part hit resolution.** Projectile hit position → which body part → unified wound pipeline (per [`dismemberment-plan.md`](dismemberment-plan.md)). NPCs lose limbs the same way players do; zeroed arms / legs disable + bleed but don't kill.
- **Penetration and falloff.** A round through a thin wall with damage falloff is a physics outcome, not a dice formula.
- **Friendly fire is automatic.** Squadmate steps in front, takes the bullet.
- **Time-of-flight matters.** Lead-the-target gameplay; player can dodge a sniper at long range.

Bounded cost via per-tick projectile budget (cap on in-flight count, cull oldest if exceeded). For offline regions, dice combat takes over per [`offline-tier-plan.md`](offline-tier-plan.md) §4 — drastically cheaper, mathematically equivalent in terms of long-run faction-level outcomes.

## 2. What this system does / does not do

**Does:**

- Spawn a `Projectile` entity for every shot fired in an online region (player or NPC).
- Tick projectiles each frame: integrate position with `BallisticsConfig` gravity + air density, swept-collision against terrain + obstacles + entity capsules.
- Resolve hit: identify hit entity + body-part region → apply weapon damage modified by armor + caliber + falloff + range.
- Apply armor mitigation: per-body-part armor coverage (chest plate vs uncovered head); penetration class vs armor class lookup.
- Apply shard effects: shards in equipped slots can modify damage (resistance, deflection, conversion). Hooks per internal design notes.
- Drive NPC weapon-fire decisions: aim-cone jitter from per-NPC accuracy stat; RPM from weapon definition; reload state from `EquippedWeaponState`.
- Provide hitscan escape valve for weapons explicitly tagged `hitscan: true` (point-blank brawling, rare extreme-long-range cases).
- Surface combat events to the world event bus: gunshot, projectile-impact, wound, kill (consumed by [`world-event-bus-plan.md`](world-event-bus-plan.md), [`squad-blackboard-plan.md`](squad-blackboard-plan.md)).

**Does not:**

- Replace [`combat-los-plan.md`](combat-los-plan.md). LOS query is a primitive used by aggro perception, cover position selection, and AI peek-shoot decisions. Combat hit resolution does not consult it — the projectile collision is authoritative.
- Drive offline-tier combat. Offline uses dice rolls; this plan covers online physical only. The two tiers' outcomes converge statistically over time but not per-shot.
- Author weapon balance numbers. Damage tables, accuracy tables, RPM, reload times live in [`weapons-plan.md`](weapons-plan.md) data registries.
- Define armor / shard data. Those live in their respective plans; combat consumes them.
- Render tracers / impact effects. Client-side rendering subscribes to projectile spawn / impact events but is not part of this server-side plan.

## 3. Data model

`Projectile` already exists; extending lightly:

```rust
#[derive(Component, Clone, Debug)]
pub struct Projectile {
    pub id: ProjectileId,
    pub source_entity: Entity,           // shooter (player or NPC)
    pub source_steam_id: Option<u64>,    // for player projectile attribution
    pub round: RoundId,                  // weapons-plan registry key
    pub position: Vec3,
    pub velocity: Vec3,
    pub spawned_tick: u64,
    pub max_lifetime_ticks: u32,         // cull after N ticks
    pub remaining_penetration: f32,      // depletes through materials
}

// New: NPC weapon-fire intent (input to combat tick, not a long-lived component)
#[derive(Clone, Debug)]
pub struct FireIntent {
    pub shooter: Entity,
    pub weapon: WeaponInstanceId,
    pub aim_dir: Vec3,                   // from aim cone roll
    pub round: RoundId,
}

// Extend BallisticsConfig with per-tick budget
pub struct BallisticsConfig {
    pub gravity_mps2: f32,
    pub air_density: f32,
    pub max_in_flight: u32,              // hard cap; oldest culled if exceeded
    pub default_lifetime_ticks: u32,     // ~80 ticks (4s) for typical rifle round
}
```

Hit resolution produces a `HitEvent`:

```rust
pub struct HitEvent {
    pub projectile: ProjectileId,
    pub target: Entity,
    pub body_part: BodyPartKind,         // Head, Torso, ArmL, ArmR, LegL, LegR
    pub damage: f32,                     // post-mitigation
    pub penetration_remaining: f32,      // for pass-through
    pub impact_position: Vec3,
}
```

## 4. System behavior — online tier

**Per-tick projectile sim** (`tick_projectiles` system, runs every server tick):

1. For each `Projectile`, integrate motion: `velocity += gravity * dt - drag(velocity, air_density) * dt`; `position += velocity * dt`.
2. Swept collision: ray from previous position to new position against terrain + static obstacles + entity capsules in a spatial hash.
3. On hit:
   - Identify body part if entity (capsule has body-part tag map).
   - Compute damage: `weapon_base_damage * caliber_factor * falloff(distance_traveled) - armor_mitigation - shard_resist`.
   - Apply via [`dismemberment-plan.md`](dismemberment-plan.md) wound pipeline.
   - Penetration: if remaining penetration > material thickness, projectile continues at reduced speed + reduced damage.
   - Stamp `LastDamager` on target.
   - Push `HitEvent` to world event bus.
4. Cull projectiles past `max_lifetime_ticks` or off-region.

**Per-tick NPC fire decision** (`npc_fire_resolution` system, replaces current `npc_combat`):

1. For each NPC with `Aggro` and a usable weapon (loaded, not reloading):
   - Check fire-rate cooldown from weapon definition vs last shot tick.
   - Roll aim direction within aim cone: `aim_dir = (target_predicted_position - shooter_position).normalized() + cone_jitter(npc_accuracy_stat)`.
   - Spawn `Projectile` at muzzle position with `velocity = weapon_muzzle_velocity * aim_dir`.
   - Decrement magazine; trigger reload state if empty.
2. Shooter perception: NPC fires whether or not target is in clear LOS at the moment of fire (the projectile sorts it out). This produces the realistic "shoots at where I was" outcome you see in real combat — accept it as feature, not bug.

**Per-tick projectile budget enforcement** (`enforce_projectile_budget` system):

- Count active `Projectile` entities. If > `BallisticsConfig::max_in_flight`, despawn oldest first.
- Default budget: 500 in-flight projectiles total, server-wide. Tunable per region density needs.

## 5. System behavior — offline tier

When a region has zero observers, the offline tier (per [`offline-tier-plan.md`](offline-tier-plan.md) §4) handles combat via dice. Summary of how this combat plan defers:

- No projectiles spawn for offline NPCs.
- Each opposing-faction pair within engagement radius rolls combat dice every offline tick (default 2 Hz).
- Roll formula (tentative): `attacker_accuracy × defender_cover_class × weapon_class_advantage` → hit probability; on hit, `weapon_class_damage × armor_class_mitigation` → HealthClass shift.
- Outcomes journal as chronicle events; no per-frame replication.
- When region transitions back to online, current `OfflineCombatState::Engaged` materializes as `Aggro` between the involved NPCs; physical combat resumes from current HealthClass-derived body-part state.

The key invariant: **statistical equivalence over time.** A 100-shot online firefight should produce roughly the same casualty distribution as the equivalent dice-resolved offline fight. Tuning lives in the dice formulas; concrete tuning is playtest-driven.

## 6. NPC accuracy + armor + shards

Three knobs feed online aim cone and damage:

**Accuracy.** Per-NPC stat from [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md), modulated by:
- Personality (jittery hands → wider cone).
- Wound state (limb wounds widen cone; pain affects steadiness).
- Stance (prone → tighter cone, standing → wider).
- Movement (running → much wider cone).
- Weapon (sniper rifle inherent vs SMG inherent).

**Armor.** Per-body-part coverage from equipped armor pieces. Armor has:
- Coverage map (what body parts it covers).
- Armor class (penetration resistance).
- Damage falloff curve per caliber class.
- Condition (degrades on hit; degraded armor mitigates less).

**Shards.** Per internal design notes, equipped shards can modify combat in/out:
- Resistance: percent damage reduction per damage type.
- Deflection: chance to deflect projectile (reduces remaining damage / penetration).
- Conversion: damage type swap (kinetic → thermal, etc.).
- Self-effects: passive bleed, slow regen, etc.

The combat tick consults all three for every hit; this is the per-shot cost ceiling. Bounded by entity counts × hits per tick.

## 7. Hitscan escape valve

For weapons where projectile sim is overkill or actively wrong, a `WeaponDef::hitscan = true` flag bypasses projectile spawn. Hitscan resolution:

1. Raycast from muzzle in aim direction up to weapon's effective range.
2. First-hit body-part resolution exactly as projectile collision.
3. Damage applied immediately.

Use cases: point-blank brawling weapons, vehicle-mounted guns where aiming is auto-true and projectile sim adds nothing, extreme-long-range engagements where projectile flight is cosmetic.

Default: every weapon is projectile. Hitscan is opt-in per weapon.

## 8. Dependencies

- **Blocks:** all of Stage 3 tactical AI (cover-system pathing, GOAP combat actions), the F.E.A.R.-class behavior in [`../walkthroughs/tactical-ai.md`](../walkthroughs/tactical-ai.md).
- **Blocked by:** [`combat-los-plan.md`](combat-los-plan.md) (LOS for aggro side-channel), [`dismemberment-plan.md`](dismemberment-plan.md) (body-part wound pipeline including limb zeroing), [`weapons-plan.md`](weapons-plan.md) (round ballistics + weapon definitions), internal design notes (shard effects), [`offline-tier-plan.md`](offline-tier-plan.md) (dice fallback for unobserved regions).

## 9. Open questions

- **Per-tick projectile budget tuning.** 500 in-flight is a guess. Real number lands via 12-player stress test. Possible per-region budgets if global cap unfair.
- **Capsule body-part resolution.** Each character capsule needs sub-shapes (head sphere, torso capsule, limb capsules) so projectile collision produces a `BodyPartKind`. How granular? More shapes = more accurate hit zones but more collision cost. Tentative: 6 zones (head, torso, two arms, two legs).
- **Penetration material model.** Walls have thickness + material class; round has penetration value; each material consumes some penetration. Concrete numbers from [`weapons-plan.md`](weapons-plan.md) but the calc model lives here. Linear consumption tentative.
- **Ricochet.** Skip-shots off hard surfaces — physics-realistic but expensive (each ricochet is effectively a new projectile). Tentative: ricochet rolls only for pistol-caliber rounds at acute angles, capped at 1 bounce.
- **Vertical aim for NPCs.** Lead-the-target plus bullet drop at long range — NPC accuracy stat needs to know about both. Aim-cone jitter handles spread; ballistic-arc compensation needs explicit modeling. Tentative: NPCs apply ballistic compensation up to their `marksmanship` stat threshold; below it, they fire flat (and miss long shots).
- **Online → offline mid-projectile.** A bullet in flight when the region goes offline: resolve immediately via dice (hit-roll weighted by remaining flight time + target proximity), or just despawn. Tentative: dice resolution. Loses no fairness because offline tier accepts dice-determined outcomes anyway.

## 10. Out of scope

- Player input handling for fire (lives in `simn-godot` input layer; this plan handles only the server-side projectile sim).
- Tracer / muzzle flash / impact decal rendering (client-side, subscribes to events).
- Non-projectile weapons (melee, energy weapons) — separate combat path; if pursued, will get its own plan.
- Vehicle-mounted weapon handling (vehicle plans don't exist yet).
- Healing items applied during combat — survival pipeline territory.
