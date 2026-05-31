# Trapframe Contributor Royalty Agreement

**v0.1 SKELETON — DRAFT, May 29, 2026**

> **THIS IS A DRAFTING SKELETON, NOT A LEGAL DOCUMENT.** It is a structured
> starting point intended to make a productive first meeting with counsel
> possible. It has not been reviewed by an attorney. **Do not sign it, ask anyone
> else to sign it, or rely on it as binding.** Provisions are intentionally
> annotated in **[BRACKETS]** to flag jurisdiction-specific or fact-specific
> items. A Colorado-licensed business attorney with experience in
> royalty/licensing and securities-exemption work should review and finalize
> every section before adoption. Trapframe should also have counsel review
> whether a separate Contributor License Agreement (for IP/copyright) and this
> Royalty Agreement (for compensation) should be combined into one document or
> kept as two — counsel preferences vary.

## Plain-English summary (read this first)

If you contribute work to Trapframe (code, art, design, writing, sound, QA,
anything we accept into our games or engine), we award you **points** in a public
ledger. Those points entitle you to a slice of the relevant revenue pool every
time we distribute. You are not buying in, you are not becoming an owner, and you
are not investing — you are being paid for the work you do, the same way a session
musician is paid royalties on a record.

**Five things to know before you sign:**

- **Game contributions** (Noosphere story, art, audio, lore, game-specific code)
  become Trapframe's proprietary IP. We need clean ownership to ship the game and
  not get sued.
- **Engine and open-source contributions** (SIMN, and any project we publish under
  an open-source license) stay yours. You retain copyright; you license your
  contribution to us and to the world under the project's OSS license. Anyone —
  including you — is free to fork the open-source projects and build something
  different. We can never re-license your merged OSS contribution into a
  proprietary-only future version.
- **Your royalty rights are personal.** You cannot sell or assign them, except to
  your estate if you die — they stay with you.
- **Payment is quarterly,** after we get paid by the storefront. No salary, no
  advance, no guarantee that the game makes any money.
- **Nothing here stops you from making your own games or tools,** even ones that
  compete with ours, as long as you don't copy our proprietary content (story,
  art, characters, lore).
- If you stick around and your work shows real depth and durability, you can be
  nominated to become a **Core Contributor** — actual LLC equity (Class B profits
  interests, vesting over four years) plus a share of a dedicated Core Contributor
  profits bucket, on top of the royalties you already earn. The criteria are
  public and the vote is real. Becoming a Core Contributor is **not** granted by
  this Agreement; it's a separate process and a separate signed document.

Read the rest if you want the legal details. Ask questions in our community
channel before you sign — that's what it's there for.

---

## Contributor Royalty Agreement

This Agreement is made between **Trapframe Studio LLC**, a Colorado limited
liability company (the "Studio"), and the individual identified in the signature
block (the "Contributor"), and governs all contributions the Contributor submits
to any project owned or operated by the Studio. By default, the Contributor is a
**Standard Contributor** (royalty-only). Contributors who later become **Core
Contributors** (royalty + equity) sign an additional Core Contributor Equity
Grant Agreement; this Royalty Agreement continues to govern their
contribution-point earnings.

### 1. Definitions

- **"Contribution"** means any work, in any medium — including but not limited to
  source code, art assets, audio assets, written materials, design documents,
  level data, bug reports with reproducible cases, and QA reports — that the
  Contributor submits to a Studio repository, asset pipeline, or community channel
  for inclusion in a Studio project.
- **"Project"** means a software, game, or engine project owned or operated by the
  Studio. Initial Projects include Noosphere (a game) and SIMN (a
  simulation/networking engine). Projects are designated by the Studio as either
  **Proprietary Projects** (commercial products, with Studio-owned IP — e.g.,
  Noosphere) or **Open-Source Projects** (released under a published open-source
  license — e.g., SIMN). The Studio maintains and publishes the list of Projects
  and their designations in its public GitHub organization.
- **"Accepted Contribution"** means a Contribution that has been merged,
  integrated, or otherwise accepted into a Project by a maintainer authorized to
  accept work for that Project.
- **"Ledger"** means the public Trapframe contribution ledger, maintained by the
  Studio as an append-only record at a location designated by the Studio
  (initially: a file in the public GitHub repository at github.com/trapframestudio).
- **"Points"** means entries in the Ledger awarded for Accepted Contributions,
  tagged to one or more Projects.
