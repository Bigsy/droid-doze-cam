#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift test
python3 scripts/test-build-tools.py
for SCRIPT in scripts/*.sh; do bash -n "$SCRIPT"; done
# Parser checks are additional checks only; they do NOT substitute for macOS SDK type checking/linking.
swiftc -frontend -parse Sources/droiddozecam/*.swift
swiftc -frontend -parse Sources/DroidDozeCamCameraExtension/*.swift
swiftc -frontend -parse Sources/DroidDozeCamMedia/*.swift Tests/DroidDozeCamMediaTests/*.swift
if [[ "$(uname -s)" == Darwin ]]; then
  # Build the unsigned test app outside dist/, which holds the signed app for make install.
  TEST_DIST="$ROOT/.build-test-dist"
  DIST_DIR="$TEST_DIST" scripts/build.sh --unsigned
  python3 scripts/test-cli.py --cli "$TEST_DIST/DroidDozeCam.app/Contents/MacOS/droiddozecam"
else echo "PASS: core tests + bundle tooling + shell checks + Swift syntax. SKIPPED: macOS frameworks/build/hardware."; fi
