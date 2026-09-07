# Contributing

## Build and validate

Use an Apple-silicon Mac, macOS 14+, Xcode Command Line Tools with Swift 6+, and Python 3. CI uses the macOS 15 arm64 runner and reports its toolchain; the binary deployment floor remains macOS 14. Offline tests need no subscriber account.

```sh
nice -n 10 swift test --jobs 2
python3 scripts/test-artifact.py
./scripts/verify-source.sh
./scripts/build-app.sh
python3 scripts/verify-artifact.py
```

Packaging builds release code with two jobs, generates an icon from the committed PNG, includes LICENSE, ad-hoc signs, creates ZIP/SHA-256 files and verifies both the bundle and extracted archive. It never installs or launches the app. Pillow is needed only for optional `scripts/generate-icon.py`, not normal builds. `Tests/run-tests.sh` remains the compatibility test entry point.

`release.json` is the only packaging version/build/platform source. Candidate versions retain a `-dev` suffix; tags must equal `v` plus that version. CI artifacts are test candidates, not published releases. There is no updater framework. Release promotion is manual and requires reviewing test evidence, signature, checksum and changelog; keep the previous download available for rollback.

## Pull requests

Keep patches focused, add a failing regression test first, and report actual commands/results plus pending checks. Update user-facing documentation. Be respectful: critique changes rather than people; harassment and publication of personal information are not acceptable.

Do not attach or commit authorization/license tokens, signed playback URLs, SPC/CKC bodies, device/account identifiers, official-app caches or network captures. Use synthetic fixtures and allowlisted diagnostics. Follow [SECURITY.md](SECURITY.md) for private reports.

Preserve native AVFoundation/FairPlay playback and legitimate entitlement. Personal still screenshots may be supported only where AVFoundation permits; retain capability checks and validate original pixel dimensions/HDR properties before claiming HDR support. No DRM bypass, credential export, recording, restreaming or video export.

## Manual release gates

With an authorized account and explicit permission, separately verify UHD/HD selection, ambiguous chooser, denial/expired session, replay/GO LIVE, VOD seeking, small/fullscreen controls, accessibility, AirPlay connect/return, sleep/network recovery and long-session UHD A/V drift/audio restoration. Still capture needs separate clear-source resolution/HDR validation and protected-source rejection checks. Offline CI does not establish these. Never disturb someone else's active playback or audio route to test a patch.