- **"Pool"** means a Project-specific or Project-class-specific revenue allocation
  determined under the Studio's then-current Operating Agreement and Distribution
  Policy. The current Pools are: the SIMN engine pool, the Core Contributor
  profits pool, and one game contributor pool per shipped game (e.g., the
  Noosphere pool).
- **"Standard Contributor"** means any Contributor who is not a Core Contributor.
  Standard Contributors participate in the SIMN engine pool and game contributor
  pools under this Agreement; they do not hold equity in the Studio.
- **"Core Contributor"** means a Contributor who has been admitted to that status
  under the procedures set out in the Studio's Operating Agreement and who has
  signed a Core Contributor Equity Grant Agreement. Core Contributors hold Class B
  profits interests in the Studio (subject to vesting), additionally participate
  in the Core Contributor profits pool, and continue to earn royalty payments
  under this Agreement on the same terms as Standard Contributors. The criteria,
  nomination process, comment period, and vote required to become a Core
  Contributor are published in the Studio's public governance repository.
- **"Net Revenue"** means revenue received by the Studio from a storefront or
  distributor, after the storefront's commission and after refunds and
  chargebacks, calculated quarterly.
- **"Distribution Period"** means a calendar quarter.

### 2. Acceptance of Contributions; Award of Points

(a) The Studio is not obligated to accept any Contribution. Decisions to accept or
reject Contributions rest with the Studio's maintainers and are guided by the
Studio's published creative and technical direction.

(b) Upon acceptance of a Contribution, the accepting maintainer will propose a
point award in the Ledger using the point scale defined in the Distribution
Policy. A second maintainer must confirm the award.

(c) Disputed point awards are resolved by the Studio's Core Contributors, with
appeal to the Studio's managers. The resolution is recorded publicly in the
Ledger.

(d) Points are non-revocable except as set out in Section 9 (Misconduct).

### 3. Royalty Compensation

(a) In consideration of the Contributor's Contributions, and as compensation for
services rendered, the Studio agrees to pay the Contributor a share of each Pool
to which the Contributor's Points are tagged, calculated as follows:

