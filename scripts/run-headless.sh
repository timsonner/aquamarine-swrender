#!/usr/bin/env bash
# Start the patched Hyprland with no DRM device and take one grim screenshot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/.build/prefix}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp/hypr-headless-runtime}"
SHOT="${1:-$ROOT/proof/hyprland-headless.png}"
LOG="${HYPR_LOG:-$ROOT/.build/hyprland.log}"

export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export XDG_RUNTIME_DIR="$RUNTIME"

mkdir -p "$RUNTIME" "$(dirname "$SHOT")" "$ROOT/.build"
chmod 700 "$RUNTIME"

if [[ -e /dev/dri ]]; then
    echo "refusing to run: /dev/dri exists" >&2
    exit 1
fi

if [[ ! -x "$PREFIX/bin/Hyprland" || ! -x "$PREFIX/bin/grim" ]]; then
    echo "missing Hyprland or grim in $PREFIX/bin. Run scripts/build.sh first." >&2
    exit 1
fi

# A previous run may still hold the socket. Hyprland can ignore SIGTERM after it forks.
pkill -x Hyprland 2>/dev/null || true
sleep 0.3
pkill -9 -x Hyprland 2>/dev/null || true
sleep 0.2

: > "$LOG"
"$PREFIX/bin/Hyprland" --config "$ROOT/scripts/headless.conf" > "$LOG" 2>&1 &
HPID=$!

cleanup() {
    if kill -0 "$HPID" 2>/dev/null; then
        kill "$HPID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$HPID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$HPID" 2>/dev/null || true
        wait "$HPID" 2>/dev/null || true
    fi
    pkill -x Hyprland 2>/dev/null || true
    sleep 0.2
    pkill -9 -x Hyprland 2>/dev/null || true
}
trap cleanup EXIT

socket=""
for _ in $(seq 1 60); do
    if ! kill -0 "$HPID" 2>/dev/null; then
        echo "Hyprland exited before the socket appeared" >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    socket="$(find "$RUNTIME" -maxdepth 1 -name 'wayland-*' -type s | head -1 || true)"
    if [[ -n "$socket" ]]; then
        break
    fi
    sleep 0.5
done

if [[ -z "$socket" ]]; then
    echo "timed out waiting for a wayland socket" >&2
    tail -80 "$LOG" >&2
    exit 1
fi

export WAYLAND_DISPLAY="$(basename "$socket")"
# The compositor is up. Give the first frame a moment to land.
sleep 1

if ! "$PREFIX/bin/grim" -o HEADLESS-1 "$SHOT"; then
    echo "grim failed" >&2
    tail -80 "$LOG" >&2
    exit 1
fi

if [[ ! -s "$SHOT" ]]; then
    echo "screenshot is empty" >&2
    exit 1
fi

echo "screenshot $SHOT"
echo "wayland $WAYLAND_DISPLAY"
file "$SHOT" || true
identify "$SHOT" 2>/dev/null || python3 - << PY
import struct, zlib
p = open("$SHOT", "rb").read()
assert p[:8] == b"\x89PNG\r\n\x1a\n"
# IHDR
w, h = struct.unpack(">II", p[16:24])
print(f"png {w}x{h} bytes {len(p)}")
PY
