# Project Plan

## Primary-priority initiatives

Two parallel workstreams, both primary priority, both design-locked and
parked pending base work and a technical evaluation.

### 1. Layered narrative system

Three tightly-ordered layers, each deferring to the one above:

1. **Scripted quests** - authored canon, authoritative over world
   state. See [`book/src/walkthroughs/scripted-quests.md`](book/src/walkthroughs/scripted-quests.md).
2. **Sim brain** - deterministic reactive layer, emits goals and
   stance shifts. See [`book/src/walkthroughs/sim-brain.md`](book/src/walkthroughs/sim-brain.md).
3. **AI-driven generation** - host-side Gemma 4 narrates around
   scripted beats and fills between them. See
   [`book/src/walkthroughs/ai-generation.md`](book/src/walkthroughs/ai-generation.md)
   for the full phased plan.

The AI-generation doc is the most detailed and drives most of the
architectural work (new `simn-ai` crate, Context Broker in `simn-sim`,
persona as first-class sim state, worldgen seed phase, capability
handshake in `simn-net`). The brain lands as Phase 2.5 in that plan.
Scripted quests are a separate workstream; the contract in that doc is
what the other layers are built against.

Fine-tuning (per-faction LoRA adapters) lands in Phase 5, after the
baseline is producing real usage data.

### 2. Tactical AI (F.E.A.R.-class and beyond)

GOAP, squad coordination, hand-annotated 5 km² maps, persona-driven
tactical personality, cross-map tactical memory, co-op-first design.
See [`book/src/walkthroughs/tactical-ai.md`](book/src/walkthroughs/tactical-ai.md)
for the full phased plan (T1–T5).

Target is **better than F.E.A.R., better than S.T.A.L.K.E.R.** - not by
replacing their substrate (GOAP, squads, annotated maps, chatter) but
by tightly composing it with the rest of Noosphere's sim architecture
(persona, memory, brain, narration). The pieces are all well-understood;
the composition is what differentiates.

### How the two workstreams relate

The narrative system and tactical AI share infrastructure but can run
as parallel workstreams. Key shared points:

- **Event bus** (Phase 2 of AI-generation) - both systems subscribe.
- **Persona system** (Phase 3 of AI-generation) - tactical layer reads
  persona for behavior weighting.
- **Memory system** (Phase 4 of AI-generation) - tactical memory lives
  in the same store, tagged for tactical retrieval.
- **LLM chatter** (Phase 4 of AI-generation + Phase T4 of tactical) -
  tactical chatter is narrated by the LLM layer when available, falls
  back to authored barks when not.

T1 (tactical annotation system) has no dependency on the narrative
system and is a strong candidate for the first implementation
workstream after the base work is further along.

---

> **Status:** this doc is being rewritten. The previous version was a
> Bevy-era plan from before the migration to Godot 4.x + gdext, and most
> of the phases, crate names, and dependencies in it no longer reflect
> reality. Rather than leave a stale plan in place, this is a pointer
> to the docs that *are* current.

## Where to look right now

- **the design overview** - the vision. Co-op philosophy,
  multiplayer systems, economy, missions, base building, mod
  compatibility, and the principles every system gets evaluated
  against. This is the most current and most complete planning doc in
  the project.
- **`book/src/development/progress.md`** (currently missing - see
  audit notes below) was meant to track what's actually working,
  what's in progress, what's broken, updated as work lands. Until
  that file exists, treat the `### What's working right now` section
  in the README plus this doc as the closest thing to a roadmap.
- **[`book/src/architecture/overview.md`](book/src/architecture/overview.md)**
  - the current Godot 4.x + gdext architecture, the five-crate layout,
  and the engine-agnostic rule.
- **[`book/src/architecture/crate-guide.md`](book/src/architecture/crate-guide.md)**
  - what each crate does and where it sits in the dependency graph.
- **[`README.md`](../README.md)** - the public-facing summary of what's
  working right now.

## What needs to land in the rewrite

When this doc gets properly rewritten, the new version should:

- Replace the old Bevy phases with phases grounded in the current
  Godot+gdext reality (asset import pipeline first, then runtime, then
  multiplayer, then gameplay systems)
- Drop the speculative week-by-week timeline (the old version had
  ~38 weeks of false precision)
- Pull the "what's working" section from `progress.md` so it stays in
  sync via the Documentation Manifest
- Reference the design overview for the vision rather than restate it
- Be written in the same casual register as the rest of the prose docs

This is on the list. Until then, treat `progress.md` + the design overview as
the authoritative sources for "where are we, where are we going."

## Documentation audit notes (2026-05-01)

Discrepancies surfaced during the docs reorganization that moved root-
level Markdown into `docs/`. Recorded here so they don't get lost; not
all are urgent.

- **`book/src/development/progress.md` does not exist.** Referenced from
  this file (above) and from prose. Either land the file with the
  "what's working right now" content, or strike the references and
  consolidate into the README section.
- **`book/src/development/ai-tools.md` does not exist.** Was referenced
  from `DEVELOPMENT.md`. The MCP server section in `DEVELOPMENT.md` has
  been removed because `tools/mcp-server/`, `bun install`, and
  `.mcp.json` referenced there are also absent (`tools/` only contains
  `bake-all-maps.sh` and `bakes/`). If MCP support comes back, restore
  the section and create the doc.
- **Crate count drift.** Several docs (root-level CONTRIBUTING, the
  README, this file, `book/src/development/contributing.md`, and
  `CLAUDE.md`) previously listed only 3 of the workspace's 5 crates
  (omitting `simn-terrain` and `simn-net`). Inline fixes have been
  applied; flag any future doc that copies the old 3-crate list.
- **`overview.md` snippet drift (minor).** The `ExtensionLibrary` impl
  example in `book/src/architecture/overview.md` is no longer the
  literal code in `crates/simn-godot/src/lib.rs` (which now installs
  tracing via an `on_stage_init` override). The doc's point is still
  correct; the snippet is illustrative.
- **`configuration.md`** does not yet mention the Terrain3D editor
  plugin enabled in `godot/project.godot` or the `GameSession`
  autoload. Worth adding next time someone touches that doc.
- **`.claude/agents/*.md` references to the design overview** are plain-text and
  still resolve readably. The agent-definition files are managed by the
  harness (writes blocked from in-session edits) and were not updated;
  the path is now `docs/the design overview and a future maintenance pass should
  refresh those mentions.
