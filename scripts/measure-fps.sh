#!/usr/bin/env bash
# Measure headless frame rate and frame-time distribution on HEADLESS-1.
#
# clients/frame-timer.c is a fullscreen xdg-shell wl_shm window, 1280x720.
# The static phase damages the buffer once, then keeps requesting
# wl_surface.frame. The damage phase repaints and damages the whole buffer
# on every callback. That second phase is the animating client. Each phase
# runs for a fixed window (--static-ms, default 3000; --damage-ms, default
# 5000). Intervals are CLOCK_MONOTONIC deltas between consecutive callbacks.
# Frames per second are (frames - 1) / elapsed_seconds. Percentiles use the
# sorted intervals, index round((n - 1) * p).
#
#   scripts/measure-fps.sh [--static-ms N] [--damage-ms N]
#
# Exit 0  the damage phase printed fps, p50, p95, and max
# Exit 1  the compositor died, the client build failed, or the arguments are wrong
# Exit 2  the client finished and the damage phase has too few frames
#
# Runtime and HOME come from scripts/lib-headless.sh. Inherited
# XDG_RUNTIME_DIR is ignored. Both directories are private mktemp paths.
# A path under /run/user is refused. Cleanup signals only process groups
# this script started, and only when this process owns them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"

usage() {
    echo "usage: $0 [--static-ms N] [--damage-ms N]" >&2
    exit 1
}

STATIC_MS=3000
DAMAGE_MS=5000
while [[ $# -gt 0 ]]; do
    case "$1" in
        --static-ms|--damage-ms)
            flag="$1"
            [[ $# -ge 2 ]] || usage
            value="$2"
            if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
                usage
            fi
            if [[ "$flag" == "--static-ms" ]]; then
                STATIC_MS="$value"
            else
                DAMAGE_MS="$value"
            fi
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

headless_env
headless_require
headless_prepare_runtime
trap 'ec=$?; headless_stop; exit "$ec"' EXIT

OUTDIR="$ROOT/.build/client"
mkdir -p "$OUTDIR"
"$PREFIX/bin/wayland-scanner" client-header \
    "$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
    "$OUTDIR/xdg-shell-client-protocol.h"
"$PREFIX/bin/wayland-scanner" private-code \
    "$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
    "$OUTDIR/xdg-shell-protocol.c"
gcc -O2 -I"$OUTDIR" -o "$PREFIX/bin/frame-timer" \
    "$ROOT/clients/frame-timer.c" "$OUTDIR/xdg-shell-protocol.c" \
    $(pkg-config --cflags --libs wayland-client)

headless_start "$ROOT/scripts/headless.lua"
headless_wait

RAW="$ROOT/.build/fps-raw.txt"
set +e
"$PREFIX/bin/frame-timer" --static-ms "$STATIC_MS" --damage-ms "$DAMAGE_MS" | tee "$RAW"
# One assignment. A second statement would replace PIPESTATUS before the tee status is read.
statuses=("${PIPESTATUS[@]}")
set -e
client_ec=${statuses[0]}
tee_ec=${statuses[1]}
if [[ "$client_ec" -ne 0 || "$tee_ec" -ne 0 ]]; then
    echo "frame-timer exited $client_ec" >&2
    exit 1
fi

echo "=== hyprctl monitors ==="
"$PREFIX/bin/hyprctl" monitors || true

python3 - "$RAW" <<'PY'
import sys
path = sys.argv[1]
data = {}
for line in open(path):
    parts = line.split()
    if not parts:
        continue
    key = parts[0]
    data[key] = parts[1:]

def summarize(name):
    frames = int(data.get(f"{name}_frames", ["0"])[0])
    elapsed_ns = int(data.get(f"{name}_elapsed_ns", ["0"])[0])
    intervals = [int(x) for x in data.get(f"{name}_intervals_ns", [])]
    print(f"phase {name}")
    print(f"  frames {frames}")
    print(f"  elapsed_s {elapsed_ns / 1e9:.6f}")
    if frames < 2 or elapsed_ns <= 0 or not intervals:
        print("  fps n/a")
        return False
    intervals.sort()
    n = len(intervals)
    def pct(p):
        idx = round((n - 1) * p)
        return intervals[idx] / 1e6
    mean = sum(intervals) / n / 1e6
    fps = (frames - 1) / (elapsed_ns / 1e9)
    p50 = pct(0.50)
    p95 = pct(0.95)
    longest = intervals[-1] / 1e6
    print(f"  fps {fps:.3f}")
    print(f"  interval_ms min {intervals[0] / 1e6:.3f} mean {mean:.3f} p50 {p50:.3f} p95 {p95:.3f} max {longest:.3f}")
    return True

summarize("static")
if not summarize("damage"):
    print("measure-fps: damage phase has no frame-time distribution", file=sys.stderr)
    sys.exit(2)
PY
