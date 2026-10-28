#!/bin/sh
# accuracy.sh — compare `du -sk` totals with `n4s-scan --json` per directory.
# Usage: scripts/accuracy.sh <dir>...
#
# Differences to expect (documented in README): du counts each directory's own
# inode (4 KB on APFS) and rounds file sizes up to 1K blocks; the scanner ignores
# directory inodes and uses ATTR_FILE_ALLOCSIZE (512-byte blocks, i.e. st_blocks*512).
# Hard links are counted once by both. A few percent on inode-heavy trees is normal.
set -eu

cd "$(dirname "$0")/.."

BIN=".build/release/n4s-scan"
if [ ! -x "$BIN" ]; then
    echo "accuracy.sh: building n4s-scan (release)..." >&2
    swift build -c release --product n4s-scan
fi

if [ "$#" -eq 0 ]; then
    echo "usage: scripts/accuracy.sh <dir>..." >&2
    exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for d in "$@"; do
    "$BIN" "$d" --json > "$tmp/scan.json" 2>/dev/null
    du -sk "$d" > "$tmp/du.txt"
    python3 - "$d" "$tmp/scan.json" "$tmp/du.txt" <<'PY'
import json, sys

path = sys.argv[1]
with open(sys.argv[2]) as f:
    report = json.load(f)
with open(sys.argv[3]) as f:
    du_kb = int(f.read().split()[0])
scan_kb = report["bytesAllocated"] // 1024
diff = (scan_kb - du_kb) * 100.0 / du_kb if du_kb else 0.0
print(f"{path:<48} {du_kb:>16,} {scan_kb:>16,} {diff:>+7.2f}%")
PY
done
