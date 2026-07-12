# NESN Player for macOS

An independent native macOS player for **current NESN subscribers** who have installed and signed into the official NESN 360 iPad app on Apple-silicon Mac hardware.

It uses Apple's AVFoundation/FairPlay playback path, offers proper resizable windows and macOS fullscreen, selects the highest HLS rendition available, recognizes 4K/HEVC/HDR masters.

## Requirements

- Apple-silicon Mac running macOS 14 or later
- Official NESN 360 app installed and signed in
- Active NESN/TV-provider entitlement

## Use

1. Install and sign into the official NESN 360 app. You do not need to start a game there.
2. Open **NESN Player**.
3. The player queries NESN's current schedule. If one primary event is live it opens automatically; if multiple live events are available it asks which one to play.
4. Resize freely or use the green button / Control-Command-F.

The app reads the official app's local authorization session, queries NESN's live/upcoming schedule, and requests a fresh playback entitlement for the selected event. It does not ask for, store, or transmit your password to any third party.

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
