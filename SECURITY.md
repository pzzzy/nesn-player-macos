# Security

Report vulnerabilities privately at [GitHub Security Advisories](https://github.com/pzzzy/nesn-player-macos/security/advisories/new). Do not disclose an exploit or account data in a public issue. Private reporting is enabled; this project has no guaranteed response SLA.

Include affected version, impact and minimal reproduction using synthetic data. Never attach authorization tokens, personalized stream URLs, FairPlay headers/SPC/CKC bodies, account/device identifiers, viewing history, official-app caches or raw network captures. If credentials were exposed, remove public copies and sign out of NESN 360; contact the provider if revocation is uncertain.

The app uses the official app's existing local session and NESN's authorization/license endpoints. Do not introduce credential export, DRM circumvention, recording, restreaming or video export. Personal still capture (**Capture frame** / **S**) uses native AVFoundation APIs and must be restricted to frames those APIs permit, with no FairPlay or other DRM bypass. Clear HLS can expose a decoded frame; this does not imply protected streams or every output route permit capture. Saved original-resolution TIFF/PNG files contain viewing content: choose their location deliberately and do not attach them to public reports without reviewing content and rights. Review diagnostics before sharing; redaction is defense in depth, not permission to upload raw logs.

Builds are ad-hoc signed for structural integrity, not Developer ID signed or Apple notarized. SHA-256 detects corruption relative to a trusted checksum; it does not authenticate the publisher. Review and build from source if preferred. No automatic update framework is included.

The `1.6.0-dev` development candidate is not a verified playback release; v1.5.0 remains published. Local calibrated clear-HLS HDR still-capture evidence does not establish actual NESN live capture or playback/audio-route non-regression. Report issues on the latest published version or current source and state which you tested; fixes are maintained on the current development branch, with no promised backport window.
