#!/usr/bin/env bash
# test.sh - run the whole Lune suite and the Rojo build.
#
# Usage: ./test.sh
#
# Both need Lune and Rojo on PATH. Exits non-zero if anything fails, so it is
# safe to wire into CI.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

fail=0

if ! command -v lune >/dev/null 2>&1; then
  echo "ERROR: lune not found. Install from https://lune-org.github.io" >&2
  exit 127
fi

echo "== module logic =="
lune run tests/run.luau || fail=1

echo
echo "== map integrity =="
lune run tests/map.luau || fail=1

echo
if command -v rojo >/dev/null 2>&1; then
  echo "== rojo build =="
  rojo build --output deadzone.rbxl || fail=1
else
  echo "== rojo build =="
  echo "SKIP: rojo not found (optional - only needed to produce deadzone.rbxl)"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAILED"
  exit 1
fi
echo "RESULT: all checks passed"
