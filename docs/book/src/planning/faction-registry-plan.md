# Faction Registry — Planning Doc

**Status:** complete — all 7 migration steps landed
**Last updated:** 2026-05-06
**Scope:** replace the closed `Faction` enum + hardcoded relation matrix with a TOML-driven runtime registry. Add the missing canonical subfactions; drop Mexican Spec Ops; rename `NoosphereWorshippers` / `CorporateResearch` / `Looters` to canonical names. Add a 5-step ordered relation spectrum (`Hostile / Cold / Neutral / Warm / Friendly`) stored as continuous `i16` scores so playthrough events can drift relations without re-architecting. Per-player reputation gets a parallel system using the same spectrum, isolated per `SteamId`.

Companions: [`npc-ai-plan.md`](npc-ai-plan.md), [`goal-arbitration-plan.md`](goal-arbitration-plan.md), [`world-ledger-plan.md`](world-ledger-plan.md), the lore docs under `docs/book/src/lore/factions/`.

This is a living design doc.

---

## 1. Why this exists

`crates/simn-sim/src/faction.rs` today is a closed enum + a giant `match` block that names every relation between every pair. Three problems:

1. **Lore tweaks are code changes.** Every time the canon shifts (renaming `NoosphereWorshippers` to `Attuned`, dropping a faction, adding the Choir), we touch Rust + GDScript + tests + snapshot migrations.
2. **Modders can't extend.** A modpack that adds a new faction needs to compile the sim crate. That's a non-starter for the modding-engineer roadmap.
3. **Subfactions are flattened.** Linemen are modeled as a peer of PWA, which silently breaks "is this NPC PWA-friendly?" queries — a player allied with PWA shouldn't have to also separately ally with Linemen.

The user-as-modder framing is the durable shape: I (Jon) want to add factions and shift relations from a config file as I build out the sim, and the same path is the one a third-party modder takes.

## 2. What this system does / does not do

**Does:**

- Define a `FactionRegistry` resource loaded from `config/factions.toml` at sim startup.
- Replace the `Faction` enum with a `FactionId(u32)` interned at registry build, with stable string `name`s as the canonical identity (saves serialize the name string).
- Express relations as a 5-step ordered spectrum stored as `i16` scores. TOML uses named anchors; arithmetic / clamping / band-snapping happens internally.
- Support subfaction inheritance: a subfaction's relation to X falls back to its parent's relation to X unless an explicit override exists.
- Provide a runtime drift API (`Sim::shift_faction_relation`, `Sim::shift_player_rep`) so gameplay events nudge relations over a playthrough. Drift events are journaled.
- Provide a parallel per-player reputation system keyed `(SteamId, FactionId) → i16`, isolated per player.
- Support mod-driven extension: enabled mods declare a `factions = "factions.toml"` path; the loader merges their entries on top of the base registry.

**Does not:**

- Define new `Relation` kinds via TOML. The spectrum is closed (5 anchors, continuous score). Modders add new factions and new relation values, not new behaviors.
- Couple to specific gameplay systems (combat, dialogue, economy). Those query `relation()` and decide what to do; this doc owns the data + lookup.
- Persist the registry itself. The TOML file is the source of truth; the registry rebuilds on every sim startup. Saves carry only the runtime drift deltas + per-player rep, both keyed by faction `name`.
- Decay drift back toward base over time (out of scope for v1; see §7 future work).
- Handle mutant factions. Experiments / Merged-style mutant logic gets a separate but parallel system per user direction; this registry is for humans / human-organized factions only.

## 3. Data model

### 3.1 Registry

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FactionId(pub u32);

#[derive(Clone, Debug)]
pub struct FactionDef {
    pub id: FactionId,
    pub name: String,             // "pwa", "linemen" — canonical key
    pub display: String,          // "PWA", "Linemen"
    pub parent: Option<FactionId>, // None = top-level; Some(pwa) for Linemen
    pub road_friendly: bool,
    pub base_aggression: f32,     // [0, 1]
    pub default_loadout: String,  // loadout id
    pub color: [u8; 3],           // for marker rendering / minimap
}

