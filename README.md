# DuplicateMe

Phase 1 implementation of a duplicate and similar-file finder for macOS without requiring full Xcode for the core engine.

## Requirements

- macOS (Apple Silicon or Intel)
- Swift toolchain (via Xcode Command Line Tools or Xcode)
- Node.js 20+ and npm (for the Electron desktop shell)

## Modules

- `MediaFingerprint`: image, video, and audio fingerprinting plus similarity scoring.
- `ScanCore`: scan orchestration, clustering, HTML export, and trash workflow.
- `ScanStore`: SQLite-backed persistence for runs, cache, and ignore rules.
- `ScanCLI`: command-line interface over the shared engine.

## Build

```bash
swift build
```

## Quick Start (CLI)

```bash
swift run duplicate-me scan --location ~/Downloads
swift run duplicate-me serve
```

## Electron Shell

Run the macOS desktop shell on top of the local Swift backend:

```bash
npm install
npm run desktop:dev
```

The Electron shell launches the local `duplicate-me serve --no-open` backend automatically and loads the review UI inside a native desktop window instead of a browser tab.

### Package a macOS app

Bundle the Swift release binary and create a packaged Electron app:

```bash
npm run desktop:dir
npm run desktop:dmg
```

The packaged app includes:

- the Electron desktop shell
- the Swift backend binary
- the bundled `ScanCLI` web assets
- a custom DuplicateMe macOS app icon

Build outputs:

- unpacked app: `dist/electron/mac-arm64/DuplicateMe.app`
- installable disk image: `dist/electron/DuplicateMe-0.1.0-arm64.dmg`

You can launch the packaged app directly:

```bash
open dist/electron/mac-arm64/DuplicateMe.app
```

### Regenerate the app icon

```bash
npm run desktop:icon
```

Generated assets:

- icon: `electron/assets/DuplicateMe.icns`
- preview: `electron/assets/DuplicateMe-preview.png`

### Optional notarization

`npm run desktop:dmg` will automatically attempt notarization and stapling if credentials are available. If not, the build still succeeds and the notarization steps are skipped.

Supported credential modes:

1. Keychain profile:

```bash
export APPLE_NOTARY_PROFILE="DuplicateMeNotary"
```

2. Apple ID + app-specific password:

```bash
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="TEAMID1234"
```

Manual notarization commands:

```bash
npm run desktop:notarize:app
npm run desktop:notarize:dmg
```

## Test

```bash
swift test
```

## CLI

```bash
swift run duplicate-me help
```

### Scan a folder

```bash
swift run duplicate-me scan \
  --location ~/Downloads \
  --similar-images \
  --similar-videos \
  --similar-audio
```

### Rescan previous locations

```bash
swift run duplicate-me rescan
```

### Export JSON or HTML

```bash
swift run duplicate-me export-json --run-id <RUN_ID> --output report.json
swift run duplicate-me export-html --run-id <RUN_ID> --output report.html
```

### Start the local review UI

```bash
swift run duplicate-me serve
```

The viewer opens in the browser by default and exposes a localhost-only review session. From there you can:

- choose folders with the native macOS folder picker
- start a new scan directly from the browser UI
- watch live scan progress while the engine runs in the background
- review duplicate and similar clusters in one continuous canvas
- keep cleanup actions visible while scrolling through cluster sections
- collapse or expand cluster groups to reduce visual noise on large scans
- hide false-positive similar groups and exclude specific files from future similar scans
- media previews and thumbnails
- smart selection for exact duplicates
- `Reveal in Finder`
- moving explicit selections to Trash

If you want to open a specific existing run directly:

```bash
swift run duplicate-me serve --run-id <RUN_ID>
```

Optional flags:

```bash
swift run duplicate-me serve --run-id <RUN_ID> --port 48222 --no-open
```

### Ignore rules

```bash
swift run duplicate-me ignore add --path ~/Downloads/cache --scope folder
swift run duplicate-me ignore list
```

### Trash selected files

```bash
swift run duplicate-me trash --run-id <RUN_ID> --cluster <CLUSTER_ID> --member <FILE_ID>
```

## Notes

- Scan runs and cache are stored in `~/.duplicate-me/store.sqlite`.
- Exact duplicates use `size -> sample hash -> full SHA-256`.
- Similarity is implemented for images, videos, and audio using lightweight local fingerprints.
- Full SwiftUI shell is intentionally deferred to phase 2.

## License

MIT. See [LICENSE](LICENSE).
