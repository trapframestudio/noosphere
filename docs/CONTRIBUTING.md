# Contributing

Hey, thanks for being interested. Noosphere is an open source co-op
survival game built on Godot 4.x with a Rust core via gdext, set in an
affected stretch of the Columbia River Gorge. Strugatsky-flavored horror
over a S.T.A.L.K.E.R.-lineage PvE-first co-op survival sim, in an original
world built from scratch.
Contributions of all sizes are welcome: gameplay systems, simulation
work, docs, bug reports, the works.

This file is the short version. The long version will eventually live in
the docs site under `docs/book/src/contributing/`.

## Before you dive in

- Skim [`GOVERNANCE.md`](GOVERNANCE.md) so you know how decisions get made.
- Read [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) - applies everywhere with
  the Noosphere name on it.
- Skim [`CLAUDE.md`](../CLAUDE.md) for code conventions and the crate layout.
  It's written for an AI assistant but the rules apply to humans too.
- Check open issues, especially `good first issue` and `help wanted`.
- **Know the deal.** Noosphere's **code is open source (MIT or Apache 2.0)**, but the game
  is sold to fund development and **contributors share in the revenue**. That
  means two things for you: (1) contributions are accepted under a
  [Contributor License Agreement](CLA.md) - a bot will prompt you on your first
  PR; and (2) the Noosphere **creative content** (art, audio, world, lore,
  faction names) is proprietary under the
  [Noosphere Content License](../LICENSE-ASSETS.md) - don't reuse it elsewhere,
  and don't submit third-party assets. See the
  [funding model](book/src/project/funding-model.md) and the
  [contributor revenue model](book/src/project/contributor-revenue.md).

## Two repos: the engine vs the game

Noosphere is built on **SIMN**, a reusable Rust sim engine that lives in its own
public repo: <https://github.com/trapframestudio/simn>. Where your contribution
goes depends on what it touches:

- **Engine work** (anything in `simn-common`, `simn-sim`, `simn-terrain`,
  `simn-net`, `simn-godot`) goes to the **SIMN repo**, under its
  [CONTRIBUTING](https://github.com/trapframestudio/simn/blob/main/CONTRIBUTING.md).
  In this game repo the engine is vendored read-only into `godot/addons/simn/`
  (run `./scripts/sync-simn.sh` first), so you don't edit it here. To work on the
  sim against the game, link a local SIMN clone in; see
  [the SIMN addon workflow](book/src/walkthroughs/simn-addon.md).
- **Game work** (Godot scenes/GDScript, the content overlay in `godot/content/`,
  game docs) goes here.

## How contributions are governed

This is a maintainer-gated project. For now:

- **Every change goes through a PR.** No direct pushes to `main`.
- **A maintainer reviews and merges.** A new contributor's PR needs a
  maintainer's approving review (you can't approve your own), and only
  maintainers merge to `main`.
- The **SIMN repo enforces this on GitHub** via a branch ruleset (required PR +
  review, blocked force-push/deletion, merges restricted to maintainers). This
  game repo is private today, so it enforces the same intent through the
  pre-push hook (see `CLAUDE.md`) plus this policy; the GitHub ruleset goes on
  once the game moves to its public home at
  <https://github.com/trapframestudio/noosphere>.

## Ground rules

A small number of things we're strict about:

- **Engine-agnostic core stays engine-agnostic.** `simn-common`,
  `simn-sim`, `simn-terrain`, and `simn-net` must compile without
  `godot`. Only `simn-godot` depends on gdext. This is the most
  important rule in the project. (It's enforced in the SIMN repo, where
  that code lives; touch the engine there, not in the vendored copy.)
- **Clippy-clean.** `cargo clippy --workspace -- -D warnings` must pass.
- **Formatted.** `cargo fmt --all` before committing.
- **No `unwrap()` in library code**, use `?` or `anyhow::Result`.
  Tests are fine.
- **Never panic into Godot.** All `#[func]` methods handle errors
  gracefully.
