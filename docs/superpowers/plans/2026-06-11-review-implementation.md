# Review-Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every issue from the 2026-06-11 end-to-end review (robustness, iCloud sync, silent failures, UI scalability), implement all ten functionality suggestions plus hygiene items, and add non-happy-path test coverage.

**Architecture:** Work proceeds in five dependency-ordered waves: (1) PinfoldCore parser/archive hardening + geometry model, (2) app pipeline robustness (scanner, commit, sync, imports, downloads), (3) UI correctness/perf, (4) features (split view first, then overlays/search/export/rename/sort/favorites/tags/links/Spotlight), (5) hygiene + localization. Every fix lands TDD: failing test → minimal fix → pass → commit on `feature/review-implementation`.

**Tech Stack:** Swift 6, SwiftUI + MV/@Observable, MKMapView via UIViewRepresentable, Swift Testing (`@Test`/`#expect`), XcodeGen, scripts/build.sh + scripts/test.sh (iPhone 17 sim, iOS 26.5), `cd PinfoldCore && swift test` for the package.

**Conventions for every task:**
- Branch: `feature/review-implementation` (already created). Commit after each task with the message given in the task.
- App tests: `scripts/test.sh -only-testing:PinfoldTests/<Suite>`. Package tests: `cd PinfoldCore && swift test`.
- After adding/removing files under `App/`, `ShareExtension/`, or `AppTests/`: the scripts run `xcodegen generate` automatically.
- SwiftLint must stay at 0 errors. A PostToolUse hook auto-formats edited Swift files.
- `EntryMetadata` Codable is hand-written: when adding a property update CodingKeys, init(from:), encode(to:), AND the memberwise init, using `decodeIfPresent` for new fields (backwards compatibility).
- All user-facing strings introduced or touched: use `String(localized:)` where a literal is user-visible.

---

## Wave 1 — PinfoldCore hardening (no app dependencies)

### Task 1: Reject DOCTYPE / entity-expansion documents

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift` (parse entry, ~line 9-13)
- Test: `PinfoldCore/Tests/PinfoldCoreTests/KMLParserTests.swift`

- [ ] **Step 1:** Write failing tests in `KMLParserTests`:
  - `parse_rejectsDOCTYPE`: a small KML string prefixed with `<!DOCTYPE kml [<!ENTITY a "x">]>` → `#expect(throws: KMLParseError.self)`.
  - `parse_rejectsBillionLaughs`: classic nested-entity payload (5 levels is enough to prove rejection) → expect throw, and the test must complete in < 1s (rejection happens before parsing).
- [ ] **Step 2:** Run `cd PinfoldCore && swift test --filter KMLParserTests` — both fail.
- [ ] **Step 3:** Implement: in `KMLParser.parse(data:)` (or the equivalent entry), before constructing `XMLParser`, scan the first chunk of the document for `<!DOCTYPE` (case-insensitive, only up to the first `<` element after the optional XML declaration — a cheap approach: search the full data for the ASCII bytes `<!DOCTYPE` is acceptable given files are loaded in memory anyway). If found, throw a new case `KMLParseError.dtdProhibited` with a doc comment explaining KML never legitimately uses DTDs and this blocks entity-expansion DoS. Also set `parser.shouldResolveExternalEntities = false` explicitly with a comment that it documents intent (it is the default).
- [ ] **Step 4:** `swift test --filter KMLParserTests` — pass. Run full `swift test`.
- [ ] **Step 5:** Commit: `fix(core): reject DOCTYPE/DTD documents to block entity-expansion DoS`

### Task 2: Sanitize KMZ entry paths (traversal-safe resource keys)

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Archive/KMZArchive.swift` (~line 69)
- Test: `PinfoldCore/Tests/PinfoldCoreTests/KMZArchiveTests.swift`

- [ ] **Step 1:** Write failing tests (build in-memory zips with ZIPFoundation in the test, as existing KMZ tests do):
  - `extract_skipsPathTraversalEntries`: archive containing entries `../evil.png` and `/abs.png` plus a valid `doc.kml` → resources dict contains neither traversal key.
  - `extract_normalizesNestedRelativeSegments`: entry `images/./icon.png` → key is `images/icon.png` (or the entry is kept verbatim only if it contains no `.`/`..` segments — assert no key contains a `..` component).
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3:** Implement a private `static func sanitizedArchivePath(_ raw: String) -> String?` in `KMZArchive`: reject (return nil) absolute paths and any path whose components contain `..`; drop `.` components; return the joined remainder. Skip entries whose sanitized path is nil. Document on the `resources` contract that keys are guaranteed traversal-safe. Add the load-bearing comment from the review on the streaming decompression check (lines ~62-66): the declared-size pre-flight is advisory; the streaming check is the real bomb defense and must not be removed.
- [ ] **Step 4:** `swift test` — pass.
- [ ] **Step 5:** Commit: `fix(core): sanitize KMZ entry paths; document streaming bomb guard`

### Task 3: Capture raw (non-CDATA) descriptions with inline HTML

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift` (didStartElement/foundCharacters/didEndElement)
- Test: `PinfoldCore/Tests/PinfoldCoreTests/KMLParserTests.swift`

- [ ] **Step 1:** Failing tests:
  - `parse_rawDescriptionWithInlineHTML`: `<description>See <b>this</b> place &amp; more</description>` inside a Placemark → `descriptionHTML == "See <b>this</b> place & more"` (child elements re-serialized as text, entities decoded by the XML parser).
  - `parse_rawDescriptionNestedTags`: `<description><div><a href="https://x.example">link</a> tail</div></description>` → contains `<a href="https://x.example">link</a>` and `tail`.
  - `parse_cdataDescriptionStillWorks`: existing CDATA behavior unchanged (guard against regression).
- [ ] **Step 2:** Verify fail (current parser keeps only the tail text).
- [ ] **Step 3:** Implement description-capture mode: add `descriptionDepth: Int` state. When `<description>` opens (placemark or container scope), enter capture mode (`descriptionDepth = 1`) and start a dedicated `descriptionBuffer`. While in capture mode: `didStartElement` re-serializes the child tag into the buffer (`<name attr="…">`, escaping attribute values) and increments depth instead of resetting `text`; `didEndElement` for child tags appends `</name>` and decrements; `foundCharacters`/`foundCDATA` append to the buffer. When depth returns to 0 at `</description>`, assign the buffer (trimmed) as today. The existing whole-CDATA path must produce identical output to before. Remove the Phase-1 limitation comment.
- [ ] **Step 4:** `swift test` — pass, including all existing fixture tests.
- [ ] **Step 5:** Commit: `fix(core): capture raw non-CDATA descriptions with inline HTML intact`

