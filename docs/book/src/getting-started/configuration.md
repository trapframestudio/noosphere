# Configuration

> **In transition.** Earlier versions of Noosphere included experimental
> importers for community file formats and a workflow that pointed at
> external content directories. That workflow is being reevaluated as
> the project shifts toward an original world. The instructions below
> reflect the current minimal configuration. Older notes about
> external content directories have been removed pending decisions
> about Noosphere's own asset pipeline.

## Binary assets (Git LFS)

Large binary assets (heightmaps, HDRIs, compressed textures, audio, 3D
interchange formats) are stored via [Git LFS]. Patterns are declared in
`.gitattributes` at the repo root; any file matching a listed extension
or path glob is routed to LFS automatically on `git add`.

### One-time setup

```bash
# Install the git-lfs binary (once per machine)
sudo dnf install git-lfs     # Fedora
sudo apt install git-lfs     # Debian/Ubuntu
brew install git-lfs         # macOS

# Register the LFS filters for your user (once per machine)
git lfs install
```

After cloning this repo for the first time, `git lfs pull` fetches the
actual binary contents for files you've checked out. A fresh clone of a
LFS-using repo will contain small pointer files in place of binaries
until the pull runs.

### What's tracked

See `.gitattributes` for the full list. Headline patterns:

| Pattern | Purpose |
|---|---|
| `*.r16`, `*.r32` | Terrain heightmaps (server-master source of truth) |
| `*.exr`, `*.hdr` | HDR textures / sky probes |
| `*.ktx2`, `*.dds`, `*.basis` | Compressed GPU textures |
| `*.blend`, `*.fbx`, `*.glb`, `*.obj`, `*.usd` | 3D authoring / interchange |
| `*.wav`, `*.ogg`, `*.flac`, `*.opus` | Audio |
| `*.mp4`, `*.webm`, `*.mov` | Video |
| `godot/assets/{environments,terrain,textures,models}/**/*.{png,jpg}` | Path-scoped - bulk art PNGs/JPGs go to LFS only inside these trees. Small authored PNGs (icons, the Godot project icon) stay as regular git blobs. |

### Asset directory layout

```
godot/assets/
├── backdrops/       # Menu art (SVG, small - regular git)
├── fonts/           # TTF/WOFF2 (regular git)
├── icons/           # UI SVG (regular git)
├── logos/           # Brand SVG (regular git)
├── environments/    # HDRI sky probes (*.exr → LFS)
├── terrain/         # Per-map heightmaps: <map_id>/{heightmap.r16, terrain.toml, …} (→ LFS)
├── textures/        # Bulk 3D textures (→ LFS for PNG/JPG inside)
└── models/          # 3D assets (→ LFS)
```

The `.gitignore` used to exclude most of `godot/assets/` wholesale; as
directories get populated with committed assets, their exclusions are
being removed so the content lives in git (via LFS) rather than on each
developer's machine only.

[Git LFS]: https://git-lfs.com/

## Running the editor

```bash
cargo build -p simn-godot
godot godot/project.godot
```

The Rust extension loads automatically via `simn.gdextension`. If
you change Rust code, rebuild and either save a file in the editor
(hot reload) or restart it.

## Steam integration

The networking layer uses the Steamworks SDK via `steamworks-rs`. For
development, the repo ships `steam_appid.txt` files (containing `480`,
Valve's public test app "Spacewar") at both the workspace root and
`godot/`, so either launch path works without a proprietary app id.

At runtime you need:

- **Steam client running and signed in.** `NetSession::init` asks Steam
  for the local user, which fails if Steam isn't running.
- **`libsteam_api.so` reachable by the loader.** `crates/simn-godot/build.rs`
  copies it from the `steamworks-sys` output directory into
  `target/<profile>/` on every build. `libsimn_godot.so` has its rpath
  set to `$ORIGIN`, so the runtime linker finds it automatically.

See [Networking](../architecture/networking.md) for the current
(listen-server P2P) scope and the session → lobby → invite flow.

## Running the game

Open the editor and press F5 (or invoke `godot godot/project.godot`
directly). The main menu has **Host**, a **Join by Lobby ID** row, and
**Quit**.

### Save format compatibility

The world save format (`world.save` + `world.journal` under
`OS.get_user_data_dir() + "/saves/"`) is versioned. When the version
bumps, older saves load with a hard error. Delete the contents of
the saves directory and start fresh - there's no migration tooling
yet, since the project is pre-alpha and saves are dev artifacts.
The format version is a `u32` tracked by
`simn_sim::persistence::format::FORMAT_VERSION` and bumps any time
a schema change lands (new resource, new component field, new
enum variant). It's intentionally loose during pre-alpha; stale
dev saves get discarded rather than migrated.
`Sim::load_or_new` falls back to a fresh sim if it can't load a
snapshot, so version mismatches in dev are recoverable - the stale
files get deleted automatically.

### Inviting a friend

Two paths, depending on how the game was launched:

- **Launched via Steam** (add Godot or the compiled game as a "Non-Steam
  Game" in Steam and start it from the Library): the Steam overlay is
  injected into the process, so Host pops the overlay invite dialog
  automatically and a friend who accepts is auto-joined.
- **Launched directly** (`godot godot/project.godot` from a terminal -
  the normal dev loop): the Steam overlay cannot inject into processes
  Steam didn't launch, so `activate_invite_dialog` is a silent no-op.
  Use the lobby-ID fallback instead: Host copies the lobby ID to the
  clipboard and shows it in the menu's status label; share it via
  Discord/chat; the friend pastes it into the **Join by Lobby ID** field.

Both paths end at the same `LobbyReady` event and load `map_a`.

## Packaging a build to send someone

```bash
./scripts/package-release.sh            # Linux + Windows
./scripts/package-release.sh linux      # Linux only
./scripts/package-release.sh windows    # Windows only
```

Produces `build/noosphere-linux.zip` and/or `build/noosphere-windows.zip`.
The recipient needs Steam installed and running; they don't need Rust,
Godot, or any build tools. Unzip, run the binary, host/join via the
lobby-ID fallback just like the dev flow.

### One-time setup on the build machine

- **Godot export templates** for both targets: Godot editor → Editor →
  Manage Export Templates → Download and Install.
- **Windows cross-compile toolchain** (Linux → Windows only):
  ```bash
  rustup target add x86_64-pc-windows-msvc
  cargo install cargo-xwin
  ```
  First `cargo xwin build` downloads ~200MB of MSVC CRT headers into
  `~/.cache/cargo-xwin/`. `steamworks-sys` ships `steam_api64.lib` in
  MSVC format, so the `-msvc` target lines up; the `-gnu` (MinGW) target
  does not.
