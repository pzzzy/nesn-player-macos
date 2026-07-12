# NESN Player for macOS

An independent native macOS player for **current NESN subscribers** who have installed and signed into the official NESN 360 iPad app on Apple-silicon Mac hardware.

It uses Apple's AVFoundation/FairPlay playback path, offers proper resizable windows and macOS fullscreen, selects the highest HLS rendition available, recognizes 4K/HEVC/HDR masters, and can mute SCTE-35-marked commercial avails.

## Requirements

- Apple-silicon Mac running macOS 14 or later
- Official NESN 360 app installed and signed in
- Active NESN/TV-provider entitlement
- Desired live event opened once in NESN 360 so its content ID is locally discoverable

## Use

1. Install and sign into the official NESN 360 app.
2. Start the desired live event once, then pause/quit it.
3. Open **NESN Player**.
4. Resize freely or use the green button / Control-Command-F.

The app reads the official app's local authorization session and requests a fresh playback entitlement from NESN. It does not ask for, store, or transmit your password to any third party.

## Commercial auto-mute

Optional and disabled by default. Enable it with:

```sh
defaults write io.github.pzzzy.nesn-player CommercialAutoMute -bool true
```

Compatible playlists observed in NESN feeds use:

- `#EXT-X-SCTE35:TYPE=0x36` during an active commercial avail
- `#EXT-X-SCTE35:TYPE=0x37` when program content resumes

The player polls the highest video media playlist and toggles `AVPlayer.isMuted`. This is best-effort: feeds without these tags, unusual local breaks, or future upstream changes may not be detected. It does not remove, skip, record, or modify advertising.

## 4K/HDR

The player imposes no bitrate or resolution ceiling. AVFoundation can select 3840x2160 HEVC HLG/PQ variants when NESN advertises them and the Mac/display/HDCP path supports them. Availability is controlled by NESN and may vary by event.

## Build

```sh
swift build -c release
.build/release/NESNPlayer
```

For a distributable local app:

```sh
./scripts/build-app.sh
open dist/NESN\ Player.app
```

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
