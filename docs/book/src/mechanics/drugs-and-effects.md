# Drugs & Effects

This chapter documents the player-facing drug + status-effect layer.
It pulls forward the medical-depth content from
`../planning/survival-and-crafting-plan.md` §4.4–4.6 - tolerance, overdose,
withdrawal, drug-specific side effects, and adrenaline revive - onto
the active-effects engine.

The design tilt is **"punishing but balanced for intermediate
players"**. In plain terms:

- **Single use is always safe.** Tolerance starts at zero. The
  overdose gate requires *both* high tolerance *and* an active dose of
  the same drug - that means the first dose of any drug never
  overdoses.
- **Real consequences land in minutes, not seconds.** Tolerance decays
  at 25 / in-world hour (≈ 5 real minutes from "moderate use" back to
  safe). Withdrawal kicks in only after sustained heavy use AND a
  4 in-world hour no-dose window.
- **Recovery is real.** Overdose is 2 in-world minutes of
  disorientation, not death. Adrenaline-revive saves you once per
  bleed-out incident, with a survivable 2 in-world minute crash
  afterwards.
- **Telegraph everything.** Tolerance counters are visible in the
  debug overlay (and the future triage panel). Active effects show
  remaining duration. The system never silently punishes.

## The drug roster

| Drug | Primary effect | Active duration | Crash | Tolerance gain |
|---|---|---|---|---|
| Painkiller | -25 pain | 5 in-world min | none | +15 |
| Morphine | -75 pain | 2 in-world min | none yet (Step 6 will add slow-reaction debuff) | +30 |
| Adrenaline | revive (vital_min < 10 → restore to 30%) | 30 in-world sec | 2 in-world min crash (regen disabled) | +50 |
| Stim cocktail | +regen (× intensity), +stamina cap | 5 in-world min | 2 in-world min fatigue rebound | +20 |
| Anti-rad | -30 radiation immediately, +5 toxicity | instant | none | +20 |
| Anti-tox | -30 toxicity immediately | instant | none | +20 |

All numbers are tunable via `MedConfig` constants in
`crates/simn-sim/src/resources.rs` and the `default_*` helpers in
`crates/simn-sim/src/systems/meds.rs`.

## How the engine works

Each drug application produces 1 or 2 entries in your `ActiveEffects`
list:

- The **active phase** (e.g. `Painkiller` for 5 in-world min).
- For drugs with a downside, a **scheduled crash phase** that activates
  when the active phase ends (e.g. `FatigueRebound` for Stim, or
  `AdrenalineCrash` for Adrenaline).

Effects are stateless - they contribute their modifier whenever
`current_tick − applied_tick < duration_ticks`. Past that, they retire
automatically. `apply_drug` also bumps the per-drug **tolerance**
counter, journaled separately.

## Tolerance and recovery

Each drug has its own tolerance counter, 0–100. Each use adds the
drug-specific gain (table above). Tolerance decays at **25 / in-world
hour** (≈ 5 real min from 25 → 0).

Practical implications:

- **Painkiller (×3 in a session):** tolerance 45 → safe; recovers in
  ~2 in-world hours.
- **Morphine (×3 in a session):** tolerance 90. Next dose overdoses
  while one is active. Wait ~3 in-world hours before another safe dose.
- **Adrenaline (×2):** tolerance 100. Saturated. Don't try a third -
  it overdoses every time.

## Overdose

Trigger: `tolerance > 75` AND another dose of the same drug is
currently active. Effect:

- The intended primary effect is **not** spawned.
- An `OverdoseDisorientation` effect spawns instead, lasting 2
  in-world min (= 600 ticks). While active: stamina regen halved.
- Tolerance still bumps from the failed dose.

The effect ends naturally; nothing the player does will speed up the
crash. Wait it out.

`Sim::apply_drug` returns `DrugOutcome::Overdose` so the UI can
surface a "you stacked too aggressively" hint instead of pretending
the drug worked.

## Withdrawal

Trigger: `tolerance > 50` AND no active dose of the same drug AND
`>= 4 in-world hours` since the last dose. Effect:

- A `Withdrawal` effect spawns. While active:
  - Stamina regen reduced by 5 (subtracted from the base rate).
  - Slow HP drain (~2 hp per in-world minute, tunable).
  - Future: aim shake (flagged but consumer doesn't exist yet).
- Lifts when tolerance falls below 25.

The "easy escape" is to take another dose - which suppresses
withdrawal but adds tolerance, deepening the hole. The "hard escape" is
to ride it out for a few in-world hours while tolerance decays.

## Adrenaline revive

Triggered specifically: when applying Adrenaline, if the player's
`vital_min` (== `min(head, torso)` HP) is less than 10, the drug
restores both head and torso to 30% of `DEFAULT_MAX` - pulls you out
of the bleed-out window and gives you ~30 in-world seconds to do
*something* before the crash.

The crash (`AdrenalineCrash`) lasts 2 in-world minutes during which
stamina regen is **disabled entirely**. You're vulnerable. Plan
your next move before the crash starts.

This is the single-player version of spec §4.6 coop revive.
Coop revive proper (where a teammate uses adrenaline + bandage on a
downed player) lands in Step 8.

## Anti-rad / Anti-tox

These are "instant" - no active phase, no crash. Apply, get the stat
change, move on. Anti-rad has the spec §4.4 trade-off baked in:
**reducing radiation by 30 raises toxicity by 5**. So heavy
anti-rad use without anti-tox eventually puts you in toxicity trouble.

Anti-tox is clean - no rad cost - but burns its own tolerance.

## Antibiotics

Antibiotics aren't a "drug" in the tolerance/withdrawal sense (no
addictive cycle). Instead, applying antibiotics spawns an
`AntibioticsActive` effect that lasts ~10 in-world minutes;
[`tick_infection`](damage-and-healing.md#infection) consumes it to
clear infection from any infected wound.

You can stack antibiotics with no overdose risk; they're a tool, not a
buff.

## Reading the debug overlay

The triage section (top-left, toggle with `` ` ``) shows everything
relevant in three blocks when applicable:

```
vitals: pain=72 rad=15 tox=8

wounds:
  torso  bleed sev=4 untreated  [2.0 hp/s]
  l_arm  bleed sev=2 bandaged

effects:
  painkiller   240s left
  fatigue_rebound  120s left

tolerance: morphine=60, painkiller=15
```

## Out of scope (deferred)

- **Drug-drug interactions.** Spec §4.4 says "lean minimum for v1" -
  no morphine+alcohol respiratory risk yet, no painkiller+stim heart
  strain.
- **Permanent addiction across sessions.** Tolerance decays over real
  time but doesn't persist past a save/reload that lets the decay run
  for many in-world hours. Heavy addiction-as-narrative is later.
- **Painkiller-specific dependency (separate from generic
  withdrawal).** The current model treats all addictive drugs the
  same. Per-drug withdrawal flavors (morphine slow reactions, alcohol
  shakes) land later.
- **Aim shake from pain / withdrawal / morphine.** The flag is
  exposed via `view.pain` and active-effect kinds; the aim system
  that consumes it doesn't exist yet.
- **Sleep / rest as fatigue-recovery.** Not in this PR - energy drinks
  cover fatigue restore for now.

## See also

- [Damage & Healing](damage-and-healing.md) - wounds, infection,
  pain derivation, healing pipeline.
- [Food & Water](food-and-water.md) - consumables and the rad/tox
  cost model.
- [Inventory & Items](inventory.md) - drugs are items; `consume_slot`
  is the normal entry point.
- `../planning/survival-and-crafting-plan.md` §4 - design source.
