# Author-Time Content Generation — Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-05-06
**Scope:** the offline (dev-time) tooling that uses a local LLM with grammar-constrained outputs and a capability-schema validator to produce shipped corpora — mission templates, faction-voice barks, persona lookup tables, few-shot example libraries — that the runtime consumes as plain data.

Companions: [`walkthroughs/ai-generation.md`](../walkthroughs/ai-generation.md) (the runtime LLM system this is upstream of), [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) (consumes the persona tables this pipeline produces), [`offline-tier-plan.md`](offline-tier-plan.md) (consumes corpora for dice-resolved encounters), [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md) (its dialog / cutscene tables are *separate* hand-authored content, not generated).

Living design doc — captures decisions, not a spec.

---

## 1. Guiding Principle

> **Author-time content is the seed; the runtime LLM is the variation layer on top.**

The hierarchy, from authoritative to mutable:

1. **Scripted canon** — hand-written quests, faction-defining moments, named-NPC dialog. Owned by the writer; never touched by any model.
2. **Author-time corpus** — generated offline, curated by hand, version-controlled, ships as data. The subject of this doc.
3. **Runtime LLM flavor** — host-side small model produces variation on top of the corpus, when enabled. See [`ai-generation.md`](../walkthroughs/ai-generation.md).
4. **Templated fallback** — pure substitution into authored templates. The "Off" tier.

The "Off" tier of `ai-generation.md` runs entirely on the corpus this pipeline produces. Players who play with no runtime model on their machine get a populated, voiced, faction-distinct world — just one with less per-session variation.

The model never authors canon. It fills slots inside structures the schema declares are valid. The curator (a human designer) accepts, edits, or rejects every generated item before it lands in the shipped corpus. Generation is a content-velocity multiplier for the curator, not an autonomous author.

---

## 2. What This System Does / Does Not Do

**Does:**

- Define a **capability schema** — the single source of truth for what content can reference (factions, mission verbs, item categories, POI kinds, NPC roles).
- Expose that schema through an **MCP server** with validator tools (`validate_mission_spec`, `validate_persona`, `get_faction_voice`, `list_*` queries). Any LLM that can speak MCP can author against it.
- Provide an **offline generator** sidecar that runs prompts through a local LLM with grammar-constrained JSON output, validates against the schema, retries on rejection, and accumulates batches.
- Provide a **curation gate** — staging directory, accept/edit/reject UI, accepted items moving into the shipped corpus.
- Define the **corpus format and on-disk layout** that `simn-sim` and the runtime LLM both load from.

**Does not:**

- Run a model at runtime. That's `ai-generation.md`.
- Generate scripted-canon content. Scripted quests, named-NPC arcs, faction-defining lore — hand-written, not generated.
- Define what an `NpcPersona` *is* at runtime. That's `npc-character-authoring-plan.md`; this doc owns the lookup tables that doc consumes.
- Define the dispatcher routing for dialog/cutscene encounters. That's `encounter-dispatcher-plan.md`. Its registries are separate hand-authored data; the corpus does not feed them.
- Ship a runtime model on the player's machine when the "Off" tier is selected.

---

## 3. The Capability Schema

The schema is the long-lived artifact. The model that consumes it is swappable; the schema outlives any specific tool choice.

Sourced from `simn-sim` enums:

- `Faction` (already exists, mirrored to GDScript by the `poi_enum_sync` test)
- `BaseKind` (exists, same drift test)
- `MissionVerb` (future — `escort`, `extract`, `assault`, `defend`, `recover`, `sabotage`, `parley`, `eliminate`)
- `ItemCategory` (future — derived from inventory work)
- `PoiKind` (existing POI taxonomy)
- `NpcRole` (future — `quartermaster`, `scout`, `medic`, `enforcer`, …)

Each enum carries a `&'static [Self]` `ALL` array so drift tests can compare Rust source-of-truth against any external mirror. The schema serializes to JSON and ships in the MCP server as a resource. Adding a variant is a Rust change; the test fails and points at the corpus drift; the corpus is regenerated or migrated.

Numbers (damage values, decay rates, density tuning) **never enter the schema**. Tuning is volatile; capability vocabulary is stable. The corpus that gets generated against this schema must survive arbitrary tuning changes without re-generation.

---

## 4. The MCP Server / Validator

A single MCP server under `tools/mcp-content/` (Rust, depends on `simn-sim` so it cannot drift). Tools:

- `validate_mission_spec(json) -> Result<(), Vec<Error>>` — structural + reference-integrity check against the schema. Hard-rejects unknown factions, verbs, items, POIs.
- `validate_persona(json) -> Result<(), Vec<Error>>` — same for persona records.
- `get_faction_voice(faction) -> VoiceCard` — register / tone / vocabulary / things-to-avoid for a faction. Authored by hand, lives in `content/voice-cards/`.
- `list_mission_verbs() -> Vec<MissionVerb>`, `list_pois(filter) -> Vec<Poi>`, `list_factions() -> Vec<Faction>` — schema queries.
- `get_few_shot_examples(category, faction, n) -> Vec<Example>` — pulls curated examples from the corpus.

