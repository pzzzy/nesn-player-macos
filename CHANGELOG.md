# Changelog

All notable user-facing changes are documented here.

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