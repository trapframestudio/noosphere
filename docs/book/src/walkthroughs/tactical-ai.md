# Tactical AI

Noosphere's combat AI target is **better than F.E.A.R., better than
S.T.A.L.K.E.R., better than S.T.A.L.K.E.R. 2.** That's not a slogan - it's
a specific set of capabilities those games either couldn't do or chose
not to, that our architecture makes possible.

This walkthrough is the canonical design doc for the tactical layer. It
sits as a sibling to the [AI-generation plan](ai-generation.md) under the
primary-priority umbrella. Phases T1–T5; implementation parked alongside
the narrative system until the base work is further along and a technical
evaluation has happened.

See also:

- [AI-driven generation](ai-generation.md) - the narration layer that
  voices tactical chatter.
- [Sim brain](sim-brain.md) - the strategic layer that sets the
  objectives tactical AI pursues.
- [Scripted quests](scripted-quests.md) - the canon layer that tactical
  AI defers to during authored arcs.

## What we're building against

**F.E.A.R. (2005)** is the high-water mark for per-squad tactical AI.
GOAP planners, hand-annotated levels, squad coordination, verbal chatter
that made the AI legible. Twenty years later, few games have matched it.
But F.E.A.R. was **solo, level-based, session-scoped, and archetypal** -
enemies had no individuality, no memory across encounters, no strategic
context beyond the current room.

**S.T.A.L.K.E.R. (2007)** shipped A-Life, an ambitious persistent-NPC
simulation where squads patrolled, fought each other, and lived the Valley
when the player wasn't looking. Strategic layer = brilliant. Tactical
layer = mediocre - weak cover use, limited squad coordination, no
individuality in combat. S.T.A.L.K.E.R. 2 regressed further on A-Life,
shipping an open world where NPCs felt like they despawned the moment
you looked away.

**Both treated tactical and strategic AI as separate problems.** Neither
made individual NPCs *persistent characters* whose tactical behavior
reflected who they were. Neither gave tactical AI memory of previous
encounters with the player. Neither designed tactical AI for co-op from
day one.

## The principle

> **Tactical AI is where persona, memory, brain, and narration all
> converge into moment-to-moment behavior. The combat encounter is the
> payoff for every other system.**

F.E.A.R. gave us the tactical substrate: GOAP, squads, annotated maps,
chatter. S.T.A.L.K.E.R. gave us the persistent world idea. Noosphere's
contribution is **tight integration** - tactical AI reads from and
writes to every other layer of the sim, producing behavior that's
simultaneously tactically competent, personally distinctive, strategically
aligned, and narratively legible.

## What we do that F.E.A.R. and S.T.A.L.K.E.R. didn't

Each of these is a concrete architectural capability, not aspiration:

1. **Persona-driven tactical personality.** Every named NPC has a
   persistent persona (name, traits, quirks, background). Tactical
   decisions read from persona: an aggressive Bandit takes cover less
   willingly than a disciplined Duty trooper; a traumatized veteran
   flinches at grenades; a newbie fumbles reloads. Faction identity
   alone isn't enough - individuals fight differently.

2. **Tactical memory of the player.** When Volkov fights the player and
   survives, he remembers *what the player did.* "This outsider flanks
   left" becomes a `MemoryFact` that biases Volkov's future tactical
   decisions toward watching his right flank. Player tactics that worked
   once may not work again against the same NPC. F.E.A.R. didn't do
   this because it was session-scoped; S.T.A.L.K.E.R. didn't because
   NPCs had no per-individual state. We can.

3. **Brain-coordinated strategic intent shapes tactics.** A squad
   defending the Refinery with brain goal `reclaim_territory` fights
   aggressively forward. A squad with `tactical_retreat` fights
   delaying actions. Same NPCs, same GOAP planner - the strategic goal
   parameter changes the shape of combat. Brain and tactical compose.

