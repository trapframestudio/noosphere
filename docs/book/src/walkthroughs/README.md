# Walkthroughs

Narrative, moderately technical explanations of how each major system in Noosphere actually works. These are the longer "sit down and explain it to me" writeups - counterweighted against the tighter, reference-y chapters under [Architecture](../architecture/overview.md) and [Mechanics](../mechanics/damage-and-healing.md).

Where walkthroughs fit in the doc set:

- **Architecture** (in this book) - reference-level summaries: crate layout, engine boundary, public surface.
- **Mechanics** (in this book) - player-facing contracts for landed gameplay systems with tuning numbers and protocols.
- **Walkthroughs** (here) - narrative deep-dives into systems that have shipped, covering why they look the way they do.
- **Planning** (in this book, next section) - forward-looking design docs for systems that haven't shipped yet.

One file per major piece. When a system changes in a way that invalidates the writeup, update the file - stale walkthroughs are worse than no walkthroughs.

## Contents

- [Networking](networking.md) - Steam P2P + host-authoritative sim replication: role model, snapshot handshake, delta broadcast, action relay, lobbies, `NetSession` tick loop, map-decoupled session, invite fallback.
- [Runs & saves](runs-and-saves.md) - named run slots, per-run save directories, solo / coop-host flow, joiner mirror-sim flow, save format, debug helpers.
- [Simulation](sim.md) - `bevy_ecs`-backed world, region graph, journal-then-snapshot persistence, mirror mode for clients, action dispatch, sim-as-authority handshake with Godot and the networking layer.
- [Terrain](terrain.md) - server-master heightmap pipeline: real DEM → Blender → canonical `.r16` + TOML sidecar, shared by sim and Godot with bit-identical sampling.
- [Dev controls](dev-controls.md) - hotkey reference, debug overlay, Solo / Host / Join modes, world scale and save file locations.
- [Scripted quests](scripted-quests.md) - the canon story layer: authored arcs, authoritative state writes, claims over entities and regions. The spine of the game.
- [Sim brain](sim-brain.md) - deterministic reactive layer that watches the event stream and emits faction goals, stance shifts, and rumor seeds. Defers to scripted canon; feeds the generative narration layer.
- [AI-driven generation](ai-generation.md) - host-side Gemma 4 inference, Context Broker, persona system, worldgen seed phase, runtime refill, fine-tuning roadmap. Narrates brain output and fills around scripted content. **Primary-priority initiative.**
- [Tactical AI](tactical-ai.md) - F.E.A.R.-class combat AI and beyond: GOAP, squad coordination, hand-annotated 5 km² maps, persona-driven tactical personality, cross-map tactical memory, co-op-first design. **Primary-priority initiative.**
- [Ground cover foliage](ground-cover-foliage.md) - tile-based deterministic scatter with GPU view-cone density culling: dense in front of the camera, lighter in periphery, sparse behind, gone past a tunable radius; biome lookup direct off the canonical splatmaps; editor preview that tracks the editor viewport camera.
- [Distant trees (cluster impostors)](distant-trees.md) - pre-baked silhouette billboards spawned in per-variant MMIs out to several km past the close-tier. Cross-billboard cards (no camera-facing) for real silhouette area at any view angle, mipmap alpha cap so distant trees don't vanish, position-jittered coverage baker mirroring the close-tier's per-tree gating. Replaces the deleted distant-foliage-tint terrain-shader pass.
- [Terrain3D](terrain3d.md) - TokisanGames Terrain3D plugin replaces Zylann HTerrain on the test path: 16-slot Megascans + AmbientCG asset set, splatmap → control-map converter, region-based on-disk format that doesn't bloat scenes. Production maps stay on the Rust `TerrainNode` for now.
- [Procedural rocks](rocks.md) - Blender-generated rock pack (6 shapes × 3 LODs), Pillow-downsampled PBR textures (1k/2k/4k tiers per physical size), per-species cluster noise for boulder-field clumping, four-tier collision dispatch (None / Steppable / Crouch / Standing). Mirrors `TreeScatter`'s tile streaming + per-instance LOD shader cull but stripped of wind / leaf grading / impostor swap.
- [Interaction areas](interaction-areas.md) - scene-placed `InteractionAreaMarker3D` nodes that designate "NPCs should do X here" spots (rest, work, socialize, guard_post, …). Per-region `InteractionAreas` registry on the sim side with capacity, faction restriction, free-form `tags`. Phase D3 wires `"rest"` into the squad planner so squads prefer a nearby rest area over a generic base position; other kinds are recognized vocabulary slots for follow-up iterations. Emits `WorldEventKind::InteractionStarted/Ended` on arrival / departure.
- [Procedural trash](trash.md) - road + zone-driven single-use litter scatter (~85 species: bottles, cans, smokables incl. cigarettes / joints / cigars / blunts, paper, food waste, broken glass, masks, flipflops, etc.). Three behavioral tiers: static MMI for tiny items (cigarettes, ash, matchboxes), `freeze = FREEZE_MODE_STATIC` for kickable cylinders (bottles, cans, drinks, coffee cups) woken by `TrashKickZone` on the player when they're walked into, and dynamic-sleeping for wind-blown light items (papers, masks, flipflops, chips bags) impulsed by `WeatherRig.wind_vector_xz()`. Tile streaming + on-disk placement cache (same contract as rocks); physics gated by a tighter active radius with a static-MMI visual fallback at distance. Placement signals: road / zone / curvature / slope / hotspot Perlin / per-species repeat damper. Authoring via `scripts/trash_species_manifest.json` + `scripts/generate_trash_species_tres.py`.
