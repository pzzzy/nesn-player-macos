#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/playback-model-tests"
mkdir -p "$BUILD"
xcrun swiftc \
  "$ROOT/Sources/NESNPlayer/PlaybackModel.swift" \
  "$ROOT/Tests/PlaybackModelTests/main.swift" \
  -o "$BUILD/PlaybackModelTests"
"$BUILD/PlaybackModelTests"