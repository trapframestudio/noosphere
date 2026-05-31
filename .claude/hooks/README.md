# Claude Code Hooks

Pre/PostToolUse hooks that enforce Noosphere's AI-automation guardrails.
Registered in `.claude/settings.json`. Run automatically — you don't
invoke them by hand.

## What's here

| File | Fires when | Purpose |
|---|---|---|
| `pre-bash.sh` | Before any Bash tool call | Blocks dangerous git commands and enforces the pre-commit gate |
| `post-bash.sh` | After any Bash tool call | Records markers when clippy/test/fmt exit 0 |

## What pre-bash.sh blocks

- **`git push --force*`** — always, no exceptions. User must run via the
  `!` bash prefix themselves.
- **`git push`** (regular) — unless `.claude/state/push-allowed` exists.
  The marker is consumed on use.
- **`git commit`** — unless fresh markers exist for clippy + test + fmt
  AND docs verification (or the corresponding waivers).
- **`git add -A`, `git add --all`, `git add .`** — always. Stage explicit
  paths only.

## State files (`.claude/state/`)

All markers are gitignored except the directory's own `.gitignore`.
TTL is 30 minutes. Auto-cleared after a successful commit.

| Marker | Written by | Cleared by |
|---|---|---|
| `clippy-pass` | `post-bash.sh` after `cargo clippy --workspace -- -D warnings` exit 0 | Successful commit |
| `test-pass` | `post-bash.sh` after `cargo test --workspace` exit 0 | Successful commit |
| `fmt-pass` | `post-bash.sh` after `cargo fmt --all -- --check` exit 0 | Successful commit |
| `docs-verified` | Main-Claude after `docs-keeper` returns PASS | Successful commit |
| `push-allowed` | Main-Claude when user says the literal word "push" | Successful push |
| `checks-waived` | Main-Claude with explicit reason for docs-only commits | Successful commit |
| `docs-waived` | Main-Claude with explicit reason when no docs apply | Successful commit |

## Waivers

Two escape hatches exist for the pre-commit gate. Both require an explicit
written reason and auto-clear on use.

**`checks-waived`** — for genuinely rust-irrelevant commits (only
`.md`, `.toml`, `.yml`, `.json`, `.sh`, `.gitignore` touched). Verify with:

```bash
git diff --cached --name-only | grep -vE '\.(md|txt|yml|yaml|toml|sh|json)$|^\.claude/|^docs/|^\.gitignore$'
```

If that prints nothing, you qualify. Write the waiver:

```bash
echo 'reason here' > .claude/state/checks-waived
```

**`docs-waived`** — when the Documentation Manifest in `CLAUDE.md` has no
applicable target. Same pattern:

```bash
echo 'reason here' > .claude/state/docs-waived
```

"I'm in a hurry" is not a valid reason for either.

## Disabling hooks for debugging

If you need to bypass the hooks temporarily (e.g. you're debugging a
hook bug), the cleanest options in order of preference:

1. **Fix the bug.** Hooks exist for reasons; if one is wrong, fix it
   rather than work around it.
2. **Create the markers manually.** All four are just empty files:
   `touch .claude/state/{clippy-pass,test-pass,fmt-pass,docs-verified}`.
   The hook can't tell the difference, but you're now lying to yourself.
3. **Comment out the hook in `settings.json`.** Last resort. Re-enable
   immediately after debugging. Don't commit a disabled-hook config.

## Dry-run testing

You can pipe fake JSON to test hook logic without a real Claude Code
session:

```bash
echo '{"tool_input":{"command":"git push"}}' | .claude/hooks/pre-bash.sh
echo "exit: $?"
```

The hook checks for a `session_id` field in the input and skips
destructive marker cleanup when it's absent (so dry runs don't eat real
waivers). Real Claude Code invocations always include `session_id`.

## Hook protocol notes

- Hooks receive the Claude Code hook JSON on stdin.
- `PreToolUse` hooks block by exiting 2 with a stderr message; the
  message is shown to Claude.
- `PostToolUse` hooks have their stdout/stderr surfaced as info, not
  error.
- The hook runs in the project root (Claude Code sets CWD).
- Use `$CLAUDE_PROJECT_DIR` in `settings.json` paths for portability.
