#!/bin/sh
# Build Spin for a physical device (signed .app in DerivedData).
# Use this when Simulator builds fail on Misaki/Kokoro resource bundle codesign
# (com.apple.provenance / "bundle format unrecognized").
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec xcodebuild \
  -project intelligent-ui-spinreader.xcodeproj \
  -scheme Spin \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  build
