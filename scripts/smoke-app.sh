#!/usr/bin/env bash
# Launch one app inside a headless Hyprland session and decide if its window
# is actually on screen.
#
#   scripts/smoke-app.sh [--timeout SEC] [--shot PATH] [--min-variance N] [--class NAME] -- CMD [ARGS...]
#
# Exit 0  window mapped and the grim crop is not a flat color
# Exit 1  compositor, grim, or usage failure
# Exit 2  no mapped window before the timeout
# Exit 3  window mapped, capture is blank
#
# Environment overrides: SMOKE_TIMEOUT, SMOKE_SHOT, SMOKE_MIN_VARIANCE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-headless.sh
source "$ROOT/scripts/lib-headless.sh"

TIMEOUT="${SMOKE_TIMEOUT:-20}"
SHOT="${SMOKE_SHOT:-$ROOT/.build/smoke-app.png}"
MIN_VAR="${SMOKE_MIN_VARIANCE:-25}"
CLASS=""
CMD=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --shot)
            SHOT="$2"
            shift 2
            ;;
        --min-variance)
            MIN_VAR="$2"
            shift 2
            ;;
        --class)
            CLASS="$2"
            shift 2
            ;;
        --)
            shift
            CMD=("$@")
            break
            ;;
        --*)
            echo "unknown option $1" >&2
            exit 1
            ;;
        *)
            CMD=("$@")
            break
            ;;
    esac
done

if [[ ${#CMD[@]} -eq 0 ]]; then
    echo "usage: $0 [--timeout SEC] [--shot PATH] [--min-variance N] [--class NAME] -- CMD [ARGS...]" >&2
    exit 1
fi

headless_env
headless_require
headless_kill_stale
headless_prepare_runtime
mkdir -p "$(dirname "$SHOT")" "$ROOT/.build"
trap 'ec=$?; headless_stop; exit "$ec"' EXIT

headless_start "$ROOT/scripts/headless.lua"
headless_wait || exit 1

"${CMD[@]}" >"$ROOT/.build/smoke-app.log" 2>&1 &
APP_PID=$!

python_match='
import json, os, sys
want = os.environ.get("SMOKE_CLASS", "")
try:
    clients = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
found = None
for client in clients:
    if client.get("mapped") is False:
        continue
    if want and want not in (client.get("class") or "", client.get("initialClass") or "", client.get("title") or ""):
        continue
    found = client
if not found:
    raise SystemExit(1)
at = found.get("at") or [0, 0]
size = found.get("size") or [0, 0]
print(at[0], at[1], size[0], size[1], found.get("class") or "", found.get("title") or "")
'

deadline=$((SECONDS + TIMEOUT))
GEOM=""
while ((SECONDS < deadline)); do
    if ! kill -0 "$HPID" 2>/dev/null; then
        echo "smoke status=compositor exit=1" >&2
        tail -40 "$LOG" >&2 || true
        exit 1
    fi
    if GEOM="$(SMOKE_CLASS="$CLASS" "$PREFIX/bin/hyprctl" clients -j | SMOKE_CLASS="$CLASS" python3 -c "$python_match")"; then
        break
    fi
    GEOM=""
    sleep 0.25
done

if [[ -z "$GEOM" ]]; then
    echo "smoke status=no-window exit=2 timeout=${TIMEOUT}" >&2
    "$PREFIX/bin/hyprctl" clients >&2 || true
    echo "--- app log ---" >&2
    cat "$ROOT/.build/smoke-app.log" >&2 || true
    exit 2
fi

read -r ATX ATY WINW WINH WINCLASS WINTITLE <<<"$GEOM"

if ! "$PREFIX/bin/grim" -o HEADLESS-1 "$SHOT"; then
    echo "smoke status=compositor exit=1 grim-failed" >&2
    tail -40 "$LOG" >&2 || true
    exit 1
fi

set +e
RESULT="$(python3 - "$SHOT" "$ATX" "$ATY" "$WINW" "$WINH" "$MIN_VAR" <<'PY'
import struct, sys, zlib

path, atx, aty, winw, winh, threshold = sys.argv[1:]
atx, aty, winw, winh = (int(float(v)) for v in (atx, aty, winw, winh))
threshold = float(threshold)
data = open(path, "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    print("status=unreadable")
    raise SystemExit(0)
pos = 8
width = height = color = depth = interlace = None
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
if interlace != 0 or depth != 8 or color not in (2, 6):
    print(f"status=unreadable png {width}x{height} depth={depth} color={color} interlace={interlace}")
    raise SystemExit(0)
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
        print(f"status=unreadable filter={filt}")
        raise SystemExit(0)
    rows.append(row)
    prev = row

x0 = max(0, atx)
y0 = max(0, aty)
x1 = min(width, atx + winw)
y1 = min(height, aty + winh)
count = 0
total = 0.0
samples = []
if x1 > x0 and y1 > y0:
    step = 1
    area = (x1 - x0) * (y1 - y0)
    if area > 250000:
        step = 2
    for y in range(y0, y1, step):
        row = rows[y]
        for x in range(x0, x1, step):
            i = x * channels
            r, g, b = row[i], row[i + 1], row[i + 2]
            lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            samples.append(lum)
            total += lum
            count += 1
if count == 0:
    print("variance=0 status=blank")
    raise SystemExit(0)
mean = total / count
var = sum((v - mean) ** 2 for v in samples) / count
status = "pass" if var >= threshold else "blank"
print(f"variance={var:.4f} samples={count} status={status} png={width}x{height} crop={x0},{y0},{x1 - x0}x{y1 - y0}")
PY
)"
py_status=$?
set -e
if [[ "$py_status" -ne 0 ]]; then
    echo "smoke status=compositor exit=1 variance-failed" >&2
    exit 1
fi

echo "$RESULT"
case "$RESULT" in
    *status=pass*)
        echo "smoke status=pass exit=0 class=${WINCLASS} title=${WINTITLE} pid=${APP_PID} shot=${SHOT} ${RESULT}"
        exit 0
        ;;
    *status=blank*)
        echo "smoke status=blank exit=3 class=${WINCLASS} shot=${SHOT} ${RESULT}" >&2
        exit 3
        ;;
    *)
        echo "smoke status=compositor exit=1 ${RESULT}" >&2
        exit 1
        ;;
esac
