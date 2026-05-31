#!/usr/bin/env bash
# Noosphere PreToolUse hook for Bash.
#
# Blocks dangerous git commands and enforces the pre-commit gate.
# Receives Claude Code hook JSON on stdin. Exit 2 = block (stderr shown to Claude).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.claude/state"
MAX_AGE_SECONDS=1800   # 30 minutes — markers older than this are considered stale

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')
# Real Claude Code hook invocations include session_id; dry-run echo tests
# typically don't. Used below to skip destructive marker cleanup on dry runs.
session_id=$(echo "$input" | jq -r '.session_id // empty')

if [[ -z "$command" ]]; then
  exit 0
fi

# --- helpers ----------------------------------------------------------------

block() {
  echo "BLOCKED by .claude/hooks/pre-bash.sh: $1" >&2
  echo "" >&2
  echo "$2" >&2
  exit 2
}

marker_fresh() {
  local marker="$STATE_DIR/$1"
  if [[ ! -f "$marker" ]]; then
    return 1
  fi
  local mtime now age
  mtime=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - mtime))
  if (( age > MAX_AGE_SECONDS )); then
    return 1
  fi
  return 0
}

# --- force-push: hard block, no exceptions ----------------------------------

if [[ "$command" =~ git[[:space:]]+push.*--force ]]; then
  block "force push" \
"Force-pushing is denied by policy. If you really need to overwrite remote
history, the user must run the command themselves with the '!' bash prefix
in the prompt."
fi

# --- regular push: soft block, requires explicit user authorization marker
# AND a fresh test-pass (test gate moved here from the commit gate so
# incremental commits don't re-pay the full sim-suite cost).

if [[ "$command" =~ ^[[:space:]]*git[[:space:]]+push([[:space:]]|$) ]]; then
  if ! marker_fresh push-allowed; then
    block "git push without authorization" \
"Pushing requires explicit user authorization in the current turn. The user
must say something containing the literal word 'push' (e.g. 'go ahead and
push', 'push it'). Vague approvals like 'looks good', 'ship it', or 'send
it' do NOT authorize a push.

When the user authorizes a push, write a marker by running:
  touch .claude/state/push-allowed
The marker is valid for $((MAX_AGE_SECONDS / 60)) minutes and is consumed
on use."
  fi
  if ! marker_fresh test-pass && [[ ! -f "$STATE_DIR/checks-waived" ]]; then
    block "git push without recent test-pass" \
"Pushing requires a fresh (within $((MAX_AGE_SECONDS / 60)) min) green run of
either:
  - cargo test --workspace
  - cargo test -p simn-sim
The PostToolUse hook records the marker on success. Run tests, then retry
the push.

For genuinely test-irrelevant pushes (docs-only, .toml-only) write the
checks-waived escape:
  echo 'reason here' > .claude/state/checks-waived"
  fi
  # Consume markers after a successful authorization check.
  # Even if the push itself fails, the user's permission was for one push.
  # Skip on dry runs (no session_id) so testing doesn't consume real markers.
  if [[ -n "$session_id" ]]; then
    rm -f "$STATE_DIR/push-allowed" "$STATE_DIR/test-pass"
  fi
fi

# --- git commit: requires lint + test + fmt markers -------------------------

if [[ "$command" =~ ^[[:space:]]*git[[:space:]]+commit([[:space:]]|$) ]]; then
  # Honor the checks-waived escape hatch first.
  if [[ -f "$STATE_DIR/checks-waived" ]]; then
    : # waiver present; skip the rust checks gate
  else
  missing=()
  marker_fresh clippy-pass || missing+=("cargo clippy --workspace -- -D warnings")
  marker_fresh fmt-pass    || missing+=("cargo fmt --all -- --check")
  # Test-pass is the push gate, NOT the commit gate (full sim suite is
  # too slow to gate every incremental commit on). Run tests before push.

  if (( ${#missing[@]} > 0 )); then
    list=$(printf '  - %s\n' "${missing[@]}")
    block "git commit without recent green checks" \
"The pre-commit gate requires recent (within $((MAX_AGE_SECONDS / 60)) min)
successful runs of these checks. Missing or stale:
$list

Run them now. The PostToolUse hook will record fresh markers when each one
exits 0. Then retry the commit.

Docs-only commits where you genuinely cannot run rust checks (e.g. only
.md files changed): write a one-line waiver to .claude/state/checks-waived
explaining why, and re-run the commit. The waiver is consumed on use.

To check if your commit qualifies for the docs-only waiver:
  git diff --cached --name-only | grep -vE '\\.(md|txt|yml|yaml|toml)\$|^docs/'
If that prints nothing, you're docs/config-only and can waive."
  fi
  fi

  # Docs verification (separate from rust checks). Check whether docs-keeper
  # has been dispatched OR an explicit doc waiver exists.
  if ! marker_fresh docs-verified && [[ ! -f "$STATE_DIR/docs-waived" ]]; then
    block "git commit without documentation verification" \
"The pre-commit gate requires documentation verification. Either:

  1. Dispatch the docs-keeper agent. When it returns 'all green', write:
       touch .claude/state/docs-verified
  2. OR write an explicit waiver explaining why no docs are affected:
       echo 'reason here' > .claude/state/docs-waived

The waiver is consumed on use. See CLAUDE.md → Documentation Manifest for
the file → docs mapping that determines what needs updating."
  fi

  # Both gates passed. Consume commit-gate markers so the next commit
  # needs fresh ones. test-pass is NOT consumed here — it's the push
  # gate's marker and survives across multiple commits in the same
  # work session.
  # Only do this on real Claude Code invocations — dry-run echo tests
  # with no session_id should not destroy waiver state.
  if [[ -n "$session_id" ]]; then
    rm -f "$STATE_DIR/clippy-pass" "$STATE_DIR/fmt-pass" \
          "$STATE_DIR/docs-verified" "$STATE_DIR/checks-waived" "$STATE_DIR/docs-waived"
  fi
fi

# --- git add -A / git add . : block as a hygiene rule -----------------------

if [[ "$command" =~ ^[[:space:]]*git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$) ]]; then
  block "git add -A / git add ." \
"Bulk-staging is denied by policy. Stage explicit paths only.

Why: bulk-staging routinely sweeps in unrelated work, build artifacts, or
files the user didn't intend to commit (this almost happened on the
governance-docs commit — caught only because git status was checked first).

Stage files by name:
  git add path/to/file.rs path/to/other.md
Or use git add -p to review hunks interactively."
fi

exit 0
