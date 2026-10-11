#!/bin/sh
# Print ns/op for one Event record. ReleaseFast.
set -eu
cd "$(dirname "$0")/.."
zig build bench -Doptimize=ReleaseFast
