# Noosphere Content License

**Version 1.0 — [DRAFT, PENDING LEGAL REVIEW]**

> **This is not legal advice and is not yet a finalized license.** It is a
> drafting starting point describing the intended terms for the proprietary
> Noosphere content in this repository. It must be reviewed and finalized by
> an attorney, and the rights holder (`[ENTITY NAME]`, the legal entity that
> will own the Noosphere intellectual property) substituted in, before it is
> relied upon.

## Summary (non-binding)

The **code** in this repository is free and open source under
[MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), your pick. **This file does
not cover the code.** It covers the **Noosphere creative content and
intellectual property**, which is **proprietary and all rights reserved**.

You may read the code, build new games on the engine and systems (under the
permissive MIT / Apache 2.0 code license), and study how Noosphere is built. You may **not** take the Noosphere
*identity* — its art, audio, world, story, characters, faction names, or brand —
and ship it as your own or as part of another product.

## 1. Covered Material

This license applies to all material in this repository that is **not source
code**, and to the Noosphere creative expression specifically, including but
not limited to:

- **Visual assets** — art, textures, models, meshes, icons, logos, backdrops,
  environments, and baked content under `godot/assets/**` (other than
  third-party addon assets, which retain their own licenses; see §6).
- **Audio assets** — music, sound effects, voice, and ambient audio.
- **World and map data** — terrain, region layouts, points of interest, and
  hand-authored location content.
- **Narrative and lore content** — the design canon in `docs/DESIGN.md`, the
  setting, timeline, and story; faction definitions, faction names, and
  faction lore; the names of in-world organizations, places, characters, and
  events (e.g. "Project Citizen", "Facility 7 / The Dalles Complex",
  "Pacific Workers' Alliance", "Revere's Guard", "Gulf Compact", "The Merged",
  "Cuts", "Blowouts", "The Broadcast").
- **Narrative payload in data files** — the *specific Noosphere content* inside
  the game's content overlay at `godot/content/`, including
  `godot/content/names/**`, `godot/content/ai/chatter_lines.toml`,
  `godot/content/factions/factions.toml` (faction names, relations, lore), and
  the flavor text/identity portions of NPC and loadout definitions. (The
  mechanics files in that overlay — items, loot, crafting, combat, etc. —
  started as copies of SIMN's permissive example pack and are NOT proprietary;
  only the creative/identity content is.)
- **The "Noosphere" name and brand** — see also [TRADEMARK.md](TRADEMARK.md).

**Not covered (governed by the MIT / Apache 2.0 code license instead):** the vendored SIMN engine source under `godot/addons/simn/**` (which carries its own MIT/Apache license),
`godot/**` scripts, build files, and the *schemas, mechanics, and tuning* of
data files — e.g. `ballistics.toml`, `recipes.toml`, `behavior.toml`,
`equipment_slots.toml`, `cover_materials.toml`, `loot_containers.toml`, and the
*structure* of all `.toml` formats. The line is: **systems and mechanics are
open; the specific Noosphere creative content is proprietary.** Where a single
file mixes both, the creative-content portions are governed by this license.

## 2. Reservation of Rights

All rights in the Covered Material are reserved by `[ENTITY NAME]`. No rights
are granted except those expressly stated in §3. Copyright and all other
intellectual property rights in the Covered Material remain with the rights
holder.

## 3. Permitted Uses

Subject to the conditions in §4, you may:

1. **View and study** the Covered Material as present in this repository.
2. **Build and run** the official Noosphere game from this repository for your
   own personal play and development.
3. **Develop, test, and submit contributions** to the official Noosphere
   project (subject to the [Contributor License Agreement](docs/CLA.md)).
4. **Create mods** that are loaded by, and used together with, a legitimately
   obtained copy of the official Noosphere game — including mods that add or
   replace assets within your own game install. Distribution of mods is
   permitted only as mod content for the official game, not as a standalone
   product, and must not redistribute the unmodified Covered Material as a
   substitute for the official game.

## 4. Prohibited Uses

You may **not**, without prior written permission from the rights holder:

1. Use the Covered Material, in whole or in part, in any product, game, or
   service other than the official Noosphere game.
2. Redistribute, sell, sublicense, or publicly distribute the Covered Material
   as a substitute for, or competitor to, the official Noosphere game.
3. Create a derivative game or product that reuses the Noosphere identity —
   its art, audio, world, story, characters, faction names, or brand.
4. Use the "Noosphere" name, logos, or faction/world names in a way governed by
   [TRADEMARK.md](TRADEMARK.md) outside the permissions granted there.

**Building a new game on the open-source engine and systems is encouraged** —
but you must bring your **own** original creative content and IP. The code
license gives you the *code*; it does not give you *Noosphere*.

## 5. No Warranty

THE COVERED MATERIAL IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED. THE RIGHTS HOLDER IS NOT LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER
LIABILITY ARISING FROM THE COVERED MATERIAL OR ITS USE.

## 6. Third-Party Material

Third-party assets, addons, fonts, and libraries bundled in this repository
(for example under `godot/addons/**` and `godot/assets/fonts/`) retain their
own licenses, which are included alongside them. This license does not modify,
restrict, or extend those licenses.

## 7. Contact

For permissions, licensing inquiries, or commercial use beyond what is granted
here, contact the rights holder (`[CONTACT — to be set once the entity exists]`).
