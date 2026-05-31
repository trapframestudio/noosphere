# Ballistics

This chapter is the player-facing contract for how rounds, weapons,
attachments, and jams behave once a shot leaves the barrel. It
covers the systems that landed across **`sim-iteration-5-12`
Phases 4A–4D**. The [Weapons](weapons.md) chapter covers the gun
loop itself (equip, reload, fire, the pen-vs-armor formula); this
one focuses on the things between *pulling the trigger* and *the
round arriving where you wanted it*.

Tuning numbers below are calibrated for "feel" today and expected
to drift with playtest. The mod authoring contract is stable:
every value lives in `data/items/*.toml` or `ballistics.toml`,
not in Rust.

## Round variants

Every ammo entry carries a **variant** tag describing its terminal
behavior family. Numbers (mass, muzzle velocity, penetration class,
damage) are still per-row in [`ammo.toml`][ammo_toml] — the variant
is the *family* the round belongs to, not a multiplier on top of
a baseline.

[ammo_toml]: https://github.com/joniler/noosphere/blob/main/crates/simn-sim/data/items/ammo.toml

| Variant | Real-world analogue | Profile |
|---|---|---|
| `fmj` | Full Metal Jacket / ball ammo | The baseline. Balanced soft damage, moderate penetration. |
| `hp` | Hollow Point / Soft Point / JHP | High soft damage on unarmored hits; penetration drops hard against plates. |
| `ap` | Armor Piercing (BP / 7N## / steel / tungsten cores) | Higher penetration class; soft damage often a touch lower than FMJ. |
| `tracer` | M196 / T-46 incendiary trace | Same ballistic profile as FMJ; renders a longer, brighter orange streak with emission. Future work ignites dry foliage on impact. |
| `overpressure` | +P / +P+ proof-load | Higher muzzle velocity + chamber pressure. Wears the weapon faster (Phase 4D parts condition reads this). |

**Default**: any round that doesn't declare a variant in TOML is
`fmj`. So the baseline `round_9x18` row sits at `fmj` implicitly;
`round_9x18_hp`, `round_9x18_ap`, and (future) `round_9x18_t`
declare their variant explicitly.

The shipped ammo catalog tags 32 non-FMJ rounds across the GAMMA
caliber roster (HP / JHP families, AP / BP / 7N## families,
flechette shotgun shells, `45acp_p` overpressure). Three canonical
tracer rounds ship at the iteration's close: `round_5_45x39_t`,
`round_556x45_tracer`, `round_762x54r_t46` (the latter as the
classic Soviet T-46 loading).

The variant tag flows into the `projectile_spawned` signal payload
as a `variant: String` field. `godot/scripts/impact_fx.gd` reads
it to pick the streak color (FMJ yellow / HP warm-red / AP pale
blue / Tracer bright orange + longer streak + slight emission /
Overpressure searing white-yellow). Casing-eject SFX and
material-aware impact FX are the remaining variant-driven hooks.

## Weapon condition + jams

Every weapon you equip carries a single aggregate **condition**
from 0 to 100. Fresh weapons spawn at 100; each shot drops the
value by the weapon's `wear_per_shot` (defaults to 0.05 — a
Kalashnikov-class reliability profile, modders adjust per row).

**Above the condition threshold (default 70) the gun never jams.**
That's the design contract: a clean weapon is a *reliable*
weapon. Below the threshold the jam-probability curve ramps
linearly to the floor (default 0.18) at condition 0:

```
jam_chance = 0 when condition >= threshold
           = floor when condition <= 0
           = floor * (threshold - condition) / threshold  otherwise
```

So a weapon at 35 % condition with the stock 70/0.18 curve jams
on about 9 % of trigger pulls. At 0 % condition it jams ~18 % —
still firing four out of five shots, but you feel every miss.

When a jam fires, the trigger pull is a **dry click**: no round
expended, no projectile spawned, no audible bang. The weapon's
`jam_state` transitions and stays stuck until you clear it via
`clear_weapon_jam`. The state names the failure mode so future
HUD prompts can pick the right clear-jam animation:

| State | Cause band | Real-world flavor | Clear-jam time (future) |
|---|---|---|---|
| `failure_to_feed` | condition 45–threshold | Round didn't chamber | Quick rack |
| `stovepipe` | condition 20–45 | Case caught in port | Quick rack |
| `failure_to_extract` | condition <20 | Spent case stuck | Manual extract / mortar |

**Clearing a jam doesn't repair condition.** It's a recovery
action, not maintenance. If a weapon jams once it'll jam again
soon unless you actually do something about the condition (Phase
5 brings the cleaning kit + workbench refurbish loop; until
then, swap to a fresher weapon).

NPC weapons don't carry condition in v1 — they fire jam-free.
That parity gap closes in a future pass once NPC loadouts roll
up condition values on spawn.

