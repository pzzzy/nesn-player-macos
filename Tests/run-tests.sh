#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/offline-model-tests"
mkdir -p "$BUILD"
# Match Package.swift's language mode and deployment target for every adapter.
SWIFT_FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0")
# Offline CLT fallback: compile fixture adapters, never the app entry point.
nice -n 10 xcrun swiftc "${SWIFT_FLAGS[@]}" -D CATALOG_STANDALONE \
  "$ROOT/Sources/NESNPlayer/SafeDiagnostics.swift" \
  "$ROOT/Sources/NESNPlayer/Entitlement.swift" \
  "$ROOT/Sources/NESNPlayer/WatchCatalogModel.swift" \
  "$ROOT/Sources/NESNPlayer/WatchCatalog.swift" \
  "$ROOT/Sources/NESNPlayer/Schedule.swift" \
  "$ROOT/Tests/NESNPlayerTests/CatalogNetworkTests.swift" \
  "$ROOT/Tests/CatalogNetworkRunner/main.swift" \
  -o "$BUILD/CatalogNetworkTests"
"$BUILD/CatalogNetworkTests"
nice -n 10 xcrun swiftc "${SWIFT_FLAGS[@]}" \
  "$ROOT/Sources/NESNPlayer/PlaybackModel.swift" \
  "$ROOT/Sources/NESNPlayer/WatchCatalogModel.swift" \
  "$ROOT/Tests/PlaybackModelTests/main.swift" \
  -o "$BUILD/PlaybackModelTests"
"$BUILD/PlaybackModelTests"
python3 "$ROOT/Tests/run-offline-fixture.py" AudioLeaseTests
python3 "$ROOT/Tests/run-offline-fixture.py" PlaybackLifecycleTests
nice -n 10 xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -D FRAME_CAPTURE_STANDALONE \
  "$ROOT/Sources/NESNPlayer/FrameCapture.swift" \
  "$ROOT/Tests/NESNPlayerTests/FrameCaptureTests.swift" \
  -o "$BUILD/FrameCaptureTests"
"$BUILD/FrameCaptureTests"
