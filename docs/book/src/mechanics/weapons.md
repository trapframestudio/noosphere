# Weapons

What you shoot with. Phases 1 and 2 land the core gun loop:
**pick up a weapon, equip it, load rounds, fire at something**.
All stats live in [`items.toml`][items_toml] + the new
[`ballistics.toml`][ballistics] - modders retune the whole
damage matrix without touching engine code.

[items_toml]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/data/items.toml
[ballistics]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/data/ballistics.toml

## What's live today

**Phase 1** - weapons are inventory items, magazines ride with the
weapon through equip/unequip, reload swaps magazines.

**Phase 2** - host-authoritative projectile sim (no more hitscan),
round variants per caliber, and armor penetration:

- Bullets have drop, drag, travel time. The sim spawns a
  `Projectile` entity at the muzzle, ticks it with gravity and
  drag, and resolves impacts against per-body-part hitbox
  approximations (head sphere, torso capsule, arm/leg capsules).
- Each caliber ships **HP / FMJ / AP** variants (plus
  buckshot/slug/flechette on the 12ga side) with distinct ballistic
  + terminal stats.
- Equip armor to `armor_vest` or `head_gear` slots; protection
  class gates which round types penetrate.
- Magazines carry one ammo variant at a time. HUD shows
  `AKS-74  AP 24/30`.
- Fire is **fire-and-forget** from the client - the client
  sends `(aim_yaw, aim_pitch)` and lets the sim resolve the hit;
  tracer + impact FX render from `ProjectileSpawned` /
  `ProjectileImpacted` signals.

## What's deferred

| Phase | What it adds |
|---|---|
| 3 | Attachment slot-tag graph (optics, grips, barrels…) — data layer landed in `sim-iteration-5-12` Phase 4C. Runtime stat effects + equip UI land with Phase 5. |
| 4 | Weapon parts condition + wear + jams — v1 landed in `sim-iteration-5-12` Phase 4D. Per-part roster, NPC jam handling, accuracy / muzzle-velocity drift, attachment wear multipliers all deferred. |
| 5 | Full material-class penetration (concrete/steel/wood) + cover |

The player-facing detail for round variants, jams, condition, and
attachments lives in the [Ballistics](ballistics.md) chapter. The
design spec for the rest of the system lives in
[`planning/weapons-plan.md`][plan].

[plan]: ../planning/weapons-plan.md

## The penetration-vs-armor formula

Each round has an integer `penetration_class`; each armor item has
an integer `protection_class`. Per impact:

```
pen_eff = round.penetration_class - armor.protection_class

if pen_eff >= 0:                                 # penetrates
    damage = round.damage_soft * body_part.soft_multiplier
else:                                            # blocked
    ratio = max(0.0, 1.0 + pen_eff * 0.25)       # -25% per class short
    damage = round.damage_blunt * ratio * body_part.soft_multiplier

damage *= clamp(E_muzzle / round.reference_energy_j, 0.2, 1.0)
```

Body-part soft multipliers (`ballistics.toml`):
**head 2.5 / torso 1.0 / limbs 0.7**.

The range-falloff term currently uses muzzle kinetic energy (no
in-flight retained-energy tracking yet - a future slice swaps to
true retained velocity).

## Starter round × armor damage matrix

5.45×39 rifle rounds against common armor + body parts (rounded):

| Round → | HP | FMJ | AP |
|---|---|---|---|
| **vs bare torso** | 55 | 38 | 32 |
| **vs class-1 soft vest** | 9 (blunt) | 38 | 32 |
| **vs class-2 ballistic rig** | 9 (blunt) | 38 | 32 |
| **vs class-3 plate carrier** | 9 (blunt) | 11 (blunt) | 32 |
| **vs class-4 exo** | 6 (blunt) | 8 (blunt) | 32 |
| **vs bare head** | 138 | 95 | 80 |
| **vs class-2 helmet head** | 22 (blunt) | 95 | 80 |

HP shines against unarmored; FMJ is the general-purpose
middle ground; AP is your "someone in plates" answer. Headshots
stack the 2.5× multiplier on top of whatever the round is doing.

