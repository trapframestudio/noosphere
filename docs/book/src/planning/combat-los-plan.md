# Combat LOS — Planning Doc

**Status:** primitive landed 2026-05-06 (PR #145) — `LosCache` resource, `clear_los_cache` system, asymmetric per-direction entries, `Sim::los_exposure(observer, target)` accessor, and `SimHost::los_exposure(...)` gdext bridge are all live. `npc_aggro` writes the cache during its FOV pass; downstream consumers plug in without re-raycasting. The interim `npc_combat` LOS gate now reads `LosCache.get(shooter, target)` on the *fire-decision* side (skips the shot if there's no entry or exposure < 0.33), while damage itself flows through the projectile-collision path from [`physical-combat-plan.md`](physical-combat-plan.md) — the dice-combat damage path was retired in `sim-iteration-5-12` Phase 4A v2. The 2026-05-05 scope reduction stands: projectile collision is the damage gate, and LOS stays an AI primitive (perception, cover validation, peek-shoot decisions, and the fire-decision gate).
**Last updated:** 2026-05-18
**Scope:** the LOS query primitive — exposure-sampling pair-checks with per-tick caching. Used by `npc_aggro` (perception), [`cover-system-plan.md`](cover-system-plan.md) (cover-quality validation), and tactical AI's peek-shoot decisions. **Not** the combat damage gate anymore — physical projectile collision in [`physical-combat-plan.md`](physical-combat-plan.md) replaced that role per the 2026-05-05 hitscan-vs-physical reversal.

Companions: [`physical-combat-plan.md`](physical-combat-plan.md) (the new combat system; consumes this primitive for AI decisions but uses projectile collision for damage), [`cover-system-plan.md`](cover-system-plan.md) (the cover-quality consumer), [`npc-ai-plan.md`](npc-ai-plan.md) (Stage 1 foundations).

This is a living design doc.

---

## 1. Why this exists

`crates/simn-sim/src/systems/npc_aggro.rs` already runs an exposure sampler from each potential observer's eye height to a target's eye height; the gate `if exposure < required { skip }` controls whether aggro is acquired. Historically `crates/simn-sim/src/systems/npc_combat.rs` ignored LOS entirely — it rolled a hit chance off distance bands and applied dice damage. That produced the wall-piercing-bullets effect.

The interim fix consults the same LOS cache on the fire-decision side. Phase 4A v2 of `sim-iteration-5-12` then retired the dice damage path: `npc_combat` no longer applies damage at all, and the projectile tick (geometric swept-ray against `world/hitbox.rs`) is the only NPC-vs-NPC damage seam. The LOS gate stays on the fire-decision side as an AI primitive — perception, cover validation, peek-shoot decisions — and projectile collision owns hit / damage resolution. Without the cache, [`cover-system-plan.md`](cover-system-plan.md) is a pointless data structure.

## 2. What this system does / does not do

**Does:**

- Provide a `LosCache` resource keyed on `(NpcId, NpcId)` with the exposure value computed during the tick.
- A query helper `los_query(cache, a, b) -> Exposure` that returns the cached value or runs a fresh exposure sample if missing.
- A small set of integration points: `npc_aggro` writes to the cache during its FOV pass; `npc_combat` reads from the cache before damage application; `tick_npc_goals`'s aggro-pursuit branch reads to decide whether to push closer or hold.

**Does not:**

- Replace or duplicate the aggro perception system. Aggro acquisition still owns its own pass; LOS cache is a side product.
- Cover the geometry of *cover points*. Cover-point selection lives in [`cover-system-plan.md`](cover-system-plan.md). LOS is a query primitive, not a tactical decision.
- Cover destructible geometry mutation. When a wall blows up, [`destruction-plan.md`](destruction-plan.md) is responsible for invalidating cover bakes; the LOS sampler doesn't track destructibles itself, just queries the current physics scene.

## 3. Data model

```rust
// crates/simn-sim/src/resources.rs
#[derive(Resource, Default)]
pub struct LosCache {
    /// Keyed unordered: `(min_id, max_id)` so `(A, B)` and `(B, A)` collide.
    entries: HashMap<(NpcId, NpcId), LosEntry>,
}

pub struct LosEntry {
    pub exposure: f32,         // 0.0 = fully blocked, 1.0 = fully exposed
    pub computed_tick: u64,    // for staleness checks
}

impl LosCache {
    pub fn get(&self, a: NpcId, b: NpcId) -> Option<f32>;
    pub fn put(&mut self, a: NpcId, b: NpcId, exposure: f32, tick: u64);
    pub fn clear_stale(&mut self, current_tick: u64); // keeps only this-tick entries
}
```

A new system `clear_los_cache` runs at the top of the tick, before any aggro / combat work. The cache is per-tick — entries are valid only for the current tick to keep memory bounded and avoid stale geometry.

## 4. System behavior

- **Tick start:** `clear_los_cache` empties the cache (or marks old entries for eviction).
- **`npc_aggro` pass:** when a candidate pair passes FOV check and the exposure sampler runs, write the result to `LosCache` regardless of whether aggro fires. This way `npc_combat` later reuses the value.
- **`npc_combat`:** before rolling hit chance, query `LosCache.get(shooter, target)`. If `Some(exposure)` and `exposure < combat_threshold`, miss (or apply degraded hit chance, see open questions). If `None`, run fresh exposure sample, write to cache.
- **`tick_npc_goals` aggro branch:** query LOS to decide push-closer vs hold-fire. If exposure low, prefer flanking move (Stage 3 territory but the hook lands here).

## 5. Dependencies

- **Blocks:** [`cover-system-plan.md`](cover-system-plan.md), [`tactical-ai`](../walkthroughs/tactical-ai.md) implementation, any honest combat behavior.
- **Blocked by:** nothing — `npc_aggro`'s exposure sampler already exists. This plan is the smallest Stage 1 foundation piece.
- **Engine-agnostic constraint:** the exposure sampler does raycasts. In `simn-sim` (engine-agnostic) this means the sampler hits a `TerrainRaycast` trait that has a Godot impl in `simn-godot` and a stub/test impl in `simn-sim`'s own tests. That contract already exists for the aggro path; this plan reuses it.

## 6. Open questions

- ~~**Threshold:** binary or scaled exposure?~~ **Decided 2026-05-05: moot.** Combat damage no longer gates on LOS — physical projectile collision in [`physical-combat-plan.md`](physical-combat-plan.md) is the actual damage resolver. LOS is now an AI primitive only (perception, cover validation, peek-shoot decisions). Exposure value is exposed for callers; consumers decide what to do with it (typical use: binary `exposure > 0.4` for "can be perceived").
- **Sample count:** `npc_aggro` uses N=3 samples (head, torso, lower torso). Cover-system queries may want more for accuracy; budget concern. Tunable per call site.
- **Async cost:** raycasts cost-bound. Caching cuts this to O(M) per tick where M = aggroed pairs. At 12-region peak with full population, M is bounded. Explicit budget cap deferred until measured to be needed.
- **`npc_aggro` decay acceleration on LOS loss?** F.E.A.R. AI loses target memory faster when LOS breaks. Stage 3 concern; lives in tactical-ai-plan when that gets written, not here.

## 7. Out of scope

- Cover-point geometry / selection (see [`cover-system-plan.md`](cover-system-plan.md)).
- Suppression mechanics (Stage 3 in tactical-ai walkthrough).
- Bullet-penetration model — different from LOS. A round may pass through thin cover with damage falloff; that's [`weapons-plan.md`](weapons-plan.md) territory.
- Sound propagation. "Hearing a gunshot" is [`world-event-bus-plan.md`](world-event-bus-plan.md), not LOS.
