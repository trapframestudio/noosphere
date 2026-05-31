# Sim QA Hand-off — 2026-05-25

Snapshot of NPC sim work landed during the long anti-clump / stuck-
state iteration that ran from ~2026-05-12 through 2026-05-25, plus
the open issues still pending QA when this session wrapped. Written
for a future session that wants to pick the work back up cold.

The work was driven entirely by playtest observations — clumping,
freezing, dogpile responses, etc. — rather than a fixed-scope
iteration plan. The hand-off lists what shipped, what's known to
still misbehave, and where to look next.

## Work shipped (anti-clump + stuck-state + combat realism)

Group by topic; commits chronologically newest-first inside each
group. All `caeed82cfb..` refs are in `sim-iteration-5-13` (66
commits ahead of `main` at handoff time).

### Spawn + dispersion

- **Spawn-disperse seed runs every tick** (`fbc05c3f70`). Originally
  gated by per-group planner slot — fresh squads with `group_id %
  200` far from `current_slot` sat at spawn for up to 10 s with no
  SquadObjective. Lifted out.
- **Disperse target seed includes `now`** (`27755fe13c`). Repeated
  offline→online cycles no longer pick the same disperse angle.
- **Projection jitter** (`610c7865ae`). `project_offline_to_online`
  adds ±15 m XZ jitter per NPC so squads don't pop back stacked at
  the same waypoint position.
- **Every NPC gets a Group on spawn** (`a873773a67`). Solo NPCs
  (Wanderers, Merged) now get a synthetic `npc_id | (1<<63)` group
  so they participate in the squad-planner pipeline (Wander drift,
  disperse, recently_visited filter) instead of idling.

### Wander behavior

- **Wander drift target** (`942fae768b`). New
  `SquadObjectiveState::wander_drift_target` — Wander squads pick
  a point 150–500 m from centroid and walk there, instead of
  standing on the centroid forever.
- **Outward-from-base bias** (`27755fe13c`). New leg picks that
  point closer to a same-faction base than the current centroid
  get mirrored 180° so squads escape gravitational wells.
- **Drift refresh every tick** (`caeed82cfb`). Refresh was inside
  the planner slot gate, so a stale drift target could sit for up
  to 10 s. Lifted out into its own per-tick pass.
- **Drift range widened** (`27755fe13c`) from 50–150 m to 150–500 m
  so squads actually traverse the region between drift points.

### Stuck-detection + objective expiry