Pistol (9×18) rounds and shotgun (12ga) variants follow the same
pattern with their own damage numbers - check `items.toml` for
the actual profiles, or see the damage-matrix test suite in
`crates/simn-sim/tests/ballistics_matrix.rs`.

## Equipment slots

Weapons equip to the paper-doll slots (defined in
`equipment_slots.toml`):

| Slot | Accepts | Typical use |
|---|---|---|
| `primary` | `weapon_primary`, `weapon_secondary` | Rifle, shotgun, SMG. |
| `secondary` | `weapon_primary`, `weapon_secondary` | Backup long arm. |
| `sidearm` | `sidearm` | Pistol. |
| `armor_vest` | `armor_vest` | Body armor. |
| `head` | `head_gear` | Helmets. |

## Controls

| Key | Action |
|---|---|
| LMB | Fire active weapon (first click captures mouse) |
| Q / E | Cycle active weapon slot (primary ↔ secondary ↔ sidearm) |
| R | Reload active weapon |

LMB is gated on the weapon's `fire_interval_s` cooldown. The
client reads this out of `player_state.equipped_weapons[slot]`
after each successful shot. `eject_magazine` is still bridge-only
(no keybind) - unload by reloading with a different matching-
caliber mag; the one coming out lands in pockets with its rounds
intact.

## The reload flow

`R` pulls the best-loaded matching-caliber mag from pockets and
installs it on the weapon. The mag's `variant` (ammo id) rides
along - if the mag was loaded with AP rounds, it fires AP. Phase 2
keeps the tactical-reload preference: mags with more rounds win
the swap, tie-break by grid placement order.

If no matching-caliber mag is in pockets, reload errors.
Previously-loaded mag returns to pockets with its round count +
variant intact - eject a partial 12/30 AP mag, it lands back in
pockets still at 12/30 AP.

## The load-ammo flow

Fresh / ejected-and-empty magazines need ammo before they can
fire. Two entry points:

**Inventory panel (player-facing)** - open the inventory (I),
find the magazine in pockets; every mag card shows its variant +
loaded/capacity (`AP 24/30` or `EMPTY 0/30`). When pockets hold
matching-caliber ammo with room in the mag, a `▲ LOAD` button
appears on the card. Click → loads to capacity, auto-picks the
ammo variant (prefers the currently-loaded variant if any; else
picks whichever matching-caliber ammo has the most rounds in
pockets). Pre-prepped mags are then one `R`-press away from
firing.

**Programmatic**:
- `Sim::load_rounds_into_mag(sid, slot_id, round_id)` - tops up
  the mag currently loaded in `slot_id` (weapon slot).
- `Sim::load_rounds_into_pocket_mag(sid, pocket_idx, round_id)` -
  tops up the mag at `pocket_idx` in pockets. This is the one
  the inventory panel's LOAD button calls.

Both paths share the same validation:

1. Caliber must match (ammo's `caliber` == mag's `caliber`).
2. Partial mag with variant X rejects loading variant Y (real-
   gun model - fire out / eject first).
3. Consumes up to `capacity - current_rounds` rounds from
   pockets; excess stays in pockets.
4. Journals `WorldDelta::MagazineLoaded { slot_id, … }` for the
   equipped-mag path, `WorldDelta::PocketMagazineLoaded {
   pocket_idx, … }` for the pockets path.

## The fire flow

LMB calls `SimHost.fire_weapon(sid, slot, aim_yaw, aim_pitch)`.
The sim:

1. Validates the weapon + mag have what they need. Dry-clicks
   on no-mag, empty-mag, or no-variant (ammo never loaded).
2. Spawns a `Projectile` entity at `player.position + muzzle_offset`
   with velocity = `aim_direction × round.muzzle_velocity_mps`.
3. Journals `WeaponFired` (HUD reactivity) + `ProjectileSpawned`
   (client tracer).
