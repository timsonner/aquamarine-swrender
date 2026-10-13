#!/usr/bin/env bash
# Start the patched Hyprland with no DRM device and take one grim screenshot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"
CLIENT=0
TERMINAL=0
SHOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --client)
            CLIENT=1
            shift
            ;;
        --terminal)
            TERMINAL=1
            shift
            ;;
        *)
            SHOT="$1"
            shift
            ;;
    esac
done

# The foot proof is produced by scripts/proof-terminal.sh, including the commands in the shot.
if [[ "$TERMINAL" -eq 1 ]]; then
    if [[ -n "$SHOT" ]]; then
        exec "$ROOT/scripts/proof-terminal.sh" "$SHOT"
    fi
    exec "$ROOT/scripts/proof-terminal.sh"
fi

if [[ -z "$SHOT" ]]; then
    if [[ "$CLIENT" -eq 1 ]]; then
        SHOT="$ROOT/proof/hyprland-headless-client.png"
    else
        SHOT="$ROOT/proof/hyprland-headless.png"
    fi
fi

headless_env
headless_require
headless_prepare_runtime
mkdir -p "$(dirname "$SHOT")"
trap 'ec=$?; headless_stop; exit "$ec"' EXIT
headless_start "$ROOT/scripts/headless.lua"
headless_wait || exit 1

if [[ "$CLIENT" -eq 1 ]]; then
    "$ROOT/scripts/build-client.sh"
    headless_spawn "$PREFIX/bin/shm-window"
    CPID=$HEADLESS_LAST_PID
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
