#!/usr/bin/env bash
# Type a command into foot with a virtual keyboard, run it, then drag-select
# the output with a virtual pointer. The grim shot is the proof.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"

SHOT="$ROOT/proof/hyprland-headless-input.png"
if [[ $# -gt 0 ]]; then
    SHOT="$1"
fi

if ! command -v foot >/dev/null 2>&1; then
    echo "foot is not installed" >&2
    exit 1
fi

headless_env
headless_require
headless_kill_stale
headless_prepare_runtime
trap 'ec=$?; headless_stop; exit "$ec"' EXIT

OUTDIR="$ROOT/.build/client"
mkdir -p "$OUTDIR" "$(dirname "$SHOT")"
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
gcc -O2 -I"$OUTDIR" -o "$PREFIX/bin/vinput" \
    "$ROOT/clients/vinput.c" \
    "$OUTDIR/virtual-keyboard-unstable-v1-protocol.c" \
    "$OUTDIR/wlr-virtual-pointer-unstable-v1-protocol.c" \
    $(pkg-config --cflags --libs wayland-client xkbcommon)

headless_start "$ROOT/scripts/headless.lua"
headless_wait

export PS1='$ '
foot -a proof-input -T proof-input -o dpi-aware=no -o pad=8x8 \
    -f "JetBrains Mono:pixelsize=32" \
    bash --noprofile --norc \
    >"$ROOT/.build/foot-input.log" 2>&1 &
FOOT_PID=$!

mapped=0
for _ in $(seq 1 40); do
    if "$PREFIX/bin/hyprctl" clients 2>/dev/null | grep -q 'proof-input'; then
        mapped=1
        break
    fi
    if ! kill -0 "$FOOT_PID" 2>/dev/null; then
        echo "foot exited before mapping" >&2
        cat "$ROOT/.build/foot-input.log" >&2 || true
        exit 1
    fi
    sleep 0.25
done
if [[ "$mapped" -ne 1 ]]; then
    echo "foot did not map" >&2
    "$PREFIX/bin/hyprctl" clients >&2 || true
    cat "$ROOT/.build/foot-input.log" >&2 || true
    exit 1
fi

sleep 0.6
"$PREFIX/bin/vinput" type $'echo KEYBOARD-OK-7741\n'
sleep 0.6

read -r ATX ATY WINW WINH < <("$PREFIX/bin/hyprctl" clients -j | python3 -c '
import json, sys
clients = json.load(sys.stdin)
for client in clients:
    if client.get("class") == "proof-input" or client.get("initialClass") == "proof-input":
        print(client["at"][0], client["at"][1], client["size"][0], client["size"][1])
        raise SystemExit(0)
raise SystemExit("proof-input window missing")
')

PROBE="$ROOT/.build/input-probe.png"
"$PREFIX/bin/grim" -o HEADLESS-1 "$PROBE"
read -r X1 Y X2 < <(python3 - "$PROBE" "$ATX" "$ATY" "$WINW" "$WINH" <<'PY'
import struct, sys, zlib
path, atx, aty, winw, winh = sys.argv[1:]
atx, aty, winw, winh = (int(v) for v in (atx, aty, winw, winh))
data = open(path, "rb").read()
pos = 8
width = height = color = None
idat = b""
while pos + 8 <= len(data):
    length = struct.unpack(">I", data[pos:pos + 4])[0]
    kind = data[pos + 4:pos + 8]
    chunk = data[pos + 8:pos + 8 + length]
    pos += 12 + length
    if kind == b"IHDR":
        width, height, depth, color, comp, filt, interlace = struct.unpack(">IIBBBBB", chunk)
    elif kind == b"IDAT":
        idat += chunk
    elif kind == b"IEND":
        break
channels = 3 if color == 2 else 4
stride = width * channels
raw = zlib.decompress(idat)
rows = []
index = 0
prev = bytearray(stride)

def paeth(left, up, ul):
    estimate = left + up - ul
    da, db, dc = abs(estimate - left), abs(estimate - up), abs(estimate - ul)
    if da <= db and da <= dc:
        return left
    if db <= dc:
        return up
    return ul

for _y in range(height):
    filt = raw[index]
    index += 1
    row = bytearray(raw[index:index + stride])
    index += stride
    if filt == 1:
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            row[x] = (row[x] + left) & 255
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 255
    elif filt == 3:
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            row[x] = (row[x] + ((left + prev[x]) // 2)) & 255
    elif filt == 4:
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = prev[x]
            ul = prev[x - channels] if x >= channels else 0
            row[x] = (row[x] + paeth(left, up, ul)) & 255
    elif filt != 0:
        raise SystemExit(f"unsupported png filter {filt}")
    rows.append(row)
    prev = row

bands = []
in_band = False
x0 = atx + 8
x1 = min(width, atx + winw - 8)
y0 = aty
y1 = min(height, aty + winh)
for y in range(y0, y1):
    bright = 0
    for x in range(x0, x1):
        i = x * channels
        if sum(rows[y][i:i + 3]) > 500:
            bright += 1
            if bright > 8:
                break
    if bright > 8:
        if not in_band:
            bands.append([y, y])
            in_band = True
        else:
            bands[-1][1] = y
    else:
        in_band = False
# Drop the block cursor, which is a short wide mark, by keeping bands taller than 8px.
text = [band for band in bands if band[1] - band[0] >= 8]
if len(text) < 2:
    raise SystemExit(f"expected the command and its output, found bands {bands}")
line = text[1]
mid = (line[0] + line[1]) // 2
print(x0 + 12, mid, x0 + 520)
PY
)
echo "window at ${ATX},${ATY} ${WINW}x${WINH}"
echo "drag ${X1},${Y} -> ${X2},${Y}"
"$PREFIX/bin/vinput" drag "$X1" "$Y" "$X2" "$Y"
sleep 0.5

if ! "$PREFIX/bin/grim" -o HEADLESS-1 "$SHOT"; then
    echo "grim failed" >&2
    tail -40 "$LOG" >&2
    exit 1
fi
echo "screenshot $SHOT"
python3 - "$SHOT" <<'PY'
import struct, sys
p = open(sys.argv[1], "rb").read()
assert p[:8] == b"\x89PNG\r\n\x1a\n"
w, h = struct.unpack(">II", p[16:24])
print(f"png {w}x{h} bytes {len(p)}")
PY
