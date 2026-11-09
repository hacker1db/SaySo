#!/bin/bash
# Compiles and runs the assert-based tests for the pure shortcut logic.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)/sayso-tests"
swiftc -swift-version 5 Sources/Shortcut.swift Sources/Statistics.swift Tests/main.swift -o "$out"
"$out"
