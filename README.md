# NESN Player for macOS

Independent native AVFoundation player for **current NESN subscribers** on **Apple silicon (arm64), macOS 14 or later**. Requires the official NESN 360 iPad app installed and signed in on the Mac plus an active entitlement. Not affiliated with NESN or Apple.

**[Download the latest published release](https://github.com/pzzzy/nesn-player-macos/releases/latest)** · [Changelog](CHANGELOG.md)

This source tree is **1.6.0-dev, build 9: an unreleased candidate**. **v1.5.0 remains the published release**; its verification does not certify this candidate. Live playback, AirPlay, audio restoration and actual NESN live screenshots still need separate acceptance checks.

## Install a published build

1. Download the arm64 macOS ZIP and matching `.sha256` file from the same trusted release. Older releases may omit `arm64` in the filename.
2. In Terminal, change to the download folder and verify the exact downloaded checksum file:
   ```sh
   shasum -a 256 -c NAME-OF-DOWNLOADED.zip.sha256
   ```
   Require `OK` before extracting. The checksum detects corruption; it authenticates neither the author nor a compromised download page.
3. Extract the ZIP and move **NESN Player.app** to your Applications folder. Quit an older copy before replacing it; keep its archive for rollback.
4. The app is **ad-hoc signed, not Developer ID signed or notarized**. If macOS blocks it, review the source and publisher before using the per-app approval in **System Settings → Privacy & Security → Open Anyway**, where available. Managed Macs may prohibit this. Never disable Gatekeeper globally or strip quarantine recursively.
5. Sign into the official NESN 360 app, then open NESN Player. No password is entered in this player.

There is no automatic updater. Install updates manually from releases, or build from reviewed source.

## Playback and controls

- Native AVFoundation/FairPlay playback, freely resizable windows and macOS fullscreen (green button / Control-Command-F).
- Automatic selection is reserved for an unambiguous primary live Red Sox source, with dedicated UHD preference. Otherwise choose explicitly from live, linear and replay sources.
- Quality is uncapped; selected resolution depends on entitlement, the provider, network, display and AVFoundation. A UHD event can be separate from the ordinary HD source.
- Move the pointer over the video for controls. Candidate controls adapt to smaller windows; **Browse sources** reopens source selection, with retry available after failures. **Pause** remains available while playback is buffering. Scroll vertically for volume; live wheel events never scrub.
- **Replay 30 seconds** stays within the available live seekable window; **GO LIVE** returns to the edge. VOD has a seek bar.
- Use the native AirPlay button for Apple TV selection or return to local playback. Route/provider restrictions can still prevent playback.
- Dedicated live UHD may temporarily align local audio output to 48 kHz to address clock drift. Candidate cleanup restores the prior rate asynchronously without intentionally overwriting newer user changes; route and long-session acceptance are still pending. Force-kill/crash restoration is not guaranteed.
- **Capture frame** (or **S**) saves a personal still through native AVFoundation APIs, at the original decoded frame resolution rather than the window size. High-precision/HDR frames use TIFF; ordinary SDR frames may use PNG. The clear-HLS current-frame path preserves PQ HDR in 16-bit TIFF without display tone mapping.
- Capture is capability-gated: not all sources or output routes expose a frame. FairPlay/protected content is rejected, never bypassed. A paused stream may time out waiting for a decoded frame; resume playback and retry. No recording, restreaming or video export.

Clear-HLS HDR capture has been validated with a local calibrated fixture, including pixels decoded from the saved TIFF, not just metadata. **An actual NESN live screenshot has not yet been verified.** This does not establish capture support for every stream, HDR format or output route.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Missing/expired session | Sign in again in the official NESN 360 app, then retry the player. |
| Entitlement denied | Verify subscription, location and source availability in the official app; do not bypass denial. |
| Catalog/provider error | Check the official app; retry later or choose another available source. |
| Network failure | Check connectivity; retry without posting request URLs. |
| DRM or AirPlay failure | Try authorized local playback; check route/provider support and report only a safe error code/category. |
| Capture unavailable or timed out | Protected sources/output routes may forbid capture. For a paused clear stream, resume and retry; do not bypass protection or grant screen-recording access as a workaround. |

Advertised master capabilities are not proof of the active rendition. AVPlayer's indicated bitrate describes the selected rendition; observed bitrate is delivery throughput. Review/redact diagnostics before sharing; never upload raw network captures or official-app caches.

## Build from source

Install Xcode Command Line Tools (Swift 6+) and Python 3 on an Apple-silicon Mac:

```sh
git clone https://github.com/pzzzy/nesn-player-macos.git
cd nesn-player-macos
./scripts/build-app.sh
python3 scripts/verify-artifact.py
```

Candidate metadata identifies `1.6.0-dev`, build `9`; the numeric bundle short version (`CFBundleShortVersionString`) is `1.6.0`. This is not a release promotion.

The script uses two release-build jobs, the committed icon PNG, explicit arm64/macOS 14 metadata and `release.json` as its version source. It includes LICENSE and verifies signature, metadata, architecture, deployment floor, archive contents and SHA-256. Outputs stay in `dist/`; **nothing is installed or launched**. Open `dist/NESN Player.app` manually when ready. Pillow is optional for icon regeneration only.

For offline tests with Command Line Tools only, run `./Tests/run-tests.sh`. With full Xcode selected, run `nice -n 10 swift test --jobs 2`. See [CONTRIBUTING.md](CONTRIBUTING.md) for test scope and manual release gates; [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## Privacy, legal and license

Authorization remains in the official app's local session. The player requests fresh NESN entitlements and uses the native protected-media path; it does not ask for your password or add third-party credential storage. Never share tokens, signed playback URLs, account/device identifiers, viewing history or SPC/CKC data.

Unofficial and unsupported; not affiliated with NESN, ViewLift, Axinom, Apple, MLB or the Boston Red Sox. Trademarks belong to their owners. Use only content you are authorized to access and comply with service terms and law. No proprietary media, credentials, DRM keys or application code are distributed. Original project source is [MIT licensed](LICENSE); packaged copies include the notice.