- **Stuck-detection** (`bcbd3c2e0c`). New `last_progress_pos` /
  `last_progress_tick` on `SquadObjectiveState`. Force-expires
  movement-oriented objectives (Patrol / Investigate / Explore /
  Relieve / Wander) when centroid hasn't moved `STUCK_PROGRESS_M
  = 5 m` in `STUCK_TICKS = 600` (30 s).
- **Arrived-mill skips stuck-check** (`7b02df9fce`). A squad
  within `ARRIVED_AT_TARGET_M = 25 m` of its objective's target
  refreshes its progress marker without force-expiring.
- **Investigate arrival-dwell cap** (`979c574ae5`, then
  `caeed82cfb`). After arriving at an Investigate target, the
  squad re-rolls after `INVESTIGATE_ARRIVAL_DWELL_TICKS = 1800`
  (90 s) rather than the full 4-min `expires_at` — keeps them
  from freezing on a spot.
- **Stuck-kind one-pick ban** (`942fae768b`). When stuck-detection
  expires an objective, the next `pick_objective` skips that kind
  for one roll so the squad doesn't immediately re-pick the same
  broken plan.
- **Disperse can unstick** (`7b02df9fce`). If disperse target is
  unreachable, the same `STUCK_TICKS` window clears
  `disperse_target` and falls through to normal needs-new path.

### Regroup behavior

- **Cohesion-break duration** (`3671e91af2`). 5 s → 30 s
  (`COHESION_REGROUP_DURATION_TICKS = 600`) so squads actually
  pull together before falling back to a movement objective.
- **Regroup early-exit** (`a38cb84afb`). When all members are
  within `REGROUP_GATHERED_RADIUS_M = 20 m` of rally,
  `expires_at` collapses to `now` so the squad re-rolls
  immediately instead of waiting the full 30 s.
- **Failed-Regroup disable** (`1d41c8868a`). When a Regroup hits
  its natural timeout without gathering (i.e. an unreachable
  outlier), `cohesion_break_disabled_until = now + 6000` (~5 min).
  `cohesion_pass` skips break detection during the window so the
  squad doesn't cycle Regroup ↔ Patrol every minute.
- **`last_regroup_exit_tick`** (`fbc05c3f70`). Split out the
  post-Regroup cooldown signal from `set_at_tick` so fresh-spawn
  squads aren't accidentally treated as "post-Regroup."

### Formation + peer-separation

- **Guard formation widened** (`6bc67d0f47`). Base radius 4 → 10 m
  with per-NPC ±2 m radius jitter so 3-NPC guard squads don't
  cluster within 3 m of each other.
- **Guard angle hashed per-NPC** (`1d41c8868a`). Was `slot =
  npc_id % 8` — large guard squads (8+ NPCs) had collisions.
  Replaced with continuous-angle hash so every NPC gets a unique
  position on the ring.
- **Rest formation widened** (`bcbd3c2e0c`). Same shape as Guard
  (10 m + jitter) instead of the prior 4–24 m band.
- **Peer separation strengthened** (`bcbd3c2e0c`).
  `SEPARATION_RADIUS_M` 2.5 → 3.5 m, `SEPARATION_NUDGE_M` 0.1 →
  0.3 m. Stacked NPCs visibly de-clump in ~1 s instead of ~30 s.

### Objective dwells (longer + more committed)

- **Objective durations** (`3671e91af2`):
  - Patrol 2 → 6 min
  - Wander 2 → 8 min
  - Investigate 2 → 4 min
  - Rest 4 → 8 min
  - Explore 10 → 12 min
- **Regroup cohesion duration** 5 s → 30 s (above).
- **Guard tenure cap** (`a873773a67`).
  `GUARD_TENURE_TICKS = 18000` (~15 min). Posted Guards re-roll
  after the cap so posts rotate through squads instead of being
  permanently held by one.

### Faction-wide aggro propagation

- **`LastKnownEnemyPos` arbitration candidate** (`30cffb5613`).
  When the squad blackboard has `LastKnownEnemyPos` (written by
  `EnemySighted` bus drain), goal-arbitration pushes an
  `InvestigateAt` candidate at priority 130 (between
  SquadObjective 80 and UnderFireAt 140) so squads near combat
  but without personal LOS still react.
- **Solo NPCs borrow same-faction intel** (`9b1320c758`).
  Ungrouped NPCs scan same-faction group centroids within 200 m
  and push the highest-priority blackboard candidate from any
  nearby squad into their own arbitration.
- **Responder cap** (`f074389522`). At most
  `RESPONDER_CAP_PER_TARGET = 3` distinct same-faction responder
  groups/solos per `(faction, target_cell_50m)`. Three squads
  reads as "cavalry arrived"; five-plus stripped the map.

### Online↔offline tier transitions

- **Aggro carry across boundary** (`fed2b1e39a`). `OfflineNpc`
  gained `aggro_target` + `aggro_last_seen_tick`. Online→offline
  sets `combat_state = Engaged { ... }`. Offline_movement skips
  travel-target selection for Engaged squads so firefights don't
  break mid-engagement. Offline_combat refreshes Engaged on
  proximity hits and ages out after 200 sim ticks.
- **Sim restart on `start` reentry** (`bd2e70c071`).
  `SimHost::start` tears down any existing worker before loading
  the new save_dir — switching runs from the runs screen no
  longer keeps the previous run's world.

### Relieve / Guard placement

- **Min guard spacing** (`62cd03cd36`, tuned `942fae768b`).
  `MIN_GUARD_SPACING_M = 30 m` — same-faction bases within 30 m
  of an already-claimed guard post can't be guarded by a new
  squad. Stops "two guards eyeballing the same spot."
- **Relief target dedup** (`18cb6b0b35`). Multiple squads can no
  longer all target the same post for Relieve; first claim wins,
  the rest fall through to Wander.
- **Evicted guards drift away** (`18cb6b0b35`). When relief swaps
  a holder out, the new Wander objective seeds
  `wander_drift_target ~80 m` away so they don't mill at the
  post for up to 10 s.
- **Rest no-fallback** (`610c7865ae`). `build_rest` returns None
  if every same-faction base is already claimed (was: fall back
  to unfiltered pool, creating pile-ups). Caller rolls Wander.
- **Rest + Guard honor `recently_visited`** (`f1b095d6d5`). Both
  builders filter against the squad's recent-position queue so
  the same squad doesn't re-pick the same base on every roll.

### Base capture

- **Investigate targets enemy bases** (`5deacbcf4b`).
  `build_investigate` prefers a hostile-faction non-HQ base in
  the squad's region over a random open-world point.
- **`base_capture_check` system** (`5deacbcf4b`). New per-3-s
  pass scans active-region bases; flips `InFaction` when
  defenders == 0 and ≥2 same-hostile-faction NPCs are within
  `CAPTURE_RADIUS_M = 40 m`. `BaseKind::Headquarters` is immune.
  Vacates GuardPosts claim, emits `BaseFlip` event + PDA toast.

### NPC self-care

- **NPC self-heal + close-mate medic** (`ae3ab96af8`). New
  `npc_treat_wounds` system runs at 1 Hz. NPCs with active
  untreated bleeds consume bandages / wound packs / tourniquets
  from their own inventory; if empty, a same-group mate within
  10 m provides one from theirs. `NPC_HEAL_COOLDOWN_TICKS = 60`
  per-applicator throttle.

### Combat visuals + safety

- **Straight tracers** (`86b9727d11`, `ad2a91d671`).
  `TRANS_LINEAR + EASE_IN` on the slide tween + shorter streak
  length so tracers read as a moving bullet trail, not a sweep.
- **Tighter cone-of-fire** (`86b9727d11`). 0.18 rad → 0.08 rad.
- **`add_child` before `global_position`** (`ac9afbb42a`).
  Node3D setter reads `get_global_transform()` internally and
  errors `!is_inside_tree()` on a freshly `new()`-d node. Pattern
  documented in CLAUDE.md → Critical Rules.
- **Freed-node race on tween chains** (`b4b80f4b35`). Scene reload
  frees in-flight tracer meshes; their tween callbacks survived
  and tripped `previously freed instance`. Untyped `Variant` read
  + `is_instance_valid` guard before typed bind.
- **Worker thread delta drain** (`f423afa0dc`). Forward
  `WorldDelta::ProjectileSpawned/Impacted` from the worker so the
  bridge can fire FX signals.

## Open issues (QA backlog)

Listed by user complaint, with the diagnostic I left off at.

### "Clumping always eventually happens, no matter what"

Despite all the above, dense same-faction populations still
visually cluster around the one base in their region. The root
cause is structural: 1 base × N squads = gravity well, and every
re-roll path (Rest, Guard, Wander outward + bias) eventually pulls
back. The drift bias and `recently_visited` filter mitigate it but
don't fix the underlying density.

**Next moves to try:**

1. **Denser POIs.** Bump POI baker `base_count` from 20 to
   40–60 so each region has multiple anchors. Single biggest
   lever — the sim-side tuning is already pushed about as far as
   it can go.
2. **Cross-region migration via Explore.** Currently bounded by
   the planner's per-region scope. A squad on Wander that
   reaches a region boundary could opt to cross instead of
   bouncing back. Needs `npc_portal_cross` extension.
3. **Wander → Patrol upgrade.** When a squad has been Wandering
   for a long stretch in a region with no recent action, roll
   them into Patrol with a longer route so they stay in motion
   on a recognizable circuit instead of organic-feeling
   drift-and-arrive.

### "Stuck in Pursue or Wander, often around bases"

The Wander side should be fixed by `caeed82cfb` (drift refresh
every tick). The Pursue side has not been addressed.

**Diagnostic to confirm next session:**

- Pursue is driven by `Aggro` component + `GoalKind::PursueTarget
  { target }`. The executor in `npc_goals.rs` walks toward the
  target's last-known position via `index.by_id[target].pos`.
- If the target is alive but at a position the NPC can't reach
  (across a wall, in a different region), the executor will just
  walk toward an unreachable point — no force-expire on Aggro.
- **Likely fix:** time-out `Aggro` if the target hasn't been
  seen-or-shot-by for some window. There's already
  `Aggro::last_seen_tick` and a 200-tick decay in `npc_aggro`,
  but it's tied to LOS reacquisition. Add a pursue-progress
  check: if the NPC hasn't gotten closer to `target.pos` in 30 s,
  drop Aggro entirely.

### "Abrupt goal changes — squads out doing something, then suddenly redirect"

User complaint that goals feel "unnatural" when they change. Some
sources:

- **Stuck-detection re-rolls** can fire after 30 s of no progress,
  which can interrupt a squad that's just slow.
- **Faction-aggro propagation** at priority 130 preempts
  SquadObjective at 80 (>20 hysteresis) — a distant gunshot can
  yank a Patrol squad off.
- **Wander drift target rolls** can be ~180° from the previous
  heading when the outward-bias fires.

**Next moves to try:**

1. **Smoother Wander drift.** Bias new leg angle toward the
   previous heading (within ±90°) unless outward-bias overrides.
2. **Wider hysteresis** for blackboard urgencies (20 → 30 ticks).
3. **"Commitment window"** — for the first N seconds after a
   SquadObjective is set, the same-source kind can't change.

### "Less guard post behavior since 15-min tenure"

`GUARD_TENURE_TICKS = 18000` makes posts rotate. With Phases A-F
of the **guard-system-plan.md** landed, this becomes structural:
multiple guard points per base means more visible guard coverage
even with rotation.

**Until that lands:**

- Consider bumping `GUARD_TENURE_TICKS` from 18000 (~15 min) to
  36000 (~30 min) so posts feel more permanent without being
  fully indefinite.
- Or: only auto-expire Guard when the squad is solo (1 NPC) —
  multi-member squads keep their post until relief.

### "Mass groups in Pursue keep clustering"

Faction-aggro responder cap is 3 squads per `(faction,
target_cell_50m)`. Three 4-NPC squads = 12 NPCs converging on one
target. Reads as a clump.

**Next moves:**

- Drop responder cap from 3 to 2.
- Spread responders by direction — pick the 3 closest from
  different bearings around the target so they encircle instead
  of converge from one side.

### "Online/offline cycling visible at first spawn"

The ±15 m projection jitter (`610c7865ae`) helps, but a squad
that was offline AT a base waypoint still spawns within ~30 m of
the base. The first-tick spawn-disperse seed kicks them out 60–
120 m. So they walk for 20–30 s after projection.

Probably acceptable as-is. If it still reads as "spawning then
sitting", look at the timeline between
`project_offline_to_online` and the first squad-planner tick that
sees the new groups.

### Solo NPC behavior post-grouping

With every NPC now in a Group (`a873773a67`), Wanderers should
roll Wander objectives like any other squad. Confirm in playtest
that Wanderers are actually moving — not just standing alone with
their synthetic group id.

### Faction-aggro propagation tuning

Currently:

- 200 m audible radius on `EnemySighted`.
- Priority 130 for `LastKnownEnemyPos` candidate.
- Cap of 3 responders.

The user has been generally happy with response, but if you see
"too many squads converging on one fight," drop priority to 110
(below the 20-hysteresis preemption threshold for
SquadObjective+20 = 100, so Patrol squads keep patrolling unless
the gunshot is closer than 130-prio worth of urgency).

### Capture mechanic edge cases

`base_capture_check` is freshly shipped. Open questions:

- What happens when the same base is being captured by *two*
  different hostile factions simultaneously? Currently the larger
  count wins on each 3-s scan; if counts tie, the lower-id
  faction wins (deterministic). That might thrash if numbers
  hover near each other.
- Should a captured base trigger a faction-wide alert (priority
  pull squads toward retaking it)? Not currently — the BaseFlip
  event broadcasts but no consumer in goal arbitration
  prioritizes "retake."
- Headquarters immunity: ensure all current test maps actually
  have a `BASE_HEADQUARTERS` (otherwise no flip-immune base
  exists and the entire region can flip).

## Files most likely to need touching next

- `crates/simn-sim/src/systems/squad_planner.rs` — every
  tuning constant + planner state lives here. The 2000+ line
  file is the heart of NPC behavior.
- `crates/simn-sim/src/systems/npc_goals.rs` — executor;
  `formation_offset` + per-NPC movement logic.
- `crates/simn-sim/src/systems/goal_arbitration.rs` —
  per-NPC goal priority resolution.
- `crates/simn-sim/src/offline_tier.rs` — projection +
  offline-tier movement/combat.
- `crates/simn-sim/src/systems/base_capture.rs` — new
  capture system, will need GuardPoints integration when
  Phase E of guard-system-plan lands.
- `godot/scripts/tools/poi_baker.gd` — POI/guard-point
  auto-generation. Phase D of guard-system-plan extends this.

## Useful one-liners for QA sessions

```bash
# Run the determinism harness — flush before any logic change to NPC tick path.
cargo test -p simn-sim --test determinism

# Run the long-running scenario suite (5+ min) before push.
cargo test -p simn-sim -- --include-ignored

# Fast feedback loop on a specific concern.
cargo test -p simn-sim --test npcs           # squad-planner + cohesion
cargo test -p simn-sim --test perception_sight  # aggro acquisition
cargo test -p simn-sim --test threat_board   # multi-target picks
```

```gdscript
# In-game debug overlay shortcuts (game_session.gd):
Ctrl+Shift+R    # wipe world + re-enter region — fresh seeded NPCs
F10             # density slider — scale population on the fly
```

## Notes on session ergonomics

- The branch is `sim-iteration-5-13` at handoff, 66 commits ahead
  of `main`. A PR for the whole anti-clump arc + the guard-system
  iteration is a reasonable place to consolidate; the chronicle
  here is the basis for the PR description.
- Every commit in the chain has a focused message — `git log
  --oneline` is the fastest way to scan the history.
- The hook gate (`.claude/hooks/pre-bash.sh`) blocks
  uncommitted work unless clippy + fmt + test markers are
  fresh. Run `cargo test -p simn-sim` near end-of-session to
  keep the test marker valid for push.
