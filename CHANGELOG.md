# Changelog

All notable user-facing changes are documented here.

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