#!/bin/bash
# Builds and runs the test suites in Tests/. Each suite is a folder with its
# own main.swift, compiled against the app's sources.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build/tests"
mkdir -p "$BUILD"
SOURCES=$(ls "$ROOT"/Sources/*.swift | grep -v 'main.swift')
SUPPORT="$ROOT/Tests/Support/Support.swift"

status=0
for suite in "$ROOT"/Tests/*/; do
  name=$(basename "$suite")
  [ "$name" = "Support" ] && continue
  [ -f "$suite/main.swift" ] || continue
  echo "== $name"
  if ! swiftc -o "$BUILD/$name" $SOURCES "$SUPPORT" "$suite/main.swift" 2>&1 | grep -E "error" ; then
    "$BUILD/$name" || status=1
  else
    echo "  ✗ build failed"
    status=1
  fi
  defaults delete "$name" 2>/dev/null
done
exit $status