#[derive(Clone, Debug)]
pub struct FactionRegistry {
    defs: Vec<FactionDef>,
    by_name: HashMap<String, FactionId>,
    pair_overrides: HashMap<(FactionId, FactionId), i16>,
    default_relation: i16,
}
```

`FactionId` values are assigned at registry build by sorting `defs` alphabetically by `name`. This makes ids stable across sim startups for a given config (a registry rebuild without TOML changes produces the same id assignments). It does NOT make ids stable across registry edits — that's why saves use the name string.

### 3.2 Relations

```rust
/// Ordered spectrum from "shoot on sight" to "come to your aid."
/// Internally stored as `i16` so playthrough events can drift the
/// score continuously; named values are anchors for TOML config.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Relation {
    Hostile,    // -100 anchor
    Cold,       //  -50 anchor
    Neutral,    //    0 anchor
    Warm,       //  +50 anchor
    Friendly,   // +100 anchor
}

const HOSTILE: i16 = -100;
const COLD: i16 = -50;
const NEUTRAL: i16 = 0;
const WARM: i16 = 50;
const FRIENDLY: i16 = 100;

pub const SCORE_MIN: i16 = -100;
pub const SCORE_MAX: i16 = 100;

/// Snap a continuous score to the nearest band.
pub fn band(score: i16) -> Relation {
    match score {
        s if s <= -75 => Relation::Hostile,
        s if s <= -25 => Relation::Cold,
        s if s <  25  => Relation::Neutral,
        s if s <  75  => Relation::Warm,
        _              => Relation::Friendly,
    }
}
```

Band thresholds (-75/-25/+25/+75) put each anchor at the center of its band so a small drift doesn't immediately re-classify. Tunable later if playtesting wants stickier hostility.

### 3.3 Lookup

```rust
fn faction_relation(reg: &FactionRegistry, deltas: &RelationDeltas, a: FactionId, b: FactionId) -> Relation {
    let score = faction_relation_score(reg, deltas, a, b);
    band(score)
}

fn faction_relation_score(reg: &FactionRegistry, deltas: &RelationDeltas, a: FactionId, b: FactionId) -> i16 {
    if a == b { return FRIENDLY; }
    let key = canonical_pair(a, b);

    // Base score: walk parent chains for inheritance.
    let base = lookup_pair_with_parent_walk(reg, a, b)
        .unwrap_or(reg.default_relation);

    // Runtime drift adds on top.
    let delta = deltas.get(&key).copied().unwrap_or(0);
    (base.saturating_add(delta)).clamp(SCORE_MIN, SCORE_MAX)
}

fn lookup_pair_with_parent_walk(reg: &FactionRegistry, a: FactionId, b: FactionId) -> Option<i16> {
    if let Some(s) = reg.pair_overrides.get(&canonical_pair(a, b)) { return Some(*s); }
    // Walk a's parent chain against b
    let mut cur = reg.defs[a.0 as usize].parent;
    while let Some(p) = cur {
        if let Some(s) = reg.pair_overrides.get(&canonical_pair(p, b)) { return Some(*s); }
        cur = reg.defs[p.0 as usize].parent;
    }
    // Walk b's parent chain against a
    let mut cur = reg.defs[b.0 as usize].parent;
    while let Some(p) = cur {
        if let Some(s) = reg.pair_overrides.get(&canonical_pair(a, p)) { return Some(*s); }
        cur = reg.defs[p.0 as usize].parent;
    }
    None
}
```

`canonical_pair(a, b)` returns `(min, max)` so the lookup table only stores one direction. Parent walk is cheap (chains are at most 2 deep in current lore: subfaction → parent → none).

### 3.4 Per-player reputation

```rust
#[derive(Default, Resource, Serialize, Deserialize)]
pub struct PlayerReputation {
    /// Keyed by player SteamId, then by faction NAME (string, for save resilience).
    by_player: HashMap<u64, HashMap<String, i16>>,
}

