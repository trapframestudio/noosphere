# Funding Model

> **Status: direction, not finalized terms.** The legal entity, exact
> revenue-share numbers, and contributor agreements are being set up with
> professional counsel. This chapter describes intent. Nothing here is a
> binding offer until the entity and signed agreements exist.

Noosphere is an experiment: build a game **in the open** and fund it
**sustainably**, without microtransactions, ads, investors steering the
design, or asking the community to work for free. The mechanism is a deliberate
split between *code* and *content*.

## The split

| Layer | What | License | Why |
|---|---|---|---|
| **Code** | Engine bridge, world simulation, terrain, networking, tooling, systems/mechanics data | [MIT](../../../../LICENSE-MIT) or [Apache 2.0](../../../../LICENSE-APACHE), permissive | Anyone can learn from it and build their **own** game on it, commercial or not. The commons is the engine; what's protected is the content and brand. |
| **Creative content** | World, art, audio, story, lore, faction names | [Noosphere Content License](../../../../LICENSE-ASSETS.md) — proprietary | This is *Noosphere*. It's the thing being sold, and the thing that can't be cloned. |
| **Brand** | The "Noosphere" name, logos | [Trademark policy](../../../../TRADEMARK.md) | Build on the code, but call your project your own thing. |

The short version — **the code is the commons; the game is the product.** You can
take the engine and systems and make a completely different game with your own
IP. You cannot take *Noosphere* — its world, its art, its name — and ship it.

## Why a paid game (and why open code doesn't break that)

The finished, assembled game is sold on **Steam** as a **one-time purchase**.
That revenue funds development. There are **no microtransactions, no
pay-to-win, no live-service grind** — consistent with the design canon
(the design overview, §9). You buy the game once; you own it.

"But the code is public — can't people just compile it for free?" They can
compile the *engine*. What they can't get for free is the *game*: the
proprietary art, audio, world, and story that make Noosphere worth playing, plus
the convenience of an official, maintained, auto-updating build with official
multiplayer. This is the same model that has worked for other commercial
open-source games — the moat was never code secrecy. It's the **content**, the
**brand**, and the **official build**.

## Where the money goes

Steam revenue (after platform fees, taxes, and operating costs) funds two
things:

1. **Development** — keeping the lights on, the servers running, and the work
   moving.
2. **A contributor pool** — a share of revenue flows back to the people whose
   merged work makes the game better. See
   [Contributor Revenue](contributor-revenue.md).

The intent is a virtuous loop: the game earns, contributors are paid, more good
work lands, the game gets better, the game earns more.

## How this is held together (legally)

- A **legal entity** (an LLC) owns the IP and trademark, signs the Steam
  agreement, holds the revenue, and pays contributors. Setup is tracked in
  Legal Structure.
- Contributions are accepted under a **[Contributor License Agreement](../../../CLA.md)**
  so the project can ship your work in the paid game and pay you for it. You keep
  your copyright.
- Revenue share is governed by a **separate signed agreement**, not by this
  document.

## Goals and non-goals

**Goals**

- A genuinely community-driven game that can also *pay* the people who build it.
- An open codebase the wider Godot + Rust + survival-sim community can learn
  from and build on.
- A clear, honest path from contributor → maintainer → paid teammate.

**Non-goals**

- Not free-to-play, not ad-supported, not microtransaction-funded.
- Not a donation/tip-jar project (though that may complement it later).
- Not crowd-equity or token-based. Revenue share is compensation for work, not
  an investment offering.

## Related

- [Contributor Revenue](contributor-revenue.md) — who shares, and how it's weighted.
- Legal Structure — the entity and the open legal questions.
- [GOVERNANCE.md](../../../GOVERNANCE.md) — how decisions get made.
