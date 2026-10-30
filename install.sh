#!/bin/sh
# Installs or updates Koe: curl -fsSL https://raw.githubusercontent.com/nqrwhal/Koe/main/install.sh | sh
set -eu

url="https://github.com/nqrwhal/Koe/releases/latest/download/Koe.zip"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Koe needs an Apple Silicon Mac." >&2; exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
    echo "Koe needs macOS 15 or later." >&2; exit 1
fi

# /Applications if writable, otherwise ~/Applications. KOE_INSTALL_DIR overrides.
dir="${KOE_INSTALL_DIR:-/Applications}"
if [ -z "${KOE_INSTALL_DIR:-}" ] && [ ! -w /Applications ]; then dir="$HOME/Applications"; fi
mkdir -p "$dir"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading Koe…"
curl -fL --progress-bar "$url" -o "$tmp/Koe.zip"
ditto -x -k "$tmp/Koe.zip" "$tmp"

pkill -x Koe 2>/dev/null || true
rm -rf "$dir/Koe.app"
mv "$tmp/Koe.app" "$dir/Koe.app"
echo "Installed $dir/Koe.app"

if [ -z "${KOE_INSTALL_DIR:-}" ]; then
    open "$dir/Koe.app"
    echo "Koe is in your menu bar (声). Grant Accessibility and Microphone access when asked;"
    echo "on first launch it downloads about 6 GB of models. Hold Right ⌘ to dictate."
fi