- **No third-party game assets in commits, ever.** Test fixtures must
  be original or generated. The repo stays clean.

## Workflow

1. **Find or open an issue.** For anything non-trivial, get rough agreement
   on the approach before writing code. Protects your time.
2. **Fork and branch.** Names like `feat/sim-faction-graph`,
   `fix/networking-tickrate`, `docs/modding-overview`.
3. **Write the change.** Keep PRs focused - one logical thing per PR.
4. **Test it** (run `./scripts/sync-simn.sh` first if you haven't, so the
   vendored engine is present):
   - `cargo test --workspace`
   - `cargo clippy --workspace -- -D warnings`
   - `cargo fmt --all -- --check`
   - `mdbook build docs/book` if you touched docs
5. **Update the docs.** If a user or modder can see the change, update the
   relevant chapter under `docs/book/src/`. There's a file → docs mapping
   in `CLAUDE.md`.
6. **Open a PR.** What changed and why. Link the issue. On your first PR a
   CLA bot will ask you to accept the [Contributor License Agreement](CLA.md);
   it has to pass before the PR can merge.
7. **Respond to review.** Reviewers will be direct but kind. If you
   disagree, push back - review is a conversation.

## Commit messages

Format: `area: short summary in lowercase`. Examples:

```
sim: faction graph and offline tier scheduler
godot: gdext bridge for player input
docs: design vision update
```

Keep the subject under ~72 chars. Body is optional but helpful for
non-obvious changes - explain *why*, the diff already shows what.

## Where things live

| Area | Where | What's in there |
|---|---|---|
| **Engine (all `simn-*`)** | **[SIMN repo](https://github.com/trapframestudio/simn)** | Sim, terrain, net, common, gdext bridge. Vendored here read-only at `godot/addons/simn/`; contribute upstream. |
| Godot project | `godot/` | Scenes, GDScript UI, addon plugins |
| Game content | `godot/content/` | The proprietary content overlay (factions, names, chatter, tuned mechanics) |
| Docs | `docs/book/` | mdbook documentation site |

If you're not sure where something belongs, ask in the issue.

## What's welcome

**Always:**

- Bug fixes with a test that reproduces the bug.
- Doc improvements, especially tutorials and onboarding.
- Performance wins with a benchmark to back them up.
- Test coverage.

**Welcome but talk to us first:**

- New crates or major refactors.
- Changes to crate boundaries or public APIs.
- New gameplay systems.
- Build system or CI changes.

**Probably won't merge:**

- Drive-by formatting / style changes unrelated to a real fix.
- New dependencies without justification.
- Anything that breaks the engine-agnostic rule for `simn-sim` or `simn-common`.
- PRs that ship third-party game assets of any kind.
- "Improvements" without a clear problem statement.

## Getting unstuck

- **PR question?** Comment on the PR or its issue.
- **Design question?** Open an issue or discussion.
- **Found a bug?** Issue with steps to reproduce.
- **Security thing?** See [`SECURITY.md`](SECURITY.md). TL;DR while the repo
  is private, file an issue with a `security` label or DM Jon.

## Credit and revenue share

Contributors get listed in [`CREDITS.md`](CREDITS.md) and via git history.
Sustained contributors in a specific area may get invited to maintain it
(see `GOVERNANCE.md` for what that means).

The final release is a paid game, and trapframe intends to share part of the
proceeds with the people who built it, across every discipline: code, art,
writing, audio, design, QA, and more. Accepted and shipped contributions may be
eligible for a contributor pool, gated on signing the Contributor License
Agreement, and the strongest contributors can be invited onto a paid team. The
framework, including how contribution weight is measured fairly across
disciplines, is in [Contributor Revenue](book/src/project/contributor-revenue.md).

That document is principles only. It sets no percentages or payout terms, and it
is not a contract or an offer. Nothing is binding until trapframe's legal entity
exists and counsel has reviewed it. Contribute because you want to build the
game; the pool is intent, not a promise.

Thanks for helping build this.
