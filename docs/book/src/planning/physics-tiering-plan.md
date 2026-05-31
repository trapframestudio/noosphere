# Physics Tiering - Planning Doc

**Status:** planning only, no implementation yet
**Last updated:** 2026-04-23
**Scope:** how physics objects are categorized, simulated, and replicated so that the world feels "truly reactive" across the full range of server/network capability - from a residential listen-server host on 30 Mbps upstream to a dedicated server on 1 Gbps. Companion to `physics-backend-plan.md` (backend abstraction + dedicated server binary) and `world-ledger-plan.md` (Tier 3 persistence).

This is a living design doc. It captures decisions and open questions; it is not a spec.

---

## 1. Guiding Principle

**Spectacle scales per-peer; truth does not.** The authoritative state of the world - what's destroyed, what's open, where the dropped pistol ended up - is the same for every player regardless of their connection. How much *motion* any given player sees in between state transitions is negotiated with their bandwidth and the server's compute headroom.

Consequence: we can hit "reactive world" without a fixed hardware requirement. A player on fiber sees a cinematic destruction scene; a player on congested Wi-Fi sees the outcome with fewer in-flight animation frames. Both agree on the result.

---

## 2. The Five Tiers

| Tier | Name              | Sim cost         | Replicated    | Persisted       | Examples                                      |
|------|-------------------|------------------|---------------|-----------------|-----------------------------------------------|
| 0    | Static baked      | zero             | no            | no (scene)      | Buildings, terrain, immovable scene props     |
| 1    | Settled dynamic   | collider only    | no            | no              | Bucket / chair at rest (server only wakes it on disturbance) |
| 2    | Active dynamic    | full rigid-body  | yes, priority | no              | Kicked barrel, tumbling gib chunk             |
| 3    | Persistent loose  | collider only    | transform only| yes (Ledger)    | Dropped weapon, corpse, migrated prop         |
| 4    | Transient effect  | client-only      | no            | no              | Shell casing, glass shard, blood decal        |

Tier assignment is dynamic. Every object starts at Tier 0 or Tier 1 and promotes on interaction.

### 2.1 Transitions

```
Tier 0 ──(state changed / damaged)──▶ Tier 1 OR Tier 3 (depending on prefab)
Tier 1 ──(impulse applied)──▶ Tier 2
Tier 2 ──(settled, |v| < ε for 1s)──▶ Tier 1 (inert) OR Tier 3 (persistent prefab)
Tier 3 ──(interaction)──▶ Tier 2 briefly, then back to Tier 3 or destroyed
```

**Rules:**

- Promotion to Tier 2 only on actual impulse (blast, projectile, kick, grab). Not on line-of-sight.
- Demotion from Tier 2 to its sleep tier is automatic after 1s below a small velocity threshold.
- If a Tier 2 body's settled position is outside its original region, demote to Tier 3 rather than Tier 1 (otherwise it would re-promote on every player visit).
- Tier 4 is never authoritative. The server doesn't know about it; clients manage locally.

---

## 3. Server-Side Budget (`PhysicsBudget`)

A resource that governs how many bodies can live at Tier 2 simultaneously on the authoritative server. Recomputed every 5s based on measured physics step cost.

```rust
pub struct PhysicsBudget {
    pub server_step_ms_ewma: f32,     // measured each tick
    pub tier2_ceiling: u32,            // computed
    pub hard_max: u32,                 // deployment config
    pub hard_min: u32,                 // deployment config
    pub target_step_ms: f32,           // default 25.0 (50% of 20Hz tick budget)
}
```

**Recalibration rule** (runs every 5s):

```rust
if ms > target * 1.2      -> tier2_ceiling *= 0.85     // aggressive back-off
else if ms < target * 0.6 -> tier2_ceiling *= 1.10     // cautious growth
// hysteresis band: no change in between
clamp to [hard_min, hard_max]
```

### 3.1 Starting bounds per deployment

| Deployment                  | hard_min | hard_max | Notes                                           |
|-----------------------------|----------|----------|-------------------------------------------------|
| Listen-server (residential) | 100      | 1,500    | Host CPU shared with client render              |
| Listen-server (fiber host)  | 200      | 2,500    | Higher upstream allows more replication         |
| Dedicated (8-core)          | 500      | 8,000    | Rapier multi-threaded, no render                |
| Dedicated (beefy, 16+ core) | 1,000    | 15,000   | Reserved for `showcase` RP community servers    |

Operator can override via config. Default auto-detects CPU cores and runs a quick Rapier benchmark on server start.

### 3.2 Eviction under pressure

When a tick ends with more Tier 2 bodies than `tier2_ceiling`, the budget system force-demotes the oldest-settled-ish bodies first, ranked by `1 - motion_magnitude + time_since_last_interaction`. Gameplay-critical bodies (combat projectiles, triggered traps) are exempt.

---

## 4. Per-Peer Replication Budget (`PeerBudgets`)

