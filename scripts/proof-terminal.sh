#!/usr/bin/env bash
# Capture proof/hyprland-headless-foot.png.
# The two foot panes run the commands in pane_info and pane_gfx. Nothing in the
# shot is typed by hand. fastfetch is tried first. On this Ubuntu image it is
# not packaged, so the pane shows that error and then neofetch --stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/.build/prefix}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp/hypr-rt}"
LOG="${HYPR_LOG:-$ROOT/.build/hyprland.log}"
SHOT="$ROOT/proof/hyprland-headless-foot.png"

wait_rows() {
    local need="$1"
    local rows=""
    local _
    for _ in $(seq 1 80); do
        rows="$(stty size 2>/dev/null | awk '{print $1}' || true)"
        if [[ -n "$rows" && "$rows" -ge "$need" ]]; then
            return 0
        fi
        sleep 0.1
    done
    echo "tty stayed at $(stty size 2>/dev/null || echo unknown), needed ${need} rows" >&2
}

pane_info() {
    set +e
    wait_rows 40
    PS4='+ '
    set -x
    if ! fastfetch; then
        neofetch --stdout
    fi
    ls -l /dev/dri
    lspci -nn | grep -Ei 'vga|3d|display' || echo 'no GPU'
    eglinfo -B 2>&1 | grep -E 'platform:|eglInitialize|renderer:' || echo 'eglinfo grep matched nothing'
    set +x
    mkdir -p "$ROOT/.build"
    stty size >"$ROOT/.build/proof-pane-info.done" 2>/dev/null || true
    sleep 60
}

pane_gfx() {
    set +e
    wait_rows 52
    PS4='+ '
    set -x
    hyprctl monitors
    hyprctl version
    set +x
    mkdir -p "$ROOT/.build"
    stty size >"$ROOT/.build/proof-pane-gfx.done" 2>/dev/null || true
    sleep 60
}

if [[ "${1:-}" == "--pane" ]]; then
    case "${2:-}" in
        info) pane_info ;;
        gfx) pane_gfx ;;
        *)
            echo "unknown pane ${2:-}" >&2
            exit 2
            ;;
    esac
    exit 0
fi

