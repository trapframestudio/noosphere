#!/usr/bin/env bash
# Rebake every (or selected) terrain bake spec under `tools/bakes/`.
#
# Usage:
#   tools/bake-all-maps.sh                    # bake every spec in tools/bakes/
#   tools/bake-all-maps.sh cascade_locks      # bake one map
#   tools/bake-all-maps.sh hood_river mt_hood # bake several maps
#
# Behavior:
#   - Builds the `terrain_bake` example once in release mode (warm
#     incremental builds are seconds; first run from a cold target/
#     is ~30 s).
#   - Verbose Cargo + Overpass + Mapzen output goes to a per-run log
#     under /tmp/noosphere-bakes/ so the terminal stays readable.
#   - One status line per map to stdout: `✓ name (Ns)` or
#     `✗ name FAILED (Ns) — see <log>`.
#   - Prints a final pass/fail tally and exits non-zero if any map
#     failed.
#
# Common reasons a bake fails:
#   - Mapzen Terrarium S3 tiles 500 transiently. Re-run that single
#     map: `tools/bake-all-maps.sh <name>` — Overpass + DEM caches
#     are warm so it'll be fast.
#   - Overpass mirror outage. The fetcher tries 4 mirrors; if all
#     fail, retry the map after a few minutes.

set -euo pipefail

# Resolve the repo root so the script is robust to where it's run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="/tmp/noosphere-bakes"
LOG_FILE="$LOG_DIR/rebake-$(date +%Y%m%dT%H%M%S).log"
mkdir -p "$LOG_DIR"

# Pick the maps to bake: CLI args win, otherwise every *.toml in bakes/.
if [[ $# -gt 0 ]]; then
    MAPS=("$@")
else
    MAPS=()
    for f in tools/bakes/*.toml; do
        MAPS+=("$(basename "$f" .toml)")
    done
fi

if [[ ${#MAPS[@]} -eq 0 ]]; then
    echo "No bake specs found under tools/bakes/." >&2
    exit 1
fi

echo "Rebake plan: ${#MAPS[@]} map(s)"
echo "Verbose log: $LOG_FILE"
echo

# Build once up front so per-map runs reuse a hot binary.
echo "Building terrain_bake (release)…"
cargo build --release -p simn-terrain --example terrain_bake \
    >> "$LOG_FILE" 2>&1
echo

passed=()
failed=()
for map in "${MAPS[@]}"; do
    spec="tools/bakes/${map}.toml"
    if [[ ! -f "$spec" ]]; then
        echo "  ✗ $map — no spec at $spec"
        failed+=("$map")
        continue
    fi
    echo "==== rebake: $map ====" >> "$LOG_FILE"
    start=$(date +%s)
    if cargo run --release --example terrain_bake -p simn-terrain -- "$map" \
            >> "$LOG_FILE" 2>&1; then
        dur=$(( $(date +%s) - start ))
        echo "  ✓ $map (${dur}s)"
        passed+=("$map")
    else
        dur=$(( $(date +%s) - start ))
        echo "  ✗ $map FAILED (${dur}s) — see $LOG_FILE"
        failed+=("$map")
    fi
done

echo
echo "Done: ${#passed[@]} passed, ${#failed[@]} failed."
if [[ ${#failed[@]} -gt 0 ]]; then
    printf '  failed: %s\n' "${failed[@]}"
    exit 1
fi
