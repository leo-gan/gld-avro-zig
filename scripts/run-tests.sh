#!/bin/sh
# Run the Zig test suite. Zig 0.16 must be on PATH.
set -eu
cd "$(dirname "$0")/.."
zig build test
