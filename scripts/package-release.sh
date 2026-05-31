#!/usr/bin/env bash
# Build a release package you can hand to someone else.
#
# Usage: ./scripts/package-release.sh [linux|windows|both]  (default: both)
#
# Linux output:   build/noosphere-linux.zip
# Windows output: build/noosphere-windows.zip
#
# Each zip unpacks to a folder with the game binary + .pck + native
# extension .so/.dll + Steam redistributable + steam_appid.txt. The
# recipient needs Steam installed and running; no Rust/Godot required.

set -euo pipefail

target="${1:-both}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

check_templates() {
    local platform="$1"
    local godot_version
    godot_version="$(godot --version | head -1 | cut -d'.' -f1-3).stable"
    local template_dir="$HOME/.local/share/godot/export_templates/$godot_version"
    if [[ ! -d "$template_dir" ]]; then
        echo "ERROR: Godot export templates not found at $template_dir" >&2
        echo "  Godot editor → Editor → Manage Export Templates → Download and Install" >&2
        exit 1
    fi
    # Platform-specific template files live inside; let Godot's export fail
    # loudly if the platform-specific pieces are missing.
    echo "  Templates dir: $template_dir"
}

package_linux() {
    echo "==> Linux build"
    echo "    cargo build --release (native)…"
    cargo build -p simn-godot --release

    local bin="$here/godot/bin/linux"
    mkdir -p "$bin"
    cp "$here/target/release/libsimn_godot.so" "$bin/"
    cp "$here/target/release/libsteam_api.so" "$bin/"

    check_templates Linux

    local out="$here/build/linux"
    mkdir -p "$out"
    rm -f "$out"/*
    godot --headless --path "$here/godot" --export-release "Linux" "$out/noosphere.x86_64"

    cp "$bin/libsteam_api.so" "$out/"
    cp "$here/steam_appid.txt" "$out/"
    chmod +x "$out/noosphere.x86_64"

    ( cd "$here/build" && rm -f noosphere-linux.zip && zip -r noosphere-linux.zip linux )
    echo "    → build/noosphere-linux.zip"
}

package_windows() {
    echo "==> Windows build"
    echo "    cargo xwin build --release --target x86_64-pc-windows-msvc…"
    if ! command -v cargo-xwin >/dev/null; then
        echo "ERROR: cargo-xwin not installed. Run: cargo install cargo-xwin" >&2
        exit 1
    fi
    cargo xwin build --release --target x86_64-pc-windows-msvc -p simn-godot

    local bin="$here/godot/bin/windows"
    mkdir -p "$bin"
    cp "$here/target/x86_64-pc-windows-msvc/release/simn_godot.dll" "$bin/"
    # steamworks-sys drops the Windows DLL in its build output dir.
    local steam_dll
    steam_dll="$(find "$here/target/x86_64-pc-windows-msvc/release/build" -name 'steam_api64.dll' | head -1)"
    if [[ -z "$steam_dll" ]]; then
        echo "ERROR: steam_api64.dll not found in Windows build output" >&2
        exit 1
    fi
    cp "$steam_dll" "$bin/"

    check_templates "Windows Desktop"

    local out="$here/build/windows"
    mkdir -p "$out"
    rm -f "$out"/*
    godot --headless --path "$here/godot" --export-release "Windows Desktop" "$out/noosphere.exe"

    cp "$bin/steam_api64.dll" "$out/"
    cp "$here/steam_appid.txt" "$out/"

    ( cd "$here/build" && rm -f noosphere-windows.zip && zip -r noosphere-windows.zip windows )
    echo "    → build/noosphere-windows.zip"
}

case "$target" in
    linux)   package_linux ;;
    windows) package_windows ;;
    both)    package_linux; package_windows ;;
    *)       echo "Unknown target: $target" >&2; exit 1 ;;
esac

echo
echo "Done."
echo
echo "Recipient instructions:"
echo "  1. Make sure Steam is installed and signed in."
echo "  2. Unzip the archive."
echo "  3. Run the binary (noosphere.x86_64 / noosphere.exe)."
echo "  4. Click 'Host' to get a lobby ID, or paste one into 'Join'."