4. **LLM-narrated tactical chatter.** F.E.A.R.'s chatter was recorded
   lines from a fixed pool. Ours can be too (that's the fallback), but
   when AI generation is available, chatter is voiced *in persona.*
   Volkov shouts different things than a generic Duty trooper - and
   what he shouts references his memory, his faction's current
   situation, his brother at Dolina. Chatter becomes characterization.

5. **Cross-map persistent tactical consequence.** Squads you wounded on
   the Western Line remember you on the Marshes. Factions you embarrassed actively
   hunt you across map transitions. This is the A-Life dream, but
   extended to tactical memory, not just spawn positions.

6. **Faction-specific tactical vocabularies.** Each faction has its own
   GOAP action library, reflecting fighting doctrine. Bandits improvise
   (flank, ambush, fall back and regroup). Duty executes doctrine (hold
   line, disciplined bounding overwatch, formal retreat). Loners are
   opportunistic (engage when numbers favor, fade when they don't).
   Faction identity shows up in combat mechanics, not just skin.

7. **Co-op tactical design from day one.** F.E.A.R. and S.T.A.L.K.E.R.
   were solo. Noosphere is co-op. Tactical AI is designed to challenge
   **multiple cooperating players**, not one. Squad coordination,
   flanking, and suppression assume the AI faces a team - which opens
   tactical problems those games never had (splitting the team,
   isolating a player, baiting overextension).

8. **Scripted-emergent tactical composition.** Scripted quests can set
   specific tactical signatures on maps and squads ("this is a Bandit
   ambush scenario, use ambush-heavy annotations and an ambush-coded
   squad role distribution"). Emergent combat still flows through the
   same GOAP+squad machinery, just parameterized differently. Scripted
   combat beats feel authored *and* tactically sharp.

Each of these is a direct product of the layered architecture we've
locked in. None is novel research. All of them compose.

## The four pillars (F.E.A.R.-inherited)

These are the tactical substrate. We build on top of them; we don't
replace them.

### Pillar 1 - GOAP (Goal-Oriented Action Planning)

Each NPC has goals (Kill Enemy, Stay Alive, Hold Position, Retreat) and
a library of actions with preconditions and effects. The planner
searches for an action sequence that satisfies the current highest-priority
goal. Small, well-understood algorithm - a few hundred lines of Rust.

**Noosphere extensions:**
- Action library is **per-faction** - Bandits and Duty have different
  vocabularies reflecting doctrine.
- Goal priority is **persona-weighted** - aggressive personas prioritize
  Kill Enemy over Stay Alive more than cautious personas do.
- Goals consume **brain state** as parameters - the `Hold Position` goal
  reads the brain's current `FactionGoal` for this faction to decide
  *which* position is worth holding.

### Pillar 2 - Squad coordination

A `SquadController` per active engagement assigns roles (anchor,
flanker, suppressor, retreater) to squadmates based on positions,
numbers, and tactical metadata. Role assignments become goal
preconditions feeding each NPC's GOAP planner. Coordination emerges
without centralized control.

**Noosphere extensions:**
- **Co-op-aware role assignment.** Squads see multiple players and
  distribute roles accordingly - split the flankers to pressure two
  players simultaneously, or concentrate suppression on the one most
  vulnerable.
- **Faction-specific role distributions.** Duty squads default to
  bounding overwatch formations; Bandits default to pincer ambushes;
  Loners prefer fire-and-maneuver. Same role set, different default
  allocations.
- **Persona-weighted role preferences.** An aggressive NPC volunteers
  for flanker; a cautious NPC gravitates to anchor. Squad composition
  becomes an emergent property of who's in it.

### Pillar 3 - Hand-annotated tactical maps

Every map is hand-crafted, 5 km² scale, with tactical annotations
authored in the Godot editor. Cover points, peek positions, flank
routes, sightlines, ambush nodes, chokepoints - all placed by level
designers as part of level authoring.

**Noosphere extensions:**
- **Annotation density tiers.** 5 km² is too much to annotate uniformly.
  Maps have designated **combat-grade** zones (faction bases, major
  POIs, chokepoint routes) with dense annotation; **skirmish-grade**
  zones (crossroads, small camps) with medium annotation; and
  **ambient** zones (open countryside, backwoods) with sparse annotation.
  Runtime query API degrades gracefully in ambient zones - falls back to
  cheap nearest-geometry cover detection.
- **Per-faction annotation hints.** An annotation can be tagged as
  "Bandit-typical" or "Duty-preferred," biasing how each faction
  prioritizes using it. Makes the same map play differently for
  different faction squads.
- **Scripted-quest annotation overlays.** Scripted arcs can inject
  temporary annotations for an encounter (a specific ambush setup),
  remove annotations to change the tactical landscape ("the walls are
  rubble now"), or mark some as locked for that arc's duration.

### Pillar 4 - Chatter (the legibility layer)

F.E.A.R.'s AI was as good as it was partly because **the AI told the
player what it was doing.** "Flanking left!" "Covering fire!" "He's
behind the crates!" Without chatter, even great tactical behavior feels
opaque. With chatter, even modest behavior feels brilliant.

**Noosphere extensions:**
- **Persona-voiced chatter.** Volkov shouts different things than a
  generic Duty trooper, in his voice, referencing his memory. See
  [AI-driven generation](ai-generation.md).
- **Brain-aware chatter.** The faction's current strategic situation
  colors what squads shout. A faction on the back foot sounds desperate;
  a faction in ascendancy sounds confident.
- **Co-op-aware chatter.** NPCs call out player actions specifically -
  "the one with the rifle is flanking!" "take down the medic first!" -
  giving co-op teams the same legibility-feedback single-player got in
  F.E.A.R.
- **Authored fallback pool always works.** With AI disabled, chatter
  falls back to faction-specific authored pools. Quality drops; the
  system still functions.

## Noosphere-specific design

### 5 km² hand-crafted maps with transition points

Original-S.T.A.L.K.E.R.-zone scale. Discrete maps connected by
authored transition points. This shapes tactical AI in three ways:

- **Tactical annotation density tiers** (above) handle the scale
  without crushing the content pipeline.
- **Tier transitions are natural seams.** Within a map, the two-tier
  sim has entities near the player on the online tier and entities
  elsewhere on the offline tier. Between maps, transitions are
  explicit persistence/handoff moments. Entity promotion from offline
  to online is bounded - a squad that comes online entered combat or
  joined an ongoing patrol, not "woke up mid-action mid-field."
- **Per-map tactical signatures are authored.** The Cooling Tower is
  an ambush corridor; the Refinery is a chokepoint-defense arena; the
  Marshes encourage long-range sparse engagement. Designers express
  tactical intent through annotation density and type.

### Co-op as a first-class design concern

Noosphere is co-op from day one. Tactical AI must:

- Present meaningful challenge to **multiple cooperating players**, not
  scale-up a solo experience
- Enable tactics that specifically target team play - split, isolate,
  bait, flank-and-pin
- Be fun to fight *together* - which means AI behavior has to be
  **legible to all players simultaneously**, not just the one being
  focused. Chatter is especially important here.

No prior-art game we're inheriting from designed for this. It's the
single biggest opportunity for Noosphere's tactical AI to differentiate.

### Persistence and cross-map memory

Tactical memory (what NPCs remember about the player) persists in the
snapshot alongside narrative memory. A squad wounded on the Western Line remembers
you in the Marshes. Factions you've embarrassed hunt you across maps.
This is the A-Life promise extended to tactical consequence.

Implementation: tactical `MemoryFact`s share the `NpcMemory` store from
the AI-generation plan. A tactical fact carries a tactical-relevance tag
so the tactical layer retrieves it cheaply without pulling narrative
memory.

## Architecture

### New module: `simn-sim::tactical`

Engine-agnostic. Pure Rust. No LLM dependency - chatter emission hooks
into the AI-generation layer when available, falls back to authored pools
when not.

```
simn-sim::tactical/
├── goap/
│   ├── Planner, Goal, Action
│   ├── Per-faction goal/action libraries
│   └── Goal priority scoring (persona-weighted)
├── squad/
│   ├── SquadController
│   ├── Role assignment (co-op-aware)
│   └── Coordination protocol
├── tactical_map/
│   ├── Annotation data structures
│   ├── Density zones
│   ├── Runtime query API
│   └── Graceful degradation to geometry-based queries in ambient zones
├── perception/
│   ├── Stimulus model (sight, sound, proximity)
│   ├── Alertness state machine
│   └── Memory-biased perception (NPC with grudge notices player faster)
└── chatter/
    ├── Tactical trigger table
    ├── Authored bark pool (per faction)
    └── LLM hook (when AI-generation is available)
```

### Godot editor tooling

Hand annotation requires ergonomic tooling. Ships as a Godot editor
plugin alongside the runtime module:

```
godot/addons/noosphere_tactical_tools/
├── Annotation node types (CoverPoint, PeekPosition, FlankRoute, ...)
├── Gizmos (cover directionality, height, sightlines)
├── Validation (warnings for isolated annotations, missing directionality)
├── Density-zone painting (mark regions as combat/skirmish/ambient)
└── Bulk operations (regenerate sightlines after geometry change)
```

Level designers author tactical data as part of level authoring, using
editor tools designed for it. This is a real workflow, not a hack
wrapped around generic nodes.

## Phased implementation

Implementation parked alongside the narrative system until the base work
progresses further and a technical evaluation has happened. Design
locked here so implementation can start fast when green-lit.

### Phase T1 - Tactical annotation system (~3 weeks)

**Goal: annotations can be authored in the editor, loaded with maps,
queried at runtime.**

- `simn-sim::tactical::tactical_map` module
  - Data structures: Cover, Peek, Flank, Sightline, Ambush, Chokepoint
  - Density zones
  - Runtime query API
- Godot editor plugin (see above)
- Style guide: per-faction annotation preferences, density expectations
  per zone type
- Validation: warnings in editor for common authoring mistakes
- Debug overlay: visualize annotations in-game during dev

### Phase T2 - GOAP individual AI (~3 weeks)

**Goal: NPCs individually behave tactically. Uses cover, reloads
sensibly, retreats when hurt, engages at appropriate range.**

- GOAP planner
- Base goal library (Kill Enemy, Stay Alive, Hold, Retreat, Patrol)
- Base action library (shoot, reload, move-to-cover, peek, flank,
  retreat, suppress)
- Per-faction goal/action extension hooks
- Perception: stimulus model, alertness state machine
- Persona-weighted goal priority
- Memory integration (retrieve tactical `MemoryFact`s, bias decisions)

### Phase T3 - Squad coordination (~3 weeks)

**Goal: NPCs in combat operate as teams. Flanking, covering fire,
bounding overwatch. Feels F.E.A.R. in every fight.**

- `SquadController` (per engagement, formed ad hoc, dissolved when
  engagement ends)
- Role definitions (anchor, flanker, suppressor, retreater)
- Role assignment (position-aware, persona-weighted, co-op-aware)
- Coordination protocol (fire discipline, wait-for-flanker,
  cover-fire triggers)
- Faction-specific role distributions
- Per-faction squad doctrine as data

### Phase T4 - Chatter (~2 weeks, parallelizable with T3)

**Goal: tactical behavior is legible. Players hear NPCs announce what
they're doing, in-character.**

- Tactical trigger table (role assignment, damage, squadmate death,
  retreat call, out-of-ammo, target-change)
- Authored bark pool per faction (content authoring work - ~50 barks
  per faction per role)
- LLM hook for persona-voiced chatter when AI generation is available
- Co-op-aware chatter (calls out player actions, per-player focus)
- Faction voice consistency via voice cards (shared with narrative
  layer)

### Phase T5 - Integration and tuning (~ongoing)

**Goal: tactical AI composes cleanly with narrative, persona, memory,
and scripted systems. Plays well at scale. Feels better than F.E.A.R.,
better than S.T.A.L.K.E.R.**

- Cross-tier handoff polish (offline-to-online squad promotion)
- Cross-map tactical memory persistence (implementation-in-detail of the
  design above)
- Scripted-quest tactical overlays (annotation injection, squad
  parameterization)
- Performance tuning at 20+ NPCs in engagement
- Per-faction tactical personality refinement
- Playtest-driven goal/action library expansion

## Integration points

### With the brain

Brain emits strategic goals per faction and per region. Tactical layer
reads those goals as parameters to GOAP goals. A squad's `Hold Position`
goal asks the brain "where should we hold?" The brain's
`FactionGoal { reclaim_refinery }` points the squad at the refinery.
Squad's GOAP plans how. This is the clean separation: brain picks
objectives, tactical executes them.

### With personas

Persona data is a first-class input to every tactical decision:

- Goal priority weighting (aggression → prioritize engage; cautious →
  prioritize survive)
- Action preference weighting (veterans reload under cover; newbies
  fumble under fire)
- Squad role preferences (natural leaders gravitate to anchor; loose
  cannons to flanker)
- Perception biases (paranoid NPCs detect faster; complacent NPCs slower)

This is how two same-faction squads play differently: their personas
differ.

### With memory

Tactical memory lives in the same `NpcMemory` store as narrative memory,
tagged for tactical relevance. Retrieval is cheap. Memory facts bias:

- Perception (NPC with grudge notices player earlier)
- Goal priority (NPC who barely survived last encounter prioritizes
  safety more)
- Action selection (NPC who saw player flank left checks right flank
  more)

Cross-map persistence falls out of the existing snapshot system - no new
machinery.

### With scripted quests

Scripted arcs can:

- Set tactical signatures on maps (annotation overlays, density shifts)
- Parameterize squads (role distribution overrides, doctrine overrides)
- Suppress tactical memory for specific encounters (scripted boss fights
  don't want emergent tactical adaptation during the fight)
- Pause the brain's influence on tactical during a scripted arc (if the
  arc wants specific behavior regardless of broader strategic context)

Same claim/release pattern as the brain-script contract.

### With AI-generation (LLM)

LLM is used for chatter narration in T4. Tactical layer functions
fully without LLM (authored barks); LLM makes chatter *specific* rather
than archetypal. See the [AI-generation plan](ai-generation.md) Phase 4
for when runtime narration becomes available.

## Risks (honest)

- **Annotation authoring is a significant content burden.** 5 km² × N
  maps × dense annotation in combat zones = real work. Mitigated by
  density tiers, good tooling, clear style guide. Still real.
- **Co-op AI tuning is harder than solo AI tuning.** More variables,
  more edge cases, more "split the team" emergent failures. Expect a
  long tail of tuning work in T5.
- **GOAP goal/action library authoring is content work, not just code.**
  The planner is easy; the library that produces interesting behavior is
  the investment. Per-faction libraries multiply the work.
- **Cross-map tactical memory can accumulate unreasonably.** An NPC who
  fights the player 30 times shouldn't have 30 memory facts biasing
  their decisions. Memory compression (already planned for narrative
  memory) applies here too - salient tactical lessons survive, verbatim
  recent encounters age out.
- **Scripted overrides can fight emergent tactics in ways that feel
  off.** If a scripted arc forces a squad into a rigid configuration,
  and emergent brain/memory would push them differently, the friction
  shows. Authoring scripted combat requires understanding what the
  emergent system was going to do.
- **LLM chatter quality depends on the narrative layer working.** If
  chatter sounds worse than authored barks, players will notice
  immediately. The LLM hook must be gated by quality validation, same
  as narrative-layer LLM output.

## Scope

Primary priority alongside the layered narrative system. Implementation
parked until the base work progresses and a technical evaluation happens.
Design locked here.

Phases T1–T4 are hard engineering with known solutions. T5 is ongoing
craft. No phase depends on novel research; every component has
well-understood reference implementations. The craft is in the
*composition* of the layers, not any single layer.

The goal isn't to do what F.E.A.R. did in 2005. It's to use what F.E.A.R.
proved out as a substrate, compose it with the rest of Noosphere's sim
architecture, and produce tactical AI that feels like it's fighting
**these specific players**, with **these specific NPCs**, in **this
specific world**, in a way no prior game has quite managed. The pieces
all exist. The composition is ours.
