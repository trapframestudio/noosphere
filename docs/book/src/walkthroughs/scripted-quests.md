# Scripted quests

Scripted quests are Noosphere's authored, curated story content. They are
written by hand, have bespoke branching, and are authoritative over world
state in ways no generative system is. They are the spine of the game.

This walkthrough is a scaffold. The scripted-quest system will be fully
designed alongside the first real scripted arc. The goal of this document
is to nail down the **contract** scripted quests have with the generative
and reactive layers, so the rest of the architecture can be built against
a stable interface.

See also:

- [AI-driven generation](ai-generation.md) - the narration layer that
  fills space around scripted content.
- [Sim brain](sim-brain.md) - the reactive layer that defers to scripted
  state.

## The hierarchy (restated)

Scripted quests are canon. They override the brain; the brain defers to
them. The LLM narrates around them; it does not write them, does not
change their state, does not invent branches.

## What scripted quests can do

- **Publish authoritative world state changes.** Faction control shifts,
  NPC deaths, location unlocks, story-flag progression. These write to
  the same sim state that emergent systems read.
- **Claim entities and regions.** A scripted arc involving Volkov marks
  him `scripted_active` for the duration, gating out LLM dialog
  generation and brain-driven stance shifts. The author controls canon
  characters during canon moments.
- **Seed brain state.** An arc can nudge the brain toward a desired
  emergent setup ahead of time - "ensure Loners are losing in the north
  before this arc triggers."
- **Consume brain state as triggers.** An arc can unlock when the brain
  has emitted a specific world state tag for long enough, using the
  emergent world as a pacing mechanism within an authored structure.
- **Suppress generative filler in a region.** While a scripted arc is
  active in Kordon, generative filler quests there are paused or
  themed (via tag injection into the Context Broker) to reference the
  arc.

## What scripted quests cannot do

- **Cannot be silently overridden.** Once a scripted quest has claimed
  state, no lower layer can mutate it. Brain and LLM layers read; only
  scripted code writes to scripted-owned state.
- **Cannot depend on LLM output for canon.** If the LLM is disabled, the
  scripted quest must still play through cleanly. LLM flavor on
  dialog/prose is fine; LLM-gated branching is not.

## The contract with lower layers

### Claims

```rust
pub struct ScriptedClaim {
    pub quest_id: QuestId,
    pub entities: Vec<EntityRef>,
    pub regions: Vec<RegionId>,
    pub factions: Vec<FactionId>,
    pub duration: ClaimDuration,   // quest-step-scoped or quest-scoped
}
```

Claims are registered on the sim's scripted-state table. The brain
consults this table every tick. The Context Broker consults it before
generating dialog for claimed entities.

### State writes

Scripted quests write to world state via an authoritative API:

```rust
pub struct ScriptedWorldWrite<'a> {
    sim: &'a mut Sim,
    quest: QuestId,
}

impl ScriptedWorldWrite<'_> {
    pub fn transfer_base(&mut self, base: BaseId, to: FactionId) { ... }
    pub fn kill_npc(&mut self, npc: NpcId, cause: DeathCause) { ... }
    pub fn unlock_region(&mut self, region: RegionId) { ... }
    pub fn set_story_flag(&mut self, flag: StoryFlag, value: bool) { ... }
    // ...
}
```

Every write is auditable - attributed to a quest, tagged in the journal,
visible in save inspection.

### Tag injection

When a scripted arc wants generative filler to reference its state, it
injects context tags:

```rust
quest.inject_context_tag(
    RegionId::Kordon,
    ContextTag {
        text: "Loners are searching for a missing patrol.",
        ttl: ClaimDuration::UntilStep(Step::PatrolResolved),
    }
);
```

These tags flow into the Context Broker's prompt assembly. Generative
quests and dialog in Kordon will reference the search without the author
having to write every line.

## What this means for the generative plan

The AI-generation phases don't change shape, but every module needs to
honor this contract:

- **Phase 2 (Context Broker)** - consults the scripted-state table and
  context-tag store during prompt assembly. Generative output for
  claimed entities is gated.
- **Phase 2.5 (Sim brain)** - every rule checks scripted flags before
  firing.
- **Phase 3 (Personas)** - worldgen respects scripted requirements
  (reserved names, pre-placed notable NPCs for scripted arcs).
- **Phase 4 (Memory + runtime flavor)** - scripted-quest events flow
  into NPC memory with a higher weight than emergent events, so canon
  beats are what NPCs talk about first.

## Scope

Design of the scripted-quest runtime itself (step graphs, branching,
authoring format) is a separate workstream from the AI-generation
initiative. This doc exists so the generative and reactive layers know
what interface to build against.

The contract is the stable part. The implementation of scripted quests
proper lands when the first real arc is being authored.
