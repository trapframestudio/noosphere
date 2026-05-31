# Security

Noosphere is a private, pre-release repo right now, so this is pretty
informal. If you've found a security issue:

- **You're a collaborator on the repo:** open an issue, slap a `security`
  label on it, include enough detail to reproduce. Issues on a private repo
  are already only visible to collaborators, so that's the private channel.
- **You're not a collaborator:** ping [@joniler](https://github.com/joniler)
  directly however you can reach him.

Same deal for [Code of Conduct](CODE_OF_CONDUCT.md) stuff - file an issue
with a `conduct` label, or DM Jon.

When the repo goes public this'll switch over to GitHub's private
vulnerability reporting and get a bit more formal. Until then, just talk to
us.

## What we care about (rough scope)

Noosphere is pre-alpha and the security model is "don't run mods from
strangers." That said, things worth flagging:

- Memory safety bugs in any of the `simn-*` Rust crates.
- Crashes, out-of-bounds reads, or panics in any `simn-*` Rust crate
  from malformed input. These matter most for anything that will
  eventually run on network-delivered content.
- Path traversal, arbitrary file write, or sandbox escapes in mod
  loaders, scripting, or any asset loading path.
- Anything that lets a malicious mod or save file mess with the host beyond
  what we've documented as expected.

Things that aren't really in scope yet:

- Multiplayer cheating / anti-cheat. Not a goal in pre-alpha.
- Stuff that needs the attacker to already have local code execution.
- DoS via legitimately huge inputs.

No bug bounty - this is a volunteer project. We'll credit you in the fix
unless you'd rather stay anonymous.
