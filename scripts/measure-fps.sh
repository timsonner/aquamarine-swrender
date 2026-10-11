#!/usr/bin/env bash
# Measure llvmpipe frame timing on HEADLESS-1.
# Static phase: one damage, then wl_surface.frame callbacks with no further damage.
# Damage phase: the client damages the buffer on every callback.
# Intervals are CLOCK_MONOTONIC deltas between consecutive callbacks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"

STATIC_MS=3000
DAMAGE_MS=5000
while [[ $# -gt 0 ]]; do
    case "$1" in
        --static-ms)
            STATIC_MS="$2"
            shift 2
            ;;
        --damage-ms)
            DAMAGE_MS="$2"
            shift 2
            ;;
        *)
            echo "usage: $0 [--static-ms N] [--damage-ms N]" >&2
            exit 2
            ;;
    esac
done

headless_env
headless_require
headless_kill_stale
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
"$PREFIX/bin/frame-timer" --static-ms "$STATIC_MS" --damage-ms "$DAMAGE_MS" | tee "$RAW"

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
        return
    intervals.sort()
    n = len(intervals)
    def pct(p):
        idx = round((n - 1) * p)
        return intervals[idx] / 1e6
    mean = sum(intervals) / n / 1e6
    fps = (frames - 1) / (elapsed_ns / 1e9)
    print(f"  fps {fps:.3f}")
    print(f"  interval_ms min {intervals[0] / 1e6:.3f} mean {mean:.3f} p50 {pct(0.50):.3f} p95 {pct(0.95):.3f} max {intervals[-1] / 1e6:.3f}")

summarize("static")
summarize("damage")
PY
