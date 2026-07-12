#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release
APP="$ROOT/dist/NESN Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NESNPlayer "$APP/Contents/MacOS/NESNPlayer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NESNPlayer</string>
<key>CFBundleIdentifier</key><string>io.github.pzzzy.nesn-player</string>
<key>CFBundleName</key><string>NESN Player</string>
<key>CFBundleDisplayName</key><string>NESN Player</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
cd "$ROOT/dist"
rm -f NESN-Player-v1.0.0-macOS.zip NESN-Player-v1.0.0-macOS.zip.sha256
COPYFILE_DISABLE=1 /usr/bin/zip -qry "NESN-Player-v1.0.0-macOS.zip" "NESN Player.app" -x '*/.DS_Store'
HASH=$(shasum -a 256 "NESN-Player-v1.0.0-macOS.zip" | cut -d' ' -f1)
printf '%s  dist/%s\n' "$HASH" "NESN-Player-v1.0.0-macOS.zip" > "NESN-Player-v1.0.0-macOS.zip.sha256"
echo "$APP"