pub fn player_relation(
    reg: &FactionRegistry,
    rep: &PlayerReputation,
    deltas: &RelationDeltas,
    player: SteamId,
    f: FactionId,
) -> Relation {
    if let Some(score) = rep.score(player, &reg.defs[f.0 as usize].name) {
        return band(score);
    }
    // First contact: fall back to faction-vs-faction baseline. Players
    // implicitly belong to a configured "player_baseline" faction defined
    // in the registry; that lets a modder shift first-contact behavior
    // without code changes.
    let baseline = reg.player_baseline_id();
    faction_relation(reg, deltas, baseline, f)
}
```

Drift API: `shift_player_rep(rep, player, faction_name, delta, reason)` — journaled as `WorldDelta::PlayerRepShift { player, faction: String, delta: i16, reason: String }`.

### 3.5 Drift on faction-vs-faction matrix

```rust
#[derive(Default, Resource, Serialize, Deserialize)]
pub struct RelationDeltas {
    /// Keyed by (faction NAME, faction NAME) pair, sorted alphabetically.
    by_pair: HashMap<(String, String), i16>,
}
```

API: `shift_faction_relation(deltas, a_name, b_name, delta, reason)` — journaled as `WorldDelta::FactionRelationShift { a, b, delta, reason }`. Reason field surfaces in the chronicle so the player can review *why* their relations evolved.

## 4. Config grammar (`config/factions.toml`)

```toml
default_relation = "neutral"
player_baseline = "wanderers"  # First-contact rep falls back to this faction's relations

# ─── factions ───────────────────────────────────────────────────────

[[faction]]
name = "pwa"
display = "PWA"
road_friendly = true
base_aggression = 0.5
default_loadout = "pwa_basic"
color = [0xCC, 0xCC, 0x33]

[[faction]]
name = "linemen"
parent = "pwa"               # subfaction of PWA
display = "Linemen"
road_friendly = true
base_aggression = 0.7
default_loadout = "linemen_elite"
color = [0xFF, 0xCC, 0x00]

# (... 7 more top-level + 6 more subfactions per the roster ...)

# ─── relations ──────────────────────────────────────────────────────
# Only the exceptions need to be listed; everything else inherits from
# `default_relation` or from a parent faction's relations.

[[relation]]
a = "pwa"
b = "revere_guard"
value = "hostile"

[[relation]]
a = "pwa"
b = "linemen"
value = "friendly"

