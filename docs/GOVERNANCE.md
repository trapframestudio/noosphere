# Governance

Status: **v0.1 - it's just Jon right now**
Last updated: 2026-04-06

How decisions get made on Noosphere. This is short on purpose. We'll grow it
when the project actually needs more structure, not before.

## The vibe

- **Decisions happen in public.** Issues, PRs, ADRs, project chat. If a
  decision got made off-channel, it gets written up after.
- **Code, docs, and rules are the same thing.** If a rule isn't written
  down, it isn't a rule.
- **Boring is good.** Process exists to remove ambiguity, not to perform
  Serious Open Source Project.
- **Contributors get treated like adults.** Clear standards, honest review,
  no busywork.

## Who's in charge

Just one person right now:

- **Jon Iler** ([@joniler](https://github.com/joniler)) - project lead, BDFL,
  whatever you want to call it.

This is a deliberate choice. The project is too young to benefit from a
council and pretending otherwise would be cosplay. Jon has final say on
technical and project direction, and in exchange commits to:

- Reviewing PRs in a reasonable timeframe.
- Saying *why* when rejecting something.
- Writing down non-obvious decisions in ADRs.
- Handing off authority as the project grows (see below).

## Roles

**Contributor** - anyone who's had a PR merged. No application, no
ceremony. You get credit in `CREDITS.md` and git history. Because the finished
game is sold to fund the project, merged contributors also become eligible for
the contributor revenue share, and sustained contributors can be invited onto
the paid team - see [Licensing](#licensing) below and
[contributor-revenue.md](book/src/project/contributor-revenue.md).

**Maintainer** - a contributor who's been given merge rights for a specific
area. Maintainers review and merge PRs in their area, triage issues, and
get listed in `CODEOWNERS` (when that file exists). Nominated by Jon based
on a sustained track record. The bar is "I'd trust this person to merge
here without me looking."

**Project lead** - currently Jon; eventually a small council. Cross-cutting
decisions, dispute resolution, keeping the direction coherent.

## How decisions get made

**Day-to-day code changes:** standard PR workflow. A maintainer in the
relevant area reviews and merges. Small stuff: one approval. Anything
touching crate boundaries, format schemas, or public APIs also needs Jon.

**Bigger architectural calls:** anything that changes how crates fit
together, public APIs, data flow, or how mods touch the engine gets an
**ADR** under `docs/book/src/adr/`. Open a PR with status `Proposed`,
discuss, get marked `Accepted` or `Rejected`. Accepted ADRs are immutable
except for status changes - don't edit history, write a new ADR that
supersedes the old one.

**Roadmap and priorities:** lives in `PROJECT_PLAN.md` and GitHub Projects.
"What should I work on?" is always a fair question and you'll get an
honest answer.

**When two contributors disagree** and can't sort it out in the PR:

1. Try harder. Most disagreements are misunderstandings about the goal.
2. Ask the area maintainer to call it.
3. Still stuck? Jon decides, and the decision gets written down.

Jon's decisions are final but not unaccountable - the maintainer council
exists in part so bad calls have a way of getting overruled later.

## Growing up

Single-maintainer is a phase, not a destination. We move to a maintainer
council when *any* of these happen:

- Three or more sustained contributors with merge rights in distinct areas.
- Jon is consistently the bottleneck on PR review.
- Jon wants out, partially or fully.

The council will roughly look like: one seat per major area (parsers,
engine bridge, networking, scripting, gameplay, docs/community), decisions
by rough consensus, project lead breaks ties during transition. We'll
ratify the actual shape via ADR when it happens. Until then, the BDFL
phase is in effect.

## What this isn't

- **Not a foundation.** Noosphere is becoming a **single legal entity** (an
  LLC) that owns the IP and trademark and signs the storefront agreement - not
  a member-governed nonprofit foundation. Direction stays with the project lead
  (see above), not a membership body. Entity setup is tracked in
  internal planning notes.
- **Not a democracy.** Contributors don't vote on direction. They influence
  it by contributing and being persuasive.
- **A funded commercial project, openly built.** The game is sold to fund
  development, and contributors share in that revenue. That commercial reality
  is now explicit (see [Licensing](#licensing) and the
  [funding model](book/src/project/funding-model.md)). The project still
  optimizes for player experience and contributor health - the funding exists
  to *sustain* that, not to override it.

## Licensing

Noosphere uses a **split license**:

- **Code → MIT OR Apache-2.0** (permissive, open source). The Rust workspace,
  GDScript, build files, and systems/mechanics data. Use it for anything,
  commercial or not. The creative IP is what's proprietary, not the engine.
- **Creative content/IP → proprietary** ([Noosphere Content License](../LICENSE-ASSETS.md)).
  Art, audio, world, story, lore, faction names. Protected by trademark
  ([TRADEMARK.md](../TRADEMARK.md)).

**A CLA is now required.** Because the game is sold commercially and combines
open code with proprietary content, contributions are accepted under a
[Contributor License Agreement](CLA.md): you keep your copyright and grant the
project broad, sublicensable, commercial rights. This is what lets the project
ship your work in the paid game and pay you for it. Signing is expected to be
automated via a CLA bot on pull requests. (This supersedes the project's earlier
"no CLA" stance, which applied before the commercial pivot.)

No third-party game assets in the repo, ever. PRs that include
copyrighted third-party content of any kind will get bounced. See the
Legal section of the README for the full disclaimer.

## Compensation

The final release is a paid game, and **Trapframe Studio LLC** (a Colorado LLC,
in formation) intends to share part of the proceeds with contributors across
every discipline, weighted by contribution. The model is a public, append-only
**contribution ledger**: accepted work earns **points** (tagged to a project),
and points entitle you to a share of the relevant revenue **pool** each quarter.
Most contributors are **Standard Contributors** (royalty-only); sustained
contributors can be nominated to become **Core Contributors** (royalty + LLC
equity) through a public, voted process.

The mechanics, point scale, bucket waterfall, and pools are drafted in the
[Contributor Royalty Agreement](CONTRIBUTOR_ROYALTY_AGREEMENT.md) (Exhibit A) —
currently a **v0.1 skeleton, not reviewed by counsel and not for signing**. The
intent/principles are in
[Contributor Revenue](book/src/project/contributor-revenue.md). Nothing is
binding until the legal entity exists, the agreement is finalized, and counsel
signs off.

## Code of Conduct

[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Applies everywhere with the
Noosphere name on it. Reports go to Jon - see the CoC for how.

## Changing this doc

PR + Jon's approval. Once the council exists, governance changes will need
council approval and a discussion period (to be specified in the
transition ADR).