### Task 4: ExtendedData SchemaData/SimpleData support

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/KMLParserTests.swift`, new fixture `PinfoldCore/Tests/PinfoldCoreTests/Fixtures/schemadata.kml`

- [ ] **Step 1:** Add fixture `schemadata.kml`: one Placemark with `<ExtendedData><SchemaData schemaUrl="#s"><SimpleData name="elevation">120</SimpleData><SimpleData name="surface">gravel</SimpleData></SchemaData></ExtendedData>`. Failing test `parse_schemaDataSimpleData`: placemark's data items contain `("elevation", "120")` and `("surface", "gravel")`.
  - Also `parse_valueOutsideDataIgnored`: a stray `<value>x</value>` directly under `<ExtendedData>` (not inside `<Data>`) does not create an item.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: handle `SimpleData` start (read `name` attribute into `currentDataName`) and end (append `KMLDataItem(name:value:)` from trimmed text). Scope the existing `value` end-element handling to require an open `<Data>` element (track `inDataElement: Bool`).
- [ ] **Step 4:** `swift test` — pass.
- [ ] **Step 5:** Commit: `feat(core): parse SchemaData/SimpleData extended data; scope <value> to <Data>`

### Task 5: StyleMap pairs with inline `<Style>`

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/KMLParserTests.swift`

- [ ] **Step 1:** Failing test `parse_styleMapWithInlinePairStyle`: document-level `<StyleMap id="m"><Pair><key>normal</key><Style><IconStyle><Icon><href>https://x/icon.png</href></Icon></IconStyle></Style></Pair></StyleMap>` + a placemark with `<styleUrl>#m</styleUrl>` → `document.resolvedStyle(forStyleUrl: "#m")?.iconHref == "https://x/icon.png"`.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: when a `<Style>` opens while inside a StyleMap pair whose current key is `normal` (or key not yet seen — KML allows key after Style; buffer the inline style and bind it when the Pair closes if its key resolves to normal), synthesize an id (`nextID("s")`), index the built style into `styles`, and set `styleMapNormalURL = "#<synthesizedID>"`. Keep the existing guard that skips inline styles inside Placemarks.
- [ ] **Step 4:** `swift test` — pass.
- [ ] **Step 5:** Commit: `fix(core): resolve StyleMap pairs that use inline Style instead of styleUrl`

### Task 6: Coordinate tuples with internal whitespace

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Model/Coordinate.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/CoordinateTests.swift`

- [ ] **Step 1:** Failing tests: `parse_tupleWithSpacesAfterCommas` (`"-122.08, 37.42, 0"` → lon -122.08, lat 37.42) and `parse_multipleTuplesFirstTaken` regression check stays green.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement fallback: after the existing whitespace-token split, if the chosen token yields fewer than 2 parseable parts, re-split the *whole* trimmed string on commas and take the first two/three trimmed components. Keep the existing range validation (lat ±90, lon ±180).
- [ ] **Step 4:** `swift test` — pass.
- [ ] **Step 5:** Commit: `fix(core): parse coordinate tuples containing whitespace after commas`

### Task 7: Geometry capture — lines, polygons, tracks (parser + model)

This is the PinfoldCore half of feature F1 (overlay rendering) and the gx:Track fix.

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Model/KMLPlacemark.swift`, `PinfoldCore/Sources/PinfoldCore/Model/KMLStyle.swift`, `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/GeometryTests.swift` (new), fixture `Fixtures/geometry.kml` (new)

- [ ] **Step 1:** Extend the model (keep everything `Sendable` value types):
  ```swift
  /// One captured geometry of a placemark beyond its representative point.
  public enum KMLGeometry: Equatable, Sendable {
      case lineString([Coordinate])
      case polygon(outer: [Coordinate], inners: [[Coordinate]])
      case track([Coordinate])
  }
  ```
  Add `public var geometries: [KMLGeometry] = []` to `KMLPlacemark`. Add to `KMLStyle`: `public var lineColor: String?` (KML aabbggrr hex), `public var lineWidth: Double?`, `public var polyColor: String?`, `public var polyFill: Bool?`. Placemark keep-rule becomes: keep if it has a point **or** any geometry (placemarks with only a track/line are no longer dropped). `coordinate` for a point-less placemark with geometry = first coordinate of its first geometry (representative point, documented).
- [ ] **Step 2:** Fixture `geometry.kml`: a LineString placemark (3 coords), a Polygon placemark (outerBoundaryIs/LinearRing 4 coords + one innerBoundaryIs ring), a `gx:Track` placemark (3 `<gx:coord>` entries, space-separated lon lat alt), a MultiGeometry with Point + LineString, plus a `<Style>` with `<LineStyle><color>ff0000ff</color><width>3</width></LineStyle><PolyStyle><color>7f00ff00</color></PolyStyle>`. Failing tests in `GeometryTests`:
  - `parse_lineStringCaptured`: 3 coordinates in order; placemark kept; `coordinate` == first vertex.
  - `parse_polygonOuterAndInnerRings`.
  - `parse_gxTrackCoordsCaptured`: `gx:coord` is space-separated `lon lat alt` (different from `coordinates`!) — assert lat/lon mapped correctly; placemark kept with representative coordinate.
  - `parse_multiGeometryPointPlusLine`: point coordinate preserved, line captured.
  - `parse_lineAndPolyStyleParsed`: style carries lineColor/lineWidth/polyColor.
  - `parse_pointOnlyFilesUnchanged`: existing fixtures still produce identical placemark counts (regression).
- [ ] **Step 3:** Implement parser capture: track geometry context (`inLineString`, polygon ring context outer/inner, `inTrack`); on `</coordinates>` outside a Point, parse *all* tuples (add `Coordinate.parseList(_:) -> [Coordinate]` reusing the tuple parser) into the current geometry; `<gx:coord>` end → parse one space-separated triple, append to track buffer; close out geometry on its end element into `placemark.geometries`. LineStyle/PolyStyle: set `styleBuilder` fields from `color`/`width` inside the respective style sections (track `inLineStyle`/`inPolyStyle` like `inIconStyle`). Update `pointCount` semantics: leave `pointCount` = placemarks with explicit `<Point>`; add `public var placemarkCount` unchanged.
- [ ] **Step 4:** `swift test` — all pass, fixtures unchanged behavior verified.
- [ ] **Step 5:** Commit: `feat(core): capture LineString/Polygon/gx:Track geometry and Line/PolyStyle`

