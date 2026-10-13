#!/usr/bin/env bash
# Capture proof/hyprland-headless-foot.png.
# The two foot panes run the commands in pane_info and pane_gfx. Nothing in the
# shot is typed by hand. fastfetch is tried first. On this Ubuntu image it is
# not packaged, so the pane shows that error and then neofetch --stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"
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
}

pane_info() {
    set +e
    # eglinfo returns non-zero when GBM or X11 fail. pipefail would hide a successful grep.
    set +o pipefail
    wait_rows 36
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
    set +o pipefail
    wait_rows 58
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

if ! command -v foot >/dev/null 2>&1; then
    echo "foot is not installed" >&2
    exit 1
fi

headless_env
headless_require
headless_prepare_runtime
trap 'ec=$?; headless_stop; exit "$ec"' EXIT
mkdir -p "$(dirname "$SHOT")"
rm -f "$ROOT/.build/proof-pane-info.done" "$ROOT/.build/proof-pane-gfx.done"

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
        gaps_in = 6,
        gaps_out = 8,
        border_size = 4,
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

headless_start "$ROOT/.build/proof-headless.lua"
headless_wait || exit 1

# 13px keeps hyprctl monitors on screen, including the HEADLESS-1 line. 15px scrolled it off.
FOOT_FONT="${FOOT_FONT:-JetBrains Mono:pixelsize=13}"
headless_spawn foot -a proof-info -T proof-info -o dpi-aware=no -o pad=2x2 -f "$FOOT_FONT" \
    "$ROOT/scripts/proof-terminal.sh" --pane info \
    >"$ROOT/.build/foot-info.log" 2>&1
headless_spawn foot -a proof-gfx -T proof-gfx -o dpi-aware=no -o pad=2x2 -f "$FOOT_FONT" \
    "$ROOT/scripts/proof-terminal.sh" --pane gfx \
    >"$ROOT/.build/foot-gfx.log" 2>&1

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