The validator is **the same code path** that `ai-generation.md` Phase 2 describes for runtime use. Single implementation, two consumers (offline generator + runtime context broker). The library lives in `simn-sim::content_validator`; the MCP server is a thin transport on top.

Modders extend by adding additional voice cards / few-shot pools at user-supplied paths; they cannot extend the enums without forking Rust.

---

## 5. The Offline Generator

A sidecar tool, **not part of the shipped game**. Lives in `tools/content-gen/`. Pipeline per item:

```
context (faction, verb, POI, …) ─┐
voice card + few-shot examples ──┼─→ prompt → local LLM ─→ grammar-constrained JSON
schema constraints ──────────────┘                              │
                                                                ▼
                                                           validator
                                                                │
                                       fail (≤2 retries) ◄──────┤
                                                                ▼
                                                       staging directory
```

Key properties:

- **Grammar-constrained decoding** (llama.cpp GBNF, Outlines, or `xgrammar`). The model literally cannot emit invalid JSON; rejection comes only from reference-integrity / anti-slop / continuity checks.
- **Retry with errors fed back into the prompt**. Capped at 2; on third failure the item is logged to a rejection log so prompts / few-shots can be improved.
- **Batch runs**. A typical run takes a verb × faction matrix and generates N candidates per cell, blocking on neither the curator nor the runtime.
- **Model choice intentionally undetermined**. Use whatever local model is good when each batch runs; the schema is what enforces consistency. Today that means something in the Qwen / Gemma / Llama family at 3B-14B parameters.

The generator is reproducible only at the seed level; LLM output is non-deterministic, so the curation gate is what guarantees stable corpus content.

---

## 6. Curation Gate

The actual quality gate. Generated items land in `content/corpus/_staging/<batch_id>/`. A small CLI tool walks the staging directory and presents each item to the curator with three actions:

- **Accept** — moves to `content/corpus/<category>/`, becomes part of the shipped corpus.
- **Edit** — opens `$EDITOR` with the item; on save, validates again and accepts.
- **Reject** — moves to `content/corpus/_rejected/<batch_id>/`. Rejections are kept (not deleted) so prompt-tuning has a feedback signal.

The curator is the canonical authority for what ships. Without curation, generated content is noise.

This is where the work actually is. The pipeline is mechanical; the curator's eye is what makes the corpus feel like Noosphere.

---

## 7. What Gets Generated, What Stays Hand-Written

| Generated | Hand-written |
|---|---|
| Per-faction barks at scale (idle chatter, combat barks, victory/defeat lines) | Faction voice cards (the prompts that constrain barks) |
| Mission template variations (10 ways to describe an escort job) | Mission verb taxonomy + structural templates |
| Persona lookup tables (names, backstory hooks, quirks, three-trait combos) | Persona schema, trait/quirk vocabularies |
| Few-shot example seed pool (after curation, examples seed the next round) | Initial seed examples |
| Faction propaganda flavor (graffiti, broadcast snippets) | Belief-sim hooks that anchor the propaganda |
| World news headlines (template-shaped, sim-event-driven) | News template structure |
|  | All scripted-canon quest content |
|  | All named-NPC dialog (Volkov, etc.) |
|  | Anything mechanically significant (item descriptions that imply mechanics) |

The model never invents structure, only fills slots. The schema enforces that.

---

## 8. Corpus On-Disk Layout

Proposed:

```
content/
├── schema/                 # Generated from simn-sim enums; checked-in artifact
│   └── capability.json
├── voice-cards/            # Hand-authored; one per faction
│   ├── loners.toml
│   ├── duty.toml
│   └── …
├── corpus/                 # Curated, version-controlled
│   ├── barks/
│   │   ├── loners.toml
│   │   └── …
│   ├── missions/
│   │   ├── escort.toml
│   │   └── …
│   ├── personas/
│   │   ├── loners-quartermaster.toml
│   │   └── …
│   ├── _staging/           # gitignored; generator output before curation
│   └── _rejected/          # gitignored; rejected items, kept for prompt tuning
└── few-shots/              # Hand-authored seed examples per category
    └── …
```

Format: TOML for human-edited files (voice cards, hand-authored seeds, curated corpus); JSON for generator input/output (mechanical). Loaded at startup by `simn-sim::content_loader` into typed structs with the same validator that gates dev-time generation.

Not in `godot/assets/` because it's data, not Godot resources. `simn-sim` reads it directly; `simn-godot` exposes it through bridge classes if needed.

