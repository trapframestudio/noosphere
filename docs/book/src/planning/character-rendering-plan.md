# Character Rendering & Modular Outfits - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-25
**Scope:** how the visual character rig - base body, clothing, gear,
weapons - is composed at runtime from the existing `Equipment`
component. The inventory system already owns slot state, item
categories, and NPC loadouts; this doc covers the rendering bridge
from `Equipment` → on-character meshes parented to a humanoid skeleton.
Companion to [`../mechanics/inventory.md`](../mechanics/inventory.md)
(the landed system this builds on) and
[`../walkthroughs/humanoids.md`](../walkthroughs/humanoids.md) (the
character node structure today).

This is a living design doc. Numbers, paths, and phase ordering are
illustrative until the work starts.

---

## 1. Guiding Principle

**Modular composition over hand-modeled uniqueness.** Noosphere needs
dozens of distinct human silhouettes - faction loadouts, civilians,
named NPCs - and the project owner is not a senior character artist.
The path that scales is a small, hand-crafted library of base bodies +
modular gear pieces + textured material variants, combined at runtime
through the slot system the inventory crate already owns. This is how
S.T.A.L.K.E.R. itself shipped its NPC roster.

**No generative 3D in the asset pipeline.** AI mesh generators
(Meshy, Tripo, Rodin, etc.) produce a recognizable blobby/melted
silhouette that breaks the grounded survival tone. The diversity comes
from combinatorics over hand-authored parts and from texture variation,
not from procedurally generated geometry.

**Hand-crafted texturing carries most of the perceived quality.** A
plain jacket with a worn, patched, dirt-streaked Substance Painter
material reads as authored; a high-poly jacket with a flat default
material reads as generic. The budget priority is texturing tools,
not generation tools.

---

## 2. Scope vs the Existing Inventory System

The inventory system in `simn-sim` is mature. Quick recap of what
already lands here, so this plan can stay narrow:

- **Equipment slots** are data-driven in
  [`crates/simn-sim/data/equipment_slots.toml`](../../../../crates/simn-sim/data/equipment_slots.toml)
  - 15 slots covering head/face (`head`, `eyes`), torso
  (`armor_vest`, `rig`), carry (`backpack`), weapons (`primary`,
  `secondary`, `sidearm`, `melee`), belt hotbar (`belt_1..4`), plus
  the virtual `pockets` and always-with-you `secure_pocket`. Each
  has a category whitelist.
- **Item categories** include `HeadGear`, `Eyes`, `ArmorVest`,
  `ChestRig`, `Backpack`, `WeaponPrimary`, `WeaponSecondary`,
  `Sidearm`, `Melee` - the gear taxonomy is in place.
- **`ItemDef`** ([`crates/simn-sim/src/items.rs`](../../../../crates/simn-sim/src/items.rs))
  is TOML-defined, registry-loaded, save-file-stable. Items are
  identified by string `ItemId`; instances are pure runtime data.
- **`Equipment` component** is a `HashMap<SlotId, EquippedItem>`,
  generic across players and NPCs.
- **NPC loadouts** ([`crates/simn-sim/src/npc_loadouts.rs`](../../../../crates/simn-sim/src/npc_loadouts.rs))
  already populate per-faction inventories at spawn; equipping them
  visually is a TODO in the same area.
- **Persistence** flows through `WorldDelta::ItemEquipped` /
  `ItemUnequipped`; visual state is derived from the same source of
  truth, never stored separately.

**This plan does not touch any of the above.** What it adds is three
narrow extensions:

1. Two new optional fields on `ItemDef` (`mesh_path`, `attachment_bone`).
2. An `equipment_changed` signal on the gdext sim bridge so the render
   layer can react without polling.
3. A new `CharacterRig` gdext class in `simn-godot` that watches the
   signal and instantiates / parents / frees GLB scenes per slot.

Everything else - base bodies, animation, materials, the actual
modeling - is asset work that lives outside the sim crate entirely.

---

## 3. `ItemDef` Extension

Two optional fields. Both default to `None` so every existing item in
`items.toml` keeps working unchanged.

