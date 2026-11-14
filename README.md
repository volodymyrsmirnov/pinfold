<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon-1024.png" alt="Pinfold app icon" width="120" />

# Pinfold

> 📝 Blog post: [Pinfold – my opinionated iOS and OSX KML viewer](https://volodymyr.smirnov.im/writing/pinfold/)

**An offline catalogue for your KML, KMZ, GPX & GeoJSON files.**

Import the places you care about once — then browse and navigate them anywhere, no signal required.

[**Download on the App Store**](https://apps.apple.com/in/app/pinfold/id6772969442)

![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS%20%7C%20macOS-blue)
![iOS](https://img.shields.io/badge/iOS-26.0%2B-orange)
![Swift](https://img.shields.io/badge/Swift-6.0-fa7343)
![UI](https://img.shields.io/badge/UI-SwiftUI%20Liquid%20Glass-9cf)

</div>

---

## ✨ Creating KML files for Pinfold

Authoring a `.kml`/`.kmz` for Pinfold? Pinfold parses a deliberately limited subset of KML, so a file that merely "is valid KML" can still render wrong. This repo ships a ready-made **agent skill** that teaches Claude, Codex, or any compatible AI agent to generate files using only the elements Pinfold actually supports: [**`skills/authoring-kml-for-pinfold`**](skills/authoring-kml-for-pinfold/SKILL.md).

Install it for your agent by copying the skill folder into your skills directory:

| Agent | Skills directory |
|---|---|
| Claude Code | `~/.claude/skills/` |
| Codex / Gemini CLI / Copilot CLI | `~/.agents/skills/` |

```bash
# Example (Claude Code)
cp -R skills/authoring-kml-for-pinfold ~/.claude/skills/
```

Then ask your agent to *"create a KML for Pinfold"* and it will follow the supported feature set. You can also read the [`SKILL.md`](skills/authoring-kml-for-pinfold/SKILL.md) directly as a human authoring reference.

---

## What is Pinfold?

Most map files come from somewhere else — Google Earth and My Maps exports, GIS tools, a GPX track a guide shared, a colleague's site survey. They end up buried in email attachments and downloads folders. **Pinfold gives those files a permanent, organized home on your device**, and lets you browse and navigate them completely offline.

It's a faithful viewer and launcher: it reads your files exactly as they were authored, then hands you off to whichever navigation app you prefer.

## Features

- **Built for offline** — load a file once with a connection; icons and photos it references are cached on import, so they're there when you're off the grid. Nothing depends on a server.
- **More than KML** — import `.kml`, `.kmz`, `.gpx` and `.geojson` files. The format is detected from the file's content, and GPX waypoints, tracks and routes or GeoJSON features land in the same browsable catalogue.
- **Browse your places** — navigate the original folder hierarchy from the file, tap any placemark for its full details (description with formatting, lists, tables and images, photos, address, phone, extended-data fields), with custom icons and colors from the file's styles preserved.
- **See it on the map** — view all of a file's pins together on an embedded map; nearby pins group into numbered clusters when you zoom out so dense files stay readable. Tap a route or an area to select it, too.
- **Search that finds more** — search across every file at once, matching names, descriptions, extended-data details and your own notes. Accents, case and character width don't matter: "Reykjavik" finds "Reykjavík".
- **Notes and favourites** — add a personal note to any place, star your favourites and mark places you've seen. Each file keeps its own.
- **Navigate with the app you already use** — open any place in Apple Maps, Google Maps, Waze, Organic Maps, CoMaps, Maps.me, OsmAnd, Magic Earth, Citymapper, Guru Maps, Sygic, Yandex Maps, 2GIS, or Google Maps on the web. Set a default for one-tap navigation, or pick each time. Apps you don't have installed are hidden automatically.
- **Import from anywhere** — share a file from any app, open one directly from Files or an attachment, or import several at once. Imports show their progress, can be cancelled, and explain what went wrong when a file can't be read.
- **Built for iPad and Mac too** — drag files onto the window to import them, and use the menu bar commands (import, search, rename, move to trash, toggle favourite, open in maps) with their keyboard shortcuts, each acting on its own window. On every device, select several files to trash them together.
- **Your call on image downloads** — choose whether Pinfold downloads the icons and photos a file links to: always, after asking for each file, or never. Images packaged inside a KMZ always show.
- **Storage and cache controls** — Settings shows how much space your files, downloaded images and extracted data use, and clears downloaded images in one tap.
- **Optional iCloud sync** — turn on iCloud to keep your imported files, favourites and notes on every device signed in to the same account. Files stay in your private iCloud; Pinfold has no account and no servers. If iCloud is unavailable, Pinfold says so and keeps working with the files on the device.
- **Private by design** — no account, no sign-up, no ads, no tracking. Your location is shown only on your device and never leaves it.

## Requirements

- **iOS / iPadOS 26.0+**, and macOS (Apple Silicon) via *Designed for iPad*
- **Xcode** (current release) with a Swift 6.0 toolchain
- Command-line tools used by the build scripts:
  ```bash
  brew install xcodegen swiftformat swiftlint
  ```

## Building & running

The Xcode project is **generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen)** from `project.yml` and **committed** (Xcode Cloud builds the checked-in `Pinfold.xcodeproj` as-is). Never edit it by hand — change `project.yml` and regenerate.

```bash
# 1. Clone
git clone <repo-url> && cd kmlore

# 2. (Optional) Regenerate the Xcode project from project.yml
xcodegen generate

# 3. Open in Xcode and run, or use the scripts below
open Pinfold.xcodeproj
```

After adding, removing, or renaming files under `App/`, `ShareExtension/`, or `AppTests/`, run `xcodegen generate` again (the scripts do this for you) and commit the resulting `project.pbxproj` change alongside your source change.

### Scripts

| Script | What it does |
|---|---|
| `scripts/build.sh` | Builds the app for the iPhone simulator (code signing disabled) |
| `scripts/test.sh`  | Runs the app test suite (filter with `scripts/test.sh -only-testing:PinfoldTests/<Suite>`) |

> **Note:** The App Group / Share-Extension handoff and iCloud sync only work on a **signed** build (device, Mac, or TestFlight). They are inactive on the unsigned simulator builds the scripts use.

## Architecture

Pinfold is split into two parts:

- **`PinfoldCore/`** — a standalone Swift Package with no UIKit/SwiftUI/SwiftData dependency: the KML/KMZ parser plus GPX and GeoJSON readers, dispatched by file content. Entry points are `KMLReader.read(data:) -> ParsedKML` and `KMLReader.readDocument(data:)`. Depends only on [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (for KMZ archives).
- **`App/` + `ShareExtension/`** — the SwiftUI app (Liquid Glass UI), using **MV + `@Observable`** (no view-model layer).

The catalogue is **folder-as-source-of-truth**: each imported file lives in its own folder (under Application Support, or in iCloud Drive when sync is on) alongside a small metadata sidecar that also carries favourites and notes. The parsed tree is never persisted — it's **re-parsed from disk on open**. Derivable per-device resources (extracted KMZ media, downloaded remote icons/photos, the search index) are cached locally and rebuilt on each device from the synced original.

## Project structure

```
.
├── App/                  # The SwiftUI app (Model, Views, Services, Support, Maps)
├── ShareExtension/       # Share-sheet extension that drops files into the shared inbox
├── AppTests/             # App test suite (Swift Testing)
├── PinfoldCore/          # Standalone KML/KMZ/GPX/GeoJSON parser package (+ its own tests)
├── skills/               # Agent skill for authoring Pinfold-friendly KML
├── scripts/              # build.sh, test.sh
├── docs/                 # Design specs, plans, icon assets
├── .github/workflows/    # Pull-request checks
├── project.yml           # XcodeGen source of truth (generates Pinfold.xcodeproj)
└── .swiftlint.yml        # Lint config
```

## Testing

```bash
# App tests (iPhone simulator, code signing disabled)
scripts/test.sh

# Parser package tests
cd PinfoldCore && swift test
```

## Formatting & linting

- **Format:** `swiftformat` (config-less, pinned via `.swift-version`).
- **Lint:** `swiftlint lint` — kept at **0 errors**.

Pull requests are checked automatically on GitHub Actions (`.github/workflows/pr-checks.yml`): `swift test` for `PinfoldCore` and `swiftlint lint`.

## Privacy

Pinfold collects **no data** and does **no tracking**. All your files live on your device and, if you enable sync, in your own private iCloud. See `App/PrivacyInfo.xcprivacy` for the declared API-usage reasons.

Some files link to icons and photos on the web. Downloading them reveals your device's IP address to the hosts the file names, so Settings → Downloads lets you choose: download always, ask for each file, or never. Network links inside a file are never followed on their own: for a file that only links to others, Pinfold offers a one-time download that names the hosts and fetches nothing until you confirm.

## License

Released under the [MIT License](LICENSE) — © 2026 Volodymyr Smirnov.

ZIPFoundation, the sole third-party dependency, is also distributed under the MIT License.