if [[ $# -gt 0 ]]; then
    SHOT="$1"
fi

export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export XDG_RUNTIME_DIR="$RUNTIME"
export XDG_CURRENT_DESKTOP=Hyprland

mkdir -p "$RUNTIME" "$(dirname "$SHOT")" "$ROOT/.build"
chmod 700 "$RUNTIME"
rm -rf "$RUNTIME/hypr" "$RUNTIME"/wayland-*
rm -f "$ROOT/.build/proof-pane-info.done" "$ROOT/.build/proof-pane-gfx.done"

if [[ -e /dev/dri ]]; then
    echo "refusing to run: /dev/dri exists" >&2
    exit 1
fi

if [[ ! -x "$PREFIX/bin/Hyprland" || ! -x "$PREFIX/bin/grim" || ! -x "$PREFIX/bin/hyprctl" ]]; then
    echo "missing Hyprland, grim, or hyprctl in $PREFIX/bin. Run scripts/build.sh first." >&2
    exit 1
fi

if ! command -v foot >/dev/null 2>&1; then
    echo "foot is not installed" >&2
    exit 1
fi

# Same monitor and the same notice suppression as scripts/headless.lua.
# Gaps are tighter here so both panes stay readable in one 1920x1080 frame.
cat >"$ROOT/.build/proof-headless.lua" <<'EOF'
hl.monitor({
    output = "HEADLESS-1",
    mode = "1920x1080@60",
    position = "0x0",
    scale = "1",
})

hl.config({
    general = {
        gaps_in = 8,
        gaps_out = 12,
        border_size = 6,
        col = {
            active_border = "rgba(ff8800ff)",
            inactive_border = "rgba(ff8800ff)",
        },
    },
    decoration = {
        rounding = 0,
        shadow = { enabled = false },
        blur = { enabled = false },
    },
    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_guiutils_check = true,
        disable_xdg_env_checks = true,
        disable_watchdog_warning = true,
    },
    debug = {
        disable_logs = false,
    },
})
EOF

pkill -x Hyprland 2>/dev/null || true
pkill -x start-hyprland 2>/dev/null || true
pkill -x foot 2>/dev/null || true
sleep 0.3
pkill -9 -x Hyprland 2>/dev/null || true
pkill -9 -x start-hyprland 2>/dev/null || true
pkill -9 -x foot 2>/dev/null || true
sleep 0.2

: >"$LOG"
"$PREFIX/bin/start-hyprland" -- --config "$ROOT/.build/proof-headless.lua" >"$LOG" 2>&1 &
HPID=$!

cleanup() {
    if kill -0 "$HPID" 2>/dev/null; then
        kill "$HPID" 2>/dev/null || true
        local _
        for _ in 1 2 3 4 5; do
            kill -0 "$HPID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$HPID" 2>/dev/null || true
        wait "$HPID" 2>/dev/null || true
    fi
    pkill -x foot 2>/dev/null || true
    pkill -x Hyprland 2>/dev/null || true
    pkill -x start-hyprland 2>/dev/null || true
    sleep 0.2
    pkill -9 -x foot 2>/dev/null || true
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

FOOT_FONT="${FOOT_FONT:-JetBrains Mono:pixelsize=15}"
foot -a proof-info -T proof-info -o dpi-aware=no -f "$FOOT_FONT" \
    "$ROOT/scripts/proof-terminal.sh" --pane info \
    >"$ROOT/.build/foot-info.log" 2>&1 &
foot -a proof-gfx -T proof-gfx -o dpi-aware=no -f "$FOOT_FONT" \
    "$ROOT/scripts/proof-terminal.sh" --pane gfx \
    >"$ROOT/.build/foot-gfx.log" 2>&1 &

mapped=0
for _ in $(seq 1 40); do
    if "$PREFIX/bin/hyprctl" clients 2>/dev/null | grep -q 'proof-info' \
        && "$PREFIX/bin/hyprctl" clients 2>/dev/null | grep -q 'proof-gfx'; then
        mapped=1
        break
    fi
    sleep 0.25
done
if [[ "$mapped" -ne 1 ]]; then
    echo "foot panes did not map" >&2
    "$PREFIX/bin/hyprctl" clients >&2 || true
    echo "--- foot-info ---" >&2
    cat "$ROOT/.build/foot-info.log" >&2 || true
    echo "--- foot-gfx ---" >&2
    cat "$ROOT/.build/foot-gfx.log" >&2 || true
    exit 1
fi

ready=0
for _ in $(seq 1 80); do
    if [[ -s "$ROOT/.build/proof-pane-info.done" && -s "$ROOT/.build/proof-pane-gfx.done" ]]; then
        ready=1
        break
    fi
    sleep 0.25
done
if [[ "$ready" -ne 1 ]]; then
    echo "timed out waiting for pane output" >&2
    echo "info $(cat "$ROOT/.build/proof-pane-info.done" 2>/dev/null || echo missing)" >&2
    echo "gfx $(cat "$ROOT/.build/proof-pane-gfx.done" 2>/dev/null || echo missing)" >&2
    exit 1
fi

# Let the last glyph land in the framebuffer before grim.
sleep 0.6

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
echo "info tty $(cat "$ROOT/.build/proof-pane-info.done")"
echo "gfx tty $(cat "$ROOT/.build/proof-pane-gfx.done")"
echo "wayland $WAYLAND_DISPLAY"
file "$SHOT" || true
python3 - <<PY
import struct
p = open("$SHOT", "rb").read()
assert p[:8] == b"\x89PNG\r\n\x1a\n"
w, h = struct.unpack(">II", p[16:24])
print(f"png {w}x{h} bytes {len(p)}")
PY
