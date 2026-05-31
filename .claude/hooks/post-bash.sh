#!/usr/bin/env bash
# Noosphere PostToolUse hook for Bash.
#
# Records markers when lint/test/fmt commands complete successfully so the
# pre-commit gate has something to check against.
#
# Receives Claude Code hook JSON on stdin.
#
# Claude Code's Bash tool_response provides {stdout, stderr, interrupted,
# isImage, noOutputExpected} but NOT an exit_code field, so we infer
# success per command from characteristic output patterns rather than
# trying to read an exit status. Diagnosed 2026-04-23 by dumping
# captured JSON to /tmp and inspecting the real shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.claude/state"
mkdir -p "$STATE_DIR"

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')
interrupted=$(echo "$input" | jq -r '.tool_response.interrupted // false')
stdout=$(echo "$input" | jq -r '.tool_response.stdout // ""')
stderr=$(echo "$input" | jq -r '.tool_response.stderr // ""')

if [[ -z "$command" ]] || [[ "$interrupted" == "true" ]]; then
  exit 0
fi

combined="$stdout$stderr"

# cargo clippy --workspace -- -D warnings: success = cargo reports
# "Finished" AND no "error:" / "warning:" lines. With -D warnings in
# play, any warning escalates to error, so their absence + Finished
# uniquely identifies a green run.
if [[ "$command" =~ cargo[[:space:]]+clippy.*--workspace.*-D[[:space:]]+warnings ]]; then
  if [[ "$combined" == *"Finished"* ]] && \
     [[ "$combined" != *"error:"* ]] && \
     [[ "$combined" != *"warning:"* ]]; then
    touch "$STATE_DIR/clippy-pass"
  fi
fi

# Accept either `cargo test --workspace` OR `cargo test -p simn-sim`
# as valid evidence the test gate has been run. `--workspace` is the
# strictest (covers every crate) but its output is large enough that
# Claude Code truncates `tool_response.stdout` and this hook never
# sees the "test result: ok" needle. `-p simn-sim` is the practical
# fallback: simn-sim is the largest crate by far and the one most
# branches touch, so a green sim test is very strong evidence the
# branch is ready to commit. Other crates (`simn-godot`, `simn-net`,
# `simn-terrain`, `simn-common`) are small and rarely changed in
# isolation; if you do change them, run `--workspace` to refresh
# the marker (or expand the regex with another `-p` clause).
#
# Success rule: "test result: ok" appears AND no "FAILED" / "error:"
# anywhere in the captured output. Every test file prints its own
# "test result: ok." line; a failure prints "test result: FAILED".
if [[ "$command" =~ cargo[[:space:]]+test.*(--workspace|-p[[:space:]]+simn-sim) ]]; then
  if [[ "$combined" == *"test result: ok"* ]] && \
     [[ "$combined" != *"FAILED"* ]] && \
     [[ "$combined" != *"error:"* ]]; then
    touch "$STATE_DIR/test-pass"
  fi
fi

# cargo fmt --all -- --check: success = empty output. When there's a
# diff, the tool prints it to stdout; when there isn't, it prints
# nothing at all.
if [[ "$command" =~ cargo[[:space:]]+fmt.*--all.*--check ]]; then
  trimmed="${combined//[[:space:]]/}"
  if [[ -z "$trimmed" ]]; then
    touch "$STATE_DIR/fmt-pass"
  fi
fi

exit 0
