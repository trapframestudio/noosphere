class_name Layers
extends RefCounted
## Canonical collision-layer bitmask constants.
##
## Must stay in sync with `crates/simn-godot/src/los.rs` (`LAYER_SOLID`,
## `LAYER_CONCEALMENT`, `LAYER_NPC_HITBOX`) — the sim's LOS provider
## relies on the exact bit assignment below to distinguish full
## occlusion from partial concealment and to ignore humanoid bodies
## when running perception raycasts.
##
## Use as `Layers.NPC_HITBOX`, never raw bit literals. Scene `.tscn`
## files use the numeric value directly (format limitation); call sites
## in GDScript should go through these constants.

## Bit 0 — terrain, walls, buildings, rock. Fully blocks LOS.
const SOLID: int = 1
## Bit 1 — bushes, smoke, cloth. Partial LOS occlusion (see
## `PerceptionConfig::concealment_visibility`).
const CONCEALMENT: int = 2
## Bit 2 — humanoid bodies (players and NPC dummies). Explicitly
## *excluded* from LOS queries so humanoids never occlude sight to
## other humanoids, but included in weapon-fire raycasts.
const NPC_HITBOX: int = 4

## Mask used by weapon-fire raycasts: stop on world, concealment, or
## any humanoid.
const WEAPON_HIT_MASK: int = SOLID | CONCEALMENT | NPC_HITBOX

## Mask used by the player's `CharacterBody3D` for movement: stop on
## world geometry and on other humanoid bodies, but pass through
## concealment (bushes shouldn't block a player walking through them).
const PLAYER_MOVE_MASK: int = SOLID | NPC_HITBOX