Modders add additional corpus paths via the existing mod manifest (see `modding-engineer` agent's domain). Mod corpora go through the same validator at load time.

---

## 9. Sequencing — When to Build This

**Hard prerequisite: the capability vocabulary must stabilize.** The schema is sourced from `simn-sim` enums, and content generated against an unstable schema is content that will be thrown away.

Stable enough today: `Faction`, `BaseKind`, `PoiKind`. Not yet stable: `MissionVerb`, `ItemCategory`, `NpcRole`. Mission/quest systems are currently parked behind base systems landing first.

Realistic trigger: after the first pass of mission systems lands and the verb taxonomy is concrete. Until then, this doc captures the shape so the validator and MCP server can be designed in parallel with whatever drives the verb taxonomy stable, without committing to building the generator side.

The schema and validator can be prototyped earlier with just the stable enums. That work isn't wasted — it's the same library `ai-generation.md` Phase 2 needs.

---

## 10. Phases

### Phase 0 — Schema + Validator + MCP Surface

**Trigger:** mission/quest verb taxonomy stabilizes.

- Define `MissionVerb`, `ItemCategory`, `NpcRole` enums in `simn-sim` with `ALL` arrays.
- Add `poi_enum_sync`-style drift tests for each.
- Build `simn-sim::content_validator`: reference-integrity, structural, anti-slop checks.
- Build `tools/mcp-content/`: MCP server exposing the validator and schema queries.
- Author voice cards for each existing faction.
- **Standalone deliverable:** a designer can write content by hand, run it through the validator, get pass/fail with reasons. No generator yet.

### Phase 1 — Offline Generator + Curation Gate

**Trigger:** Phase 0 stable; first batch of seed examples curated by hand.

- `tools/content-gen/`: prompt builder, llama.cpp wrapper with GBNF, retry-with-errors loop.
- Staging / accept / reject CLI.
- First production batches: barks per faction, mission templates per verb.
- Rejection log → prompt tuning loop.
- **Standalone deliverable:** the corpus starts populating with curated, model-assisted content.

### Phase 2 — Corpus Integration

**Trigger:** corpus has enough content per category to be worth loading.

- `simn-sim::content_loader` reads `content/corpus/` at startup.
- "Off" tier of `ai-generation.md` runs on the corpus (no runtime model).
- `npc-character-authoring-plan.md` Phase 4 swaps its placeholder tables for the corpus tables.
- Modders can add additional corpus paths.
- **Standalone deliverable:** the game ships with curated, faction-distinct content out of the box, with or without a runtime model.

### Phase 3 (optional) — Runtime LLM Lights Up

This is `ai-generation.md`'s Phase 4. The corpus serves as the few-shot pool the runtime context broker draws from. No new author-time work; the corpus and validator from Phase 0-2 are the dependency.

---

## 11. Open Questions

- **Model choice for the generator.** Intentionally undetermined; pick whatever's good locally when each batch runs.
- **Corpus format.** TOML for human-edited, JSON for mechanical seems clean; sqlite was considered for query-by-tag at runtime but discarded — the corpus is small enough that loading everything to memory is fine.
- **Curation tool surface.** Start CLI; consider a lightweight web UI if the curator needs side-by-side comparison or batch review. Don't gold-plate.
- **Modder schema extension.** Today modders can add corpus, not enums. Whether mods can declare new factions / verbs / item categories is a larger design question that touches `modding-engineer`'s domain; defer until there's a concrete mod use case.
- **Voice-card iteration loop.** When a voice card changes, do existing curated corpus items get re-validated? Probably yes; prepare for a `content-validate-all` CI check.

---

## 12. Risks

- **Schema drift.** Mitigated by `poi_enum_sync`-style tests. Each enum carries `ALL`; any mirror must match.
- **Corpus rot from gameplay tuning.** Mitigated by the rule that *numbers don't enter the corpus* — only capability references do. A damage rebalance never invalidates a bark.
- **"AI slop" in generated content.** Mitigated by (a) heavy templating: model fills slots, doesn't write structure; (b) the curation gate, which is the actual quality wall; (c) the same anti-slop list `ai-generation.md` uses, fed into the validator. The curator is the last line.
- **Authoring burden.** Real and load-bearing. Voice cards, seed examples, the curator's time — all writing work. If nobody owns the writing, the corpus produces mediocre content regardless of pipeline quality. Same risk `ai-generation.md` flags for itself.
- **Premature scope.** Building this before mission/quest systems land means designing in a vacuum. Phase 0's schema work is safe to do early; Phase 1 should not start until the verb taxonomy is concrete.
- **Curation throughput becomes the bottleneck.** If the generator produces 1000 items and the curator can review 50/day, the queue grows unboundedly. Mitigation: rate-limit batch generation to the curator's throughput; reject-rate metrics drive prompt improvements that lift acceptance rates.

---

## Cross-Reference Summary

- **Up-link:** [`ai-generation.md`](../walkthroughs/ai-generation.md) Phase 2 (Context Broker + Validator) and Phase 3 (Personas) — the runtime systems this is upstream of. The validator library is shared.
- **Up-link:** [`npc-character-authoring-plan.md`](npc-character-authoring-plan.md) §4 (Authoring pipeline) — this doc owns the tables that section consumes.
- **Boundary:** [`encounter-dispatcher-plan.md`](encounter-dispatcher-plan.md) — its dialog/cutscene registries are separate hand-authored content, not generated.
- **Boundary:** [`offline-tier-plan.md`](offline-tier-plan.md) — consumes corpora for dice-resolved encounter flavor; doesn't author them.
- **Pattern reference:** the `poi_enum_sync` test in `simn-sim` (Rust ↔ GDScript drift test) is the same pattern this doc adopts for schema drift.