### Task 8: Parser perf + structured parse errors

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift`, `PinfoldCore/Sources/PinfoldCore/Model/KMLContainer.swift`, `PinfoldCore/Sources/PinfoldCore/Model/KMLDocument.swift`, `PinfoldCore/Sources/PinfoldCore/KMLReader.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/KMLParserTests.swift`, `KMLReaderTests.swift`

- [ ] **Step 1:** Failing tests:
  - `parse_truncatedDocumentThrowsWithLineInfo`: a valid KML cut mid-element → thrown error is `KMLParseError.malformedXML` carrying non-zero line number (extend the case to `malformedXML(line: Int, column: Int, detail: String)`).
  - `read_kmzWithMalformedRootKMLMentionsEntry`: KMZ whose `doc.kml` is truncated → error description mentions the entry name (wrap in `KMLReadError.kmzEntryParseFailed(entry: String, underlying: Error)` or extend existing error enum).
  - `counts_doNotMaterializeArrays` isn't directly testable — instead add `counts_matchAllPlacemarks` equivalence test (counts equal `allPlacemarks` derived values on the geometry fixture).
- [ ] **Step 2:** Verify fail / compile errors guide the enum change.
- [ ] **Step 3:** Implement:
  - `malformedXML` carries `parser.lineNumber`/`parser.columnNumber` + underlying NSError code description (not localizedDescription matching).
  - `KMLReader` wraps root-KML parse failures with the KMZ entry name.
  - Perf: in `foundCharacters`, skip accumulation when the current element's text is not consumed (maintain a small `wantsText` flag set in didStartElement for: name, description-capture mode, coordinates-when-capturing (point or geometry context), gx:coord, key, styleUrl, value/SimpleData inside ExtendedData, color, width, scale, href). `placemarkCount`/`pointCount` on `KMLContainer`: compute by recursion summing counts without building arrays.
- [ ] **Step 4:** `swift test` — pass.
- [ ] **Step 5:** Commit: `perf(core): structured parse errors with location; avoid array materialization and dead text accumulation`

### Task 9: 50k-placemark perf regression fixture

**Files:**
- Test: `PinfoldCore/Tests/PinfoldCoreTests/LargeFileTests.swift` (new; generates the document in code — no giant fixture file checked in)

- [ ] **Step 1:** Write `parse_50kPlacemarksCompletesQuickly`: build a KML string in memory with 50,000 `<Placemark><name>P<i></name><Point><coordinates>lon,lat,0</coordinates></Point></Placemark>` entries, parse via `KMLReader.read(data:)`, assert `pointCount == 50_000` and wall-clock under a generous bound (e.g. 10s) using `ContinuousClock` — the goal is catching quadratic regressions, not micro-benchmarks. Mark `.timeLimit(.minutes(1))`.
- [ ] **Step 2:** Run; should pass already after Task 8 (if it fails, that *is* the regression signal — fix before committing).
- [ ] **Step 3:** Commit: `test(core): 50k-placemark parse regression guard`

---

## Wave 2 — App pipeline robustness

### Task 10: CatalogScanner — never clobber an existing-but-unreadable sidecar

**Files:**
- Modify: `App/Services/CatalogScanner.swift`, `App/Model/StorageLocations.swift` (readMetadata signature)
- Test: `AppTests/CatalogScannerTests.swift`

- [ ] **Step 1:** Failing tests (use temp `StorageLocations(root:)` per existing suite conventions):
  - `scan_corruptSidecarWithOriginal_doesNotOverwriteSidecar`: seed folder with valid original + garbage `metadata.json` → after `scan()`, the garbage bytes are still on disk unchanged, and the returned entry (if any) is derived in-memory only.
  - `scan_corruptSidecar_preservedEntryStillListed`: same seed → entry appears in scan results (derived from original) rather than vanishing.
  - `scan_missingSidecarWithOriginal_backfillsSidecar`: existing self-heal behavior stays (sidecar absent → written).
  - `scan_corruptSidecarNoOriginal_entrySkippedButFolderUntouched`: garbage sidecar, no original → no entry, nothing written or deleted.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: change `StorageLocations.readMetadata` usage so the scanner can distinguish *absent* from *undecodable*: add `enum SidecarReadResult { case missing; case unreadable; case ok(EntryMetadata) }` (or a throwing read the scanner catches by error type — `CocoaError.fileReadNoSuchFile` vs decode error). In `entry(forFolderNamed:)`: `.ok` → as today; `.missing` → `rebuildFromBareOriginal` (writes sidecar, as today); `.unreadable` → derive the entry in memory from the original (same logic as rebuild) but **do not write anything**; if no original either, return nil without writing.
- [ ] **Step 4:** `scripts/test.sh -only-testing:PinfoldTests/CatalogScannerTests` — pass.
- [ ] **Step 5:** Commit: `fix(app): scanner no longer overwrites corrupt sidecars (favorites/trash preserved)`

### Task 11: Crash-safe commit ordering + single entry identity

**Files:**
- Modify: `App/Services/ImportService.swift`, `App/Services/CatalogScanner.swift`, `App/Model/CatalogEntry.swift` (check how `id` is used)
- Test: `AppTests/ImportServiceTests.swift`, `AppTests/CatalogScannerTests.swift`

- [ ] **Step 1:** Failing tests:
  - `commit_writesSidecarBeforeOriginal` — hard to assert ordering directly; instead test the recovery property: `scan_folderWithSidecarButNoOriginal_skippedWithoutWrites` (crash window simulation: sidecar present, original missing → scanner returns no entry, writes nothing, does NOT delete the folder).
  - `commit_entryIDDerivedFromFolderName`: after `commit`, `entry.id.uuidString == result.storageFolderName`.
  - `rebuild_bareOriginal_reusesFolderUUIDAsID`: `rebuildFromBareOriginal` for folder named `<uuid>` produces metadata with `id == UUID(uuidString: folderName)`.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement:
  - `commit`: write `metadata.json` **first**, original second (sidecar alone is harmless: scanner skips a sidecar-without-original folder per the test above; once the original lands the entry surfaces with its intended identity — no re-derivation window).
  - In `CatalogScanner.entry(forFolderNamed:)`: a readable sidecar whose original file is missing → return nil (folder left untouched; iCloud may still be downloading the original; the watcher rescans later).
  - Identity: `commit` uses `UUID(uuidString: result.storageFolderName)!` for the entry id; `rebuildFromBareOriginal` uses `UUID(uuidString: folderName) ?? UUID()`. Document on `EntryMetadata.id` that it equals the folder UUID.
- [ ] **Step 4:** Run ImportService + CatalogScanner suites — pass. Full `scripts/test.sh`.
- [ ] **Step 5:** Commit: `fix(app): crash-safe commit ordering; entry id derived from folder UUID`

### Task 12: NSFileCoordinator on synced root + favorites/visited conflict merge

**Files:**
- Modify: `App/Model/StorageLocations.swift`, `App/Support/UbiquityContainer.swift`
- Test: `AppTests/StorageLocationsTests.swift`

- [ ] **Step 1:** Failing tests (coordination itself can't be integration-tested without iCloud; test the seams):
  - `writeMetadata_readMetadata_roundTripsUnderCoordination`: behavior unchanged for local roots (coordinated I/O works on plain files).
  - `mergeConflict_unionsFavoriteAndVisitedKeys`: pure-function test for a new `EntryMetadata.merging(conflicts:)` — current `{fav: [a], visited: []}` merged with conflict versions `{fav: [b]}`, `{visited: [c]}` → favorites `{a,b}`, visited `{c}`; scalar fields (displayName, trashedAt) keep the *current* version's values except `trashedAt` resolves to the **latest non-nil wins if any version trashed more recently than current's restore** — keep it simple and deterministic: `trashedAt = versions.compactMap(\.trashedAt).max() ?? current.trashedAt` only when current is trashed or any version is; document the rule.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement:
  - Add private helpers `coordinatedRead(at:) throws -> Data` / `coordinatedWrite(_:to:) throws` in `StorageLocations` using `NSFileCoordinator(filePresenter: nil)` with `.forUploading`/`.forReplacing` options as appropriate; route `readMetadata`, `writeMetadata`, and the original-file read in `UbiquityContainer.readDownloadingIfNeeded` through them. Only when the root is ubiquitous? No — use them unconditionally (correct and cheap for local files too); note in a comment.
  - Conflict merge: in `readMetadata`, after a successful read, check `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`; if non-empty, decode each version's data, apply `EntryMetadata.merging(conflicts:)`, write the merged result back, and mark versions resolved (`version.isResolved = true`, `NSFileVersion.removeOtherVersionsOfItem`). Guard the whole block in `#if !targetEnvironment(simulator)`? No — it is inert when there are no versions; keep it unconditional, wrapped in `try?` with a comment (merge is best-effort; a failed merge must not block reading).
