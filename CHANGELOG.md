# Changelog

All notable user-facing changes are documented here.

## 1.6.0-dev (build 9) — Unreleased candidate

- Centralized release metadata; explicit arm64/macOS 14 packaging with bundled MIT license.
- Added archive, SHA-256, ad-hoc signature, version and platform gates plus offline corruption regression tests.
- Added read-only, bounded CI packaging and privacy-aware contribution/reporting forms.
- Clarified installation, checksum trust and manual release requirements.
- Added **Capture frame** / **S** for native, capability-gated still capture at original decoded resolution. High-precision frames use TIFF; clear HLS HDR current-frame capture supports 16-bit PQ TIFF without display tone mapping.
- Validated clear-HLS HDR capture with a local calibrated fixture, including serialized TIFF pixels decoded back from disk. Actual NESN live screenshots are not yet verified; protected or unsupported sources/routes remain unavailable, and paused capture may time out. No FairPlay bypass, recording or video export.
- Added **Browse sources** and retry paths, Pause while buffering, responsive controls and asynchronous audio-rate restoration as candidate features.
- Candidate packaging uses `1.6.0-dev`, build `9`, with numeric bundle short version (`CFBundleShortVersionString`) `1.6.0`. Documented the CLT offline fallback alongside full-Xcode tests.

v1.5.0 remains the published release. This candidate is not live-playback-certified or proven non-regressing. UHD/AirPlay/audio-route and actual NESN live capture acceptance remain separate manual gates. Historical verification below applies only to the version named.

## 1.5.0 — 2026-08-24

### Added

- Native AirPlay route selection in the playback control bar for sending the active NESN stream directly to an Apple TV on the same network.
- Accessible labeling and active-route state feedback for the AirPlay control.

### Verified

- Live NESN linear playback at 1920×1080p60 and the top advertised 8.128 Mbps rendition while AVFoundation external playback was active on an Apple TV.
- Protected playback remains in the native AVFoundation/FairPlay path without recording, restreaming, or video transcoding.

## 1.4.2 — 2026-08-18

### Fixed

- Dedicated live 4K playback now aligns the active audio output device to the feed's native 48 kHz clock, preventing the slowly accumulating 2–3 second audio lag seen during long home-game sessions.
- The output device's prior sample rate is restored when NESN Player exits.

## 1.4.1 — 2026-07-22

### Fixed

- When no live Boston Red Sox game is available, the live-source chooser now reliably remains visible instead of accepting a stale default action.
- Minor-league and other unrelated live events never bypass the chooser; the regular 24/7 NESN channel remains available alongside them.
- The chooser is brought to the foreground and requires an explicit Watch click.

## 1.4.0 — 2026-07-19

### Added

- Launch chooser when no unambiguous live Red Sox game is available.
- Playback of current non-baseball live events, the regular NESN linear channel, and recent Red Sox full-game replays.
- Mouse-enabled scrub bar with elapsed and total time for on-demand replays only.

### Changed

- Live sources retain accidental-scrub protection, 30-second replay, and LIVE/GO LIVE controls.
- Replay discovery is read from NESN's current full-game replay tray and preserves provider ordering with newest items first.

## 1.3.0 — 2026-07-19

### Changed

- Replaced AVPlayerView's overlapping native transport overlay with a compact custom control bar.
- Removed mouse scrubbing to prevent accidental live-stream timeline jumps.
- Vertical scrolling over the player now controls volume.

### Added

- A dedicated 30-second replay control constrained to the current seekable HLS window.
- A clickable LIVE/GO LIVE control that returns playback to the live edge.
- Green live-edge and red replay-state indicators.
- Automated playback-model regression tests for live-state thresholds, volume bounds, replay bounds and live-edge calculations.

## 1.2.0 — 2026-07-17

### Added

- Automatic preference for dedicated live events labeled 4K or UHD.
- Playback support for the direct-HLS entitlement form used by NESN's dedicated 4K feed, while retaining FairPlay playback for ordinary feeds.
- Runtime diagnostics for master resolution, frame rate, HDR, HEVC, audio channels, advertised bandwidth, selected rendition bitrate and observed throughput.

### Verified

- Live dedicated home-game playback at 3840×2160, 59.94 fps, HEVC, HDR and six-channel audio.
- AVPlayer selected the top advertised rendition at approximately 19.4 Mbps with no application bitrate or resolution ceiling.

## 1.1.0

- Added live schedule discovery and automatic primary-event selection.
- Added the original project icon and versioned macOS application packaging.

## 1.0.0

- Initial native macOS player with resizable window, fullscreen playback and NESN entitlement integration.