## Attachments

Weapons declare a list of **slots**, each of which exposes one or
more **mount-surface tags** (`threaded_14x1_lh`, `dovetail_side`,
`picatinny`, `warsaw_stock`, `ak_handguard`, `ak_545_mag`, …).
Attachments declare **what tag they consume** and **what new
tags they provide** downstream:

- A scope on the AK's side rail **consumes** `dovetail_side`
  and provides nothing — direct mount, one step.
- A dovetail → Picatinny adapter **consumes** `dovetail_side` and
  **provides** `[picatinny]` — opens up the whole western-rail
  attachment ecosystem on Warsaw-Pact weapons.
- An Aimpoint **consumes** `picatinny` and provides nothing — so
  on the AK you reach it via the adapter chain
  (`dovetail_side` → adapter → `picatinny` → Aimpoint).

The resolver walks the chain in order; the first invalid step
fails the whole chain with a named error you can surface in UI:

| Error | Means |
|---|---|
| `UnknownItem` | The id isn't in the registry. Modder typo or removed item. |
| `NotAWeapon` | You passed something that isn't a weapon as the chain root. |
| `NotAnAttachment` | The middle of the chain isn't an attachment item. |
| `NoMatchingSlot` | The attachment needs a tag the weapon doesn't expose (e.g., red dot without an adapter). |
| `TagAlreadyConsumed` | Two attachments race for the same slot (only one wins per slot). |

Phase 4C ships **the data layer plus the validator**. UI for
actually installing attachments is the Phase 5 slice; Phase 4D's
condition + jam loop is the prerequisite work for the wear-
multiplier interactions a suppressor would impose on the gas
system. The fields are already authored on every attachment
(`barrel_wear_mult`, `gas_system_wear_mult`, `sound_signature`,
…) — they're just not yet consumed at runtime.

### Shipped attachment roster

Five canonical entries ship with the iteration. They exercise
the four main chain patterns:

| Item | Consumes | Provides | Notes |
|---|---|---|---|
| `att_pso1_scope` | `dovetail_side` | — | Direct mount: Soviet PSO-1 on the AK side rail. |
| `att_ak_dovetail_picatinny` | `dovetail_side` | `picatinny` | Adapter step; sacrifices the side rail to open Picatinny mounts. |
| `att_aimpoint_compm4` | `picatinny` | — | Western red dot; reaches the AK only via an adapter. |
| `att_pbs1_suppressor` | `threaded_14x1_lh` | — | Muzzle device on a Warsaw thread; sound + flash down, wear up. |
| `att_ultimak_rail` | `ak_handguard` | `picatinny` | Alternative route to Picatinny via the gas tube — useful when the side rail is occupied. |

### Tag vocabulary

The shipped starter tags. Modders extend by inventing new tag
strings — engine code never hard-codes a tag value, so a new
weapon with a `proprietary_mp7_stock` slot Just Works with any
attachment that declares the same string.

- **Mounting surfaces**: `picatinny`, `dovetail_side` (AK/SVD),
  `dovetail_top` (Mosin/SKS), `m-lok`, `keymod`,
  `rmr_footprint`, `docter_footprint`.
- **Muzzle threads**: `threaded_14x1_lh`, `threaded_14x1_rh`,
  `threaded_1/2-28`, `threaded_5/8-24`.
- **Stock interfaces**: `warsaw_stock`, `ar15_buffer`,
  `folding_triangle_ak`, `proprietary_<weapon>`.
- **Magazine wells**: `ak_762_mag`, `ak_545_mag`, `stanag`,
  `svd_mag`, …

## What's parked

These are the next slices on top of Phase 4's foundation. The
data and seams exist; what's missing is the runtime application:

- **Per-part condition roster** — `barrel`, `bolt`, `extractor`,
  `gas_system`, `receiver`, `spring_set`, `trigger_group` as
  separate condition pools (Phase 4D v2). Per-part lets a
  suppressor specifically beat up the gas tube without prematurely
  retiring the rest of the weapon.
- **Accuracy + muzzle-velocity drift with condition** — once
  per-part lands, a worn barrel costs MV + accuracy specifically.
- **Attachment runtime apply** — the `recoil_control`,
  `ergonomics`, `zoom`, `sound_signature`, `barrel_wear_mult`,
  `gas_system_wear_mult` fields all exist on the attachment data
  but aren't yet consumed. Wires up with the Phase 5 equip UI.
- **NPC condition + jam handling** — NPCs share the projectile
  pipeline already; they just don't carry condition in v1.
- **Material-class penetration + cover** — `weapons-plan.md` §6.1
  full list (wood, cinderblock, brick, …) with the cover-
  penetration resolution in §6.2.

[plan]: ../planning/weapons-plan.md
