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
  -framework AppKit -framework AVFoundation -framework Carbon -framework ApplicationServices -framework SwiftUI -framework ServiceManagement \
  -import-objc-header Sources/Bridging.h -I"$(brew --prefix)/include" -L"$(brew --prefix)/lib" -lwhisper -lggml \
  Sources/*.swift -o "$app/Contents/MacOS/Sayso"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Resources/Sayso.icns "$app/Contents/Resources/Sayso.icns"
# A stable Developer ID is preferable for persistent permissions. Ad hoc signing supports local testing.
# Prefer a real certificate: macOS ties Accessibility/Microphone grants to the signature, and ad-hoc
# signatures change on every rebuild, which silently revokes auto-paste.
identity="${SIGNING_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
if [[ -n "${SAYSO_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${SAYSO_VERSION}" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SAYSO_BUILD:-1}" "$app/Contents/Info.plist"
fi
if [[ -n "$identity" ]]; then
  # Hardened runtime + secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --entitlements Sayso.entitlements --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
echo "Built: $app"
echo "Copy it to /Applications before granting permissions, then open it there."
