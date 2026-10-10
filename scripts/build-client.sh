#!/usr/bin/env bash
# Build the wl_shm xdg-shell client into the private prefix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/.build/prefix}"
OUTDIR="${OUTDIR:-$ROOT/.build/client}"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CC="${CC:-gcc}"

mkdir -p "$OUTDIR"
"$PREFIX/bin/wayland-scanner" client-header \
    "$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
    "$OUTDIR/xdg-shell-client-protocol.h"
"$PREFIX/bin/wayland-scanner" private-code \
    "$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
    "$OUTDIR/xdg-shell-protocol.c"
"$CC" -O2 -I"$OUTDIR" -o "$PREFIX/bin/shm-window" \
    "$ROOT/clients/shm-window.c" "$OUTDIR/xdg-shell-protocol.c" \
    $("$PREFIX/bin/pkg-config" --cflags --libs wayland-client 2>/dev/null || pkg-config --cflags --libs wayland-client)
echo "built $PREFIX/bin/shm-window"
