#!/bin/sh
# Regenerate LongList and diff it against the checked-in sample.
set -eu
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
zig build run -- --schema testdata/avsc/longlist.avsc --out "$out"
diff -u tests/generated/LongList.zig "$out/LongList.zig"
echo "generated LongList matches"
