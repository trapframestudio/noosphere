# Sim brain

The sim brain is a lightweight, deterministic reactive layer that watches
the sim's event stream and emits structured reactions - faction goals,
world state tags, NPC stance shifts, rumor seeds. It is the thing that
makes the world between scripted narrative beats feel like it's
*thinking* without ever pretending to author canon.

**It is not an LLM.** It has no model, no prompts, no non-determinism.
It's pattern rules over an event window, evaluated every tick or every
relevant event. Compute cost is negligible compared to rendering or
inference. It runs on every supported host tier, including headless
Steam Deck.

See also:

- [Scripted quests](scripted-quests.md) - the authored canon layer the
  brain defers to.
- [AI-driven generation](ai-generation.md) - the narration layer that
  paraphrases brain output into player-facing text.

## The hierarchy (restated)

1. **Scripted narrative is canon.** Brain rules must check for
   `scripted_active` flags on entities, factions, and regions. If a
   scripted arc has claimed jurisdiction over something, the brain
   stands down in that area.
2. **Brain rules are deterministic and authoritative over emergent
   state.** When scripted content is silent, brain rules drive faction
   behavior, NPC opinion shifts, and rumor propagation.
3. **Generative content (LLM) narrates brain output.** It never decides
   what factions do; it just writes prose about decisions already made.

## Architecture

Engine-agnostic Rust module, `simn-sim::brain`. Subscribes to the same
event bus the Context Broker reads from (shared infrastructure from
Phase 2 of the AI-generation plan).

```rust
pub struct Brain {
    rules: Vec<Box<dyn Rule>>,
    event_window: EventWindow,         // last N sim-hours, indexed by type
    aggregates: AggregateCache,        // incrementally maintained
    cooldowns: HashMap<RuleId, WorldTime>,
    scripted_regions: HashSet<RegionId>, // set by scripted-quest system
}

pub trait Rule: Send + Sync {
    fn id(&self) -> RuleId;
    fn event_types(&self) -> &[EventType];   // for dispatch indexing
    fn cooldown(&self) -> Duration;
    fn evaluate(&self, ctx: &BrainContext) -> Option<Reaction>;
}

pub enum Reaction {
    FactionGoal {
        faction: FactionId,
        goal: GoalKind,
        target: EntityRef,
        deadline: WorldTime,
        priority: Priority,
        reason: RuleId,
    },
    WorldStateTag {
        tag: StateTag,
        region: Option<RegionId>,
        ttl: Duration,
        reason: RuleId,
    },
    NpcStanceShift {
        npc: NpcId,
        toward: EntityRef,
        delta: f32,
        reason_text: &'static str,   // surfaced in memory
        reason: RuleId,
    },
    RumorSeed {
        topic: RumorTopic,
        origin: RegionId,
        affected_factions: Vec<FactionId>,
        reason: RuleId,
    },
    Event(WorldEvent),   // new event back onto the bus
}
```

### Tick cadence

- **Reactive tick** - fired when an event lands on the bus. Only rules
  whose `event_types()` include that event's type are evaluated. Cheap
  and targeted.
- **Periodic tick** - every sim-minute (or tuned). Rules dependent on
  windowed aggregates (counts, streaks, ratios) re-evaluate.

Aggregates are incrementally maintained: when an event enters the
window, it updates a handful of counters; when it ages out, it
decrements them. O(1) per event.

### Deferral to scripted state

Every rule consults the `BrainContext` for scripted flags before firing:

```rust
fn evaluate(&self, ctx: &BrainContext) -> Option<Reaction> {
    if ctx.is_scripted_active(FactionId::Loners) { return None; }
    if ctx.region_scripted(RegionId::Kordon) { return None; }
    // ... rule logic
}
```

Scripted quests flip these flags via `ScriptedQuestHandle::claim(...)`
and release them on completion. The brain cannot override a claim.

## The starter rule library

Phase 2.5 ships with ~30 hand-authored rules covering the baseline
behaviors that make the world feel alive. Example categories:

- **Territorial pressure** - faction loses N bases → emits reclaim goal.
- **Player aggression** - player kills M NPCs of faction Y in window →
  stance shifts for all Y NPCs, rumor seed about player's reputation.
- **Casualty ripple** - notable NPC dies → rumor seed to faction and
  region, stance shifts for the NPC's close associates.
- **Border friction** - two factions have N+ skirmishes on a shared
  border → escalation or negotiation goal (picked by faction
  personality).
- **Economic pressure** - trader supply chain disrupted → price shift
  tag, escort-request goal.
- **Curiosity** - player repeatedly enters a region without engaging →
  rumor seed about player's presence.

Rules live in a data format (TOML or Rust DSL - pick one during Phase
2.5) so modders can add or override without touching engine code.

## Integration points

### With the offline tier

The offline tier's faction AI reads brain-emitted goals and plans
against them. A `FactionGoal { Loners, reclaim, Refinery }` becomes:
offline tier plans a reclaim operation, generates events over N
sim-hours, brain watches those events, emits follow-up reactions. The
loop sustains itself.

### With NPC memory

`NpcStanceShift` reactions flow into the per-NPC memory system. The
`reason_text` becomes a `MemoryFact` so the shift has a durable in-world
justification, not just a hidden number change.

### With the news/dialog system

`RumorSeed` reactions enter the news queue. The Context Broker picks up
the seed, gathers relevant persona and world state, and dispatches to
the LLM for narration. Without the LLM, rumors are narrated from
templates.

### With scripted quests

Scripted quests can:

- **Claim** entities/regions to suppress brain activity during canon
  beats.
- **Seed** brain state they expect to find (e.g., "this quest assumes
  the Loners are on the back foot; if they aren't, the brain can be
  nudged toward that state a few sim-days ahead of the beat").
- **Consume** brain state as triggers (e.g., "this quest unlocks when
  the brain has emitted `LonersLosingNorth` for at least 24 sim-hours"
  - emergent pacing within an authored arc).

The scripted system and the brain communicate through structured,
auditable interfaces. Neither is allowed to silently mutate the other's
state.

## Testing

Because the brain is deterministic, it's genuinely testable:

- **Golden-state tests** per rule: given a canned event stream, assert
  exact reactions.
- **Replay tests**: recorded event stream from a playtest session re-run
  against the current rule set must produce identical reactions, or
  flag as a regression.
- **Conflict tests**: scripted-active flags correctly suppress rules
  across the library.

This is a sharp contrast with the LLM layer, where only rubric-based
evaluation is possible. Keeping the brain LLM-free is what makes this
testability possible.

## Debugging

Every reaction carries `reason: RuleId`. A debug overlay (added to the
existing debug infrastructure) surfaces:

- Active faction goals, grouped by faction, with rule that fired them
- Recent rule firings (last N minutes), filterable by rule
- Current world state tags
- Active scripted claims

When a faction is behaving oddly, inspect the active goals and trace
them back to rules. When a rule never fires, check cooldowns and
scripted claims.

## Scope

This walkthrough is a scaffold. Rule details, the aggregate format, and
the exact event types will land as the rule library is authored. The
architectural shape above is the stable target; the contents of the
rule library are living content.

Primary-priority as part of the AI-generation initiative. Phase 2.5 per
the [AI-generation plan](ai-generation.md).
