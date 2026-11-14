# Pinfold improvement backlog

Candidate fixes and features from the code review of 2026-11-12 (commit `1455674`, version 1.7).
Tick the items you want implemented (`- [x]`), then hand the file back.

**Baseline at review time:** 331 app tests and 82 parser tests pass, SwiftLint reports 0 errors and 3 file-length warnings.

## How to read an item

Each item has an id, a rough size and an evidence level.

| Tag | Meaning |
|---|---|
| `S` / `M` / `L` | Rough size: hours / a day or two / a multi-day project. Guesses from reading the code, not estimates. |
| **reproduced** | I ran the parser against a test input and saw the wrong result. |
| **read** | Found by reading the code. The code path is clear, but nothing was run. |
| **device** | Plausible from the code, but needs a signed build or two devices to confirm. |
| **unverified** | Reported by a review pass and not checked by me. Confirm before fixing. |
| ★ | I would do this in the first batch. |

---

## A. Parser fixes (`PinfoldCore`)

- [X] **A1 ★ Stray `<name>` and `<description>` rename files and folders** · `S` · reproduced
  Any `<name>` outside a placemark overwrites the enclosing container's name. A document named "My Trip" containing `<atom:author><atom:name>Jane Doe</atom:name>` shows up as "Jane Doe". A folder followed by a `NetworkLink` or `GroundOverlay` takes that element's name. Same for descriptions. `Parsing/KMLParser.swift:347` and `:425`.

- [X] **A2 ★ Extra points in a `MultiGeometry` are lost** · `M` · reproduced
  Three `<Point>`s in one placemark give one pin, and the last one wins. There is no point case in `KMLGeometry`, so the fix touches the model and the map (either a new geometry case or splitting into several placemarks). Prerequisite for GeoJSON multi-point support (D10).

- [X] **A3 ★ Lines with spaces after commas parse to nothing** · `S` · reproduced
  `<coordinates>1, 2, 0 3, 4, 0</coordinates>` in a `LineString` yields an empty line, and the placemark is kept with no location. The tolerant fallback only exists for single points. `Model/Coordinate.swift:26`.

- [X] **A4 ★ Whole file rejected for trivial XML defects** · `S` · reproduced
  Leading whitespace before `<?xml`, or a single control character in a description (common in spreadsheet-sourced data), fails the import. Fix: trim the prolog and strip characters that are illegal in XML 1.0 before parsing.

- [X] **A5 Harmless `<!DOCTYPE kml>` rejects the file** · `S` · reproduced
  Any DOCTYPE fails the import, by design, as an entity-expansion guard. A DOCTYPE with no internal subset (no `[`) carries no entities and could be allowed. Security trade-off: this loosens a deliberate guard, so it needs careful tests.

- [X] **A6 ★ Non-KML XML imports as an empty entry** · `S` · reproduced
  A GPX file parses "successfully" to an empty document because the root element is never checked. Fix: require a `<kml>` root (or a bare `Document`/`Folder`/`Placemark`) and report "not a KML file" otherwise. Do this even if D10 is not picked.

- [X] **A7 DOCTYPE guard does not see UTF-16 files** · `S` · reproduced (bypass only)
  The guard scans ASCII bytes, so a UTF-16 document with a DOCTYPE gets past it. Foundation still refused my test file, so this is a hardening gap, not a demonstrated exploit. Fix: detect the BOM and transcode or reject before scanning.

- [X] **A8 ★ Import errors do not say what is wrong** · `S` · read
  A failure surfaces as "NSXMLParserErrorDomain code 111". None of the parser error types provide a readable description, and a corrupt zip surfaces ZIPFoundation's raw error. Fix: readable messages per case ("line 12: unclosed tag", "this KMZ has no KML inside").

- [X] **A9 Invalid or degenerate geometry is kept** · `S` · unverified
  A `<Point>` with unparseable coordinates leaves the placemark flagged as having a point but with no coordinate, which also skips the line-geometry fallback. Empty and one-point lines and rings with fewer than three points are never dropped.

- [X] **A10 KMZ extraction holds everything in memory** · `M` · read
  Every archive entry is inflated into RAM alongside the archive itself, with a 2 GiB cap. A photo-heavy KMZ well under the cap could get the app killed on a phone. Plain KML has no size cap at all. Fix: lower the cap, extract the root KML first, stream resources to disk. `Archive/KMZArchive.swift:38`.

- [X] **A11 Support inline styles inside a placemark** · `M` · read
  Inline `<Style>` in a `<Placemark>` is ignored (documented in the authoring skill as the most common mistake). GIS exporters commonly emit exactly this, so those files show default pins.

