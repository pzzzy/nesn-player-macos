#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release
APP="$ROOT/dist/NESN Player.app"
rm -rf "$APP" "$ROOT/build/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/AppIcon.iconset"
cp .build/release/NESNPlayer "$APP/Contents/MacOS/NESNPlayer"
for spec in '16 16x16' '32 16x16@2x' '32 32x32' '64 32x32@2x' '128 128x128' '256 128x128@2x' '256 256x256' '512 256x256@2x' '512 512x512' '1024 512x512@2x'; do
  set -- ${(z)spec}
  sips -z "$1" "$1" "$ROOT/Assets/AppIcon.png" --out "$ROOT/build/AppIcon.iconset/icon_$2.png" >/dev/null
done
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NESNPlayer</string>
<key>CFBundleIdentifier</key><string>io.github.pzzzy.nesn-player</string>
<key>CFBundleName</key><string>NESN Player</string>
<key>CFBundleDisplayName</key><string>NESN Player</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.4.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
cd "$ROOT/dist"
rm -f NESN-Player-v1.4.1-macOS.zip NESN-Player-v1.4.1-macOS.zip.sha256
COPYFILE_DISABLE=1 /usr/bin/zip -qry "NESN-Player-v1.4.1-macOS.zip" "NESN Player.app" -x '*/.DS_Store'
HASH=$(shasum -a 256 "NESN-Player-v1.4.1-macOS.zip" | cut -d' ' -f1)
printf '%s  dist/%s\n' "$HASH" "NESN-Player-v1.4.1-macOS.zip" > "NESN-Player-v1.4.1-macOS.zip.sha256"
echo "$APP"
