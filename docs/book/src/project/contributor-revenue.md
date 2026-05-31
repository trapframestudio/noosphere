# Contributor Revenue

> **Status: principles, not a binding offer.** This chapter describes *how the
> contributor revenue share is intended to work*. The concrete percentages,
> point scale, and pools now live in the
> [Contributor Royalty Agreement](../../../CONTRIBUTOR_ROYALTY_AGREEMENT.md) —
> currently a **v0.1 draft skeleton that has not been reviewed by counsel and is
> not for signing**. Until that agreement is finalized and signed, **any payment
> is discretionary**. Don't contribute *expecting* money; contribute because you
> want to build the game, and know that if it succeeds, there's a real, intended
> mechanism to share that success with you.

## Why this exists

Most open-source projects ask for volunteer labor and offer credit in return.
Noosphere sells the finished game, so it can offer more than credit: **a share
in the game's success.** The point is to make community contribution
*sustainable* — to let people who pour real work into Noosphere be paid for it,
and to build a path from casual contributor to paid team member.

This is funded by game revenue (see [Funding Model](funding-model.md)), and it's
made legally possible by the [CLA](../../../CLA.md), which gives the project the
rights it needs to ship your work in the paid game.

## Who qualifies

The bar is **merged, quality-gated, sustained contribution** — not activity for
its own sake. In principle:

- **Eligible:** work that lands in `main` and meets the project's standards —
  gameplay systems, simulation work, tooling, performance, content pipelines,
  documentation, art/audio that the project accepts, and the review/maintenance
  labor that keeps quality high.
- **Weighted toward impact, not volume.** A small, load-bearing fix can matter
  more than a large mechanical change. Drive-by noise, churn, and
  AI-slop-without-judgment don't count.
- **Quality is gated** by the same review, CI, clippy/fmt, test, and docs
  standards every contributor already meets (see `CONTRIBUTING.md` and
  `CLAUDE.md`). The revenue share rewards work that *clears* the bar, not work
  that's merely submitted.

## How contribution is weighted (concept)

The intended model is a **contribution-weighting** approach, not a flat
per-PR bounty and not "everyone splits evenly." The weighting is meant to
reflect, roughly:

- **Impact** — how much the change moves the game (a maintainer's judgment,
  visible in review).
- **Scope and difficulty** — what it took to do well.
- **Sustained involvement** — ongoing maintainers and reviewers, not just
  one-time drops.
- **Role** — building, reviewing, triaging, and maintaining are all
  contribution.

The exact rubric, the size of the pool, vesting, and payout cadence are
**intentionally not fixed here.** Locking numbers in public before the entity
and counsel exist would read as a binding promise and create legal and tax
problems. They will be set in the Contributor Agreement and may evolve.

## Fairness across disciplines

This is not a code-centric system. A shipped art pack, a lore arc, a music cue,
or a design doc that gets built is a first-class contribution alongside an
engineering feature. The model is built so artists, writers, audio people, and
designers get a fair shake, not an afterthought.

It works like this:

- **One unit, many disciplines.** Everything resolves into a single
  discipline-agnostic unit, *contribution credits*. Code, art and 3D, writing
  and lore, audio, design, QA, tooling and infrastructure, and translation and
  community work each have their own intake and their own published rubric, and
  each earns credits in the same currency.
- **Hybrid scoring.** Automated signals are used where real data exists (git
  history and review records for code and tooling). Everywhere else, the
  relevant discipline lead scores the work against the rubric. In every case a
  human adjusts for impact. The automated number is a starting point, never the
  final word.
- **A parity council** of discipline leads calibrates the rubrics against each
  other so comparable effort earns comparable credit: a major art pack should
  land near a major feature, which should land near a major lore arc. Parity
  guidelines are published and reviewed each period, because this is the part
  most likely to feel unfair and most likely to drift.
- **Impact, not volume.** No paying by lines of code, word count, or asset
  count. All three are gamed easily and reward bulk over value.

## The path: contributor → maintainer → paid team

Noosphere wants its best modders and contributors to *become the team*:

1. **Contributor** — you've had a PR merged. Credited in `CREDITS.md`; eligible
   for the revenue share once the agreement is live.
2. **Maintainer** — sustained, trusted work in an area earns merge rights there
   (see `GOVERNANCE.md`). More responsibility, more weight.
3. **Paid team** — the strongest, most consistent contributors can be invited
   into a formal paid role. This is hiring, with everything that implies
   (agreement, tax status, expectations).

## The honest caveats

- **Nothing is owed until it's signed.** This document is intent. The
  Contributor Agreement is the binding instrument.
- **Revenue share depends on revenue.** If the game earns little, the pool is
  little. This is a share of *success*, not a salary or a guarantee.
- **It's compensation for work, not an investment.** You are not buying equity
  or a token, and you are not promised a return on a contribution. (Structuring
  it otherwise would raise securities issues — see
  Legal Structure.)
- **Tax and payment logistics are real.** Payments mean tax forms
  (e.g. W-9/W-8) and payment rails, and cross-border contributors add
  complexity. Details come with the agreement.

## Status & how to follow along

The Contributor Agreement, the pool size, and the payout mechanics are open
items, sequenced in Legal Structure.
When they're ready, this chapter will link to the signed terms. Questions are
welcome — open a discussion.