> (Contributor's Points in Pool ÷ Total Points in Pool) × Pool's allocation of Net
> Revenue for the Distribution Period

(b) Pool allocations are governed by the Distribution Policy attached as Exhibit A
and may be amended only as provided in the Studio's Operating Agreement. The
Contributor acknowledges that the Distribution Policy is incorporated by reference
and that the Studio is bound by it.

(c) Payments are made within sixty (60) days after the close of each Distribution
Period. Payments below a minimum threshold (currently US$25) accrue and are paid
when the cumulative balance exceeds the threshold.

(d) The Contributor is solely responsible for taxes owed on royalty payments. The
Studio will issue Form 1099-NEC, Form 1099-MISC, or Form 1042-S, as applicable,
and will withhold treaty-rate taxes on payments to non-U.S. Contributors as
required by law.

(e) The Studio will provide the Contributor with quarterly statements showing: (i)
the Contributor's Point balance per Pool, (ii) each Pool's allocation, (iii) the
Contributor's calculated share, and (iv) any deductions.

### 4. No Investment, No Securities Offering

> This Section is the linchpin of the structure. It is what keeps the Royalty
> Agreement out of securities-law treatment. **Counsel should review this language
> word-by-word** against current SEC guidance and applicable state blue-sky law.

(a) The Contributor acknowledges and agrees that: (i) no payment of money or other
consideration is being made by the Contributor to the Studio in exchange for this
Agreement; (ii) the royalty rights granted under this Agreement are compensation
for services rendered (Contributions), and not an investment in the Studio or any
Project; (iii) the royalty rights do not constitute equity, membership interest,
partnership interest, debt, or any other form of ownership interest in the Studio;
and (iv) the royalty rights do not entitle the Contributor to vote, govern,
manage, or direct the Studio.

(b) Both parties intend that this Agreement is not an investment contract,
security, or financial instrument under the U.S. Securities Act of 1933, the
Securities Exchange Act of 1934, applicable state blue-sky laws, or comparable
laws of the Contributor's country of residence. The parties intend the same
characterization for all tax purposes.

(c) The Contributor agrees not to characterize, market, or transfer the royalty
rights in a manner inconsistent with this characterization.

### 5. Non-Transferability

(a) The royalty rights granted under this Agreement are personal to the
Contributor and may not be sold, assigned, pledged, encumbered, securitized, or
otherwise transferred, in whole or in part, except by operation of law to the
Contributor's estate upon the Contributor's death.

(b) Any attempted transfer in violation of this Section is void. Points held by a
deceased Contributor remain in the Ledger; royalty payments continue to the
Contributor's estate, identified by court-issued documentation, for the life of
each Project's commercial exploitation.

(c) The Studio will not maintain or recognize any secondary market for the royalty
rights and reserves the right to terminate payments to any person who attempts to
create one.

### 6. Intellectual Property

> Section 6 is the centerpiece of Trapframe's relationship to its contributors and
> the OSS community. Proprietary game content is assigned to the Studio.
> Open-source contributions are **licensed** to the Studio (not assigned), the
> Contributor retains copyright, and the work remains available to anyone under
> the project's published open-source license. **Counsel must align this Section
> with the actual license files committed to each Open-Source Project repository.**

(a) **Project classification.** Each Project is designated by the Studio as either
a Proprietary Project or an Open-Source Project. Initial designations: Noosphere
is a Proprietary Project; SIMN is an Open-Source Project. The current list of
Projects and their designations is maintained in the Studio's public GitHub
organization at github.com/trapframestudio.

(b) **Proprietary Project Contributions.** For each Contribution to a Proprietary
Project, the Contributor hereby assigns to the Studio all right, title, and
interest, including all copyrights and other intellectual property rights, in and
to that Contribution. This assignment is effective upon the Studio's acceptance of
the Contribution and is irrevocable. The Contributor waives any moral rights or
droit moral in those Contributions to the extent permitted by applicable law. This
category includes, without limitation, the Noosphere story, lore, characters,
faction designs, level data, environment art, character art, weapon and prop art,
audio assets, music, voice recordings, and game-specific code that is not part of
any Open-Source Project.

(c) **Open-Source Project Contributions.** For each Contribution to an Open-Source
Project, the Contributor retains copyright in the Contribution. The Contributor
licenses the Contribution to the Studio and to the public under the Open-Source
Project's published license at the time of acceptance (currently expected to be
**[MIT / Apache-2.0 / dual MIT-Apache-2.0 — COUNSEL TO CONFIRM]**).

(d) This license is irrevocable as to the version of the Contribution merged into
the Open-Source Project. The Studio acknowledges that nothing in this Agreement
permits the Studio to retroactively re-license a merged Open-Source Project
Contribution into a more restrictive license, and that any continuation, fork, or
derivative of the Open-Source Project by third parties under the OSS license is
permitted and outside the Studio's control.

(e) **Right to fork; freedom to create.** Nothing in this Agreement prevents the
Contributor or any third party from forking any Open-Source Project, in accordance
with that Project's published OSS license, for any purpose — including building a
different game, a different engine derivative, or any other work. Nothing in this
Agreement prevents the Contributor from creating new works, including works that
compete with the Studio's Proprietary Projects, provided those new works do not
incorporate or infringe the Studio's Proprietary IP (story, characters, lore, art,
audio, or other proprietary content described in Section 6(b)). This Agreement
contains no non-compete covenant.

(f) **Reuse of Open-Source Project Contributions by the Studio.** The Studio may
use Open-Source Project Contributions in any Project, Proprietary or Open-Source,
on the terms of the applicable OSS license. Use of an Open-Source Project
Contribution in a Proprietary Project does not convert the Contribution into
Proprietary IP; the Contribution remains available under its OSS license.