- [ ] **Step 4:** StorageLocations suite + full app tests — pass.
- [ ] **Step 5:** Commit: `fix(app): coordinate synced-root file I/O; union-merge metadata conflicts`

### Task 13: Root migration — collect failures, never strand entries silently

**Files:**
- Modify: `App/Model/StorageLocations.swift` (`migrateEntryFolders`), `App/PinfoldApp.swift` (`applyStorage`), `App/Views/SettingsView.swift` (error surface)
- Test: `AppTests/StorageLocationsTests.swift` (extend `StorageMigrationTests` if that's the suite name — check)

- [ ] **Step 1:** Failing tests:
  - `migrate_continuesPastFailingFolder`: seed 3 entry folders, make the middle one unmovable (e.g. destination collision: pre-create a folder with the same name containing a file), run migration → folders 1 and 3 moved, function returns/throws a result naming exactly the failed folder.
  - `migrate_reportsFailedFolders`: returned `MigrationReport { moved: [String], failed: [(folder: String, error: Error)] }` (struct) reflects reality.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: `migrateEntryFolders` loops all folders, catching per-folder errors into a `MigrationReport` return value instead of throwing on first. In `PinfoldApp.applyStorage`: drop the `try?`; await the report; if `report.failed` is non-empty, still repoint (the moved majority lives in the new root) but set a new `@State`-surfaced alert string on a small `@Observable` `MigrationStatus` object (or simplest: a `@State var migrationError: String?` in the App struct passed into SettingsView as a binding — choose the existing pattern used for import alerts in HomeView, an `alert(item:)`). Message lists failed folder display names and says the files remain in the previous location. Also: after a fully successful local→iCloud migration, remove the now-orphaned old local per-entry `resources/` directories (the old root's entry folders) — verify with a test `migrate_cleansUpEmptiedSourceFolders`.
- [ ] **Step 4:** Suites pass; `scripts/build.sh` compiles the app.
- [ ] **Step 5:** Commit: `fix(app): migration survives per-folder failures and reports them to the user`

### Task 14: Surface import failures on all arrival paths

**Files:**
- Modify: `App/PinfoldApp.swift` (`importFile`), `App/Services/PendingImportInbox.swift`, new `App/Services/ImportFailureLog.swift`
- Test: `AppTests/PendingImportInboxTests.swift`, new `AppTests/ImportFailureLogTests.swift`

- [ ] **Step 1:** Failing tests:
  - `drain_parseFailure_recordsFailureAndRemovesFile`: inbox file with garbage bytes → after drain, file removed (a parse failure is permanent), and a failure record `(filename, reason)` exists.
  - `drain_ioFailure_keepsFileForRetry`: simulate commit failure by using a read-only storage root (chmod the root 0o555 in the test, restore after) → inbox file still present after drain.
  - `failureLog_capsEntries`: log keeps at most N (e.g. 20) most recent.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement:
  - `ImportFailureLog`: tiny `@MainActor @Observable final class` holding `private(set) var failures: [ImportFailure]` (`struct ImportFailure: Identifiable { let id = UUID(); let filename: String; let reason: String; let date: Date }`), `func record(filename:reason:)` capping at 20, `func clear()`. Injected via environment alongside Catalog.
  - `PendingImportInbox.drain`: distinguish `ImportError.parseFailure` (record + delete file) from commit/file-system errors (record + **keep** file). Accept the log in its initializer.
  - `PinfoldApp.importFile`: replace `try?` chain with do/catch reporting to the log; only delete the sandbox copy on success or parse failure (keep on I/O failure).
  - UI: in `HomeView`, observe the log; when non-empty show a dismissible banner/alert listing recent failures ("Couldn't import Rome.kml: not a valid KML or KMZ file."), with a Clear action. Strings via `String(localized:)`.
- [ ] **Step 4:** Suites pass; build passes.
- [ ] **Step 5:** Commit: `fix(app): import failures are recorded and surfaced; transient failures retryable`

### Task 15: Serialize inbox drains; coalesce catalog reloads

**Files:**
- Modify: `App/PinfoldApp.swift`, `App/Services/Catalog.swift`
- Test: `AppTests/PendingImportInboxTests.swift`, `AppTests/CatalogTests.swift`

- [ ] **Step 1:** Failing tests:
  - `drain_concurrentCallsImportOnce`: write one file into a temp inbox; run two `drain()` calls concurrently (`async let` both, await both) → exactly one entry folder exists afterwards.
  - `reload_concurrentCallsPublishLatestScan`: seed root with 1 folder; run `async let a = catalog.reload(); async let b = catalog.reload()`; add a 2nd folder between (best-effort timing) — at minimum assert no crash and `entries.count` equals the final on-disk folder count after a final awaited reload. (The deterministic part is the generation-token unit: expose `internal` generation counter or test via behavior.)
- [ ] **Step 2:** Verify fail (concurrent drain currently duplicates).
- [ ] **Step 3:** Implement:
  - Drain serialization: give `PinfoldApp` a single `@State private var inboxDrainer = InboxDrainer()` — an `actor InboxDrainer { func drain(_ work: @Sendable () async -> Void) async }` that runs bodies serially (or simpler: a `@MainActor` guard flag + pending-rerun bit, mirroring `materializeTask`). All three triggers (bootstrap, scenePhase, onOpenURL) call through it.
  - Reload coalescing in `Catalog`: monotonically increasing `scanGeneration`; capture generation before detaching; only assign `entries` if `generation == latest`. Also fix `scheduleResourceMaterialization` lost-wakeup: add `materializePending` flag — if a reload arrives while a pass runs, set it; on completion re-run once.
- [ ] **Step 4:** Suites pass (CatalogTests is `@Suite(.serialized)` — keep new tests in it).
- [ ] **Step 5:** Commit: `fix(app): serialize inbox drains; generation-guard catalog reloads; re-run materialization when dirty`

### Task 16: ResourceCache download limits

**Files:**
- Modify: `App/Services/ResourceCache.swift`, `App/Services/ImportService.swift` (href cap at prepare)
- Test: `AppTests/ResourceCacheTests.swift`

- [ ] **Step 1:** Failing tests (the suite already injects a `downloader` closure — extend its shape if needed to also return a content type, or validate by bytes):
  - `download_skipsResponsesOverSizeCap`: downloader returns 21 MB of zeros for an href → nothing written, manifest unchanged (cap: 20 MB per resource).
  - `download_skipsNonImageData`: downloader returns HTML bytes (`<!doctype html>`) → not written. Validate by sniffing magic bytes (PNG/JPEG/GIF/WebP/BMP/TIFF/HEIC) in a small `static func looksLikeImage(_ data: Data) -> Bool` — content-type header is unreliable; magic bytes are what we render anyway.
  - `download_capsHrefCountPerEntry`: 600 hrefs → only first 500 attempted (assert via a counting downloader).
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement constants `maxResourceBytes = 20 * 1024 * 1024`, `maxRemoteResourcesPerEntry = 500` (file-level, documented as DoS bounds from untrusted KML). Apply count cap in `downloadRemote` (and mention dropped count via `os_log` debug); size + magic-byte check before write. Keep manifest/retry semantics: an over-cap or non-image response is recorded as permanently skipped (remove from remote-hrefs retry set) so it isn't re-fetched forever.
- [ ] **Step 4:** ResourceCacheTests pass.
- [ ] **Step 5:** Commit: `fix(app): bound remote resource downloads (size, count, image-only)`

### Task 17: Filename sanitization across the pipeline

**Files:**
- Modify: `ShareExtension/ShareViewController.swift`, `App/Services/ImportService.swift` (prepare), new shared helper `App/Support/SafeFilename.swift` (App target; share extension gets its own tiny copy or the file is added to both targets via project.yml `sources` — check project.yml: sources are globbed per-target, so add the file under a folder included by both, or duplicate 10 lines in the extension with a comment; prefer adding `App/Support/SafeFilename.swift` to the ShareExtension target's sources in project.yml)
- Test: `AppTests/ImportServiceTests.swift` (+ new `AppTests/SafeFilenameTests.swift`)

- [ ] **Step 1:** Failing tests:
  - `sanitize_stripsPathSeparatorsAndDotSegments`: `"images/evil.kml"` → `"images-evil.kml"` (or just last component — decide: take `lastPathComponent`-style final segment, then strip `/`, `\0`, leading dots, cap at 255 bytes; `"../x.kml"` → `"x.kml"`).
  - `sanitize_capsLength`: 300-char name → ≤ 255 bytes keeping extension.
  - `prepare_sanitizesSourceFilename`: `ImportService.prepare(data:sourceFilename: "a/b.kml")` → `result.sourceFilename == "b.kml"`.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement `enum SafeFilename { static func sanitize(_ raw: String) -> String }`; apply in `ImportService.prepare` (single choke point all three arrival paths flow through) and in `ShareViewController.copyIntoInbox` before building the dest URL. Update project.yml to include the helper in the ShareExtension target sources.
- [ ] **Step 4:** Suites pass; `scripts/build.sh` (regenerates project) passes.
- [ ] **Step 5:** Commit: `fix(app): sanitize attacker-controlled filenames at import choke points`

---

## Wave 3 — UI correctness & scalability

### Task 18: Map representable — fresh parent + annotation reconciliation

**Files:**
- Modify: `App/Views/PlacemarkMapRepresentable.swift`
- Test: `AppTests/PlacemarkAnnotationsTests.swift` stays green; map diffing logic gets a unit-testable helper + new `AppTests/AnnotationDiffTests.swift`

- [ ] **Step 1:** Extract pure diff logic: `static func annotationDiff(current: [String: PlacemarkAnnotation], desired: [KMLPlacemark]) -> (toAdd: [KMLPlacemark], toRemove: [PlacemarkAnnotation])` keyed by `stableKey`. Failing tests: add/remove/no-change cases.
- [ ] **Step 2:** Verify fail (helper doesn't exist).
- [ ] **Step 3:** Implement:
  - `updateUIView` starts with `context.coordinator.parent = self` (standard idiom; remove staleness).
  - Coordinator maintains `annotationsByKey: [String: PlacemarkAnnotation]`. `updateUIView` computes the diff when the placemark set changed (compare a stored `lastPlacemarkKeys: Set<String>`), applies add/remove, re-fits when the set changed, and uses `annotationsByKey` for the favorite/visited re-decoration loop (replacing the O(N) `mapView.annotations.compactMap`).
  - Consolidate the duplicated cluster-tap fit logic into `Self.fit` (single-point fixed-span path already there).
- [ ] **Step 4:** New tests pass; build passes; run full app test suite.
- [ ] **Step 5:** Commit: `fix(app): map reconciles placemark changes; coordinator reads fresh state`

### Task 19: Map selection keyed by stableKey

**Files:**
- Modify: `App/Views/PlacemarkMapView.swift`, `App/Views/PlacemarkMapRepresentable.swift`
- Test: build + existing suites (pure refactor; no new unit surface)

- [ ] **Step 1:** Replace `selectedID`/`placemarkToOpenID` (unstable `placemark.id`) with `selectedKey`/`placemarkToOpenKey` using `stableKey` end-to-end (binding names, `PlacemarkAnnotation.placemarkID` usages, `placemarks.first(where:)` lookups).
- [ ] **Step 2:** `scripts/build.sh` + full `scripts/test.sh` green.
- [ ] **Step 3:** Commit: `fix(app): key map selection by stableKey, surviving re-parses`

### Task 20: KMLDetailView — drop AnyView recursion, memoize search

**Files:**
- Modify: `App/Views/KMLDetailView.swift`, `App/Support/PlacemarkSearch.swift`
- Test: `AppTests/PlacemarkSearchTests.swift`

- [ ] **Step 1:** Failing tests for a new flattened model: `struct PlacemarkOutline { struct Row: Identifiable { enum Kind { case placemark(KMLPlacemark), folder(name: String, depth: Int) } ... } static func rows(for container: KMLContainer, matching query: String) -> [Row] }` — cases: empty query returns full tree flattened with depths; query filters placemarks by name (existing `PlacemarkSearch` semantics) keeping ancestor folder rows of matches only; folder with no matching descendants omitted.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement `PlacemarkOutline` (pure, in Support). Rework `contentList` to a single `List(outlineRows)` rendering rows by kind with indentation (`.padding(.leading, CGFloat(depth) * 16)`) — no `AnyView`, no recursive view structs. DisclosureGroup behavior: preserve collapse/expand by tracking `collapsedFolderIDs: Set<String>` state and filtering rows under collapsed folders (folder identity: its path in the tree). Memoize: `@State private var outlineRows: [PlacemarkOutline.Row]` recomputed in `.onChange(of: searchText)` (debounced via `.task(id: searchText)` + `try? await Task.sleep(for: .milliseconds(250))` and on document load; `mappablePlacemarks` derives from the same memoized result (placemark rows with coordinates) instead of re-walking the tree.
- [ ] **Step 4:** PlacemarkSearchTests + build green. Manual sanity via existing fixture-driven tests.
- [ ] **Step 5:** Commit: `perf(app): flattened lazy placemark outline; debounced memoized search`

### Task 21: Pin images off-main + forced clustering threshold

**Files:**
- Modify: `App/Views/PlacemarkMapRepresentable.swift`, `App/Support/PlacemarkPinImage.swift`, `App/Views/PlacemarkMapView.swift`
- Test: build + suites (image generation is UIKit; logic threshold gets a constant + unit check in `AnnotationDiffTests`)

- [ ] **Step 1:** Implement:
  - Annotation creation no longer builds images in `makeUIView`'s loop. `PlacemarkAnnotation` stores the inputs (style href URL, tint, favorite/visited); `viewFor` requests the image from a coordinator-owned cache `pinImageCache: [String: UIImage]` keyed by style-href+tint; misses are built synchronously *once per distinct style* (KML files have few distinct styles even with 50k placemarks — building per-style not per-placemark is the actual win; document this). Decoration (favorite/visited badge) composites lazily per annotation as today but only for on-screen views.
  - Forced clustering: `static let forcedClusteringThreshold = 2_000`; in `makeUIView`/diff-apply, if placemark count exceeds it, use clustering regardless of `clusterPins` setting (comment: MapKit collapses under tens of thousands of unclustered views).
- [ ] **Step 2:** `scripts/build.sh` + full tests green.
- [ ] **Step 3:** Commit: `perf(app): per-style pin image cache; force clustering above 2k pins`

### Task 22: Antimeridian-aware map fitting

**Files:**
- Modify: `App/Support/MapRectBuilder.swift`
- Test: `AppTests/MapAppTests.swift`? No — new `AppTests/MapRectBuilderTests.swift`

- [ ] **Step 1:** Failing tests:
  - `boundingRect_antimeridianClusterStaysTight`: coords at lon 179.5 and -179.5 (lat 0) → resulting rect width < the width of a 30°-span rect (i.e. wrapped, not whole-globe).
  - `boundingRect_normalSpanUnchanged`: Paris+Rome rect identical to current behavior.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: compute both the naive rect and the wrapped rect (shift negative longitudes by +360, build rect in shifted space, then translate into MapKit's wrapped coordinate space via `MKMapPoint` x offset of world width); return whichever is narrower. MapKit handles rects crossing the world's x-edge when `setVisibleMapRect` receives an x beyond the world width — verify with the existing `fit` path (it does; `MKMapRect` is continuous in x).
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit: `fix(app): tight map fit for pin sets straddling the antimeridian`

### Task 23: Extract + test ImportCoordinator; add import progress UI

**Files:**
- Create: `App/Services/ImportCoordinator.swift` (moved from HomeView.swift), `AppTests/ImportCoordinatorTests.swift`
- Modify: `App/Views/HomeView.swift`

- [ ] **Step 1:** Move `ImportCoordinator` verbatim into its own file (no behavior change), build green, commit: `refactor(app): extract ImportCoordinator from HomeView`.
- [ ] **Step 2:** Failing tests in `ImportCoordinatorTests` (inject temp storage + catalog, follow `@Suite(.serialized)` + temp-root conventions from CatalogTests):
  - `import_queueProcessesSequentially` (2 files → 2 entries, order preserved by import date).
  - `import_duplicateStallsUntilDecision` (same content twice → second waits; `skip()` → 1 entry; rerun with `importAnyway()` → 2 entries).
  - `import_isImportingTrueWhileProcessing` (assert the new progress flag flips).
  - `importAnyway_awaitsReloadBeforeNext` (regression for the race: queue duplicate + distinct file; after importAnyway both entries present exactly once).
- [ ] **Step 3:** Verify fail (flag doesn't exist; race may flake — make `importAnyway` await commit+reload before `processNext`).
- [ ] **Step 4:** Implement: add `private(set) var isImporting: Bool` + `private(set) var currentFilename: String?` to the coordinator; make the `commit` path await `catalog.reload()` before `processNext()` (both paths). In `HomeView`, overlay a thin `ProgressView` bar / toolbar spinner with the filename while `isImporting` ("Importing Rome.kmz…", localized), and disable the import button.
- [ ] **Step 5:** Suites pass. Commit: `feat(app): import progress indicator; ImportCoordinator tests and race fix`

---

## Wave 4 — Features

### Task 24: NavigationSplitView + iPad/Mac Commands (F8) — do this FIRST in the wave

**Files:**
- Modify: `App/PinfoldApp.swift`, `App/Views/HomeView.swift`, `App/Views/KMLDetailView.swift`
- Test: build + full suite (navigation is UI-only; keep all logic tests green)

- [ ] **Step 1:** Restructure root: `NavigationSplitView { HomeView(selection: $selectedEntry) } detail: { NavigationStack { if let selectedEntry { KMLDetailView(entry:) } else { ContentUnavailableView("Select a File", ...) } } }`. HomeView's rows become `List(selection:)`-driven on regular width; compact width must keep current push behavior (NavigationSplitView collapses automatically). Keep the environment re-injection notes working (the `.environment(annotations)` workaround sites) — re-inject at the detail-stack root once instead of per-destination, deleting the four scattered injections.
- [ ] **Step 2:** Add `.commands { CommandGroup(after: .newItem) { Button("Import…") { … } .keyboardShortcut("i") } CommandGroup(after: .textEditing) { Button("Search") { focus search } } }` — wire Import via a shared `@Observable` UI-intent object or `FocusedValue`; simplest: a `Notification`-free `@Observable AppCommands` object in environment that HomeView observes.
- [ ] **Step 3:** `scripts/build.sh` + full `scripts/test.sh` green. Manual check via `run-sim` skill if needed.
- [ ] **Step 4:** Commit: `feat(app): NavigationSplitView layout for iPad/Mac with menu commands`

### Task 25: Map overlays for lines/polygons/tracks (F1, app half)

**Files:**
- Modify: `App/Views/PlacemarkMapRepresentable.swift`, `App/Support/KMLColor.swift` (verify aabbggrr handling exists — it does, reuse), `App/Views/KMLDetailView.swift` (mappable = has coordinate OR geometry), `App/Views/PlacemarkRow.swift` (geometry placemarks show a line/area glyph instead of pin)
- Test: `AppTests/OverlayBuilderTests.swift` (new)

- [ ] **Step 1:** Failing tests for pure builder `enum OverlayBuilder { static func overlays(for placemarks: [KMLPlacemark], document: KMLDocument) -> [StyledOverlay] }` where `StyledOverlay` wraps `MKPolyline`/`MKPolygon` + stroke/fill UIColor + width (resolved from placemark style via document, defaulting stroke accent-blue width 3, fill 25% alpha):
  - line placemark → 1 polyline with 3 points and the style's color/width;
  - polygon with inner ring → MKPolygon with `interiorPolygons`;
  - track → polyline;
  - point-only placemark → no overlay.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement builder + map wiring: `makeUIView`/diff-apply adds overlays; coordinator implements `mapView(_:rendererFor:)` returning configured `MKPolylineRenderer`/`MKPolygonRenderer`; fit-to-pins includes overlay bounding rects (`MapRectBuilder` accepts an extra `[MKMapRect]`). Track placemarks keep their representative-point pin; pure line/polygon placemarks get NO pin (the overlay is the representation) but remain selectable from the list (selecting zooms to the overlay rect).
- [ ] **Step 4:** Tests + build green.
- [ ] **Step 5:** Commit: `feat(app): render LineString/Polygon/Track overlays with KML styling`

### Task 26: Per-entry placemark index + global search (F2)

**Files:**
- Create: `App/Services/PlacemarkIndex.swift`, `AppTests/PlacemarkIndexTests.swift`
- Modify: `App/Services/CatalogScanner.swift` (write index during materialization), `App/Services/ImportService.swift` (write at commit), `App/Views/HomeView.swift` (search UI)

- [ ] **Step 1:** Failing tests:
  - `index_writeAndQueryRoundTrip`: `PlacemarkIndex.write(entries:to:)` then `PlacemarkIndex.search("camp", inResourcesDirs:)` returns matching `(folderName, stableKey, name, coordinate?)`.
  - `index_builtDuringMaterialization`: seed a folder with original + no index → `materializeMissingResources()` creates `placemarks-index.json` in `resources/`.
  - `index_searchToleratesMissingIndexFiles`: folders without index are skipped, not fatal.
  - `index_caseAndDiacriticInsensitive`: "café" matches "cafe" query (use `.localizedStandardContains` semantics — match PlacemarkSearch).
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: `placemarks-index.json` (local-only, derivable → lives in `resources/`) = array of `{key, name, lat?, lon?}`; written at `commit` (from the already-parsed document — pass placemark summaries through `ImportResult` as a new `indexEntries: [PlacemarkIndex.Entry]` field) and during materialization for synced-in folders (it already re-parses there). `search` reads each active entry's index file lazily off-main. HomeView: `.searchable` on the catalogue list; results section shows matched files (name match on entry OR placemark hits, grouped by file, each hit row deep-links to the entry's `KMLDetailView` with the search prefilled (pass `initialSearch:` / scroll target stableKey).
- [ ] **Step 4:** Suites green.
- [ ] **Step 5:** Commit: `feat(app): global placemark search backed by per-entry local index`

### Task 27: Export, rename, sort/filter (F3 + F4 + F5)

**Files:**
- Modify: `App/Views/HomeView.swift`, `App/Views/FileRow.swift`, `App/Services/Catalog.swift`, `App/Model/AppSettings.swift`
- Test: `AppTests/CatalogTests.swift`

- [ ] **Step 1:** Failing tests:
  - `rename_updatesSidecarAndList`: `catalog.rename(entry, to: "New")` → reloaded entry displayName "New"; sidecar on disk updated.
  - `rename_rejectsEmptyOrWhitespace`: name unchanged.
  - `sortedActive_byNameAndPointCountAndDate`: a new `catalog.active(sortedBy:)` or a pure `EntrySort.apply(_:to:)` helper — three orderings verified.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement:
  - `Catalog.rename(_:to:)` via `updateMetadata` + reload (trim, reject empty).
  - `enum EntrySort: String, CaseIterable { case dateDesc, nameAsc, pointCountDesc }` + pure sorter; persisted in `AppSettings.entrySort` (new UserDefaults-backed property following the existing Key pattern).
  - HomeView: toolbar `Menu` (arrow.up.arrow.down icon) for sort; context-menu + swipe "Rename" with `.alert` text field; context-menu `ShareLink(item: storage.originalFile(for: entry))` — original is a file URL; verify ShareLink presents it (use `SharePreview(entry.displayName)`); a trashed entry doesn't offer share/rename.
- [ ] **Step 4:** Suites + build green.
- [ ] **Step 5:** Commit: `feat(app): rename entries, share original files, catalogue sort options`

### Task 28: Cross-file favorites view (F7)

**Files:**
- Create: `App/Views/FavoritesView.swift`
- Modify: `App/Views/HomeView.swift` (entry point: toolbar star or top segment), `App/Services/PlacemarkIndex.swift` (lookup by keys)
- Test: `AppTests/PlacemarkIndexTests.swift`

- [ ] **Step 1:** Failing test `index_resolvesFavoriteKeys`: given two entries with favoriteKeys and index files, `PlacemarkIndex.resolve(keys:inResourcesDirs:)` returns name+coordinate per (folder, key) including which entry each belongs to; missing keys (favorited placemark no longer in file) are skipped.
- [ ] **Step 2:** Verify fail; implement resolver.
- [ ] **Step 3:** `FavoritesView`: sections per file, rows show placemark name + file name; tap deep-links into the entry detail (same mechanism as Task 26 deep link); empty state `ContentUnavailableView("No Favorites")`. Entry point: a `Star` toolbar item on HomeView.
- [ ] **Step 4:** Build + suites green.
- [ ] **Step 5:** Commit: `feat(app): consolidated favorites across all files`

### Task 29: Tags + distance-from-me sort (F9 + suggestion 11)

**Files:**
- Modify: `App/Model/EntryMetadata.swift` (tags, with decodeIfPresent), `App/Services/Catalog.swift`, `App/Views/HomeView.swift`, `App/Views/FileRow.swift`, `App/Views/PlacemarkRow.swift`, `App/Support/LocationAuthorization.swift` (expose last location)
- Test: `AppTests/EntryMetadataTests.swift`, `AppTests/CatalogTests.swift`

- [ ] **Step 1:** Failing tests:
  - `metadata_tagsRoundTripAndLegacyDecode`: encode/decode with tags; legacy JSON without tags decodes to empty.
  - `catalog_setTags_persists`: `catalog.setTags(["hiking"], for: entry)` round-trips through reload.
  - `filter_byTag`: pure filter helper returns only matching entries.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement: `var tags: [String] = []` in EntryMetadata (update all four Codable sites; encode sorted). `Catalog.setTags`. HomeView: horizontal tag-chip filter bar above the list (only when any tags exist), tag editor in the rename-style alert or a small sheet from the context menu ("Edit Tags…", comma-separated TextField — keep it simple). Distance: `LocationAuthorization` exposes `var lastLocation: CLLocation?` (one-shot `CLLocationUpdate.liveUpdates` first fix or `CLLocationManager` last known); `PlacemarkRow` shows formatted distance (`Measurement<UnitLength>` + `.formatted(.measurement(width: .abbreviated))`) when available; placemark list gets a "Nearest First" sort toggle in KMLDetailView's filter menu (sort outline placemark rows by distance when enabled and location known).
- [ ] **Step 4:** Suites + build green.
- [ ] **Step 5:** Commit: `feat(app): entry tags with filter chips; distance display and nearest-first sort`

### Task 30: Tappable links in descriptions (F10)

**Files:**
- Modify: `App/Support/AttributedHTML.swift`, `App/Views/PlacemarkDetailView.swift`
- Test: `AppTests/AttributedHTMLTests.swift`

- [ ] **Step 1:** Failing tests:
  - `attributed_anchorBecomesTappableLink`: `<a href="https://x.example/a">See</a>` → `AttributedString` run with `.link == URL("https://x.example/a")` and text "See".
  - `attributed_bareURLDetected`: "visit https://x.example now" → link run on the URL.
  - `attributed_javascriptHrefStripped`: `<a href="javascript:alert(1)">x</a>` → plain text, no link (only http/https/mailto/tel schemes become links).
  - `plainText_behaviorUnchanged`: existing preview-stripping tests stay green.
- [ ] **Step 2:** Verify fail.
- [ ] **Step 3:** Implement `AttributedHTML.attributed(_ html: String) -> AttributedString`: extend the existing regex-based parser (do NOT adopt NSAttributedString's HTML importer — the documented main-thread/privacy hazard stands): capture `<a href="…">text</a>` pairs into link runs (scheme-allowlisted), strip remaining tags as `plainText` does, then run `NSDataDetector(types: .link)` over non-link ranges for bare URLs. `PlacemarkDetailView` renders `Text(attributed)` (links open via default `openURL`).
- [ ] **Step 4:** Suite green.
- [ ] **Step 5:** Commit: `feat(app): tappable, scheme-allowlisted links in placemark descriptions`

### Task 31: Spotlight indexing + App Intents (F6)

**Files:**
- Create: `App/Services/SpotlightIndexer.swift`, `App/Intents/PinfoldIntents.swift` (AppEntity + OpenEntryIntent + AppShortcuts)
- Modify: `App/Services/ImportService.swift` (index on commit), `App/Services/Catalog.swift` (deindex on deleteForever), `App/PinfoldApp.swift` (`onContinueUserActivity(CSSearchableItemActionType)` routing), `project.yml` (CoreSpotlight needs no entitlement; AppIntents needs nothing for in-app intents)
- Test: `AppTests/SpotlightIndexerTests.swift` (build the searchable items as pure values; don't hit the live index in tests)

- [ ] **Step 1:** Failing tests for pure item builder: `items(for: entry, placemarks:)` → one `CSSearchableItem` per placemark (uniqueIdentifier `"<folderName>/<stableKey>"`, domain `"placemarks"`, title = placemark name, contentDescription = plain-text description prefix, latitude/longitude set when coordinate present) + one item per entry (domain `"entries"`). Test identifier format round-trip parse `SpotlightID.parse("folder/key")`.
- [ ] **Step 2:** Verify fail; implement builder + thin `SpotlightIndexer` wrapper over `CSSearchableIndex.default()` (`index(entry:placemarks:)`, `deindex(folderName:)`) called fire-and-forget (Task.detached, errors logged) from commit / deleteForever / rename (reindex entry item).
- [ ] **Step 3:** App Intents: `CatalogEntryEntity: AppEntity` (id = folderName, display = displayName) + `EntryQuery: EntityStringQuery` reading from the shared Catalog; `OpenEntryIntent: AppIntent` (`@Parameter var entry: CatalogEntryEntity`, opens app + navigates — route through the same deep-link mechanism as Spotlight: a `@MainActor @Observable NavigationRouter { var pendingDestination: Destination? }` consumed by the split-view root); `PinfoldShortcuts: AppShortcutsProvider` with phrase "Open ${applicationName} file". Spotlight tap routing: `onContinueUserActivity(CSSearchableItemActionType)` parses the identifier and sets the router destination (entry, optional placemark stableKey → detail view scrolls/opens it).
- [ ] **Step 4:** Build + suites green (intents compile-checked; query covered indirectly).
- [ ] **Step 5:** Commit: `feat(app): Spotlight placemark indexing and App Intents with deep-link routing`

---

## Wave 5 — Hygiene & localization

### Task 32: Target hygiene — share-extension activation rule, entitlements, plist, README

**Files:**
- Modify: `ShareExtension/Info.plist`, `ShareExtension/ShareExtension.entitlements`, `App/Pinfold.entitlements`, `App/Info.plist`, `README.md`, `CLAUDE.md`
- Test: `scripts/build.sh` (both targets compile + sign-free build), manual plist review

- [ ] **Step 1:** `ShareExtension/Info.plist`: replace `NSExtensionActivationSupportsFileWithMaxCount` with an `NSExtensionActivationRule` SUBQUERY predicate matching UTIs `com.google.earth.kml` / `com.google.earth.kmz` (max 10). Keep `TRUEPREDICATE` out.
- [ ] **Step 2:** Remove `com.apple.developer.ubiquity-kvstore-identifier` from both entitlements; remove iCloud Documents container entitlements from the ShareExtension (it only touches the App Group). Verify `ShareViewController` truly never touches the ubiquity container before removing (grep).
- [ ] **Step 3:** `App/Info.plist`: drop dead `mapswithme` from `LSApplicationQueriesSchemes`.
- [ ] **Step 4:** README: remove `samples/` from the project-structure section; CLAUDE.md: soften "Design + plans live in docs/superpowers/" to mention plans now include this implementation plan.
- [ ] **Step 5:** `scripts/build.sh` green. Commit: `chore: share-sheet UTI filtering, entitlement cleanup, plist/docs fixes`

### Task 33: Localization-safety fixes

**Files:**
- Modify: `App/Views/FileRow.swift`, `App/Views/PlacemarkDetailView.swift`, `App/Views/MapPickerSheet.swift`, plus any string literal touched in earlier tasks
- Test: `AppTests/` — new `AppTests/CoordinateFormattingTests.swift` for the formatter helper

- [ ] **Step 1:** Failing tests for `CoordinateFormatter.string(for: Coordinate)` → fixed `"37.421998, -122.084000"` style with `.` decimal separator regardless of locale (explicit `Locale(identifier: "en_US_POSIX")` number formatting, comma+space separator) — used wherever coordinates are displayed/copied.
- [ ] **Step 2:** Implement helper in `App/Support/`; replace raw interpolations in PlacemarkDetailView/MapPickerSheet.
- [ ] **Step 3:** FileRow: `"\(entry.pointCount) points"` → `String(localized: "^[\(entry.pointCount) point](inflect: true)")` (verify inflection renders in build; fallback: explicit singular/plural ternary with String(localized:)). Sweep user-facing literals in files already modified by this plan to `String(localized:)`.
- [ ] **Step 4:** Suites + build green. Commit: `fix(app): pluralization, locale-safe coordinate formatting, localized strings`

### Task 34: Final verification

- [ ] **Step 1:** `cd PinfoldCore && swift test` — all green.
- [ ] **Step 2:** `scripts/test.sh` — all green.
- [ ] **Step 3:** `swiftlint lint` — 0 errors.
- [ ] **Step 4:** `scripts/build.sh` — clean build.
- [ ] **Step 5:** Re-read the review summary; confirm every High/Medium finding and features 1-10 + hygiene have a landed commit. Use superpowers:finishing-a-development-branch.
