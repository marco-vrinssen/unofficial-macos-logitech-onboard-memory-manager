#!/bin/sh
set -e

# Prefer the Homebrew bin because it is user owned and already on PATH
if [ -z "$PREFIX" ] && [ -w /opt/homebrew/bin ]; then
	PREFIX=/opt/homebrew/bin
fi

PREFIX="${PREFIX:-$HOME/.local/bin}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

swift build -c release --package-path "$ROOT"

mkdir -p "$PREFIX"
install -m 755 "$ROOT/.build/release/lomm" "$PREFIX/lomm"

echo "installed $PREFIX/lomm"
"$PREFIX/lomm" list
