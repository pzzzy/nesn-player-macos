# Contributing

Thanks for helping improve NESN Player.

## Development requirements

- macOS 14 or later
- Xcode Command Line Tools with Swift
- The official NESN 360 app, signed in with an authorized account, for live integration testing

## Build and test

```bash
swift build -c release
./Tests/run-tests.sh
./scripts/build-app.sh
codesign --verify --deep --strict "dist/NESN Player.app"
./scripts/verify-source.sh
```

The packaged app is written to `dist/NESN Player.app`. Build products and release archives under `build/`, `dist/`, and `.build/` are intentionally ignored by Git.

## Pull requests

1. Create a focused branch from `main`.
2. Keep changes small and use a conventional commit message.
3. Add or update tests for behavior changes.
4. Update `README.md` and `CHANGELOG.md` for user-facing changes.
5. Run the complete validation commands above before opening a pull request.

## Security and privacy

Never commit or include in logs:

- authorization, subscription, or license tokens;
- complete signed playback URLs;
- FairPlay SPC or CKC data;
- device identifiers;
- official-app caches or account data.

Use the official app's existing local session only at runtime. Do not add DRM-circumvention, credential-export, video-capture, or recording functionality. Please report vulnerabilities according to [SECURITY.md](SECURITY.md), not in a public issue.

## Scope and legal note

This project is an independent client and is not affiliated with or endorsed by NESN. Contributors are responsible for using it only with content they are authorized to access and for respecting applicable terms and rights.
