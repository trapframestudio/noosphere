# Weapons, Ballistics, Parts & Loot - Planning Doc

**Status:** partially delivered.
- **Phase 1** (data model, magazines, reload, hitscan fire) — landed via PR #24.
- **Phase 2** (projectile sim + round variants + armor/penetration — §4 and the damage half of §6) — landed via PR #27. Player-side projectile pipeline is live (`Projectile` ECS entity, gravity + drag from `BallisticsConfig`, swept-ray hits against `world/hitbox.rs` body-part primitives, penetration vs `ArmorConfig.protection_class`, journals `ProjectileSpawned` / `ProjectileImpacted`).
- **GAMMA caliber roster + per-category TOML split** — landed 2026-05-09 (PR #150). `crates/simn-sim/data/items/{weapons,magazines,ammo,armor,medical,food,salvage,tools,containers}.toml` carry the canonical roster; ammo entries tag a `caliber_class` (Pistol / PDW / Intermediate / FullPowerRifle / Magnum / AntiMateriel / Shotgun) consumed by the world event bus's audibility model and the future `resolve_wound_kind`.
- **NPC-side firing path** — migrated to the shared `Projectile` ECS path. Phase 4A v1 (`sim-iteration-5-12`) added cosmetic NPC projectile spawns alongside the dice path; Phase 4A v2 retired the dice path entirely and routes NPC damage through the projectile-hit branch (NPC vs NPC and NPC vs player both resolve geometrically via `world/hitbox.rs`; attribution writes from `Sim::apply_npc_attribution_for_hit` at impact time). `npc_combat` is now a pure fire-decision system that queues `NpcShotIntent`; `accuracy_hit_multiplier` is retained for legacy unit-test compatibility but unused at runtime. See [`sim-iteration-5-12-plan.md`](sim-iteration-5-12-plan.md) §4A for the rollout, and [`physical-combat-plan.md`](physical-combat-plan.md) for the broader combat pipeline.

- **Attachment slot-tag graph (§3 data layer)** — landed in `sim-iteration-5-12` Phase 4C. `WeaponConfig.slots`, `ItemCategory::Attachment`, `AttachmentConfig { consumes_tag, provides_tags, effects }`, and `validate_attachment_chain` are live. Five canonical attachments shipped (`att_pso1_scope`, `att_ak_dovetail_picatinny`, `att_aimpoint_compm4`, `att_pbs1_suppressor`, `att_ultimak_rail`); AKS-74 exposes its five native slot tags. Validator covers direct mounts, 2-stage adapter chains, parallel routes, and duplicate-consume rejection. Effect strings on attachments are *authored* but not yet runtime-applied; that wiring lands with Phase 4D follow-ons / Phase 5 alongside the equip UI.
- **Parts condition + jams (§5 v1)** — landed in `sim-iteration-5-12` Phase 4D. v1 ships a single aggregate `condition` per weapon (not the §5.1 per-part roster) with a linear jam-probability curve. `EquippedWeaponState.condition` + `jam_state` (`Cleared` / `FailureToFeed` / `FailureToExtract` / `Stovepipe`); `WeaponConfig.wear_per_shot` / `jam_threshold` / `jam_chance_floor` author per-weapon. `Sim::fire_weapon` rolls jam before expending a round; `Sim::clear_weapon_jam` is the unjam action. Three new deltas (`WeaponJammed`, `WeaponJamCleared`, `WeaponConditionChanged`) round-trip across persistence and mirror replay. NPC weapons don't carry condition yet — they fire jam-free in v1. Per-part roster, attachment wear multipliers, and stat degradation (accuracy / muzzle velocity drift) are deferred to later iterations on top of this v1 scaffold.

Remaining: per-part condition roster (§5.1), attachment wear multiplier consumption (§5.6 → §3.4 stat aggregation), accuracy / muzzle-velocity drift curves (§5.3), NPC jam handling, material-class penetration + cover (rest of §6), loot economy (§7 — see companion doc).

The player-facing contract for the shipped Phase 4 work lives in [`mechanics/ballistics.md`](../mechanics/ballistics.md).
**Last updated:** 2026-05-20
**Scope:** data model and system boundaries for the modular weapon system, ballistics, and Anomaly/GAMMA-style internal parts. Loot economy lives in `loot-and-economy-plan.md`.

This is a living design doc. It captures decisions and open questions; the sections marked "delivered" ship today; the rest is not a spec yet.

---

## 1. Goals & Non-Goals

**Goals**
- Maximally modular attachments: any real-world-plausible combination should be expressible as data, no code changes.
- Per-round-variant ballistics (GAMMA-style caliber spread: FMJ, HP, AP, tracer, overpressure).
- Internal parts with independent wear, cannibalization, field repair, jams (Anomaly/GAMMA-style).
- Server-authoritative loot with deterministic, seedable rolls.
- Fully data-driven (TOML/RON) so modders can add weapons, rounds, attachments, and loot pools without touching Rust.

**Non-Goals (for now)**
- Photoreal recoil animation model - out of scope for sim crate.
- Full internal-ballistics simulation (pressure curves, barrel harmonics). Use tabulated muzzle velocity + drag model instead.
- Heat/thermal simulation. Future extension, not v1.

---

## 2. Crate Boundaries

| Concern | Crate | Rationale |
|---|---|---|
| Item/weapon/round/attachment definitions | `simn-sim` | Pure data, engine-agnostic |
| Ballistics math (drag, drop, penetration) | `simn-sim` | Math, no Godot |
| Parts wear + condition curves | `simn-sim` | Simulation |
| Loot table rolling | `simn-sim` | Server-side, deterministic |
| Projectile entities + raycast bridge | `simn-godot` | Needs Godot physics/raycast |
| Weapon visual attachment mounting | `simn-godot` + scenes | Scene bones / attach points |
| Loot container UI | `godot/scripts` (GDScript) | UI layer |

**Hard rule (already in CLAUDE.md):** `simn-sim` never imports `godot`. All above respects this.

---

## 3. Attachment System - Slot-Tag Graph

### 3.1 Model

Every weapon has a set of **slots**. Every attachment **consumes** one slot tag and optionally **provides** one or more new tags. This makes rails, adapters, and mount conversions just ordinary attachments.

```
Weapon (AKM)
├── slot: receiver_top           tags: [ak_dust_cover]
├── slot: receiver_side          tags: [dovetail_side]
├── slot: handguard              tags: [ak_handguard]
├── slot: muzzle                 tags: [threaded_14x1_lh]
├── slot: stock                  tags: [warsaw_stock]
├── slot: pistol_grip            tags: [ak_grip]
├── slot: magazine               tags: [ak_762_mag]
└── slot: trigger_group          tags: [ak_fcg]
```

**Attachment examples:**

```
Attachment: AK Dovetail→Picatinny Adapter
  consumes: dovetail_side
  provides: [picatinny]

Attachment: PSO-1 Scope (Russian)
  consumes: dovetail_side
  provides: []

Attachment: Aimpoint CompM4
  consumes: picatinny
  provides: []

Attachment: Ultimak Gas Tube Rail (AK)
  consumes: ak_handguard     # replaces top handguard
  provides: [picatinny]

Attachment: B&T Rotex Suppressor
  consumes: threaded_14x1_lh
  provides: []
  effects:
    - barrel_wear_mult: 1.4
    - gas_system_wear_mult: 1.5   # accelerates parts (#5)
    - sound_signature: -0.6
    - muzzle_flash: -0.9
```

### 3.2 Why tags instead of explicit whitelists

- AK side-rail accepts either a native Russian dovetail optic OR a dovetail→pic adapter OR a dovetail→micro-T1 adapter. Tags handle all three without `if weapon == "AKM"` code.
- Modders add a new weapon with a `picatinny` slot and every existing pic attachment Just Works.
- Handguard replacement (e.g., Ultimak, Magpul Zhukov) cleanly swaps the tag graph: the replacement handguard declares different provided tags than the stock one.

### 3.3 Starter tag vocabulary

- **Mounting surfaces:** `picatinny`, `m-lok`, `keymod`, `dovetail_side` (AK/SVD/VSS), `dovetail_top` (Mosin/SKS/Dragunov), `rmr_footprint`, `docter_footprint`
- **Muzzle threads:** `threaded_14x1_lh`, `threaded_14x1_rh`, `threaded_1/2-28`, `threaded_5/8-24`
- **Stock interfaces:** `warsaw_stock`, `ar15_buffer`, `folding_triangle_ak`, `proprietary_<weapon>`
- **Magazine wells:** `ak_762_mag`, `ak_545_mag`, `stanag`, `svd_mag`, etc.
- **Slot kinds (not tags):** `optic`, `underbarrel`, `muzzle`, `laser_light`, `handguard`, `stock`, `grip`, `magazine`, `trigger_group`, `receiver_top`, `receiver_side`

### 3.4 Stat aggregation

**Hybrid model:**
- **Physical stats recomputed from parts+attachments:** total weight, overall length, muzzle velocity (barrel length factor), balance point.
- **Feel stats additive from modifiers:** ergonomics, recoil control, handling, durability.

Example: swapping a 16" barrel for a 10" barrel recomputes muzzle velocity from first principles (round's base velocity × barrel-length curve). Swapping a vertical foregrip adds `+8 ergo, +5 recoil_control` flat.

### 3.5 Open questions

- Do we allow multiple underbarrel attachments (grip + laser on same rail)? Lean yes via sub-slots provided by rail segments.
- How do we represent two-stage adapters (dovetail → pic → RMR footprint)? Probably fine as chained attachments, but need to validate no infinite recursion in the tag resolver.

---

## 4. Caliber & Round Variants

> **Phase 2 - DELIVERED (PR #27).** `AmmoConfig` carries per-
> variant ballistic + terminal stats (mass_g, muzzle_velocity_mps,
> drag_k, penetration_class, damage_soft, damage_blunt,
> reference_energy_j). Host-side `tick_projectiles` integrates
> drag + gravity and resolves impacts. Three variants ship per
> caliber (HP / FMJ / AP on pistol + rifle; buckshot / slug /
> flechette on shotgun). See
> `docs/book/src/mechanics/weapons.md` for the player-facing
> tour. Remaining in this section: attachment-driven stat
> aggregation (§3.4) which needs the attachment graph (§3) to
> ship first.
>
> **CaliberClass taxonomy + TOML field — landed 2026-05-09.**
> The `CaliberClass` enum graduated from a 3-band placeholder
> (Light/Medium/Heavy) to the 7-class model in this section
> (Pistol / PDW / Intermediate / FullPowerRifle / Magnum /
> AntiMateriel / Shotgun). `AmmoConfig` gains a `caliber_class`
> TOML field (defaults to `pistol`); audibility radii calibrated
> per class (PDW 150 m → AntiMateriel 600 m). Legacy `audible_band`
> 3-tier mapping retained as `CaliberClass::audible_band` for
> consumers that don't need the full taxonomy. Unblocks
> `dismemberment-plan.md` §5 `resolve_wound_kind` (sever-threshold
> table keys off `CaliberClass`).
>
> **GAMMA-roster ammo expansion — landed 2026-05-09.** The catalog
> now ships 68 ammo entries spanning every modern-era caliber the
> setting plausibly carries: pistol (9×18, 9×19, 9×21 Gyurza,
> 7.62×25, .45 ACP, .357 Mag, .44 Mag, .50 AE, .22 LR), PDW
> (4.6×30, 5.7×28), intermediate (5.45×39, 5.56×45, 7.62×39,
> 9×39 SP-5/SP-6, .300 BLK, .366 TKM), full-power rifle
> (7.62×54R, .308 Win, .30-06), magnum (.338 Lapua,
> .300 Win Mag), anti-materiel (.50 BMG, 12.7×108, 14.5×114),
> and shotgun (12ga, 20ga, .410). FMJ / HP / AP variants per
> applicable caliber, real-world velocities (m/s) calibrated to
> factory load tables, kinetic-energy-derived `reference_energy_j`,
> penetration_class scaled 0–8 (HP → AP-I).
>
> **Per-category items split — landed 2026-05-09.** Single
> `items.toml` retired in favor of `data/items/{food, medical,
> salvage, tools, containers, weapons, magazines, ammo,
> armor}.toml`. The loader concatenates them at compile time via
> `include_str!` so the runtime parse is unchanged; the split
> just keeps each file readable as the catalog grows.

### 4.1 Two-level model

**Caliber** (shared physical properties):
- Bore diameter, case length, base chamber pressure rating
- Magazine compatibility tag (which mag wells accept it)

**Round variant** (what you actually load):
- Bullet mass (grains)
- Muzzle velocity (m/s, measured from reference 16" barrel - scaled for actual barrel length at aggregation time)
- Ballistic coefficient / drag model
- Penetration class (see #6)
- Terminal behavior: expansion (HP), fragmentation, over-penetration tendency
- Tracer flag
- Chamber pressure (affects parts wear multiplier - see #5)
- Rarity tier for loot tables (see #7)
- Cost (barter value)

### 4.2 Starter caliber list (Eastern Bloc focus, matching setting)

- **9×18 Makarov** - PMM, 57-N-181S
- **9×19 Parabellum** - FMJ, JHP, 7N21 (AP)
- **5.45×39** - 7N6, 7N10, 7N22, 7N24 (GAMMA-style escalating AP)
- **5.56×45 NATO** - M193, M855, M855A1, Mk262
- **7.62×39** - PS, BP, 7N23
- **7.62×54R** - LPS, 7N1, 7N26, B-32 (AP-I)
- **.308 Win / 7.62×51** - M80, M80A1, Mk316
- **12ga** - 00 buck, slug, flechette, dragon's breath
- **.366 TKM** - civilian-legal Russian round, rare
- **9×39** - SP-5, SP-6 (VSS/AS Val subsonic AP)
- **.50 BMG** (for late-game anti-materiel content)

### 4.3 Key decision: projectile sim vs. hitscan

Recommend **projectile simulation with drop and drag**, not hitscan with falloff.

- Cost: one entity per in-flight bullet. At realistic fire rates (say 100 concurrent projectiles peak across all players) this is trivial.
- Benefit: subsonic 9×39 at 300m feels different from 5.45 at 300m. AP rounds retain velocity. Ballistic drop creates skill ceiling.
- Implementation sketch: `Projectile` component with `position`, `velocity`, `mass`, `bc`, `source_weapon_id`, `round_variant_id`. Tick applies gravity + drag. On impact, resolve against target's material/armor using retained kinetic energy.

---

## 5. Internal Parts & Condition (Anomaly/GAMMA-style)

### 5.1 Part roster per archetype

Target **5–8 parts per weapon**. Archetype-specific additions where they matter mechanically.

**Common core (every firearm):**
- `receiver` - structural. Catastrophic failure at 0% (weapon dead, repair requires workbench).
- `barrel` - accuracy + velocity degrade with wear. Threaded barrels wear faster under suppressor.
- `bolt` / `bolt_carrier` - cycling reliability, FTE jams at low condition.
- `trigger_group` - trigger pull weight, disconnector reliability.
- `spring_set` - feed reliability, FTF jams at low condition.
- `extractor` - FTE jam probability curve.

**Archetype additions:**
- Gas-operated (AK, AR, SVD): `gas_system` - cycling reliability, accelerated wear from suppressors.
- Bolt-action (Mosin, SV-98): no gas system; `bolt` absorbs its role.
- Break-action shotguns: `hinge_pin` instead of bolt.

### 5.2 Part properties

```
Part {
  part_kind: "ak_bolt",
  condition: 0..100,
  quality_tier: worn | serviceable | pristine | milspec,
  max_condition_ceiling: 85 | 95 | 100 | 100,   // from quality
  wear_rate_base: f32,                           // per shot
  donor_compat: [weapon_ids it fits in],
}
```

### 5.3 Wear model

Per shot fired:
```
wear = part.wear_rate_base
     * round.pressure_mult
     * attachment.wear_mults[part.kind]
     * cleanliness_factor
     * (1.0 - quality_tier_resistance)
```

Condition maps to stat degradation + jam probability via per-part curves:
- `barrel` 100→50: velocity -3%, accuracy -15%. 50→0: velocity -15%, accuracy -50%.
- `bolt` 100→70: no effect. 70→40: FTE chance ramps 0→5%. 40→0: ramps 5→25%.
- `receiver` 100→10: no effect. 10→0: catastrophic failure chance per shot.

### 5.4 Jam types

- **Failure to feed (FTF)** - `spring_set` low. Clear: rack bolt (1.5s).
- **Failure to extract (FTE)** - `extractor` or `bolt` low. Clear: mortar / manual extract (3–6s).
- **Double feed** - rare, combo of spring + magazine. Clear: drop mag, clear, reload (5–8s).
- **Stovepipe** - `bolt` / `gas_system` tuning. Clear: rack bolt (1.5s).
- **Catastrophic** - `receiver` at 0%. Weapon dead until workbench.

### 5.5 Repair & cannibalization economy

- **Field cleaning** (any gun oil + rag): restores condition toward part ceiling, doesn't raise ceiling.
- **Part swap** (field toolkit): swap a part from donor weapon into primary. Ceiling = donor part's ceiling.
- **Refurbish** (workbench): raises ceiling partway toward pristine using consumables.
- **Machining** (advanced workbench, late game): fabricate new parts from scrap + ingot.

### 5.6 Interaction with attachments (#3)

External attachments modify part wear rates via `wear_mults`. This is how a suppressor "beats up" an AK - no special case, just a data field on the suppressor attachment.

---

## 6. Penetration & Damage

> **Phase 2 - PARTIALLY DELIVERED (PR #27).** The body-armor
> slice shipped: `ArmorConfig { protection_class, coverage }` on
> `ItemDef`, the integer pen-vs-class formula (`damage_soft` on
> penetrate, blunt-scaled `damage_blunt` on block, –25% per class
> short), body-part soft multipliers in `ballistics.toml`
> (head 2.5 / torso 1.0 / limbs 0.7), retained-energy floor
> for range falloff. Five armor items ship (soft vest → class-IV
> exo + 6B47 helmet). 8 damage-matrix integration tests cover
> the HP/FMJ/AP × bare/class-1/2/3/4 × torso/head cells. See
> `docs/book/src/mechanics/weapons.md` for the player-facing
> damage table. **Not yet delivered**: material classes for
> world cover (§6.1 full list - wood, cinderblock, brick, etc.)
> and the cover-penetration resolution in §6.2; those ride on
> the cover + destructible-geometry slice (future).

### 6.1 Material classes

Every hittable surface declares a **material class**:
- `flesh_soft`, `flesh_armored_light`, `flesh_armored_heavy`, `flesh_armored_plates`
- `cover_light` (wood, drywall), `cover_medium` (cinderblock, car door), `cover_heavy` (brick, steel plate)
- `armor_tier_1` (kevlar), `armor_tier_2` (soft+trauma plate), `armor_tier_3` (rifle plate), `armor_tier_4` (milspec ceramic)

### 6.2 Resolution

On projectile impact:
1. Compute retained kinetic energy from projectile state (mass + velocity at impact).
2. Compare against material's **energy-to-penetrate** threshold.
3. If penetrate: subtract energy cost, continue projectile through with reduced velocity. Apply damage to entity behind material.
4. If not penetrate: stop projectile, apply blunt-trauma damage (reduced, scaled by round+armor combo).

This gives natural over-penetration, wall-bang mechanics, and makes AP rounds meaningfully different from FMJ against armored targets - all from one model.

### 6.3 Damage curves

Per round variant: `damage_per_kj_retained` curves for `flesh_soft` vs `flesh_armored_*`. HP rounds dump more energy in soft tissue; AP rounds retain energy through armor but do less in soft tissue.

---

## 7. Loot - see companion doc

Loot tables, faction-driven restocking, depth tiers, NPC progression, notoriety, ambient scatter, and the circulating-inventory feedback loop are owned by `loot-and-economy-plan.md`. This doc stops at the weapon instance.

What this doc still owns: the shape of a rolled weapon instance, because that's the serialization contract the loot system consumes.

### 7.1 Weapon instance shape

Containers and NPC inventories both store weapons as full state trees, not item_ids:

```
WeaponInstance {
  weapon_id: "akm",
  parts: [
    { kind: "barrel",         condition: 42, quality: serviceable },
    { kind: "bolt",           condition: 67, quality: worn },
    { kind: "gas_system",     condition: 55, quality: serviceable },
    { kind: "trigger_group",  condition: 71, quality: serviceable },
    { kind: "spring_set",     condition: 33, quality: worn },
    { kind: "extractor",      condition: 48, quality: serviceable },
    { kind: "receiver",       condition: 80, quality: serviceable },
  ],
  attachments: [
    { slot: "magazine", attachment: "ak_762_mag_30rd" },
    // rolled for containers; actually-equipped for NPC corpses
  ],
  loaded_rounds: 17,
  loaded_variant: "round_762x39_ps",
}
```

For a container restock, the loot system rolls this from faction × depth × family pools (see `loot-and-economy-plan.md` §3). For an NPC corpse, this is just the NPC's real inventory at time of death - no roll. Same shape, different source.

### 7.2 Pool gating hooks this doc must expose

The loot system needs these lookups from the weapons data:

- **Round variants by tier:** each round variant declares the minimum depth tier it should appear in (or the per-tier weight curve). Gates 7N24 / exotic rounds to deep zones.
- **Part quality by tier:** distributions over `{worn, serviceable, pristine, milspec}` per tier. Shallow skews worn, deep skews pristine+.
- **Attachment compatibility pools:** "what attachments can be rolled onto this weapon at tier N." Used by container rolls, not by corpse drops.
- **Weapon availability by tier and faction:** which weapon archetypes belong in which faction pool at which tier.

These are part of the weapons data files, queried by the loot roller. Concrete shape TBD alongside the modding manifest.

---

## 8. Proposed Rollout Order

1. **Round variants + caliber table + basic ballistics** - projectile sim, drag/drop, no parts yet. Weapons roll as whole items with flat condition.
2. **Attachment slot-tag system** - optics, suppressors, magazines. Stat aggregation.
3. **Parts + condition + jams** - the GAMMA layer. Wear, cleaning, field swap.
4. **Penetration + material classes + armor tiers** - the full damage model.
5. **Loot table system** - see `loot-and-economy-plan.md` for its own rollout sequence; begins once steps 1–4 here give rolls something meaningful to produce.
6. **Repair/cannibalization economy** - workbenches, toolkits, machining.

Each step produces a playable increment. Step 1 alone gives us "shooting with meaningful round choice." Step 2 adds customization. Steps 3–4 add GAMMA feel. Step 5 ties it all into the world economy.

---

## 9. Open Cross-Cutting Questions

- **Serialization of rolled weapons.** A weapon instance carries substantial state (parts × condition × quality, attachment list, loaded rounds). Needs a compact serialized form for the journal/snapshot persistence in `simn-sim`.
- **Networking.** When we get to `simn-net`, per-weapon state needs efficient replication. Parts condition changes slowly - candidate for delta + interval sync rather than per-tick.
- **Modding manifest shape.** All four systems (weapons, rounds, attachments, loot) need a consistent data-file layout. Worth designing together, not piecemeal.
- **Condition UI surface.** How does the player *see* that their extractor is worn? Inspect screen with per-part breakdown? Hinted by jam frequency? Probably both. UI-layer decision, but data model must expose it.

---

## 10. What This Doc Is Not

- Not a spec. Numbers here are illustrative.
- Not a schedule. No dates.
- Not committed. Sections can be reworked freely during planning.

Revisit before any of this lands in code.
