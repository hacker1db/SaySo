#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build this app on macOS 13+ with Xcode Command Line Tools (xcode-select --install)." >&2
  exit 1
fi
app="$PWD/build/Sayso.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework AVFoundation -framework Speech -framework Carbon -framework ApplicationServices \
  Sources/main.swift -o "$app/Contents/MacOS/Sayso"
cp Info.plist "$app/Contents/Info.plist"
# A stable Developer ID is preferable for persistent permissions. Ad hoc signing supports local testing.
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "Built: $app"
echo "Copy it to /Applications before granting permissions, then open it there."
