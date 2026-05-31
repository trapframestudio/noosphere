# AI-driven generation

Noosphere uses a locally-hosted small language model, running host-side, to
generate the texture of the world: NPC personas, quest briefings, faction
propaganda, world news, and dialog variation. The model is load-bearing
for texture, never for function - every system that uses the model has a
template-only fallback so the game runs identically (just less richly) with
AI disabled.

This is the canonical design doc for that subsystem. The principles here
drive every downstream decision; if a proposed feature violates one of
them, the feature is wrong, not the principle.

## The principle

> **Scripted narrative is canon. The sim brain is reactive. Generative
> content is filler. These three layers are strictly ordered, and each
> lower layer must defer to the one above it.**

Noosphere has authored, curated story quests - hand-written by a human,
with bespoke branching, authoritative effects on world state, and
narrative intent that no generative system can or should try to match.
That scripted content is the spine of the game. It drives major world
state changes, sets up the narrative beats players will remember, and is
the thing reviewers and players talk about.

The sim brain (see [Sim brain](sim-brain.md)) watches the event stream
and emits deterministic reactions - faction goals, stance shifts, rumor
seeds. It gives the world between scripted beats a sense of pattern and
consequence.

The LLM is the *narration* layer on top of both. It paraphrases sim
state, writes quest flavor for procedurally-generated filler quests,
voices NPC dialog variations, and produces world news prose. It never
authors canon. It never overrides scripted state. It never contradicts
what the brain has declared.

This ordering is the single most important thing to get right. When
systems conflict:

1. **Scripted narrative wins.** Canon state is authoritative. The brain
   cannot emit a goal that contradicts an active scripted quest. The
   LLM cannot generate a rumor that contradicts canon.
2. **Brain rules win over generative content.** A brain-declared faction
   goal or stance shift constrains what the LLM can say. Flavor
   narrates the decision; it doesn't override it.
3. **Generative content is texture, never structure.** It fills the
   space between scripted beats and around brain-declared events.
   Pulling the generative layer out should leave a playable, coherent
   game - just a less textured one.

The test for every design decision: **does this respect the hierarchy?**
If the generative layer could override scripted state, or the brain
could contradict canon, the design is wrong.

### What this means concretely

- **Scripted quests own world state.** They publish authoritative state
  changes (faction control shifts, NPC deaths, location unlocks). Brain
  and generative layers read that state but cannot overwrite it.
- **Scripted quests can suppress generative output.** A scripted arc
  involving Volkov can flag his NPC as "scripted-active," which gates
  out LLM-generated dialog and brain-driven stance shifts for the
  duration. The author stays in control of canon characters during
  canon moments.
- **Scripted quests can seed and consume brain state.** An author can
  write a scripted beat that *requires* the Loners to be losing in the
  north, and trust that the brain's emergent state will produce that
  setup between scripted arcs. Scripted content benefits from the
  living world the generative layer produces.
- **The LLM never authors canon.** It cannot invent entities. It cannot
  kill NPCs. It cannot change faction control. It narrates what
  already is.

### The sim as source of truth, restated

The sim holds the authoritative state. Scripted quests write to it.
Brain rules write to it (in narrow, declared ways). The LLM never writes
to it - it only reads, and emits text that the sim can choose to surface
or ignore. The sim is the court of last resort for every question of
"what is true in this world right now."

## Why local, why Gemma 4

- **Local only.** No cloud dependency. Noosphere is open-source co-op; the
  game has to work on a player's machine, a rented server, or a LAN box
  with no internet.
- **Small model.** Runs on typical gaming hardware. A Gemma 4 E2B Q4 GGUF
  is ~1.5 GB and hits 20–50 tok/s on CPU-only inference. E4B Q4 is
  ~2.8 GB, comfortable on any discrete GPU. 26B MoE and 31B dense are
  options for dedicated-server hosts with beefy rigs.
- **Host-only.** The model runs on the session host. Clients never load a
  model, never allocate VRAM for inference, never call llama.cpp. They
  receive generated content as replicated entities over `simn-net`. This
  is the single most important architectural decision: it takes GPU
  contention with the renderer off every client machine and concentrates
  the compute cost on one box.
- **MatFormer architecture.** E4B contains E2B as a sub-network; one
  weights file, two capability tiers, picked at load time based on host
  hardware.

## Deployment tiers

All four configurations produce a playable, populated world. The gradient
is purely texture richness.

| Config | Persona source | Runtime flavor | Typical host |
|---|---|---|---|
| Full | 26B / 31B model | 26B / 31B model | Rented/owned server, 24GB+ VRAM |
| Medium | E4B model | E4B model | Typical gaming PC, 8–16GB VRAM |
| Light | E2B model | E2B model | Integrated GPU, weak host, Steam Deck |
| Off | Lookup tables | Templates only | Any |

