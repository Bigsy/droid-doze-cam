#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift test
python3 scripts/test-build-tools.py
for SCRIPT in scripts/*.sh; do bash -n "$SCRIPT"; done
# Parser checks are additional checks only; they do NOT substitute for macOS SDK type checking/linking.
swiftc -frontend -parse Sources/phonecam/*.swift
swiftc -frontend -parse Sources/PhoneCamCameraExtension/*.swift
swiftc -frontend -parse Sources/PhoneCamMedia/*.swift Tests/PhoneCamMediaTests/*.swift
if [[ "$(uname -s)" == Darwin ]]; then
  scripts/build.sh --unsigned
  python3 scripts/test-cli.py
else echo "PASS: core tests + bundle tooling + shell checks + Swift syntax. SKIPPED: macOS frameworks/build/hardware."; fi
