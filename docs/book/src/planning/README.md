# Planning

Forward-looking design documents for Noosphere systems that haven't shipped yet. Each doc captures decisions, tradeoffs, open questions, and enough technical detail that an implementer can pick it up cold.

Where planning fits in the doc set:

- **Architecture** - how the code is structured today.
- **Mechanics** - the contracts for gameplay systems that have landed.
- **Walkthroughs** - narrative deep-dives into shipped systems.
- **Planning** (here) - living design docs for systems still ahead. Numbers, thresholds, decay constants here are illustrative, not committed.

A plan doc graduates to a walkthrough when its system ships. Until then, the plan doc is authoritative for design intent.

## Contents - project & operations

- Legal Structure - the legal scaffolding behind the [funding model](../project/funding-model.md): why an entity, entity type/jurisdiction leans, the setup sequence (form → EIN → bank → assign IP → trademark → Steam → CLA → rev-share agreement), and the open questions that need an attorney/CPA (notably whether the contributor revenue share is a security). Direction + checklist, not legal advice.

## Contents - world & simulation

- Shards - fault-born items with persistent effects, acquisition loop, inventory integration, and Fault-adjacent rarity tiers.
- [Author-Time Content](author-time-content-plan.md) - offline (dev-time) pipeline that turns a local LLM + capability-schema validator + curation gate into shipped corpora (barks, mission templates, persona tables); upstream of the runtime LLM and the "Off" tier.
- Belief Sim - the Noosphere as a distributed belief field: how rumor, faith, and observation modify the simulation.
- [Contestation](contestation-plan.md) - rotating-ownership tick for `BASE_*` POIs marked `contested = true`: tier-driven attack cadence, garrison resolution, ledger-persisted ownership.
- [Guard System](guard-system-plan.md) - designer-placeable `GuardPointMarker3D` + POI-baker auto-generation. Static posts + perimeter patrol loops, capture-aware, replaces the current "stand at base center on formation ring" model.
- Faults - fault zones (traps, phenomena, re-manifestation sites), Squalls as a Valley refresh mechanic, shard spawning pulse.
- [Ecosystem](ecosystem-plan.md) - creature ecology, predator-prey graphs, population dynamics, mutation lineages.
- [Survival & Crafting](survival-and-crafting-plan.md) - the hunger/thirst/fatigue + wound + drug model source of truth, step-by-step rollout plan.
- [Weapons](weapons-plan.md) - ballistics, parts, round variants, attachments, condition model.
- [Loot & Economy](loot-and-economy-plan.md) - server-authoritative loot surfaces (containers, corpses, ambient scatter), faction-driven restocking, depth-tier risk/reward, circulating inventory feedback loop.
- Map Bounds Review - systematic check that every map's UTM bounds actually contain the POIs the design overview anchors to that location; tracking artifact, not a forward design doc.

## Contents - architecture & systems

