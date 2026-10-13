#!/usr/bin/env bash
# Shared setup for a headless Hyprland session. Source this file.
# The caller owns set -euo pipefail and the EXIT trap.

headless_env() {
    PREFIX="${PREFIX:-$ROOT/.build/prefix}"
    RUNTIME="${XDG_RUNTIME_DIR:-/tmp/hypr-rt}"
    LOG="${HYPR_LOG:-$ROOT/.build/hyprland.log}"
    export PATH="$PREFIX/bin:$PATH"
    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
    export XDG_RUNTIME_DIR="$RUNTIME"
    export XDG_CURRENT_DESKTOP=Hyprland
}

headless_require() {
    if [[ -e /dev/dri ]]; then
        echo "refusing to run: /dev/dri exists" >&2
        return 1
    fi
    if [[ ! -x "$PREFIX/bin/Hyprland" || ! -x "$PREFIX/bin/grim" || ! -x "$PREFIX/bin/hyprctl" ]]; then
        echo "missing Hyprland, grim, or hyprctl in $PREFIX/bin. Run scripts/build.sh first." >&2
        return 1
    fi
}

headless_kill_stale() {
    local name
    for name in Hyprland start-hyprland shm-window foot frame-timer vinput input-sink; do
        pkill -x "$name" 2>/dev/null || true
    done
    sleep 0.3
    for name in Hyprland start-hyprland shm-window foot frame-timer vinput input-sink; do
        pkill -9 -x "$name" 2>/dev/null || true
    done
    sleep 0.2
    return 0
}

headless_prepare_runtime() {
    mkdir -p "$RUNTIME" "$ROOT/.build"
    chmod 700 "$RUNTIME"
    rm -rf "$RUNTIME/hypr" "$RUNTIME"/wayland-*
}

headless_start() {
    local config="$1"
    : >"$LOG"
    "$PREFIX/bin/start-hyprland" -- --config "$config" >"$LOG" 2>&1 &
    HPID=$!
}

headless_wait() {
    local socket=""
    local signature=""
    local _
    for _ in $(seq 1 60); do
        if ! kill -0 "$HPID" 2>/dev/null; then
            echo "Hyprland exited before the socket appeared" >&2
            tail -80 "$LOG" >&2
            return 1
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
        return 1
    fi
    export WAYLAND_DISPLAY="$(basename "$socket")"
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
        return 1
    fi
    export HYPRLAND_INSTANCE_SIGNATURE="$signature"
}

headless_stop() {
    if [[ -n "${HPID:-}" ]] && kill -0 "$HPID" 2>/dev/null; then
        kill "$HPID" 2>/dev/null || true
        local _
        for _ in 1 2 3 4 5; do
            kill -0 "$HPID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$HPID" 2>/dev/null || true
        wait "$HPID" 2>/dev/null || true
    fi
    headless_kill_stale
    return 0
}
