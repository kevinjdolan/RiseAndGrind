#!/bin/bash
# Remove the background from one or more renders using Photoshop's Select Subject.
#
# Usage:
#   ./remove_bg.sh [--trim] IMAGE [IMAGE ...]
#
# Writes <basename>.png beside each input, then verifies the alpha channel.
# --trim additionally crops to the subject's bounding box (off by default, to
# match the existing assets, which keep the source canvas).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSX="$SCRIPT_DIR/ps_remove_bg_and_crop.jsx"
PS_APP="Adobe Photoshop (Beta)"

INPUTS=/tmp/ps_bg_inputs.txt
RESULT=/tmp/ps_bg_result.txt
TRIM_FLAG=/tmp/ps_bg_trim.txt

rm -f "$TRIM_FLAG"
if [ "${1:-}" = "--trim" ]; then
    touch "$TRIM_FLAG"
    shift
fi

if [ "$#" -eq 0 ]; then
    echo "usage: $(basename "$0") [--trim] IMAGE [IMAGE ...]" >&2
    exit 2
fi

# Photoshop needs absolute paths; fail loudly rather than silently skipping.
: > "$INPUTS"
for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "no such file: $f" >&2
        exit 1
    fi
    python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$f" >> "$INPUTS"
done

echo "Processing $(wc -l < "$INPUTS" | tr -d ' ') file(s)..."
rm -f "$RESULT"

osascript <<EOF >/dev/null
set jsCode to (read (POSIX file "$JSX") as «class utf8»)
tell application "$PS_APP"
	activate
	do javascript jsCode
end tell
EOF

if [ ! -f "$RESULT" ]; then
    echo "Photoshop produced no result file — did the script fail to run?" >&2
    exit 1
fi

echo
cat "$RESULT"
echo
echo "Verifying alpha:"
awk -F'\t' '$1=="OK" {print $2}' "$RESULT" | while read -r png; do
    python3 - "$png" <<'PY'
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p)
a = im.convert('RGBA').getchannel('A')
h = a.histogram()
tot = a.size[0] * a.size[1]
name = p.rsplit('/', 1)[-1]
print(f"  {name:34s} {im.mode} {im.size} bbox={a.getbbox()} "
      f"transparent={h[0]/tot:.3f} opaque={h[255]/tot:.3f} soft_edge_px={sum(h[1:255])}")
if im.mode != 'RGBA' or h[0] == 0:
    sys.exit(f"  WARNING: {name} has no transparency — background removal did not apply")
PY
done