```rust
pub struct ItemDef {
    // ... existing fields ...

    /// Path to a Godot scene/mesh asset for this item's on-character
    /// representation. Typically a GLB file under `godot/models/gear/`.
    /// `None` for items that never render on the character (ammo,
    /// food, junk, components, magazines stored in pouches).
    #[serde(default)]
    pub mesh_path: Option<String>,

    /// Skeleton bone this item attaches to when equipped. Overrides
    /// the slot-level default (see `EquipmentSlotDef`). Useful when
    /// the same slot category needs different anchors - e.g., a
    /// rifle slung on `spine_03` vs. a pistol holstered on
    /// `thigh_r`. `None` means "use the slot default".
    #[serde(default)]
    pub attachment_bone: Option<String>,
}
```

**Why on `ItemDef` and not `EquipmentSlotDef`:** the slot is too coarse
when a single category covers visually distinct items. Both an AK and
a shotgun fit `primary`, but they may want subtly different sling
anchors. Putting the override on the item keeps the slot definition
clean and lets per-item authoring stay in `items.toml`.

**Slot-level defaults still useful.** `EquipmentSlotDef` should grow a
matching optional field so authors don't have to set `attachment_bone`
on every helmet:

```rust
pub struct EquipmentSlotDef {
    // ... existing fields ...

    /// Default attachment bone for items in this slot. Items without
    /// their own `attachment_bone` fall back to this.
    #[serde(default)]
    pub default_attachment_bone: Option<String>,
}
```

**The sim never resolves these strings.** They're opaque to
`simn-sim`; only `simn-godot`'s `CharacterRig` reads them. The
engine-agnostic invariant on the sim crate stands.

---

## 4. `equipment_changed` Signal

Today the inventory UI re-polls `equipment_view()` on hotkey. That's
fine for menus; it's wrong for a render layer that needs to react
within a frame of an equip / unequip / drop.

Add one signal on the gdext sim host:

```rust
#[signal]
fn equipment_changed(steam_id: i64, slot_id: GString);
```

Fire from every site that mutates `Equipment`:

- `Sim::equip` / `Sim::unequip` (the obvious cases)
- `Sim::drop_item` when the dropped item is the contents of an
  equipment slot
- NPC death (when a corpse becomes a `WorldContainer`, the NPC's
  rendered gear should disappear)
- NPC loadout application at spawn (so the rig populates without a
  manual nudge)

Existing UI keeps working unchanged - `equipment_view()` is still the
read path. The signal is push-only; `CharacterRig` is the only
intended subscriber for now.

---

## 5. `CharacterRig` (simn-godot)

A new gdext class living at `crates/simn-godot/src/character/`:

```rust
#[derive(GodotClass)]
#[class(base = Node3D, init)]
pub struct CharacterRig {
    base: Base<Node3D>,
    /// Owner of the equipment (player steam_id, or NPC entity id mapped to a steam_id placeholder).
    owner_id: i64,
    /// Skeleton this rig drives. Resolved from the character scene at `_ready`.
    skeleton: Option<Gd<Skeleton3D>>,
    /// One slot → one Node3D parent containing the instantiated mesh.
    /// `None` means slot is empty.
    rendered_slots: HashMap<SlotId, Gd<Node3D>>,
}
```

Lifecycle:

1. **`_ready`** - locate the `Skeleton3D` child, subscribe to the
   sim's `equipment_changed` signal, do a one-shot full sync from
   `equipment_view(owner_id)` so the rig matches sim state on spawn /
   scene load.
2. **On signal** - diff the changed slot only:
   - If the slot is now empty and we had a mesh, free the old node.
   - If the slot is now filled, look up `mesh_path` on the new item's
     `ItemDef`, load the scene (cached), instantiate, find the
     attachment bone (item override → slot default), parent the mesh
     to a `BoneAttachment3D` targeting that bone.
   - If the slot was already filled with a different item, free old +
     instantiate new.
3. **Material variants** (deferred to a later phase) - once the rig
   exists, faction colors and condition wear apply as `MaterialOverride`
   on the loaded scene's `MeshInstance3D` children.

Hook into the existing `humanoid_dummy.tscn` by adding a `CharacterRig`
child and forwarding the NPC entity id at spawn. The current
`humanoid_dummy.gd` keeps owning collision / damage; rendering is the
new responsibility of `CharacterRig`.

---

## 6. Asset Pipeline & Tooling

The shape of the data above only matters if there's a viable pipeline
to author the GLBs that fill `mesh_path`. Locked tooling choices for
this project:

| Role | Tool | Cost | License |
|---|---|---|---|
| Modeling / rigging hub | **Blender** | Free | GPL on app, exports are yours |
| Base body generator | **MakeHuman** (standalone) | Free | Outputs explicitly **CC0** |
| Auto-rig + animation library | **Mixamo** | Free | Free commercial use |
| Texturing | **Substance Painter - Indie / Steam** | ~$240 one-time on Steam | Indie license covers studios under $100k revenue |
| Engine import | **glTF 2.0 / GLB** | - | Native to Godot 4 |

