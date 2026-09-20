#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
vedaCache="$(cd ../../work && pwd)/swift-cache-v3"
mkdir -p ../../work/tests
swiftc -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$vedaCache" Sources/Core.swift Tests/main.swift -o ../../work/tests/veda-tests
../../work/tests/veda-tests