- [X] **A12 Keep folder descriptions** · `S`–`M` · read
  A `<Folder>`'s description is parsed and then discarded, because the container model has no field for it. Needs a model field and somewhere to show it in the outline.

- [X] **A13 Small data-capture gaps** · `S` · unverified
  `<Snippet>`, `<address>` and `<phoneNumber>` are never captured. `<displayName>` on extended data is ignored, so the raw attribute name is shown. Two `<Data>` items with the same name produce duplicate list ids.

- [X] **A14 Authoring skill disagrees with the code on `gx:MultiTrack`** · `S` · unverified
  The skill says multi-track geometry is not rendered, but the review reports that each inner track is captured. Check which is true and fix the doc or the code comment.

- [X] **A15 Cheap parser performance wins** · `S` · read
  A placemark's stable key recomputes a SHA-256 on every access, and lookups by key are linear. Cache the key at construction. Flattening all placemarks allocates an array per nesting level.

- [X] **A16 Cancellable parsing** · `S`–`M` · read
  Parsing and KMZ extraction are synchronous with no cancellation check, so leaving the screen during a huge import does not stop the work.

---

## B. Storage, sync and import

- [X] **B1 ★ iCloud unavailable at launch silently falls back to local** · `M` · read, device
  With sync on, if the iCloud container cannot be resolved (signed out, slow), the app uses local storage without saying so. The catalogue looks empty, the toggle still shows on, and files imported meanwhile stay in the local root when iCloud returns. `App/Views/RootView.swift:418`. Fix: show the state, and move stranded local entries once iCloud is back.

- [X] **B2 ★ A not-yet-downloaded `metadata.json` may be overwritten** · `M` · device
  The sidecar read treats a missing file as "absent" and rebuilds a fresh one. If the original file has downloaded but the sidecar has not, the rebuild would write empty favourites, visited marks and tags over the remote copy. Nothing in the scan path checks iCloud download status. Needs a two-device test before fixing. `App/Model/StorageLocations.swift:212`, `App/Services/CatalogScanner.swift:53`.

- [X] **B3 Turning sync on uploads the local resource cache** · `S`–`M` · read
  Migration moves whole entry folders, including the `resources/` cache that is meant to stay per-device. After an on, off, on cycle the cache directory itself can be treated as an entry folder and pushed to iCloud. Fix: skip `resources/` and only move UUID-named folders.

- [X] **B4 ★ One bad HTTP response loses an image permanently** · `S` · read
  The downloader ignores the HTTP status. A 404, 429, 5xx or captive-portal page fails the image check and marks the link as permanently skipped, so it is never retried. Fix: treat non-2xx as a retryable network failure. `App/Services/ResourceCache.swift:42`.

- [X] **B5 Failed downloads retry on every catalogue reload** · `S`–`M` · read
  Pending downloads are re-requested on every reload (foreground, watcher event, any edit), sequentially, with a 60-second timeout and no backoff. Also, two passes can update the same download manifest without a lock. Fix: attempt counter with backoff, and serialise manifest writes.

- [X] **B6 Download size cap applies after the download** · `S`–`M` · read
  The cap is checked once the whole body is already in memory. Fix: check `Content-Length`, stream with a running limit, set a shorter timeout.

- [X] **B7 Setting for downloading remote images on import** · `S` · read
  Importing a file fetches every icon and photo link in it immediately, which reveals the device's IP address to whatever hosts the file names. A setting ("Download images: always / ask / never") and a line in the privacy text would make this explicit.

- [X] **B8 A failed import can leave a half-written folder** · `M` · read
  There is no rollback if writing the original fails after the sidecar is written. The orphan folder is skipped by the scanner forever, and the retry creates another. Separately, a failure writing the rebuildable cache fails the whole import, which can lead to a duplicate on retry. Fix: clean up on failure, and never fail an import over cache writes.

- [X] **B9 ★ Re-importing a trashed file does nothing** · `S` · read
  The duplicate check matches entries in the Trash. For share-sheet and "Open in" imports the new file is dropped with no message. Fix: offer to restore the trashed copy, or import as new.

- [X] **B10 ★ Share-extension files can be named `<UUID>-file.kml`** · `S` · read
  The extension prefixes a UUID to avoid collisions, and nothing strips it afterwards. A file with no `<name>` gets that prefixed filename as its title. `ShareExtension/ShareViewController.swift:81`.