Cloth simulation (Marvelous Designer) is deferred - not budgeted for
year one, revisit when authored jackets / coats become a quality
ceiling.

**Avoided:**
- Daz3D (per-asset Interactive License pricing is hostile to a publicly-developed, open-source-code project that ships its assets in a public repo).
- Character Creator 4 (good tool, but the addon ecosystem nickel-and-dimes past budget).
- Unity / Unreal marketplace assets (engine-locked licenses).

**Spend reservation.** Year-one tooling spend caps at ~$240 (Substance
Painter on Steam, watch for a sale). Everything else free. The
reserved budget goes to **hiring artists for the things that need a
human**: hero NPCs, faction signature gear, faces with character.

**Asset folder layout:**

```
godot/
└── models/
    ├── character/
    │   ├── body_male_average.glb
    │   ├── body_male_heavy.glb
    │   └── body_female_average.glb
    └── gear/
        ├── head/
        │   ├── helmet_steel.glb
        │   └── balaclava_black.glb
        ├── armor/
        │   └── vest_pmc_olive.glb
        ├── rig/
        ├── backpack/
        ├── weapons/
        └── ...
```

Paths in `items.toml` are `res://models/gear/<category>/<id>.glb`.

---

## 7. Skeleton Convention

**Standard: Mixamo humanoid skeleton.** ~65 bones, well-documented,
works with the entire Mixamo animation library out of the box, broadly
supported by Blender add-ons (Auto-Rig Pro, etc.).

**The discipline that makes the modular system work:** every gear
piece is rigged or weight-painted to that exact skeleton, with the
expected bone names (`mixamorig:Hips`, `mixamorig:Spine`,
`mixamorig:Head`, etc.). Anything authored in Blender then drops onto
any character without retargeting. A piece that ships with a different
skeleton breaks the system; the import gate enforces the convention.

Slot → default bone mapping (proposed; tune in `equipment_slots.toml`):

| Slot | `default_attachment_bone` |
|---|---|
| `head` | `mixamorig:Head` |
| `eyes` | `mixamorig:Head` |
| `armor_vest` | `mixamorig:Spine1` |
| `rig` | `mixamorig:Spine1` |
| `backpack` | `mixamorig:Spine` |
| `primary` (slung) | `mixamorig:Spine2` |
| `secondary` (slung) | `mixamorig:Spine` |
| `sidearm` (holstered) | `mixamorig:RightUpLeg` |
| `melee` | `mixamorig:LeftUpLeg` |
| `belt_*` | not rendered on character |
| `secure_pocket` | not rendered on character |

Held-weapon attachment (right hand) is a separate state from
slung-weapon attachment, covered under Open Questions (§9).

---

## 8. Layering & Fit

Z-fighting between overlapping items (jacket under vest, shirt under
jacket) is **solved at authoring time, not in code**. Each gear piece
is modeled with enough clearance over the base body that the next
layer up has room. This is how STALKER, Tarkov, and most modular
loadout systems handle it. The sim/render layer never tries to
reason about cloth interpenetration.

Practical authoring rules:

- Base body is the innermost layer. All gear sits at least 2–3 mm
  above skin.
- Vests and rigs are modeled assuming a jacket layer exists beneath.
  When no jacket is equipped, the vest will float slightly - that's
  acceptable; it reads as "wearing armor over a t-shirt".
- Backpacks attach high on the spine and are modeled to clear the
  vest silhouette without intersecting it.

If any combination ever fights badly enough to require runtime
correction, the cheap fix is a slot-based "hide base body region"
flag (e.g., heavy armor hides the chest portion of the body mesh).
Defer until needed; don't author it speculatively.

---

## 9. Open Questions

These are the known unresolved design questions; addressing them is
out of scope for the first rollout.

- **Held vs. slung weapon state.** A primary slot weapon should render
  slung on the back when not in hand and parented to the right hand
  when wielded. Likely needs a parallel `held_attachment_bone` field
  plus a "currently wielded" state on the rig. Defer until the weapon
  wield/holster animation set exists.
