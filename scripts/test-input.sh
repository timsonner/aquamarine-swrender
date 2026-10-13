#!/usr/bin/env bash
# Prove keyboard text and a left click reach a client on the headless output.
#
#   scripts/test-input.sh [--timeout SEC] [--text STRING]
#
# Exit 0  the client decoded the text and received BTN_LEFT
# Exit 1  compositor, build, or usage failure
# Exit 2  no mapped window before the timeout
# Exit 4  the window mapped and the text never arrived
# Exit 5  the text arrived and no left button did
#
# Environment overrides: INPUT_TIMEOUT, INPUT_TEXT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"

TIMEOUT="${INPUT_TIMEOUT:-20}"
TEXT="${INPUT_TEXT:-KEYBOARD-OK-7741}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --text)
            TEXT="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        --*)
            echo "unknown option $1" >&2
            exit 1
            ;;
        *)
            echo "unknown argument $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$TEXT" || "$TIMEOUT" -le 0 ]]; then
    echo "usage: $0 [--timeout SEC] [--text STRING]" >&2
    exit 1
fi

headless_env
headless_require
headless_kill_stale
headless_prepare_runtime

OUTDIR="$ROOT/.build/client"
mkdir -p "$OUTDIR" "$ROOT/.build"
BOUND="$(mktemp -d)"
KB_BOUND="$BOUND/keyboard"
PTR_BOUND="$BOUND/pointer"
trap 'ec=$?; rm -rf "$BOUND"; headless_stop; exit "$ec"' EXIT

"$PREFIX/bin/wayland-scanner" client-header \
    "$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
    "$OUTDIR/xdg-shell-client-protocol.h"
"$PREFIX/bin/wayland-scanner" private-code \
    "$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
    "$OUTDIR/xdg-shell-protocol.c"
"$PREFIX/bin/wayland-scanner" client-header \
    "$ROOT/clients/virtual-keyboard-unstable-v1.xml" \
    "$OUTDIR/virtual-keyboard-unstable-v1-client-protocol.h"
"$PREFIX/bin/wayland-scanner" private-code \
    "$ROOT/clients/virtual-keyboard-unstable-v1.xml" \
    "$OUTDIR/virtual-keyboard-unstable-v1-protocol.c"
"$PREFIX/bin/wayland-scanner" client-header \
    "$ROOT/clients/wlr-virtual-pointer-unstable-v1.xml" \
    "$OUTDIR/wlr-virtual-pointer-unstable-v1-client-protocol.h"
"$PREFIX/bin/wayland-scanner" private-code \
    "$ROOT/clients/wlr-virtual-pointer-unstable-v1.xml" \
    "$OUTDIR/wlr-virtual-pointer-unstable-v1-protocol.c"

gcc -O2 -Wall -Wextra -Wno-unused-parameter -I"$OUTDIR" -o "$PREFIX/bin/input-sink" \
    "$ROOT/clients/input-sink.c" \
    "$OUTDIR/xdg-shell-protocol.c" \
    $(pkg-config --cflags --libs wayland-client xkbcommon)
gcc -O2 -I"$OUTDIR" -o "$PREFIX/bin/vinput" \
    "$ROOT/clients/vinput.c" \
    "$OUTDIR/virtual-keyboard-unstable-v1-protocol.c" \
    "$OUTDIR/wlr-virtual-pointer-unstable-v1-protocol.c" \
    $(pkg-config --cflags --libs wayland-client xkbcommon)

headless_start "$ROOT/scripts/headless.lua"
headless_wait || exit 1

CLIENT_TIMEOUT=$((TIMEOUT + 45))
SINK_OUT="$ROOT/.build/input-sink.out"
SINK_LOG="$ROOT/.build/input-sink.log"
"$PREFIX/bin/input-sink" \
    --text "$TEXT" \
    --timeout "$CLIENT_TIMEOUT" \
    --kb-bound "$KB_BOUND" \
    --ptr-bound "$PTR_BOUND" \
    >"$SINK_OUT" 2>"$SINK_LOG" &
SINK_PID=$!

deadline=$((SECONDS + TIMEOUT))
mapped=0
while ((SECONDS < deadline)); do
    if ! kill -0 "$HPID" 2>/dev/null; then
        echo "test-input status=compositor exit=1" >&2
        tail -40 "$LOG" >&2 || true
        exit 1
    fi
    if ! kill -0 "$SINK_PID" 2>/dev/null; then
        echo "test-input status=compositor exit=1 client-exited" >&2
        cat "$SINK_LOG" >&2 || true
        cat "$SINK_OUT" >&2 || true
        exit 1
    fi
    if "$PREFIX/bin/hyprctl" clients 2>/dev/null | grep -q 'input-sink'; then
        mapped=1
        break
    fi
    sleep 0.25