- [X] **B11 Import work on the main thread** · `M` · read
  Share-sheet and "Open in" imports read, hash, parse and commit on the main actor. Spotlight items for the whole file are also built there. Several large files shared at once would freeze the UI at launch. The in-app importer already does the heavy part off-main.

- [X] **B12 Unreadable sidecar brings trashed entries back** · `S`–`M` · read
  When `metadata.json` cannot be decoded, the entry is rebuilt in memory as not trashed. Renames, tag edits and trash changes to such an entry fail silently, as does a failed permanent delete.

- [X] **B13 Spotlight and cache go stale after remote changes** · `M` · read
  Spotlight is only updated by actions on this device. An entry deleted or renamed on another device, or in the Files app, leaves a dead Spotlight result and an orphaned local cache folder. Fix: reconcile at launch.

- [X] **B14 File coordination for writes and deletes in iCloud** · `M` · read, device
  Only sidecar reads and writes are coordinated. Writing the original file, creating folders and deleting folders inside the iCloud container are not.

- [ ] **B15 Conflict merge cannot carry an un-favourite or a restore** · `M`–`L` · read
  Conflicting sidecars are merged by union, so removing a favourite, a visited mark or a tag on one device can be undone by the other device's copy. A full fix needs per-item timestamps. Rare in practice.

- [X] **B16 Possible double import of an "Open in" file** · `S` · device
  The direct import and the inbox drain can both pick up the same file before the catalogue has reloaded, so the duplicate check misses.

- [X] **B17 Catalogue scan and search scale poorly** · `S`–`M` · read
  Every reload decodes each file's full search index only to check that it exists, and every search re-reads all of them from disk. With hundreds of files, or one very large file, each favourite or rename gets slow. Fix: existence check, and an in-memory index.

- [X] **B18 Pinfold claims to be the default app for KML/KMZ** · `S` · read
  `LSHandlerRank` is `Owner` in `App/Info.plist`. `Alternate` is the conventional value for an app that opens a format it does not own. Leave it if being the default is intended.

---

## C. Quick UX fixes

- [X] **C1 ★ Confirm permanent delete, add Empty Trash** · `S` · read
  "Delete" in the Trash is permanent on one tap, from both the swipe and the context menu. There is no Empty Trash and no automatic purge. `App/Views/HomeView.swift:403`. Options to tick separately:
  - [X] Confirmation dialog on permanent delete — later removed (2.1, owner decision): Trash deletes without asking
  - [X] Empty Trash button — later replaced (2.1) by Select mode with a bulk Delete
  - [ ] Auto-purge after 30 days

- [X] **C2 ★ Search ignores accents** · `S` · read
  Search is case-insensitive but accent-sensitive, so "Reykjavik" does not find "Reykjavík". Applies to file search, in-file search, cross-file search and the Shortcuts picker.

- [X] **C3 Search descriptions and extended data** · `M` · read
  Only placemark names are searchable. Including description text and extended-data values means growing the per-file search index.

- [X] **C4 Import progress and cancel** · `S`–`M` · read
  A multi-file import shows a bare spinner with no count and no way to cancel.

- [X] **C5 ★ Tell the user when map tiles need a connection** · `S` · read
  The app is pitched as offline, but the embedded map uses online tiles. Off-grid, users see pins on a blank map with no explanation. A small banner when offline is the cheap fix (the full fix is D4).

- [ ] **C6 Accessibility pass** · `S`–`M` · read. Tick separately:
  - [ ] VoiceOver labels on the map style and tracking buttons, cluster counts, and favourite/visited state on pins
  - [ ] Dynamic Type for row icons, thumbnails and photo tiles, which use fixed sizes
  - [ ] Honour Reduce Motion for pin and camera animations

- [X] **C7 Refresh the navigation-app list** · `S` · unverified
  Candidates to add: CoMaps, HERE WeGo, Komoot, Gaia GPS. Maps.me may be worth dropping. Each URL scheme needs checking against the app's own documentation.

- [X] **C8 iPad and Mac conveniences** · `M` · read. Tick separately:
  - [X] Drag and drop a `.kml`/`.kmz` onto the window to import
  - [X] Multi-select files for bulk trash (and bulk delete in Trash); tagging was removed in 2.1
  - [X] More menu commands and shortcuts (only ⌘I and ⌘F exist): trash, favourite, open in maps, plus (2.1) the online-list, Seen and copy actions; rename and tags were removed in 2.1

- [X] **C9 Storage usage and Clear Cache in Settings** · `S`
  Show how much space files and cached images take, with a way to clear the image cache.

---

## D. Product features

