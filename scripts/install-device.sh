#!/bin/sh
# Build Debug for device and install to a connected iPhone via devicectl.
# xcodebuild … install can report success without leaving an icon; this path is reliable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DD="$(ls -td "${HOME}/Library/Developer/Xcode/DerivedData"/intelligent-ui-spinreader-* 2>/dev/null | head -1)"
APP="${DD}/Build/Products/Debug-iphoneos/Spin.app"

echo "Building Spin for device…"
xcodebuild \
  -project intelligent-ui-spinreader.xcodeproj \
  -scheme Spin \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  build

test -d "$APP" || { echo "Missing: $APP" >&2; exit 1; }

UDID="${INSTALL_DEVICE_ID:-}"
if test -z "$UDID"; then
  UDID="$(xcrun xctrace list devices 2>/dev/null | sed -n 's/.*(\([0-9A-F-]\{25,\}\)).*/\1/p' | head -1)"
fi
test -n "$UDID" || { echo "No device UDID. Connect iPhone & trust Mac, or set INSTALL_DEVICE_ID." >&2; exit 1; }

echo "Installing to device $UDID …"
exec xcrun devicectl device install app --device "$UDID" "$APP" -t 240 --verbose
