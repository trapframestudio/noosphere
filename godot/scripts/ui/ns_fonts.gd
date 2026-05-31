class_name NSFonts
extends RefCounted
## Noosphere font handles. One lazy getter per family; the `stencil()`
## helper returns a weighted FontVariation of the Oswald variable face.
## All four families are vendored into `assets/fonts/` and licensed
## under the OFL (or Apache-2.0 for Special Elite). See
## `godot/assets/fonts/LICENSE-fonts.txt`.
##
## Why lazy instead of `const preload(...)`: on a cold project open the
## font import cache can be empty when the engine first resolves
## preloaded consts, which takes the whole class down and cascades into
## every script that reads `NSFonts.MONO` etc. Property-getter loads
## happen at first *use*, which is always after the autoload _ready()
## has fired and the filesystem scan has settled.

static var _stencil: Font = null
static var _mono: Font = null
static var _mono_bold: Font = null
static var _typewriter: Font = null
static var _serif: Font = null

static var STENCIL: Font:
	get:
		if _stencil == null:
			_stencil = load("res://assets/fonts/Oswald-Variable.ttf") as Font
		return _stencil

static var MONO: Font:
	get:
		if _mono == null:
			_mono = load("res://assets/fonts/JetBrainsMono-Regular.ttf") as Font
		return _mono

static var MONO_BOLD: Font:
	get:
		if _mono_bold == null:
			_mono_bold = load("res://assets/fonts/JetBrainsMono-Bold.ttf") as Font
		return _mono_bold

static var TYPEWRITER: Font:
	get:
		if _typewriter == null:
			_typewriter = load("res://assets/fonts/SpecialElite-Regular.ttf") as Font
		return _typewriter

static var SERIF: Font:
	get:
		if _serif == null:
			_serif = load("res://assets/fonts/IBMPlexSerif-Regular.woff2") as Font
		return _serif

## Convenience: a `FontVariation` of Oswald at the given weight
## (600 = SemiBold, 700 = Bold in Oswald's wght axis).
static func stencil(weight: int = 700) -> FontVariation:
	var v := FontVariation.new()
	v.base_font = STENCIL
	v.variation_opentype = { &"wght": weight }
	return v