- [Iteration 5-12 Roadmap](sim-iteration-5-12-plan.md) - sequenced four-phase execution plan after the threaded-sim merge: offline-tier MVP, inventory UI overhaul, loot & economy Step 1, ballistics Step 3. Points at the existing per-system plans for design depth; this doc owns *ordering*.
- [Iteration 5-13 — Nav Pipeline + Interaction Areas](sim-iteration-5-13-plan.md) - Terrain3D-painted nav overrides flowing to the sim grid, programmatic POI obstacle stamping (task #17 bundled in), a sparse offline-tier waypoint graph, and placeable `InteractionAreaMarker3D` nodes that give NPCs flexible "do X here" descriptors (rest spots, work spots, etc.). Four phases (A: paint → sim shipped; B: POI stamping; C: offline graph; D: interaction areas).
- [Iteration 5-14 — Test-Map Authoring Rework](sim-iteration-5-14-plan.md) - Noise-layered varied terrain on the four test maps, `Sim::register_authored_base` API + bridge, a new `scene_authored_pois` flag on `Region` that gates `world_seed`'s procedural scatter, an editor `PoiBaker` tool that scatters `PoiMarker3D` + `InteractionAreaMarker3D` markers into scenes, and the GDScript spawner that walks them on map load. End-to-end QA: walk the 2×2 region grid with authored bases instead of procedural Y=0 clumps. Six phases (A–F).
- [Sim QA Hand-off — 2026-05-25](sim-qa-handoff-2026-05-25.md) - Snapshot of the anti-clump / stuck-state / combat-realism work landed between 2026-05-12 and 2026-05-25 (60+ commits), plus the open QA backlog and the diagnostic notes for each unresolved complaint. Reads as a session continuation guide rather than a forward plan.
- [Tier Transition](tier-transition-plan.md) - online ↔ offline tier handoff: projection function, when handoffs fire, event-replay vs. state-copy, overlap with multiplayer replication.
- [Sim Hardening](sim-hardening-plan.md) - small pre-netcode items in `simn-sim` (determinism harness, format versioning, etc.) cheap to do now, painful to retrofit later.
- [Threaded Sim](threaded-sim-plan.md) - move sim onto a dedicated worker thread; render reads published snapshots and interpolates. Required for the 60+ FPS target under multi-region / multi-player load. Covers projectile lag-compensation and tier coexistence with offline-tier on the same worker.
- [Physics Backend](physics-backend-plan.md) - `PhysicsBackend` trait in `simn-sim`, dual-mode deployment (Godot Jolt for listen-server, Rapier for dedicated), new `simn-server` binary.
- [Physics Tiering](physics-tiering-plan.md) - five physics tiers, dynamic server-side Tier 2 budget, priority-based per-peer replication, bandwidth probing, Tier 3-only degradation floor.
- [World Ledger](world-ledger-plan.md) - SQLite-backed `simn-world` crate for persistent world-object state alongside journal+snapshot.
- [Destruction](destruction-plan.md) - hybrid-granularity destructibles (prop / world-building / base-section), ECS components, stable IDs, Squall-coupled refresh, nav handling.
- [Dismemberment & Reactive IK](dismemberment-plan.md) - `LimbState` extension of `BodyParts`, caliber-driven `WoundKind` resolution, `SkeletonModifier3D`-based reactive IK, authoring requirements.
- [Combat LOS](combat-los-plan.md) - wire `npc_aggro`'s exposure sampler into `npc_combat` so cover and walls actually gate damage; per-tick `LosCache` resource avoids duplicate raycasts.
- [Cover System](cover-system-plan.md) - pre-baked cover-point graph derived from navmesh + heightmap + static obstacles; runtime queries for tactical positioning; invalidated by destructible flips.
- [Encounter Dispatcher](encounter-dispatcher-plan.md) - routes `EncounterTrigger3D` signals to per-kind runners (combat / ambush / scripted / dialog / cutscene), data-table lookup, fired-once persistence.
- [Faction Registry](faction-registry-plan.md) - TOML-driven faction roster + relation matrix replacing the closed `Faction` enum; 5-step ordered relation spectrum stored as continuous `i16` scores; subfactions inherit parent relations with explicit overrides; runtime drift API + per-player reputation parallel system.
- [Goal Arbitration](goal-arbitration-plan.md) - resolver that picks an NPC's current goal from candidate sources (squad objective, individual aggro, blackboard urgency, scripted claim, personality bias); `ActiveGoal` component as the single goal channel.
- [Multiplayer-Aware A-Life](multiplayer-alife-plan.md) - co-op extension of tier-transition: per-region observer sets, witness-sync of NPC events, server-authoritative chronicle replication, "follow squad across regions" semantics. 12-player target locked.
- [NPC AI - Umbrella](npc-ai-plan.md) - staged roadmap from today's NPC simulation to S.T.A.L.K.E.R. + F.E.A.R.-class behavior plus multiplayer-aware extensions; orders the other NPC-AI plans and tracks deferred sub-pieces.
- [NPC Character Authoring](npc-character-authoring-plan.md) - procedural per-NPC identity (name, backstory, rank, personality traits, stat block) seeded from `(world_seed, npc_id, faction)`; persists across squad joins, region transitions, online↔offline tier transitions.
- [NPC Traversal](npc-traversal-plan.md) - Rust-side pathfinding (uniform-grid A* over heightmap + obstacle bake for online; waypoint graph for offline); deterministic, dedicated-server-friendly, replay-survival contract. *(Reversed from earlier `NavigationServer3D` framing 2026-05-05.)*
- [Offline Tier](offline-tier-plan.md) - the 2D + waypoint + dice abstraction for regions with zero observers. World simulates ambivalent of player presence; combat resolves via dice; statistical equivalence with online physical sim over time. The cost relief that makes the 12-player target tractable.
- [Physical Combat](physical-combat-plan.md) - server-authoritative projectile sim for online tier (NPCs share the player projectile system; body-part hit resolution; per-tick budget); dice resolution for offline tier; hitscan escape valve for special weapons.
- [Squad Blackboard](squad-blackboard-plan.md) - per-`Group` typed key/value store with TTLs; substrate for shared squad facts (last enemy seen, ally down, suppressed-from, rally point); written by world event bus + AI systems, read by goal arbitration + planner.
- [Squad Threat Board](threat-board-plan.md) - extends `Aggro` from single-target to a multi-target threat list; per-NPC `RecentAttackers` + squad blackboard `ThreatList` keyed by attacker NpcId, scored by `damage × recency × proximity`. Direct prerequisite for the 12-player MP target.
- [World Event Bus](world-event-bus-plan.md) - AI-strategic event broadcaster (gunshots, corpses, base flips, ally-down) with spatial decay; the propagation cousin of the encounter dispatcher; writes to squad blackboards, drives reactive objectives, feeds belief sim.
- [Worldgen - OSM Ingest](worldgen-osm-plan.md) - offline pipeline that turns OpenStreetMap / Overture building data into a canonical worldgen artifact, spawned at runtime as per-building scene nodes anchored to `simn-terrain`.
- [Character Rendering & Modular Outfits](character-rendering-plan.md) - bridge from the existing `Equipment` slot system to on-character meshes: `ItemDef` mesh fields, `equipment_changed` signal, `CharacterRig` gdext class, and the Blender / MakeHuman / Mixamo / Substance Painter asset pipeline.
- [Foliage & Tree Scattering](foliage-plan.md) - what's been tried (HTerrain detail layers, PolyHaven cards, Megascans atlas cell-pick, mesh-based scatter, tree perf overhaul), why each failed, and what's still in the codebase for the next attempt to build on.
- [Scatter Optimizations Backlog](scatter-optimizations-plan.md) - items deferred from the 2026-05-05 scatter-stack audit (shared `TileStreamer`, GPU per-instance frustum culling, leaf-card double-sided rendering). Each parked behind a "trigger to act" so the next profile-driven sweep has a known shortlist.
