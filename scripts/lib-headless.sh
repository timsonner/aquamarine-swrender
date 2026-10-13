#!/usr/bin/env bash
# Shared setup for a headless Hyprland session. Source this file.
# The caller owns set -euo pipefail and the EXIT trap.
#
# Runtime and HOME are private directories this process creates with mktemp.
# Inherited XDG_RUNTIME_DIR is ignored. Cleanup signals only PIDs recorded in
# the private runtime (their process group when this script started that
# group) and deletes only those owned directories.

headless_env() {
    PREFIX="${PREFIX:-$ROOT/.build/prefix}"
    LOG="${HYPR_LOG:-$ROOT/.build/hyprland.log}"
    # Never adopt a caller's runtime directory.
    unset XDG_RUNTIME_DIR
    unset RUNTIME
    export PATH="$PREFIX/bin:$PATH"
    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
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

# Refuse a runtime or home path that could belong to a live session.
headless_assert_private() {
    local path="$1"
    local label="$2"
    local resolved
    if [[ -z "$path" || "$path" != /* || "$path" == "/" || "$path" == "/tmp" || "$path" == "/tmp/" ]]; then
        echo "refusing $label path: ${path:-empty}" >&2
        return 1
    fi
    resolved="$(realpath -m "$path")"
    case "$resolved" in
        /run/user|/run/user/*)
            echo "refusing $label path under /run/user: $resolved" >&2
            return 1
            ;;
        /tmp/hypr-rt.*|/tmp/hypr-home.*)
            ;;
        *)
            echo "refusing unexpected $label path: $resolved" >&2
            return 1
            ;;
    esac
    return 0
}

headless_prepare_runtime() {
    if [[ -n "${HEADLESS_OWNED_RUNTIME:-}" ]]; then
        echo "headless runtime already prepared" >&2
        return 1
    fi
    mkdir -p "$ROOT/.build"
    # sun_path is 108 bytes. The template stays under /tmp and stays short.
    # mktemp with a template does not consult XDG_RUNTIME_DIR or TMPDIR.
    RUNTIME="$(mktemp -d /tmp/hypr-rt.XXXXXX)"
    HOME="$(mktemp -d /tmp/hypr-home.XXXXXX)"
    headless_assert_private "$RUNTIME" runtime
    headless_assert_private "$HOME" home
    printf '%s\n' "$$" >"$RUNTIME/.headless-owned"
    printf '%s\n' "$$" >"$HOME/.headless-owned"
    chmod 700 "$RUNTIME" "$HOME"
    HEADLESS_OWNED_RUNTIME="$RUNTIME"
    HEADLESS_OWNED_HOME="$HOME"
    HEADLESS_PIDFILE="$RUNTIME/pids"
    : >"$HEADLESS_PIDFILE"
    chmod 600 "$HEADLESS_PIDFILE"
    export RUNTIME HOME
    export XDG_RUNTIME_DIR="$RUNTIME"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
}

headless_track() {
    local pid="$1"
    if [[ -z "${HEADLESS_PIDFILE:-}" || ! -f "$HEADLESS_PIDFILE" ]]; then
        echo "headless_track: private runtime is not ready" >&2
        return 1
    fi
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "headless_track: not a pid: $pid" >&2
        return 1
    fi
    printf '%s\n' "$pid" >>"$HEADLESS_PIDFILE"
}

# Start a command in its own session so stop can signal that group only.
# Redirections on the call apply to the command. Sets HEADLESS_LAST_PID.
headless_spawn() {
    python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
    HEADLESS_LAST_PID=$!
    headless_track "$HEADLESS_LAST_PID"
}

headless_start() {
    local config="$1"
    mkdir -p "$(dirname "$LOG")"
    : >"$LOG"
    # start-hyprland forks Hyprland in this process group.
    headless_spawn "$PREFIX/bin/start-hyprland" -- --config "$config" >"$LOG" 2>&1
    HPID=$HEADLESS_LAST_PID
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

headless_pgid() {
    local pid="$1"
    local stat rest
    [[ -r "/proc/$pid/stat" ]] || return 1
    stat="$(cat "/proc/$pid/stat")"
    # comm is wrapped in parentheses and may contain spaces.
    rest="${stat#*) }"
    awk '{print $3}' <<<"$rest"
}

# Pids from headless_spawn are session leaders. Hyprland is forked into that
# group and can ignore SIGTERM after the watchdog exits, so the group is
# signaled even when the leader's /proc entry is already gone.
headless_signal() {
    local sig="$1"
    local pid="$2"
    if ! kill "-$sig" -- "-$pid" 2>/dev/null; then
        kill "-$sig" "$pid" 2>/dev/null || true
    fi
}

headless_group_members() {
    local want="$1"
    local pid stat rest pgid
    local entry
    for entry in /proc/[0-9]*; do
        pid="${entry##*/}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$pid" == "$$" || "$pid" == "1" ]] && continue
        stat="$(cat "$entry/stat" 2>/dev/null || true)"
        [[ -n "$stat" ]] || continue
        rest="${stat#*) }"
        pgid="$(awk '{print $3}' <<<"$rest")"
        if [[ "$pgid" == "$want" ]]; then
            printf '%s\n' "$pid"
        fi
    done
}

headless_remove_owned() {
    local path="$1"
    local resolved owner
    [[ -n "$path" ]] || return 0
    resolved="$(realpath -m "$path")"
    case "$resolved" in
        /tmp/hypr-rt.*|/tmp/hypr-home.*)
            ;;
        *)
            echo "refusing to remove $path" >&2
            return 0
            ;;
    esac
    case "$resolved" in
        /run/user|/run/user/*)
            echo "refusing to remove $resolved" >&2
            return 0
            ;;
    esac
    if [[ ! -f "$resolved/.headless-owned" ]]; then
        echo "refusing to remove $resolved without an ownership marker" >&2
        return 0
    fi
    owner="$(cat "$resolved/.headless-owned" 2>/dev/null || true)"
    if [[ "$owner" != "$$" ]]; then
        echo "refusing to remove $resolved owned by ${owner:-unknown}" >&2
        return 0
    fi
    rm -rf -- "$resolved"
}

headless_stop() {
    local pid p member _
    local -a pids=()
    local -a members=()
    if [[ -n "${HEADLESS_PIDFILE:-}" && -f "$HEADLESS_PIDFILE" ]]; then
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            pids+=("$pid")
        done <"$HEADLESS_PIDFILE"
    fi
    if [[ -n "${HPID:-}" ]]; then
        pids+=("$HPID")
    fi
    for p in "${pids[@]}"; do
        while read -r member; do
            members+=("$member")
        done < <(headless_group_members "$p")
        # Drop the shell's job record so a signaled leader does not print Aborted.
        disown "$p" 2>/dev/null || true
    done
    for p in "${pids[@]}"; do
        headless_signal TERM "$p"
    done
    for _ in 1 2 3 4 5; do
        local alive=0
        for member in "${members[@]}"; do
            if [[ -d "/proc/$member" ]]; then
                alive=1
            fi
        done
        [[ "$alive" -eq 0 ]] && break
        sleep 0.2
    done
    for p in "${pids[@]}"; do
        headless_signal KILL "$p"
    done
    for member in "${members[@]}"; do
        if [[ -d "/proc/$member" ]]; then
            kill -KILL "$member" 2>/dev/null || true
        fi
    done
    for p in "${pids[@]}"; do
        wait "$p" 2>/dev/null || true
    done
    HPID=""
    if [[ -n "${HEADLESS_OWNED_RUNTIME:-}" ]]; then
        headless_remove_owned "$HEADLESS_OWNED_RUNTIME"
        HEADLESS_OWNED_RUNTIME=""
        RUNTIME=""
        HEADLESS_PIDFILE=""
        unset XDG_RUNTIME_DIR
    fi
    if [[ -n "${HEADLESS_OWNED_HOME:-}" ]]; then
        headless_remove_owned "$HEADLESS_OWNED_HOME"
        HEADLESS_OWNED_HOME=""
    fi
    return 0
}
