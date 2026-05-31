class_name NSColors
extends RefCounted
## Noosphere design-system palette, ported from `colors_and_type.css`.
##
## Three concentric layers — ground (damp Gorge), material (salvaged
## surplus), signal (the only saturated colors) — plus faction tokens
## and semantic aliases. Do not introduce new hex values here without
## updating the design bundle first; this file is the one source of
## truth on the Godot side.

# ---- Ground: backgrounds and chrome ----
const BASALT_BLACK   := Color("#0F1311")
const WET_SLATE      := Color("#1A201D")
const MOSS_SHADOW    := Color("#262E2A")
const LICHEN         := Color("#3A4741")
const FOG            := Color("#5B6A63")
const MIST           := Color("#8A9A91")

# ---- Material: salvaged surplus ----
const CARBON_PAPER   := Color("#C9B086")
const FIELD_DRESSING := Color("#A89B7A")
const PAGE_CREAM     := Color("#E6DCC2")
const OXIDIZED_BRASS := Color("#8A6A3B")
const RUST           := Color("#6E4428")
const INK_BLACK      := Color("#1A1714")
const STAMP_RED      := Color("#8C3A2E")
const CARBON_BLUE    := Color("#2F3E55")

# ---- Signal: saturated, use sparingly ----
const VLF_PHOSPHOR     := Color("#7FB26A")
const VLF_PHOSPHOR_DIM := Color("#4E6F42")
const WARNING_RUST     := Color("#C94A2E")
const PWA_SLATE        := Color("#3B5A6E")
const PAGE_WHITE       := Color("#D6CDB4")

# ---- CRT well background ----
const BG_CRT := Color("#0A1410")

# ---- Rules / borders ----
const RULE_1 := Color("#2A332E")
const RULE_2 := Color("#3A4741")

# ---- Faction tokens (from GDD map legend) ----
const FAC_PWA      := Color("#B8933F")
const FAC_LINEMEN  := Color("#D96428")
const FAC_RG       := Color("#4A7AA8")
const FAC_FEDERAL  := Color("#555555")
const FAC_ATTUNED  := Color("#8E4DBE")
const FAC_MERGED   := Color("#C94A2E")
const FAC_COMPACT  := Color("#C9B086")
const FAC_CARTEL   := Color("#8C2A2A")
const FAC_WANDERER := Color("#9C9C9C")
const FAC_FAULT    := Color("#5F9E7E")

# ---- Semantic aliases ----
const FG_1 := PAGE_WHITE       ## Primary text on dark.
const FG_2 := MIST             ## Secondary text on dark.
const FG_3 := FOG              ## Tertiary text, captions.
const FG_ON_PAPER := INK_BLACK ## Ink text on carbon paper.
const FG_ON_PAPER_2 := Color("#3A342B")

const BG_0 := BASALT_BLACK
const BG_1 := WET_SLATE
const BG_2 := MOSS_SHADOW
const BG_3 := LICHEN
const BG_PAPER   := CARBON_PAPER
const BG_PAPER_2 := PAGE_CREAM

const ACCENT     := VLF_PHOSPHOR
const ACCENT_DIM := VLF_PHOSPHOR_DIM
const DANGER     := WARNING_RUST
const COLD       := PWA_SLATE
