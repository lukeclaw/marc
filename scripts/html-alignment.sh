#!/bin/bash
# Compares marc's source parser against the rendered DOM for an HTML file, using
# the same WebKit engine and the same reader script the app uses.
#
#   scripts/html-alignment.sh Tests/Fixtures/html-stress-test.html
#   scripts/html-alignment.sh Tests/Fixtures/html-stress-test.html --write
#
# --write refreshes the snapshots the stress fixtures embed in their own reports.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/marc-html-alignment"
mkdir -p "$build"
swiftc -O -o "$build/html-alignment" \
  "$root"/Sources/MarcCore/*.swift "$root/scripts/html-alignment.swift"
exec "$build/html-alignment" "$@"