Model choice is a user setting, not a hardware gate. Hardware detection
recommends a tier; the user picks. The model file is a path, not an enum -
modders and advanced users can drop in any GGUF.

## Architecture

### New crate: `simn-ai`

Engine-agnostic. Thin wrapper around `llama-cpp-2` with a worker thread,
request queue, grammar-constrained decoding (GBNF), and capability
reporting. Feature-gated so clients compile without it.

### Context Broker (in `simn-sim`)

The load-bearing module. Given a generation request, queries the sim for
the relevant slice of state and produces a prompt:

- **Voice card** (authored, class-level): who's speaking - faction, role,
  register, vocabulary, things to avoid.
- **Persona card** (generated once at worldgen, persisted): this specific
  NPC - name, background hook, three traits, quirks, preferred vocab.
- **Memory** (evolves with play): what this NPC remembers about the
  player, compressed into 2–3 salient facts.
- **World beat**: what's happened recently in the sim - nearby faction
  skirmishes, territorial shifts, notable deaths.
- **Constraint**: valid goal types, valid entity references, valid
  locations - all drawn from current sim state.
- **Format**: target JSON schema, enforced by GBNF grammar at sampling.
- **Few-shot**: two hand-authored examples in this voice.

Typical budget: ~800 tokens in, ~150 tokens out. Comfortably inside E4B's
CPU-inference budget.

Everything the model sees is a reference to something real in the sim.
The model picks from fixed lists; it cannot invent a fourth option. This
is the single biggest anti-slop lever.

### Validator (in `simn-sim`)

Every LLM output passes through a validator before reaching the player:

- Structural: JSON parses, schema matches.
- Reference integrity: target and location exist in sim.
- Anti-slop: no phrases from the curated slop list, no excessive hedging,
  length bounds enforced.
- Continuity: doesn't contradict persona or memory.

On rejection: retry once with a tightened prompt. If that fails, fall
back to a template. Never surface bad output.

### Persona system (in `simn-sim`)

Personas are first-class sim state, stored in the snapshot, not
regenerated session-to-session.

**Worldgen seed phase (first launch only).** After static worldgen and
entity spawn, the AI worker generates personas for all notable NPCs and
an initial pool of uncommitted personas per faction. Themed loading UI
("The Valley takes shape...") with progress. Budget: ~5–7 minutes on a
typical host for a campaign-sized world. After completion: initial
snapshot written, personas are now durable sim state.

**Runtime refill (continuous, background).** The persona pool refills
during play, at low priority, using leftover generation budget. Per-faction
watermarks trigger refill when a pool drops. Dynamic spawns (bandit raids,
refugees, reinforcements) draw from the pool; the next spawn never blocks
on generation.

**Fallback chain.** Main model → tiny model (E2B) → lookup tables. Every
tier produces structurally identical personas; downstream code cannot
tell the difference. A purely-tabular persona has the same fields as an
LLM-generated one; it just has less unique prose.

### Memory layer (in `simn-sim`)

Two-tier per-NPC memory:

