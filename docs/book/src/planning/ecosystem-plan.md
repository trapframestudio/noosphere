# Contributor & Modder Ecosystem - Planning Doc

Status: **draft / thinking out loud**
Owner: Jon
Last updated: 2026-04-06

This is a working planning doc, not a spec. Goal: figure out how Noosphere's
contributor and modder ecosystems should work, and lock in the decisions that
need to be made early so we don't paint ourselves into a corner. Once sections
stabilize they should graduate into ADRs under `docs/book/src/adr/` and user-
facing docs under `docs/book/src/modding/` and `docs/book/src/contributing/`.

---

## 1. Two audiences, one porous boundary

**Contributors** change the engine itself - Rust crates, gdext bridge, GDScript
scenes. Build from source, run clippy, write tests, open PRs.

**Modders** change content and behavior without touching engine source. They
work with configuration files, GDScript, textures, models, maps, and similar
content surfaces. Install the game, drop files into a folder.

The killer move is making the boundary between these as porous as possible: a
popular mod author should be one PR away from becoming an engine contributor,
and engine internals should be exposed as modding APIs wherever it doesn't cost
us. The most enduring modding scenes exist because content is just files in a
folder, and we are aiming to be one of those scenes.

---

## 2. Contributor ecosystem

### 2.1 Lowering the on-ramp

The "I cloned it and now what" cliff is the main thing to flatten.

- **`good-first-issue` discipline from day one.** Every system, every
  module has bite-sized chunks. Tag aggressively.
- **CODEOWNERS per crate**, mapped onto the existing agent team structure
  Translates to humans as the
  team grows.
- **ADRs in `docs/book/src/adr/`.** Capture the *why* behind crate boundaries,
  the engine-agnostic rule, coordinate conversion, the gdext-only-in-`simn-godot`
  rule. New contributors read ADRs instead of rediscovering tribal knowledge in
  PR review.
- **Public roadmap with explicit "claim this" semantics.** Promote sections of
  `PROJECT_PLAN.md` into GitHub Projects.
- **One-command local CI.** `just check` or `make check` running clippy, fmt,
  tests, and `mdbook build`. Contributors should never be surprised by CI.
- **A "first PR" tutorial.** Pick a real, small task and write it up as
  a walkthrough in `docs/book/src/contributing/`.
- **Async chat from day one** (Discord / Matrix), even if quiet. Modders
  especially need a low-friction place to ask questions.
- **Governance signal early.** A `GOVERNANCE.md` even if it's just "BDFL for
  now, moving to maintainer council at N contributors." Removes ambiguity.

### 2.2 Things to write down

- `docs/book/src/contributing/` skeleton:
  - environment setup
  - first PR walkthrough
  - code conventions (lifted from `CLAUDE.md`)
  - agent team explanation for humans (not just Claude)
- `GOVERNANCE.md` - boilerplate is fine; absence is a stronger signal than
  contents.
- `CODE_OF_CONDUCT.md` - Contributor Covenant.
- `CONTRIBUTING.md` at repo root pointing into the mdbook chapter.

---

## 3. Modder ecosystem

This is the more important design problem. Decisions made in the next few
months determine whether modding is a first-class feature or a retrofit.

### 3.1 Core principle: content lives outside the executable

The most enduring modding cultures exist because game content is just files
on disk. We commit to that pattern and aim to improve on it with better
manifests, stable APIs, and conflict resolution.

### 3.2 Concrete commitments

1. **Mounted content directories with explicit load order.** Not the
   classic "drop files into a shared content folder" approach, which is
   a nightmare of silent conflicts. Instead: a `mods/` directory where
   each mod is a self-contained folder with
   a manifest (`mod.toml`: name, version, dependencies, load priority,
   conflicts). Game enumerates them at startup, resolves order, mounts them as
   overlay layers over base content. Last-loaded wins for file conflicts, but
   the manifest declares conflicts so the user gets warnings instead of silent
   breakage.

2. **Section-level config overrides instead of whole-file replacement.**
   The pattern of patching individual sections of a config file rather
   than replacing the entire file is well-established in modding
   communities and prevents most accidental conflicts. Whatever
   configuration format Noosphere settles on, section-level overrides
   should be first-class and documented as the preferred way to change
   configs. Two mods touching the same item should compose without
   conflict.

3. **Stable, versioned modding APIs - separate from internal APIs.** The hard
   one. The Lua scripting layer needs a *public* API surface versioned
   independently of engine internals. Mods declare `api_version = 2` in their
   manifest; engine refuses incompatible mods with a clear error. Changing
   internals is fine; changing the modding API requires a deprecation cycle.

4. **Scripting layer with a stable, documented API.** Whether the
   primary scripting language ends up being GDScript only, or GDScript
   plus an embedded Lua runtime via `mlua`, the public scripting
   surface needs to be designed as a product in its own right.
   Versioned, deprecation-aware, and documented. The scripting layer
   is the primary creative surface for modders who want to add new
   gameplay logic, and it deserves the same care we give to the
   simulation core.

