#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
if [[ "$(uname -m)" != arm64 ]]; then
  print -u2 'Packaging requires an Apple-silicon Mac (arm64).'
  exit 1
fi
APP="$ROOT/dist/NESN Player.app"
# Read the kernel executable path, not argv/pgrep (names and arguments can lie).
# Check again after compilation in case the target was started during the build.
refuse_running_target() {
  python3 - "$APP/Contents/MacOS/NESNPlayer" <<'PY'
import ctypes
import os
import subprocess
import sys

libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
target = os.path.realpath(sys.argv[1])
pids = subprocess.run(['/bin/ps', '-axo', 'pid='], check=True,
                      capture_output=True, text=True).stdout.split()
running = []
for value in pids:
    pid = int(value)
    path = ctypes.create_string_buffer(4096)
    # Exited/inaccessible processes may have no readable executable path.
    if libproc.proc_pidpath(pid, path, len(path)) > 0:
        if os.path.realpath(os.fsdecode(path.value)) == target:
            running.append(pid)
if running:
    print(f'Refusing to replace running target: {target} (PID(s): '
          + ', '.join(map(str, running)) + '). Quit it manually first.', file=sys.stderr)
    sys.exit(1)
PY
}
refuse_running_target
# No installation or launch: all products remain inside this checkout.
# An explicit triple prevents a newer host OS from raising the deployment floor.
export MACOSX_DEPLOYMENT_TARGET=14.0
nice -n 10 swift build -c release --jobs 2 --triple arm64-apple-macosx14.0
BIN_DIR=$(swift build -c release --jobs 2 --triple arm64-apple-macosx14.0 --show-bin-path)
refuse_running_target
rm -rf "$APP" "$ROOT/build/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/AppIcon.iconset"
cp "$BIN_DIR/NESNPlayer" "$APP/Contents/MacOS/NESNPlayer"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
for spec in '16 16x16' '32 16x16@2x' '32 32x32' '64 32x32@2x' '128 128x128' '256 128x128@2x' '256 256x256' '512 256x256@2x' '512 512x512' '1024 512x512@2x'; do
  set -- ${(z)spec}
  sips -z "$1" "$1" "$ROOT/Assets/AppIcon.png" --out "$ROOT/build/AppIcon.iconset/icon_$2.png" >/dev/null
done
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
python3 scripts/verify-artifact.py --write-plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
ARCHIVE=$(python3 scripts/verify-artifact.py --archive-name)
cd "$ROOT/dist"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ARCHIVE" 'NESN Player.app' -x '*/.DS_Store'
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
python3 "$ROOT/scripts/verify-artifact.py"
print -r -- "$APP"