Even with the server simulating 3,000 Tier 2 bodies, we don't push all of them to every peer. Each peer has a separate byte/sec budget; the server fills it per snapshot with the most relevant bodies to that peer.

```rust
pub struct PeerBudgets {
    pub budgets: HashMap<PeerId, PeerBudget>,
}

pub struct PeerBudget {
    pub bytes_per_sec: u32,
    pub rtt_ms_ewma: f32,
    pub loss_ratio_ewma: f32,
    pub probed_bandwidth: Option<u32>,
    pub min_floor: u32,
    pub degraded: bool,
}
```

**Recalibration rule** (runs every 5s per peer):

```rust
if loss > 0.02 || rtt > 250ms   -> bytes_per_sec *= 0.80
else if loss < 0.005 && rtt < 100ms -> bytes_per_sec *= 1.10
clamp to [min_floor, peer_max_bps]
```

### 4.1 Default per-peer bounds

- `peer_max_bps = 500_000` (4 Mbps for physics; non-physics channels budgeted separately)
- `min_floor = 5_000` (50 bodies at 100 B/s each - the minimum "meaningfully reactive" threshold)

### 4.2 Bandwidth probing on join

On connect, a 15-second calibrated probe:

1. Server sends a step-up burst: 128 KB/s → 2 MB/s over 15s.
2. Peer ACKs delivered rate, reports median RTT and jitter.
3. Server seeds `probed_bandwidth` and sets `bytes_per_sec = probed * 0.6` (leaving headroom for non-physics channels).

Clients cache their probe result for 24h; reconnects honor the stored hint unless the peer opts into re-probing. Skipped probe + no stored hint → start at `min_floor` and let passive measurement ramp up.

---

## 5. Priority-Based Per-Peer Replication

Every Tier 2 body has a `ReplicationPriority` component:

```rust
pub struct ReplicationPriority {
    pub gameplay_weight: f32,
    pub ticks_since_sent: HashMap<PeerId, u32>,
    pub demoting_soon: bool,
}
```

On every snapshot tick (10 Hz for Tier 2 - physics doesn't need the 20 Hz rate), for each peer, score each body:

```rust
score(body, peer) =
    + w.distance  * 1.0 / (1.0 + body.distance_to(peer.player) / 50.0)
    + w.gameplay  * body.gameplay_weight
    + w.recency   * body.ticks_since_sent[peer] as f32
    + w.motion    * clamp(body.velocity.length() / 20.0, 0.0, 1.0)
    - w.demoting  * (body.demoting_soon as f32)
```

Sort descending, fill peer's per-tick byte budget (`peer.bytes_per_sec / 10`), stop when full. Bodies not sent get `ticks_since_sent` incremented so the recency term eventually forces an update even on the slowest link.

### 5.1 Starting weights (tunable, to be playtested)

```toml
[replication.priority_weights]
distance = 1.0
gameplay = 3.0      # strong - combat-relevant always wins
recency  = 0.1      # gentle starvation protection
motion   = 0.5      # favor things visibly moving
demoting = 2.0      # subtract, don't waste bandwidth on settling bodies
```

Gameplay weight is set by sim systems that know a body matters right now - damage-model raycasts, blast wave propagation, melee contact. Default gameplay weight for plain debris is 0.0.

### 5.2 Sent-body wire cost

Per-object update, quantized:

- Object ID: 4 B
- Position (three i16 at cm precision, region-local): 6 B
- Rotation (smallest-three quaternion, 10 bits per component + 2 bit index): 4 B
- Velocity (delta-compressed): ~3 B
- Flags (state, awake): 1 B
- **Total: ~18 B raw, ~10 B with delta compression**

At 10 Hz, that's ~100 B/sec per active object per peer.

---

## 6. Gameplay-Critical Lane

Three hard rules separate spectacle (priority-budgeted) from gameplay (always replicated):

1. **Gameplay-critical entities skip the priority budget entirely.** Players, NPCs, combat projectiles, open doors, triggered traps, breached walls. They use a reliable channel with no per-peer byte cap.
2. **State transitions are not priority-budgeted.** A wall changing `Intact → Destroyed` is a Tier 3 Ledger event, broadcast reliably to all peers regardless of their Tier 2 budget. The debris that flies is Tier 2 and scales per peer. The state transition is invariant; the motion in between is negotiated.
3. **No teleports, ever.** A Tier 2 body a peer doesn't receive updates for freezes at its last-known pose, then eases to its next reported pose with velocity-aware interpolation. When it finally settles, the authoritative Tier 3 row reaches every peer anyway.

---

## 7. Degradation Floor

When a peer's `bytes_per_sec` sustains at `min_floor` for more than 10 seconds - they can't support even the minimum 50 bodies of reactive physics - flip `degraded = true`:

- Peer stops receiving Tier 2 updates entirely.
- Client shows a non-intrusive "Degraded physics - authoritative state only" banner.
- Peer still receives all gameplay-critical replication and Tier 3 state normally.
- When loss/RTT recover for 10+ s, `degraded` flips back to false and Tier 2 replication resumes.

No kicks. A peer with a bad connection still gets a playable, coherent session - just a less cinematic one.

---

## 8. Client-Side Consumption

Clients receive Tier 2 body updates as priority-ranked streams. Handling:

- For every known Tier 2 body: interpolate to the latest reported pose over one snapshot interval.
- For Tier 2 bodies that didn't receive an update this snapshot: freeze at last known pose. When the next update arrives, ease (don't snap) over the now-stale interval.
- For bodies that transition from Tier 2 to Tier 3 (settle): the Ledger-broadcast final pose arrives on the gameplay-critical channel; client eases to it over the transition.