5. **Content hot-reload during development.** We already have hot reload for
   the gdext dylib. Extend the ethos to content: editing a config file
   or a script in a mod folder reloads it in a running game without
   restart. Modders iterate 100x faster, and so do we.

6. **Asset import pipeline accessible to mods.** A modder dropping a
   custom asset into a mod folder should get the same import treatment
   as base content. Whatever import flow Noosphere uses, this should
   work transparently for mods.

7. **Asset replacement via path mounting, not file editing.** A mod
   that retextures an item ships its own texture file in its mod
   folder, and the mount layer handles the override. Modders never
   edit base game files. Uninstalling a mod is `rm -rf mods/cool-retexture/`.

### 3.3 Open design questions

- **Mod manifest schema.** Even a stub `mod.toml` parser in `simn-common` is
  worth writing soon, because it forces commitment on fields: `id`, `version`,
  `deps`, `api_version`, `conflicts`, `load_order_hint`, capabilities.
- **Mod ID namespace.** Reverse-DNS or GitHub-handle prefixes prevent
  collisions. Pick one and document.
- **Script sandbox / capability model.** A multiplayer game cannot
  hand mod scripts unrestricted filesystem or network access. Decide
  early: do server mods get more privileges than client mods? Is there
  a capability system? At minimum, document the threat model so
  modders aren't blindsided when restrictions land later.
- **Multiplayer + mods.** The hardest unsolved problem. Server-authoritative
  content hash, client downloads matching mod set, version negotiation on
  join. Worth an ADR now even if implementation is far off - the networking
  design in `simn-net` will be shaped by the answer.
- **Mod distribution.** Local folder is fine for v1. But "Workshop-style"
  distribution (even just a JSON index hosted on GitHub Pages) is what turns
  a moddable game into a modding *community*. Plan for it; don't build it yet.

### 3.4 `docs/book/src/modding/` chapter outline

Stub pages, even if half are placeholders - signals intent and starts SEO:

- Overview / philosophy
- "Your first mod" - config tweak walkthrough
- "Your first script mod" - scripting hello-world
- "Your first asset mod" - texture replacement
- Mod manifest reference
- Config override system (section-level patches)
- Scripting API reference
- API stability policy
- Multiplayer compatibility rules
- Publishing your mod

---

## 4. Decisions to lock in soon

Ordered by leverage. Each of these unblocks a bunch of downstream design.

| # | Decision | Why it matters | Owner |
|---|---|---|---|
| 1 | Modding architecture ADR (mount layers, manifest, override semantics) | Everything else flows from this | Jon |
| 2 | Mod manifest schema (`mod.toml` fields + serde stub in `simn-common`) | Forces identity / versioning decisions | Jon |
| 3 | Modding API stability policy (`api_version` semantics, deprecation rules) | Determines whether modders trust us | Jon |
| 4 | Script capability / sandbox model | Shapes `simn-scripting` from day one | scripting-engineer (future) |
| 5 | MP + mods compatibility model (content hashing, version negotiation) | Shapes `simn-net` from day one | network-engineer (future) |
| 6 | Scripting API surface and stability policy | Determines whether modders can build long-term on the API | scripting-engineer (future) |

---

## 5. Next two weeks - concrete actions

None of these touch the render pipeline work in flight.

1. **Write modding ADR** - `docs/book/src/adr/0001-modding-architecture.md`.
   Highest-leverage thing on the list; everything else flows from it.
2. **Stub `mod.toml` schema** in `simn-common` with serde. No loader logic,
   just the types and a doc comment. Forces mod identity decisions.
3. **`docs/book/src/modding/` skeleton** with stub pages so the URL structure
   exists and search engines start indexing it.
4. **`docs/book/src/contributing/` skeleton** - env setup, first PR
   walkthrough, conventions, agent team explanation for humans.
5. **`GOVERNANCE.md` + `CODE_OF_CONDUCT.md` + `CONTRIBUTING.md`** at repo root.
6. **Promote this doc's stable sections into ADRs** as decisions get locked.

---

## 6. Open questions / parking lot

- Should modders be able to ship Rust code (dynamic library mods), or is the
  scripting boundary strictly GDScript (and possibly embedded Lua) + content? (Strong lean: no native
  mods. Security, portability, and trust nightmare.)
- Do we want a dedicated mod editor / launcher app, or lean entirely on the
  Godot editor + filesystem?
- How do we handle mods that declare dependencies on specific original
  Noosphere asset packs the user may or may not have installed? Manifest
  declares asset deps, mod manager warns or auto-installs?
- Is there a "vanilla+" baseline mod the project itself maintains as a
  reference / smoke test for the modding API?
- Localization story for mods - does the manifest carry locale strings, or
  does each mod ship its own locale files?
