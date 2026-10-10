#!/usr/bin/env bash
# Start the patched Hyprland with no DRM device and take one grim screenshot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/.build/prefix}"
# sun_path is 108 bytes. The instance signature plus .socket.sock needs a short runtime dir.
RUNTIME="${XDG_RUNTIME_DIR:-/tmp/hypr-rt}"
LOG="${HYPR_LOG:-$ROOT/.build/hyprland.log}"
CLIENT=0
SHOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --client)
            CLIENT=1
            shift
            ;;
        *)
            SHOT="$1"
            shift
            ;;
    esac
done

if [[ -z "$SHOT" ]]; then
    if [[ "$CLIENT" -eq 1 ]]; then
        SHOT="$ROOT/proof/hyprland-headless-client.png"
    else
        SHOT="$ROOT/proof/hyprland-headless.png"
    fi
fi

export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export XDG_RUNTIME_DIR="$RUNTIME"

mkdir -p "$RUNTIME" "$(dirname "$SHOT")" "$ROOT/.build"
chmod 700 "$RUNTIME"
rm -rf "$RUNTIME/hypr" "$RUNTIME"/wayland-*

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
pkill -x start-hyprland 2>/dev/null || true
pkill -x shm-window 2>/dev/null || true
sleep 0.3
pkill -9 -x Hyprland 2>/dev/null || true
pkill -9 -x start-hyprland 2>/dev/null || true
pkill -9 -x shm-window 2>/dev/null || true
sleep 0.2

: > "$LOG"
export XDG_CURRENT_DESKTOP=Hyprland
# start-hyprland is the watchdog Hyprland expects. Args after -- go to Hyprland.
"$PREFIX/bin/start-hyprland" -- --config "$ROOT/scripts/headless.lua" > "$LOG" 2>&1 &
HPID=$!
CPID=""

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
    if [[ -n "${CPID:-}" ]] && kill -0 "$CPID" 2>/dev/null; then
        kill "$CPID" 2>/dev/null || true
    fi
    pkill -x shm-window 2>/dev/null || true
    pkill -x Hyprland 2>/dev/null || true
    pkill -x start-hyprland 2>/dev/null || true
    sleep 0.2
    pkill -9 -x shm-window 2>/dev/null || true
    pkill -9 -x Hyprland 2>/dev/null || true
    pkill -9 -x start-hyprland 2>/dev/null || true
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

if [[ "$CLIENT" -eq 1 ]]; then
    "$ROOT/scripts/build-client.sh"
    signature=""
    for _ in $(seq 1 40); do
        signature="$(find "$RUNTIME/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -1 || true)"
        if [[ -n "$signature" ]]; then
            break
        fi
        sleep 0.1
    done
    if [[ -z "$signature" ]]; then
        echo "no Hyprland instance signature" >&2
        tail -40 "$LOG" >&2
        exit 1
    fi
    export HYPRLAND_INSTANCE_SIGNATURE="$signature"
    "$PREFIX/bin/shm-window" &
    CPID=$!
    mapped=0
    for _ in $(seq 1 40); do
        if ! kill -0 "$CPID" 2>/dev/null; then
            echo "shm-window exited before mapping" >&2
            exit 1
        fi
        if "$PREFIX/bin/hyprctl" clients 2>/dev/null | grep -q 'shm-window'; then
            mapped=1
            break
        fi
        sleep 0.25
    done
    if [[ "$mapped" -ne 1 ]]; then
        echo "shm-window did not map" >&2
        "$PREFIX/bin/hyprctl" clients >&2 || true
        tail -40 "$LOG" >&2
        exit 1
    fi
fi

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