- **Recent**: ring buffer of the last 5–10 interactions, full detail.
- **Salient**: compressed memory facts, distilled from `recent` when
  entries age out. Compression uses the LLM ("summarize these three
  interactions as 1-2 sentences in the NPC's voice").

At prompt time: top-3 most relevant facts by tag match, weight, and
recency. ~100 tokens injected into the voice card.

Shared memory pools exist at faction and location level so everyone in a
faction knows what the player did for that faction - not just the one NPC
who handed out the quest.

### Bridge (in `simn-godot`)

`AiBridge` gdext class exposes the subsystem to GDScript via `#[func]`
submit methods and `#[signal]` response-ready callbacks. Generation is
always async; GDScript never blocks on the model.

### Replication (in `simn-net`)

Session-join handshake includes an `AiCapabilities` descriptor so clients
know what kind of content to expect. Generated content (quests, news,
dialog) replicates from host to clients as entity state, using the same
mechanism as any other sim entity. Single source of truth prevents
per-peer divergence.

## Cadence and tiering

Over-frequency is a failure mode. Generated content is selective,
budgeted, and tiered by significance.

### Rate limiting

`generation_budget_per_minute` setting caps total LLM calls. When
exhausted, the sim falls back to templates. Players never notice; the sim
always produces content.

### Quest tiers

Scripted-canon quests are a separate channel entirely - they do not go
through the generative pipeline. The table below is for generated filler
quests only.

| Tier | Strategy |
|---|---|
| Scripted (canon story arcs) | Hand-authored, authoritative, bypasses this pipeline entirely |
| Trivial (fetch 5 herbs) | Template only |
| Standard (bandit camp nearby) | Template + one-line LLM bark |
| Notable (faction-significant) | Full LLM briefing + dialog |
| Emergent milestone (brain-declared stakes) | Full LLM, brain-seeded, validator pass twice |

Generated quests exist to fill time between scripted beats and to give
factions/regions a sense of ongoing activity. A scripted arc can pause
generative quests in a region, or seed them with specific flavor (e.g.,
"generate Loner quests in Kordon that reference the missing patrol" -
the brain plus Context Broker handle this via tags).

### NPC talkativeness budget

Per-NPC cooldown. An NPC can produce LLM-generated dialog every N minutes
of playtime; in between, they use authored barks from a small pool.
Prevents "every NPC is a chatterbox."

## Fine-tuning (later, not day one)

A single GPU is sufficient for LoRA/QLoRA fine-tuning across the whole
Gemma 4 family. But tuning happens **after** the base system is working
and real usage data exists; training blind is a waste.

### What to tune

- **Voice.** Teach the model the game's register, per faction. Purge the
  assistant-chatbot voice.
- **Format.** Teach reliable JSON emission in the schemas the validator
  expects. Reduces rejection rate and shrinks prompts.

### What NOT to tune

- **World knowledge.** The sim is the source of truth for facts. A model
  trained to "know" Noosphere lore will confidently contradict the sim.
  Stable lore belongs in the system prompt, not the weights.

### Toolchain

Unsloth is the right default - purpose-built for single-GPU Gemma tuning,
outputs plug straight into llama.cpp. Dataset curation is the actual work;
training is a weekend's worth of scripting once the data is ready.

### Mod story

Adapters are 30–100 MB. Community total conversions ship as adapter +
content pack + voice cards - no need to redistribute base weights.

## The phased implementation plan

This is the primary-priority initiative going forward. Phased so each
phase produces something usable on its own.

### Phase 1 - Foundation (~2 weeks)

**Goal: the AI subsystem loads, runs, and produces output. No gameplay
integration yet.**

- New crate `simn-ai` (engine-agnostic, feature-gated)
  - `llama-cpp-2` wrapper, worker thread, request queue
  - GBNF grammar loader
  - `AiCapabilities` descriptor
  - Model warmup validation (loads a canned prompt, confirms parseable
    output; refuses to enable AI features if the model is broken)
- Settings plumbing in `project.godot`: model path, inference device,
  context size, budget
- Hardware probe: RAM, GPU/VRAM, CPU cores → recommended default tier
- `simn-godot` `AiBridge` stub with submit/response signals
- `simn-net` capability handshake on session join

### Phase 2 - Context Broker + Validator (~3 weeks)

**Goal: the sim can request text generation against current state and get
back validated output. Still no gameplay wiring.**

- `simn-sim::context_broker`
  - `QuestContext` builder, `PersonaContext` builder, `NewsContext`
    builder
  - Entity catalog: what entities are "real" and referenceable
  - Voice card registry + few-shot example library structure
- `simn-sim::validator`
  - Structural, reference-integrity, anti-slop, length, continuity checks
  - Retry-once-then-fallback logic
  - `SLOP_PHRASES` list (living, expanded from playtest)
- Template fallback system - must work standalone with AI disabled
- Eval harness (`simn-ai-eval` or test-only module): run N generations
  against fixed contexts, score against rubrics

### Phase 2.5 - Sim brain (~3 weeks)

**Goal: deterministic pattern-matching on the event stream emits goals,
stance shifts, and rumor seeds into the sim. No LLM dependency.**

See [Sim brain](sim-brain.md) for the full design. Key integration
points:

- `simn-sim::brain` module, engine-agnostic, no LLM dep
- Event bus subscription shared with the Context Broker
- Starter rule library (~30 rules) authored alongside the module
- Reaction emission: faction goals, world state tags, NPC stance shifts,
  rumor seeds, events back onto the bus
- **Scripted-quest respect**: brain rules check `scripted_active` flags
  on entities and regions before firing; never emits reactions that
  conflict with canon
- Debug overlay: active goals, recent rule firings, cooldowns

### Phase 3 - Personas (~4 weeks)

**Goal: a fresh campaign seeds personas; persona pool refills during play;
NPCs feel specific.**

- `simn-sim::persona`
  - `NpcPersona` struct, snapshot/journal integration
  - `Trait` and `Quirk` enums (authored vocabularies, ~30 and ~50 slots)
  - Cultural name pools per faction (~200 each)
  - Pool manager with per-faction watermarks, priority queue
- Worldgen seed phase
  - Runs after entity spawn, before first snapshot
  - Progress reporting hook
  - Batched generation (many concurrent requests to the worker)
- Runtime refill subsystem
  - Low-priority background generation during idle budget
  - Fallback chain: main model → tiny model → lookup table
- Content work (authoring, not coding)
  - Faction lookup tables: names, background hooks, quirks, vocab
  - These tables double as few-shot example pools for the LLM

### Phase 4 - Memory + runtime flavor (~3 weeks)

**Goal: NPCs remember; quests and world news are generated and feel
grounded.**

- `simn-sim::memory`
  - Per-NPC `recent` + `salient` tiers
  - Faction- and location-level shared memory
  - Tag-based retrieval at prompt time
  - Compression pipeline (LLM-based, constrained to "summarize, do not
    add")
- Quest generation integration
  - Tiered strategy: template, bark, briefing, milestone
  - Budget-aware, cooldown-gated
- World news generation
  - Hook into offline-tier events; selective generation for significant
    beats
  - Replicated to all clients via `simn-net`

### Phase 5 - Fine-tuning (post-MVP, quality phase)

**Goal: tuned adapters per faction, meaningfully better output at same or
lower compute cost.**

- Data collection: harvest working few-shot prompts, curate ~2–4k
  examples
- Unsloth training pipeline (separate repo, reproducible configs)
- Adapter composition at runtime (voice + format adapters loaded together)
- A/B toggle: base vs. tuned, for dev comparison
- "Train your own adapter" mod guide

## Cross-cutting concerns

### Persistence

Personas and persona pools live in the snapshot (permanent, rarely
mutated). Memory lives in the journal (frequently mutated, compressed
into snapshots over time). Schema versioning: persona format version in
the snapshot header so future changes can migrate old saves.

### Determinism

Single source of truth is the host. LLM output is non-deterministic, but
it's generated once on the host and replicated as data. Clients render
what they're told; they don't re-generate.

### Testing

Traditional unit tests don't work on LLM output. The eval harness
(scoring generations against rubrics) is the substitute. CI can run the
harness against a small fixed model for regression detection on the
Context Broker and Validator - the *structure* of generation is testable
even when the text isn't.

### Performance

CPU-only inference is the default. GPU inference is opt-in and gated
behind VRAM detection. Generation is always async, never on the frame
thread. The renderer is never starved by the model.

### Modding

Model path is a setting, not hardcoded. Voice cards, lookup tables, and
few-shot examples live in editable content files (TOML/JSON). Fine-tuned
adapters ship as GGUF files, drop-in. The whole subsystem is designed so
a community fork with a different setting swaps in different adapters +
content, not different code.

## Risks (honest)

- **Dataset curation is the whole game.** For both few-shot prompting and
  fine-tuning, output quality is bounded by example quality. A bad
  example teaches bad output.
- **The slop list is maintenance work.** It grows with every playtest.
  Acceptable but real.
- **Compression hallucination.** Memory-compression prompts can invent
  detail. Mitigation: constrained prompt, lower-weighted compressed
  facts, verbatim recent memory always outranks compressed.
- **Authoring burden.** Voice cards, faction name pools, quirk/trait
  vocabularies, few-shot examples - all writing work. Not code work. If
  nobody owns the writing, the system produces mediocre output regardless
  of engineering quality.
- **Host-machine GPU contention in solo play.** When the player is the
  host, they pay the inference cost. The E2B / CPU-inference tier exists
  specifically for this case; solo play defaults to the lightest tier
  unless the user opts in.
- **Model licensing.** Gemma's license permits commercial use with
  use-restriction conditions; fine-tuned derivatives are permitted. Read
  the terms before shipping; nothing unusual for the intended use.

## Documentation that needs to land alongside this

When phases complete, the Documentation Manifest requires:

- Phase 1 → `../architecture/crate-guide.md` (new `simn-ai`
  crate) and `../architecture/overview.md` (new crate in the dependency graph)
- Phase 1 → `../getting-started/configuration.md` (new
  settings)
- Phase 2+ → updates to this walkthrough as systems solidify
- Phase 5 → separate `fine-tuning.md` writeup with the
  adapter training pipeline, for modders

## Summary

This subsystem is the single biggest gameplay differentiator in
Noosphere. The entire design is organized around one principle: **the
LLM narrates a world the sim authors.** Worldgen seeds personas once;
runtime is always flavor on top of authoritative sim state; the model is
optional infrastructure for texture, never required infrastructure for
function. Every phase produces something that ships even if later phases
never land. Every hardware tier produces a playable world.

This is a primary-priority initiative.
