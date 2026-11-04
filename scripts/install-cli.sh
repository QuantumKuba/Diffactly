#!/usr/bin/env bash
# Builds the `diffactly` command-line tool and installs it.
# Usage: scripts/install-cli.sh [install-dir]   (default: /usr/local/bin, falls back to ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/../DiffactlyKit"
swift build -c release --product diffactly
bin="$(swift build -c release --show-bin-path)/diffactly"
dest="${1:-/usr/local/bin}"
if [ ! -w "$dest" ]; then dest="$HOME/.local/bin"; mkdir -p "$dest"; fi
install -m 755 "$bin" "$dest/diffactly"
echo "Installed diffactly to $dest/diffactly"
case ":$PATH:" in *":$dest:"*) ;; *) echo "Note: add $dest to your PATH" ;; esac