Client-side physics for severed limbs, Tier 4 debris, etc. is entirely local and never authoritative. The server doesn't know about it.

---

## 9. Measurement & Observability

The system is opaque unless we measure it. Required instrumentation:

- **Per-tick**: `server_step_ms` value that feeds the EWMA.
- **Every 5s**: `tier2_ceiling`, active Tier 2 count, demotion events, eviction count. Structured tracing.
- **Per-peer per-5s**: `bytes_per_sec`, `rtt_ms`, `loss_ratio`, `degraded` transitions.
- **Per-snapshot-tick**: for one sample peer, the ranking cutoff score (score of lowest-ranked body we sent) - tells us how much budget pressure exists.
- **Squall-triggered**: a dedicated log snapshot capturing Tier 2 peak, eviction count during peak, per-peer impact. Squalls are the worst case.

All logs under tracing target `physics.tier`, toggled with `RUST_LOG=physics.tier=info`.

---

## 10. Config (operator-facing)

```toml
[physics]
target_step_ms   = 25.0
recal_interval_s = 5.0

[physics.listen_server]
hard_min = 100
hard_max = 1500

[physics.dedicated]
hard_min = 500
hard_max = 8000

[replication]
physics_hz        = 10
peer_max_bps      = 500_000
peer_min_floor    = 5_000
degrade_timeout_s = 10

[replication.priority_weights]
distance = 1.0
gameplay = 3.0
recency  = 0.1
motion   = 0.5
demoting = 2.0

[replication.probe]
enabled        = true
duration_s     = 15
cache_hours    = 24
```

Auto-detect runs when operator hasn't set explicit bounds. Dial lives in the server config file only; players don't see it.

---

## 11. Interaction with Squalls

Squalls (see internal design notes) are the worst case for Tier 2 pressure - dozens of destructibles transitioning simultaneously, hundreds of gib chunks spawning at once. Expected behavior:

- Peak Tier 2 count spikes well above the steady-state ceiling.
- The budget system's aggressive-backoff rule kicks in within 5s, but the spike itself is sustained.
- Priority replication keeps each peer's experience focused on their immediate surroundings; distant Squall damage they can't see gets low ranking and is effectively skipped.
- Authoritative state transitions (which walls end up `Ruined`, which containers got scrubbed) reach every peer on the gameplay-critical channel regardless.

No special-case code for Squalls. The general system handles them correctly because it's priority-based, not fixed-cap.

---

## 12. Open Questions

- **Probe accuracy at the edge.** A 15-second probe overestimates for bursty connections. Do we add a "sustained" phase (hold at the peak for 30s before trusting it)? Costs join time.
- **Per-peer gameplay channel sizing.** Gameplay-critical replication is unbudgeted by design, but a malicious peer could generate load (spamming interactions). Rate-limit per peer on the server side.
- **Voice radio budget accounting.** Currently assumed ~8 KB/s baseline for in-world radio. Needs measurement once Steam VoIP integration lands. May require a dedicated channel pool rather than sharing the non-physics bucket.
- **Gib burst spike accounting.** A single Squall can spawn hundreds of Tier 2 chunks in one tick. Recalibration at 5s granularity can't react fast enough; chunks live ~2–5s each, so the spike completes before budget catches up. Needs a quick-eviction path on burst-spawn: if `tier2_count + incoming > ceiling * 1.5`, pre-demote the weakest already-active chunks.
- **Replication for Tier 3 transform changes.** When a Tier 3 object's settled position changes (a player drags a crate that wakes up and re-settles), does it broadcast through the gameplay-critical channel or wait for the next region-online refresh? Leaning toward gameplay-critical since players will expect immediate feedback.

---

## 13. Cross-References

- `physics-backend-plan.md` - how the Tier 2 bodies are actually simulated (GodotJoltBackend vs RapierBackend).
- `world-ledger-plan.md` - how Tier 3 state persists.
- `destruction-plan.md` - how state transitions drive tier promotion on wreckage.
- `loot-and-economy-plan.md` - dropped items as Tier 3.
- `../architecture/networking.md` - current replication story; this doc is the next milestone.
- `../walkthroughs/sim.md` - the sim tick loop and journal+snapshot that this plugs into.