4. Each subsequent tick, `tick_projectiles` integrates the
   projectile's gravity + drag, sweeps a ray against humanoid
   hitboxes in the same region, and on hit:
   - Reads the target's armor for the hit body part.
   - Runs the penetration formula to compute `damage` + `penetrated`.
   - Calls `apply_damage_to_npc_part` (shared with the melee /
     scripted damage paths) which drains HP + spawns a Bleed
     wound when damage crosses threshold.
   - Journals `ProjectileImpacted` with `hit_npc`, `body_part`,
     `damage_applied`, `penetrated`.
5. Client renders a tracer (yellow-orange cylinder) from origin
   along velocity on `ProjectileSpawned`, and a small impact
   sphere (red on penetration, white on blocked) at impact pos
   on `ProjectileImpacted`. Both fade over ~0.3s.

Hitscan is gone. Projectiles have a `max_range_m` from the firing
weapon; out-of-range projectiles despawn with a null-target
`ProjectileImpacted` so clients render a terminal ground puff.

## The HUD

The bottom-right weapon slot shows the active weapon's name, the
loaded variant tag, and ammo count:

```
AKS-74  AP 24/30
```

Variant tag is derived from the round id: `round_*_hp` → `HP`,
`round_*_ap` → `AP`, `round_12ga_slug` → `SLG`, `round_12ga_flechette`
→ `FLCH`, `round_12ga_buckshot` → `BCK`, else `FMJ` for the
phase-1 canonical ids (`round_9x18`, `round_5_45x39`).

When the slot is empty: `[ NO WEAPON IN PRIMARY ]`. When the
weapon has no mag loaded: `AKS-74  -/-`. When the mag is loaded
but no variant was ever ammo-loaded: the tag is blank and the
next LMB dry-clicks with `fire: magazine has no ammo variant
loaded`.

## Walking through it

Debug grant, equip, load, fire loop:

1. **Grant** a rifle + mag + 30 rounds of AP ammo + plate carrier
   armor via the debug spawn panel (`G`). Search "AKS", "5.45 ap",
   "plate", etc., or scroll the WEAPONS / MAGAZINES & AMMO / ARMOR
   buckets and click `+1` / `+10` / `+stack`.
2. **Equip** the rifle to `primary` and the plate carrier to
   `armor_vest`. HUD shows `AKS-74  -/-`.
3. **Reload** with `R`. HUD flips to `AKS-74  0/30` - the mag is
   loaded but empty.
4. **Load rounds** via the inventory panel's `▲ LOAD` button on
   the magazine card (open inventory with I, find the mag, click
   LOAD). Or programmatically via `SimHost.load_rounds(sid,
   "primary",
   "round_5_45x39_ap")` (bind in the debug overlay for convenience).
   HUD flips to `AKS-74  AP 30/30`.
5. **Fire** with LMB → tracer streaks out, NPC HP drops by ~32 if
   unarmored. Equip a class-3 plate carrier on the target NPC
   (debug-granted), swap to HP mag, fire again → near-zero blunt
   damage; AP mag back on, damage returns to ~32.
6. **Aim up 30°** and fire into the distance → projectile arcs,
   impacts ground past the range with a terminal sphere puff.
7. **Save + reload** → equipped armor, mag variants, in-flight
   projectiles all persist.

## Tuning

Weapon stats: `crates/simn-sim/data/items.toml` under
`[items.weapon_config]`.

Round ballistic + terminal stats: same file, `[items.ammo_config]`.
Each row carries caliber, mass_g, muzzle_velocity_mps, drag_k,
penetration_class, damage_soft, damage_blunt, reference_energy_j.

Armor: same file, `[items.armor_config]`. Each row has
protection_class and coverage.

Global formula tuning: `crates/simn-sim/data/ballistics.toml` -
gravity, retained-energy floor, blocked-damage ratio per class
short, muzzle offset, body-part soft multipliers.

All three TOMLs are the single source of truth; engine code reads
them and never supplies fallbacks. A weapon without a
`weapon_config` can't fire. A magazine without `magazine_config`
can't be loaded. A round without `ammo_config` can't be loaded
into a mag. An armor item without `armor_config` doesn't protect.
