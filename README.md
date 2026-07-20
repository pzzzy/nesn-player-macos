# NESN Player for macOS

An independent native macOS player for **current NESN subscribers** who have installed and signed into the official NESN 360 iPad app on Apple-silicon Mac hardware.

It uses Apple's native AVFoundation playback path, offers freely resizable windows and true macOS fullscreen, and leaves adaptive streaming uncapped so AVPlayer can select the highest sustainable rendition.

## Video quality and dedicated 4K events

NESN may publish a home-game 4K broadcast as a **separate schedule event**, rather than as a rendition inside the ordinary HD event. NESN Player therefore:

1. Prefers a live event whose title identifies it as `4K` or `UHD`.
2. Falls back to the primary Red Sox telecast when no dedicated UHD event exists.
3. Supports both NESN delivery forms currently observed:
   - FairPlay-protected HLS for ordinary feeds.
   - Direct HLS returned by the entitlement API for dedicated 4K feeds.
4. Sets no application-level bitrate or resolution ceiling (`preferredPeakBitRate = 0` and `preferredMaximumResolution = .zero`). Final adaptive selection still depends on NESN's master playlist, network conditions, display capabilities, and AVFoundation.

When launched from Terminal, the player writes non-sensitive diagnostics to standard error. These report the master playlist's maximum resolution, frame rate, HDR/HEVC flags, audio-channel count and bandwidth, followed by AVPlayer's indicated and observed bitrates. Stream URLs, authorization tokens and DRM material are not logged.

Example from a verified dedicated feed:

```text
Master capabilities: 3840x2160 @ 59.94fps, HDR=true, HEVC=true, audioChannels=6, bandwidth=16781600bps
Stream quality: indicated=19421600bps observed=323829854bps
```

`indicated` is the bitrate AVPlayer reports for the selected rendition. `observed` is measured delivery throughput, not the encoded video bitrate.

## Requirements

- Apple-silicon Mac running macOS 14 or later
- Official NESN 360 app installed and signed in
- Active NESN/TV-provider entitlement

## Use

1. Install and sign into the official NESN 360 app. You do not need to start a game there.
2. Open **NESN Player**.
3. The player queries NESN's current catalog. A dedicated live Red Sox 4K/UHD event is preferred automatically. When no unambiguous live Red Sox game is available, a launch chooser offers current live events, the regular NESN linear channel, and recent Red Sox full-game replays.
4. Resize freely or use the green button / Control-Command-F.

## Playback controls

- Move the pointer over the video to reveal the compact control bar.
- Scroll vertically over the player to adjust volume.
- For live sources, wheel events never scrub. **Replay 30 seconds** jumps backward within the provider's current seekable HLS window, while **GO LIVE** returns to the live edge. The status light is green at the live edge and red while delayed.
- For on-demand full-game replays, a mouse-enabled scrub bar and elapsed/total duration display permit normal seeking. The live-edge indicator is omitted.
- The player does not record or save video locally.

The app reads the official app's local authorization session, queries NESN's live and replay catalogs, and requests a fresh playback entitlement for the selected source. It does not ask for, store, or transmit your password to any third party.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for build, test, security, privacy, and pull-request guidelines.

## Build from source

```sh
git clone https://github.com/pzzzy/nesn-player-macos.git
cd nesn-player-macos
./scripts/build-app.sh
open "dist/NESN Player.app"
```

The build script requires Xcode command-line tools and creates an ad-hoc-signed application plus a versioned ZIP and SHA-256 file under `dist/`.

## Privacy and security

- No credentials, stream URLs, content keys, Charles captures, or account identifiers are included.
- Authorization remains in the official NESN app container.
- FairPlay SPC/CKC messages are handled by AVFoundation and NESN's license endpoint.
- The project does not decrypt, save, redistribute, or bypass protected media.
- See [SECURITY.md](SECURITY.md).

## Legal / trademark

Unofficial, unsupported, and not affiliated with NESN, ViewLift, Axinom, Apple, MLB, or the Boston Red Sox. NESN and related marks belong to their owners. Use requires a legitimate subscription and compliance with applicable service terms and law. No media, DRM keys, certificates, tokens, or proprietary application code are distributed.

## License

MIT for this project's original source code. See [LICENSE](LICENSE).