- **Faction colors and condition wear.** Material variants per faction
  (Bandits' mismatched / dirty look vs. Aegis Pacific's clean
  uniform) are downstream of the rig itself. Approach is likely a
  `MaterialVariant` lookup keyed on `(item_id, faction_id)` resolving
  to a Substance-baked alt-texture set. Worth its own plan doc when it
  comes up.
- **LOD strategy.** A populated faction camp could have 20+ NPCs in
  view. Each rendered with full gear meshes is expensive. Likely path:
  swap the modular composition for a single baked silhouette mesh past
  ~30 m. Defer until profiling demands it.
- **Offline-tier characters.** Characters in offline regions today
  don't exist as visual entities at all - they're abstract sim state.
  When tier transitions materialize them on player approach, the rig
  has to populate within a frame of materialization. Mostly a
  signal-routing question once the rig exists; flag for the
  [tier-transition-plan](tier-transition-plan.md) when that work picks
  up.
- **Base body variants.** How many base bodies cover the cast?
  Probably 3–5 (male average, male heavy, female average, female
  athletic, plus one "mutant frame" for warped Fault characters).
  Choosing per character is a content decision, not a render decision;
  store on the character entity, look up at rig spawn.
- **Player first-person view.** First-person hands and weapon are a
  separate problem from third-person rig composition. The decision -
  whether FP shares the third-person rig or runs its own simplified
  arm rig - is downstream of the wield/holster work. Out of scope here.

---

## 10. Rollout

Six narrow phases, each independently shippable. Visual results land
incrementally; nothing forces a giant integration phase.

### Phase 1 - `ItemDef` extension (no rendering yet)

- Add `mesh_path` and `attachment_bone` to `ItemDef`.
- Add `default_attachment_bone` to `EquipmentSlotDef`.
- Existing `items.toml` and `equipment_slots.toml` continue to load
  unchanged (all new fields default `None`).
- Tests: round-trip TOML load with the new fields populated.
- Docs: this plan's "ItemDef Extension" section becomes the contract.

### Phase 2 - `equipment_changed` signal

- Emit `equipment_changed(steam_id, slot_id)` from every `Equipment`
  mutation site in `simn-godot`.
- No subscribers yet; verify with a debug-overlay print.
- Docs: API reference at `docs/book/src/api/sim-host.md`.

### Phase 3 - `CharacterRig` minimum-viable

- New `CharacterRig` class in `crates/simn-godot/src/character/`.
- One base body mesh hardcoded into the dummy scene.
- Rig handles a single slot (`head`) end-to-end: load mesh from
  `mesh_path`, parent to bone, free on unequip.
- Author one helmet (`items.toml` row + GLB) and verify the round
  trip on a player and on a spawned NPC.

### Phase 4 - fill in remaining slots

- Extend `CharacterRig` to handle `armor_vest`, `rig`, `backpack`,
  `primary`, `secondary`, `sidearm`, `melee`, `eyes`.
- Author one item per slot to verify the pipeline. Faction-specific
  art comes later.
- NPCs auto-equip from their loadout via the existing
  `npc_loadouts` path; rig follows.

### Phase 5 - material variants

- Introduce a `MaterialVariant` system for faction colors and
  condition wear. Likely `(item_id, faction_id)` → texture override.
- Wire condition wear to `Wear` (when that lands - see weapons-plan
  step 3).
- Docs: own mechanics chapter at `docs/book/src/mechanics/character-appearance.md`.

### Phase 6 - LOD + offline-tier handoff

- Profile populated camps; introduce a baked silhouette swap past
  a tunable distance (see [physics-tiering-plan](physics-tiering-plan.md)
  for the precedent of distance-based degradation).
- Wire tier-transition materialization through the same rig spawn
  path NPCs use today (free once Phase 3 is in).
- Plan doc graduates to `docs/book/src/walkthroughs/character-rendering.md`.

---

## 11. What Stays Out of Scope

- **Animation system.** Mixamo provides the animation library; how
  Noosphere blends, transitions, and synchronizes animations with
  weapons / wounds / states is a separate plan.
- **Facial animation / lip sync.** Far downstream; entirely separate
  pipeline if it ever lands.
- **Player customization UI.** No character creator. Players pick from
  authored archetypes at character-picker time, archetype determines
  base body + starting kit. Per `characterPicker.tscn` scaffold.
- **Modding hooks.** Mod-defined items adding new `mesh_path`s should
  Just Work because the field is opaque-string and TOML-loaded - but
  the mod-asset pipeline itself is an [`ecosystem-plan`](ecosystem-plan.md)
  concern.