(g) **Representations and warranties.** The Contributor represents and warrants
that each Contribution is the Contributor's original work, that the Contributor
has the legal right to make the Contribution, that the Contribution does not
infringe any third party's intellectual property, privacy, or publicity rights,
and that the Contribution does not incorporate any third-party material except
material that is properly licensed (under a license compatible with the relevant
Project's license) and disclosed at the time of submission.

### 7. Code of Conduct

(a) By contributing, the Contributor agrees to abide by the Studio's published
Community Code of Conduct, available at github.com/trapframestudio.

(b) Conduct that violates the Code of Conduct may result in suspension of the
Contributor's ability to submit new Contributions. Existing Point balances remain
(subject to Section 9), and the Contributor remains entitled to royalty payments
on Points previously awarded.

### 8. Sanctions and Lawful Payments

(a) The Contributor represents that they are not located in, ordinarily resident
in, or organized under the laws of any jurisdiction that is the subject of
comprehensive U.S. economic sanctions (as administered by the U.S. Office of
Foreign Assets Control, OFAC), and is not on any U.S. or applicable foreign
sanctions or restricted-party list.

(b) If the Contributor becomes located in a sanctioned jurisdiction, or otherwise
becomes a person to whom the Studio cannot lawfully make payments, the Studio will
hold the Contributor's accrued royalty balance in escrow, without interest, until
lawful payment is again possible or until the balance is treated as unclaimed
property under applicable law.

### 9. Misconduct; Revocation of Points

(a) If the Studio determines, after notice to the Contributor and a reasonable
opportunity to respond, that a Contribution was plagiarized, that it infringed
third-party rights, that it was submitted in violation of the Contributor's
representations under Section 6, or that the Contributor materially breached this
Agreement or the Code of Conduct, the Studio may revoke Points associated with the
offending Contribution by a vote of the Core Contributors, with appeal to the
Studio's managers.

(b) Revocation is prospective only. Royalty payments already made are not subject
to clawback except in cases of fraud or willful misconduct.

(c) Revocations are publicly logged in the Ledger with a written rationale.

### 10. Records and Audit

(a) The Studio will maintain books and records sufficient to verify the
calculations underlying each royalty payment for a period of at least seven (7)
years.

(b) The Contributor, or an independent certified public accountant designated by
the Contributor and reasonably acceptable to the Studio, may audit the Studio's
books and records related to the Contributor's royalty payments not more than once
per twelve-month period, upon at least thirty (30) days' prior written notice.
Audit costs are borne by the Contributor unless the audit reveals an underpayment
of more than five percent (5%) for the audited period, in which case the Studio
bears the audit costs and remits the underpayment with interest at **[INTEREST
RATE — COUNSEL TO ADVISE; e.g., 5% or the prevailing federal short-term rate]**.

### 11. Term; Survival

(a) This Agreement is effective on the date the Contributor signs it
electronically and continues until terminated under this Section.

(b) Either party may terminate the Contributor's ability to submit new
Contributions on thirty (30) days' written notice. Termination does not affect:
(i) the Contributor's previously awarded Points, which remain in the Ledger; (ii)
the Contributor's entitlement to future royalty payments on those Points for the
duration of each Project's commercial exploitation; or (iii) the Studio's
ownership of previously assigned Contributions.

(c) Sections 4 (No Investment), 5 (Non-Transferability), 6 (IP Assignment), 10
(Records and Audit), 11 (Term; Survival), 13 (Governing Law), and 14 (Dispute
Resolution) survive any termination.

### 12. Independent Contractor; No Employment

(a) The Contributor is an independent contractor and not an employee, partner,
joint venturer, or agent of the Studio. Nothing in this Agreement creates an
employer-employee relationship, and the Contributor is not entitled to any
employee benefits.

(b) The Contributor has no authority to bind the Studio. The Contributor is solely
responsible for their own taxes, insurance, and compliance with the laws of their
jurisdiction of residence.

### 13. Governing Law

(a) This Agreement is governed by the laws of the State of Colorado, U.S.A.,
without regard to its conflict-of-laws principles. The parties submit to the
exclusive jurisdiction of the state and federal courts located in **[Denver
County, Colorado — COUNSEL TO CONFIRM based on the Studio's principal place of
business]**

(b) for any dispute that cannot be resolved through the procedures in Section 14.

### 14. Dispute Resolution

(a) Before bringing any claim against the other party, the parties agree to
attempt good-faith resolution through direct discussion for at least thirty (30)
days.

(b) If direct discussion fails, the parties agree to non-binding mediation
conducted by **[JAMS / AAA / a mediator agreed by the parties — COUNSEL TO
CONFIRM]**

(c) If mediation fails, claims must be brought in the courts identified in Section
13. The parties waive any right to a jury trial.

### 15. Miscellaneous

(a) **Entire Agreement.** This Agreement (including the Distribution Policy
referenced in Exhibit A) is the entire agreement between the parties on its
subject matter and supersedes all prior negotiations or understandings.

(b) **Amendments.** The Studio may amend this Agreement on thirty (30) days'
notice to the Contributor by posting the amended version on the Studio's website
and in the Studio's GitHub repository. Amendments to the Distribution Policy that
reduce the Contributor's royalty share, or that reduce the OSS tithe floor below
five percent (5%), require the additional consent procedures set out in the
Operating Agreement and bind the Contributor only if those procedures are
followed. Continued submission of Contributions after the effective date of an
amendment constitutes acceptance.

(c) **Severability.** If any provision of this Agreement is held unenforceable,
the remainder of the Agreement remains in full force, and the unenforceable
provision will be reformed to the minimum extent necessary to make it enforceable.

(d) **Notices.** Notices to the Studio are sent to the address listed in the
Studio's then-current business filings. Notices to the Contributor are sent to the
email address provided at signature. Either party may update its notice address by
written notice to the other.

(e) **Counterparts; Electronic Signature.** This Agreement may be executed in
counterparts, including by electronic signature, each of which is deemed an
original.

### Signature

**CONTRIBUTOR**

| | |
|---|---|
| Signature | Date |
| Legal name (printed) | Country of tax residence |
| Trapframe / GitHub handle | Email for notices and payouts |

**STUDIO**

By: ________________________  Authorized Manager, Trapframe Studio LLC (a Colorado LLC)  ·  Date: __________

---

## Exhibit A — Distribution Policy

This Distribution Policy sets out the current bucket percentages, point scale, and
pool definitions that govern royalty payments under the Contributor Royalty
Agreement. The Policy may be amended only as set out in the Studio's Operating
Agreement.

### A.1 Bucket waterfall (from Net Revenue, in order)

| Bucket | Share | Notes |
|---|---|---|
| Tax & operating reserve | 25% | Capped at 12 months of operating budget, then reduced to 10%. |
| Open-source tithe | 5% | Floor — cannot be reduced below 5% without supermajority of active Contributors. |
| SIMN engine pool | 10% | |
| Core Contributor profits | 10% | Class B profits-interest holders only; distributed by tenure-weighted formula in proportion to vested interests. |
| Game contributor pool | 50% | Allocated to the game that generated the Net Revenue. |

### A.2 Point scale

| Size | Points | Examples |
|---|---|---|
| XS | 1 | Typo fixes, small documentation tweaks, single-asset cleanups. |
| S | 3 | Small bug fixes, single props, single voice lines, contained playtest reports. |
| M | 9 | Scripted encounters, small dialogue trees, contained subsystem improvements, ambient music loops. |
| L | 27 | Complete weapons or systems, major encounters, points of interest, meaningful engine features. |
| XL | 81 | Faction questlines, complete biomes, sustained multi-month efforts. |

### A.3 Project tags

Each Point award is tagged to one or more Projects. Initial tags:

- `simn` — work that improves the SIMN engine; earns from the SIMN engine pool of
  every game built on SIMN.
- `noosphere` — work specific to the Noosphere game; earns from the Noosphere game
  contributor pool.

Future tags will be added as future Projects are shipped. Splits across tags are
permitted and recorded in the Ledger.

### A.4 OSS tithe split (initial)

| Recipient | Share |
|---|---|
| Godot Foundation | 40% |
| Rust Foundation | 25% |
| Bevy | 20% |
| Blender Foundation | 10% |
| Discretionary (other upstream OSS used by the Studio) | 5% |

Reviewed annually.

### A.5 Payment cadence

Quarterly. Payments below US$25 roll forward.

---

> **Counsel checklist before adoption:** (1) confirm Colorado LLC formation status
> and authorized signatory; (2) finalize Section 4 language against current SEC and
> Colorado Division of Securities guidance; (3) confirm OSS license choice for each
> Open-Source Project, ensure license files in the repositories match Section 6(c),
> and verify the license is irrevocable as drafted; (4) confirm Section 6 IP split
> (assignment for Proprietary Projects, license-only for Open-Source Projects) is
> structured correctly under Colorado contract law and U.S. copyright law; (5)
> confirm interest rate in Section 10; (6) confirm venue and ADR provider in
> Sections 13–14; (7) confirm tax-form policy with CPA; (8) confirm sanctions
> screen mechanism in Section 8; (9) confirm whether amendments to the Distribution
> Policy require a separate Notice of Amendment process beyond what Section 15
> contemplates; (10) consider whether to use a separate Contributor License
> Agreement (CLA / DCO) for Open-Source Projects in addition to this Royalty
> Agreement.

*End of skeleton. Counsel review required before adoption. v0.1, May 29, 2026.*