done

if [[ "$mapped" -ne 1 ]]; then
    echo "test-input status=no-window exit=2 timeout=${TIMEOUT}" >&2
    "$PREFIX/bin/hyprctl" clients >&2 || true
    cat "$SINK_LOG" >&2 || true
    exit 2
fi

"$PREFIX/bin/hyprctl" dispatch focuswindow "class:input-sink" >/dev/null || true

read -r CX CY < <("$PREFIX/bin/hyprctl" clients -j | python3 -c '
import json, sys
clients = json.load(sys.stdin)
for client in clients:
    if "input-sink" not in (client.get("class") or "", client.get("initialClass") or "", client.get("title") or ""):
        continue
    at = client.get("at") or [0, 0]
    size = client.get("size") or [0, 0]
    # The buffer may be smaller than the tiled window and sit at its top left.
    print(int(at[0] + min(size[0] / 2, 160)), int(at[1] + min(size[1] / 2, 120)))
    raise SystemExit(0)
raise SystemExit("input-sink window missing")
')
echo "test-input click ${CX},${CY}" >&2

TYPE_LOG="$ROOT/.build/vinput-type.log"
set +e
VINPUT_WAIT_BOUND="$KB_BOUND" "$PREFIX/bin/vinput" type "$TEXT" >"$TYPE_LOG" 2>&1
type_ec=$?
set -e
if [[ "$type_ec" -ne 0 ]]; then
    cat "$TYPE_LOG" >&2 || true
    cat "$SINK_LOG" >&2 || true
    if grep -q 'VINPUT_WAIT_BOUND' "$TYPE_LOG"; then
        echo "test-input status=no-keyboard exit=4" >&2
        exit 4
    fi
    echo "test-input status=compositor exit=1 vinput-type=${type_ec}" >&2
    exit 1
fi

PTR_LOG="$ROOT/.build/vinput-pointer.log"
set +e
VINPUT_WAIT_POINTER="$PTR_BOUND" "$PREFIX/bin/vinput" drag "$CX" "$CY" "$CX" "$CY" >"$PTR_LOG" 2>&1
ptr_ec=$?
set -e
if [[ "$ptr_ec" -ne 0 ]]; then
    cat "$PTR_LOG" >&2 || true
    cat "$SINK_LOG" >&2 || true
    if grep -q 'VINPUT_WAIT_POINTER' "$PTR_LOG"; then
        echo "test-input status=no-pointer exit=5" >&2
        exit 5
    fi
    echo "test-input status=compositor exit=1 vinput-pointer=${ptr_ec}" >&2
    exit 1
fi

sink_ec=1
for _ in $(seq 1 40); do
    if ! kill -0 "$SINK_PID" 2>/dev/null; then
        set +e
        wait "$SINK_PID"
        sink_ec=$?
        set -e
        break
    fi
    sleep 0.25
done

if kill -0 "$SINK_PID" 2>/dev/null; then
    echo "test-input status=compositor exit=1 client-hung" >&2
    cat "$PTR_LOG" >&2 || true
    cat "$SINK_OUT" >&2 || true
    cat "$SINK_LOG" >&2 || true
    exit 1
fi

RESULT="$(cat "$SINK_OUT" 2>/dev/null || true)"
echo "$RESULT"
case "$sink_ec" in
    0)
        if grep -F "status=pass" <<<"$RESULT" >/dev/null && grep -F "text=${TEXT}" <<<"$RESULT" >/dev/null; then
            echo "test-input status=pass exit=0 text=${TEXT} click=${CX},${CY} ${RESULT}"
            exit 0
        fi
        echo "test-input status=compositor exit=1 bad-pass-line ${RESULT}" >&2
        exit 1
        ;;
    4)
        echo "test-input status=no-keyboard exit=4 ${RESULT}" >&2
        cat "$SINK_LOG" >&2 || true
        exit 4
        ;;
    5)
        echo "test-input status=no-pointer exit=5 ${RESULT}" >&2
        cat "$SINK_LOG" >&2 || true
        exit 5
        ;;
    *)
        echo "test-input status=compositor exit=1 client=${sink_ec} ${RESULT}" >&2
        cat "$SINK_LOG" >&2 || true
        exit 1
        ;;
esac
