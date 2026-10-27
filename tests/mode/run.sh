#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_BIN=$(mktemp -d)
trap 'rm -rf "$TEST_BIN"' EXIT
xcrun swiftc src/Sock.swift src/app/LEDModeText.swift tests/mode/main.swift -o "$TEST_BIN/check"
"$TEST_BIN/check"