- [X] **D1 Richer descriptions** · `M` · read
  Descriptions render as plain text with links. Bold, lists, tables and inline images are dropped, so a Google My Maps key/value table becomes a run of words. The current approach is deliberately safe (no web view), and this would keep it that way.

- [X] **D2 Tappable lines and polygons** · `M` · read
  Routes and areas cannot be selected on the map; only pins can.

- [X] **D3 Network-link files: download a snapshot** · `M` · read
  A KML that only contains a `<NetworkLink>` imports empty, since links are never followed. Offer a one-time download that inlines the content. I have not tested this against a real Google My Maps export, so confirm the file shape first.

- [ ] **D4 Offline basemap** · `L`
  A real offline map under the pins. This means a different map renderer and downloadable region packs, so it is the largest item here.

- [ ] **D5 Localisation** · `M` · read
  There is no String Catalog. Plurals ("1 point" / "5 points") and VoiceOver strings are built by hand in English. Adding the catalogue is the groundwork; each language is then translation work.

- [x] **D6 Map performance for large files** · `M` · read
  Long tracks are never simplified, all pins are added in one pass on the main thread, and toggling one favourite redraws every pin image.

- [X] **D7 Favourites map across files** · `M`
  A list/map toggle in the Favourites sheet showing every starred pin, tinted per file, plus "nearest first". The per-file search index already stores coordinates, so nothing needs re-parsing. Points only, since lines and polygons are not in the index.

- [X] **D8 Personal notes per placemark** · `M` COMMENT: we can do it in metadata.json, we don't have many users.
  Your own text on a place, synced and searchable. Store it in a separate `notes.json` per entry, not in `metadata.json`, because an older app version on another device would rewrite the sidecar without the notes and delete them. Conflicts need newest-edit-wins per note. Notes whose placemark disappears after a re-import should be kept and shown.

- [ ] **D9 Export favourites** · `M`
  Share only the starred or visited places as KML (optionally GPX), for example to load a shortlist into an offline navigation app. Needs a KML writer in `PinfoldCore`, which also enables round-trip parser tests.

- [X] **D10 GPX and GeoJSON import** · `S` (GeoJSON), `M` (GPX)
  Readers that produce the same document tree the app already uses, so the outline, map and search work unchanged. Depends on A2 for multi-point features. This widens the app beyond "KML catalogue", which is a positioning choice.

- [ ] **D11 More Shortcuts actions** · `S`–`M`
  Only "Open File" exists. Candidates: Find Places, Open Place, Navigate to Place, Import File, Get Favourites, Mark Visited. Actions that run without opening the app need the catalogue available before the main view starts up.

- [ ] **D12 Nearby favourites widget** · `M`
  A home or lock screen list of the nearest favourites. Needs a favourites snapshot written to the App Group container. Widget location updates are infrequent, and the App Group only works on signed builds, so this is the hardest one to test.

---

## E. Housekeeping

- [X] **E1 ★ README says the Xcode project is gitignored** · `S` · read
  `README.md` says `Pinfold.xcodeproj` is gitignored and must not be committed. It is committed, and `CLAUDE.md` says to commit it.

- [X] **E2 Stale comment about SwiftData** · `S` · read
  The doc comment on `EntryMetadata` still describes rebuilding a SwiftData index.

- [X] **E3 Tests for untested paths** · `M` · read
  No tests cover the iCloud conflict-resolution path, migration with separate cache and data roots, or cleanup after a failed import. Parser regression tests come with each fix in section A.

- [X] **E4 Split the three oversized view files** · `M` · read
  `PlacemarkMapRepresentable.swift`, `KMLDetailView.swift` and `RootView.swift` exceed the 500-line lint limit. These are the three remaining lint warnings.

- [X] **E5 Pull-request checks on GitHub** · `S`–`M`
  There is no GitHub workflow. Running `swift test` for the parser and `swiftlint` on each pull request would catch regressions before Xcode Cloud does.

- [X] **E6 Privacy manifest reason for file timestamps** · `S` · unverified
  The app reads creation dates of files in iCloud and user-granted locations. Check whether the declared reason code covers that use.

- [X] **E7 Multi-window behaviour** · `S` · unverified
  Multiple scenes are enabled, and menu commands are shared across windows. Check on iPad or Mac whether ⌘I and ⌘F act on every open window.

---

## Suggested first batch

The ★ items: A1, A2, A3, A4, A6, A8, B1, B2, B4, B9, B10, C1, C2, C5, E1.
They are mostly small, the parser ones are already reproduced, and B1 and B2 are the two that can lose or hide user data.