# Subfaction override: PWA is Neutral with Gulf Compact;
# Linemen are explicitly Hostile because Compact funds extraction.
[[relation]]
a = "linemen"
b = "gulf_compact"
value = "hostile"
```

Parser is a thin `serde` deserialization on a struct that mirrors the TOML; the registry builder consumes the parsed struct and assigns ids. Loader path: `simn-sim/src/faction/registry.rs::load_from_path(&Path) -> Result<FactionRegistry, RegistryError>`. Mod loader (`load_with_overlays(&[Path])`) applies overlays in order; later entries override earlier ones for the same `name` or `(a, b)` pair.

## 5. Roster (final, post-cleanup)

**9 top-level + 7 subfactions = 16 ids**

| Top-level | Subfaction | Role |
|---|---|---|
| `pwa` | `linemen` | Territorial coalition + grid-defense elite |
| `revere_guard` | — | Traditionalist faction |
| `federal` | `ghost_teams` | Federal remnant + special-ops arm |
| `gulf_compact` | `registry` | Trade faction + enforcement elite |
| `aegis_pacific` | `recovery_division` | Corporate research + dark-ops arm |
| `attuned` | `choir` | Belief cult + adept cells |
| `merged` | — | Endgame antagonists |
| `bandits` | `looters`, `cartel` | Heterogeneous scavengers (low-end + organized) |
| `wanderers` | — | Non-aligned drifters |

**Removed:**

- `mexican_spec_ops` faction + `docs/book/src/lore/factions/mexican_spec_ops.md` deleted, reference scrubbed from `docs/book/src/lore/factions/README.md`.
- `Experiments` stays in lore as setting flavor; no `Faction` entry. Mutant AI lands in a separate parallel system, modeled on this registry but with mutation-specific data (Imprinted variant, Echo type, etc.).

## 6. Migration steps

Five small commits, in order:

1. **Registry + TOML loader + new `Relation` spectrum.** New module `crates/simn-sim/src/faction/registry.rs`. Old `Faction` enum stays compiling. `Relation` enum gets the 5-step rename (`Detente` removed). Tests cover load, parent-walk inheritance, drift apply.

2. **Snapshot/save migration.** `InFaction(Faction)` → `InFaction(FactionId)`. `WorldDelta` variants and journal entries migrate. A migration tool `tools/migrate_factions` walks existing snapshots and rewrites the on-disk format. `Heightmap`-style format-version bump in the snapshot header rejects un-migrated saves.

3. **Roster expansion + lore scrub.** New `config/factions.toml` with the final roster, all relations from current lore. Delete `mexican_spec_ops.md`. Update `docs/book/src/lore/factions/README.md`. Drop the old `match` block in `faction.rs` after every callsite is on the registry. Update `crates/simn-sim/tests/factions.rs` to load from a test-fixture TOML.

4. **GDScript registry bridge.** `SimHost::faction_count()`, `faction_def(id) -> Dictionary`, `faction_relation(a_id, b_id) -> int` (returns score, GDScript snaps to band via a script-side helper), `faction_id_by_name(name) -> int`. Drop `godot/scripts/world/poi_marker.gd` enum mirror; markers query the registry. The `poi_enum_sync` Rust test deletes; replace with `crates/simn-godot/tests/registry_roundtrip.rs` that asserts `faction_count` and `faction_def` match the TOML.

5. **Drift APIs + journal.** `Sim::shift_faction_relation` and `Sim::shift_player_rep`. New `WorldDelta` variants. No callers wire it up in this commit — that's gameplay work that lands when missions / quests / belief-sim need it.

Each commit ends green (cargo test passes), so the branch can stop or PR after any step.

## 7. Open questions / future work

- **Drift decay.** Should runtime relation shifts decay toward the TOML base over time? Probably yes for minor events (helping a single Lineman crew), no for major ones (assassinating a Council member). v1 lands persistent drift only; a `decay_rate` field on `FactionDef` (or per-pair) lands when the gameplay tuning surfaces it.
- **Per-region relations.** PWA and the Compact are Neutral globally but might be Cold in a specific contested region. Out of scope for v1; potentially a per-region overlay stored on `Region` if it ever matters.
- **Cross-faction NPC squads.** A Linemen-led PWA squad with mixed Linemen + PWA-regular members. The registry supports it (squad cohesion uses parent for "are these allies" checks); spawn defaults probably keep squads homogenous by subfaction for now.
- **Relation events surfaced to the player.** The chronicle already tracks NPC deaths; `WorldDelta::PlayerRepShift { reason }` should surface in the same UI ("PWA reputation shifted -10: helped Looter raid"). Out of scope; lands when the chronicle UI does.
- **Mutant faction system.** Experiments + Merged variants are different beasts (different relation drivers — exposure, imprint type, broadcast resonance). They'll get their own registry-shaped module that *can* reference faction ids from this registry for inter-system relations (a Merged unit's relation to Federal is "shoot on sight" at the registry level).

## 8. Out of scope

- Combat damage relations. Aggro/threat is handled by `npc_aggro` + the upcoming threat board; relation only gates *initial* hostility.
- Dialogue / barter pricing. Those will read `relation()` but the pricing logic itself is the loot-and-economy plan's territory.
- Faction lore documents. The lore docs are the source of truth for *what* a faction is; the registry config is the source of truth for *how the sim treats* it. Single-source-of-truth-rule: the registry's `display` / `color` / `default_loadout` references resolve to the lore-defined identity, not duplicate it.
