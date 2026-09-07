# Contributing

## Build and validate

Use an Apple-silicon Mac, macOS 14+, Xcode Command Line Tools with Swift 6+, and Python 3. CI uses the macOS 15 arm64 runner and reports its toolchain; the binary deployment floor remains macOS 14. Offline tests need no subscriber account.

With full Xcode selected, run the Swift package tests. A Command Line Tools-only installation may lack the test frameworks required by `swift test`; use the offline fixture fallback instead:

```sh
# Full Xcode:
nice -n 10 swift test --jobs 2
# CLT-only fallback (not a live-playback acceptance test):
./Tests/run-tests.sh
```

Then validate packaging without launching the app:

```sh
python3 scripts/test-artifact.py
./scripts/verify-source.sh
./scripts/build-app.sh
python3 scripts/verify-artifact.py
```

Packaging builds release code with two jobs, generates an icon from the committed PNG, includes LICENSE, ad-hoc signs, creates ZIP/SHA-256 files and verifies both the bundle and extracted archive. It never installs or launches the app. Pillow is needed only for optional `scripts/generate-icon.py`, not normal builds. `Tests/run-tests.sh` compiles offline fixture adapters rather than launching the app entry point. Neither test path proves live playback or audio-route non-regression.

`release.json` is the only packaging version/build/platform source. The current candidate is `1.6.0-dev`, build `9`, with numeric bundle short version (`CFBundleShortVersionString`) `1.6.0`. Candidate versions retain a `-dev` suffix; tags must equal `v` plus the release metadata version. v1.5.0 remains the published release. CI artifacts are test candidates, not published releases. There is no updater framework. Release promotion is manual and requires reviewing test evidence, signature, checksum and changelog; keep the previous download available for rollback.

## Pull requests

Keep patches focused, add a failing regression test first, and report actual commands/results plus pending checks. Update user-facing documentation. Be respectful: critique changes rather than people; harassment and publication of personal information are not acceptable.

Do not attach or commit authorization/license tokens, signed playback URLs, SPC/CKC bodies, device/account identifiers, official-app caches or network captures. Use synthetic fixtures and allowlisted diagnostics. Follow [SECURITY.md](SECURITY.md) for private reports.

Preserve native AVFoundation/FairPlay playback and legitimate entitlement. Personal still screenshots (**Capture frame** / **S**) use native AVFoundation APIs only where permitted. Retain capability checks, original decoded dimensions and high-precision TIFF output. Validate pixels decoded from the serialized image as well as dimensions, bit depth and color transfer; metadata alone is not HDR evidence. No DRM bypass, credential export, recording, restreaming or video export.

## Manual release gates

With an authorized account and explicit permission, separately verify UHD/HD selection, ambiguous chooser, denial/expired session, replay/GO LIVE, VOD seeking, small/fullscreen controls, accessibility, AirPlay connect/return, sleep/network recovery and long-session UHD A/V drift/audio restoration. Exercise **Browse sources**, retry, Pause while buffering, responsive controls and asynchronous audio restoration. Clear-HLS 16-bit PQ TIFF capture has local calibrated-fixture evidence, including decoded saved pixels; actual NESN live capture remains unverified. Still capture needs separate authorized live resolution/HDR validation, protected-source rejection and unsupported-output-route checks. Check paused-frame timeout handling; resume before retrying when no frame is available. Offline CI does not establish these. Never disturb someone else's active playback or audio route to test a patch.
