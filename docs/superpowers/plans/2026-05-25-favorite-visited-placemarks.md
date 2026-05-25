# Favorite & Visited Placemarks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user mark any placemark as favorite (leading star icon) and/or visited (struck-out), from a leading swipe in the points list and the point detail's three-dots menu, persisting the state in each entry's `metadata.json` and reflecting it on the map.

**Architecture:** A content-derived `stableKey` on `KMLPlacemark` (PinfoldCore) keys two `Set<String>` fields added to `EntryMetadata`. A `@MainActor @Observable PlacemarkAnnotations` store, owned by `KMLDetailView` and injected into the environment, holds the open file's sets, exposes toggles, and synchronously writes through to `metadata.json` via a new read-modify-write helper (no catalogue reload, no re-parse). Views read the store to render the star/strikethrough and swipe/menu controls; list order is unchanged.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, Swift Testing (`import Testing`), CryptoKit (already used for hashing), MapKit/UIKit (existing map representable). Build/test via `scripts/build.sh`, `scripts/test.sh`, and `cd PinfoldCore && swift test`.

**Spec:** `docs/superpowers/specs/2026-05-25-favorite-visited-placemarks-design.md`

**Conventions reminder:** Do NOT commit unless the user explicitly asks (per `CLAUDE.md`). The commit steps below are written for completeness; if commits are deferred, still run them as `git add` staging checkpoints and skip the `git commit` until asked. After adding files under `App/`, the test/build scripts run `xcodegen generate` themselves (sources are globbed), so no `project.yml` edit is needed for new files.

---

## File Structure

**PinfoldCore (parser package):**
- `PinfoldCore/Sources/PinfoldCore/Model/KMLPlacemark.swift` — add `sourceID`, computed `stableKey`.
- `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift` — capture `<Placemark id="…">`.
- `PinfoldCore/Tests/PinfoldCoreTests/StableKeyTests.swift` *(new)* — `stableKey` + `sourceID` tests.

**App:**
- `App/Model/EntryMetadata.swift` — add `favoriteKeys`/`visitedKeys` + custom `Codable`.
- `App/Model/StorageLocations.swift` — add `updateMetadata(forFolderNamed:_:)` read-modify-write helper.
- `App/Services/Catalog.swift` — switch `writeTrashedAt` to the new helper.
- `App/Services/PlacemarkAnnotations.swift` *(new)* — `@Observable` store.
- `App/Support/EnvironmentKeys.swift` — add an environment injector for the store (optional convenience; `.environment(store)` works directly).
- `App/Views/KMLDetailView.swift` — own + inject the store, add leading swipe actions.
- `App/Views/PlacemarkRow.swift` — leading star + strikethrough.
- `App/Views/PlacemarkDetailView.swift` — star before title + menu toggles.
- `App/Support/PlacemarkPinImage.swift` — `decorated(...)` badge/dim variant.
- `App/Views/PlacemarkMapRepresentable.swift` — pass favorite/visited sets, decorate pins.
- `App/Views/PlacemarkMapView.swift` — read store, pass sets down, decorate preview card.

**AppTests:**
- `AppTests/EntryMetadataTests.swift` — extend with new-field round-trip + legacy decode.
- `AppTests/StorageLocationsTests.swift` — extend with `updateMetadata` preservation test.
- `AppTests/PlacemarkAnnotationsTests.swift` *(new)* — toggle + write-through.

---

## Task 1: PinfoldCore — stable placemark key

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Model/KMLPlacemark.swift`
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/StableKeyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PinfoldCore/Tests/PinfoldCoreTests/StableKeyTests.swift`:

```swift
import Testing
@testable import PinfoldCore

struct StableKeyTests {

    private func placemark(
        id: String = "p1",
        name: String? = nil,
        coordinate: Coordinate? = nil,
        sourceID: String? = nil
    ) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: name, descriptionHTML: nil, styleUrl: nil,
            coordinate: coordinate, extendedData: [], photoLinks: [], sourceID: sourceID
        )
    }

    @Test func usesSourceIDWhenPresent() {
        let key = placemark(name: "A", coordinate: Coordinate(longitude: 2, latitude: 1), sourceID: "abc").stableKey
        #expect(key == "id:abc")
    }

    @Test func emptySourceIDFallsThrough() {
        let key = placemark(name: "A", coordinate: Coordinate(longitude: 2, latitude: 1), sourceID: "").stableKey
        #expect(key.hasPrefix("h:"))
    }

    @Test func hashIsStableForSameContent() {
        let a = placemark(name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 51.5)).stableKey
        let b = placemark(id: "p99", name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 51.5)).stableKey
        #expect(a == b)            // independent of parse-order id
        #expect(a.hasPrefix("h:"))
    }

    @Test func hashDiffersByCoordinate() {
        let a = placemark(name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 51.5)).stableKey
        let b = placemark(name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 52.0)).stableKey
        #expect(a != b)
    }

    @Test func hashDiffersByName() {
        let coord = Coordinate(longitude: 2, latitude: 1)
        #expect(placemark(name: "A", coordinate: coord).stableKey != placemark(name: "B", coordinate: coord).stableKey)
    }

    @Test func placelessNamelessFallsBackToParseOrderID() {
        #expect(placemark(id: "p7").stableKey == "p:p7")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd PinfoldCore && swift test --filter StableKeyTests`
Expected: FAIL to compile — `KMLPlacemark` has no `sourceID` parameter and no `stableKey` member.

- [ ] **Step 3: Add `sourceID` + `stableKey` to `KMLPlacemark`**

Edit `PinfoldCore/Sources/PinfoldCore/Model/KMLPlacemark.swift`. Add `import Foundation` and `import CryptoKit` at the top, add the stored property, the init parameter (defaulted so existing callers still compile), and the computed key:

```swift
import CryptoKit
import Foundation

public struct KMLPlacemark: Equatable, Sendable, Identifiable {
    /// A parse-order identifier ("p1", "p2", …) assigned by the parser.
    /// **Not stable across re-parses** — if the source file changes, the same placemark
    /// may receive a different id on the next parse. Do not persist this value as a
    /// durable key; use it only for in-memory identity within a single parse session.
    public let id: String
    public let name: String?
    public let descriptionHTML: String?
    public let styleUrl: String?
    /// nil for a placeless placemark (no Point geometry).
    public let coordinate: Coordinate?
    public let extendedData: [KMLDataItem]
    /// Photo URLs gathered from ExtendedData `gx_media_links` (kept separate from extendedData).
    public let photoLinks: [String]
    /// The author-provided `<Placemark id="…">` XML attribute, if any. Stable across
    /// re-parses (unlike `id`), so it is the preferred basis for `stableKey`.
    public let sourceID: String?

    public init(id: String, name: String?, descriptionHTML: String?, styleUrl: String?,
                coordinate: Coordinate?, extendedData: [KMLDataItem], photoLinks: [String],
                sourceID: String? = nil) {
        self.id = id
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.styleUrl = styleUrl
        self.coordinate = coordinate
        self.extendedData = extendedData
        self.photoLinks = photoLinks
        self.sourceID = sourceID
    }

    /// A durable identity for this placemark, safe to persist across re-parses.
    ///
    /// Fallback chain:
    /// 1. `"id:<sourceID>"` when the author supplied a non-empty `<Placemark id>`.
    /// 2. `"h:<hash>"` — a SHA-256 (16 hex chars) of `"<name>|<lat>|<lon>"`. Survives
    ///    folder reordering; only changes if this placemark's own name/coordinate change.
    /// 3. `"p:<id>"` — parse-order id, last resort for a placeless, nameless placemark.
    public var stableKey: String {
        if let sourceID, !sourceID.isEmpty { return "id:\(sourceID)" }
        if name != nil || coordinate != nil {
            let lat = coordinate.map { String(format: "%.6f", $0.latitude) } ?? ""
            let lon = coordinate.map { String(format: "%.6f", $0.longitude) } ?? ""
            let basis = "\(name ?? "")|\(lat)|\(lon)"
            let digest = SHA256.hash(data: Data(basis.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
            return "h:\(hex)"
        }
        return "p:\(id)"
    }
}
```

- [ ] **Step 4: Capture the `<Placemark id>` attribute in the parser**

Edit `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift`.

(a) Add the field to `PlacemarkBuilder` (after `hasNonPointGeometry`):

```swift
    private struct PlacemarkBuilder {
        var name: String?
        var descriptionHTML: String?
        var styleUrl: String?
        var coordinate: Coordinate?
        var extendedData: [KMLDataItem] = []
        var photoLinks: [String] = []
        var hasPoint = false
        var hasNonPointGeometry = false
        var sourceID: String?
    }
```

(b) In `didStartElement`, capture the attribute on `<Placemark>`:

```swift
        case "Placemark":
            var builder = PlacemarkBuilder()
            builder.sourceID = attributeDict["id"]
            placemark = builder
```

(c) In `didEndElement` for `"Placemark"`, pass it through:

```swift
                    let built = KMLPlacemark(id: nextID("p"), name: pm.name,
                                             descriptionHTML: pm.descriptionHTML,
                                             styleUrl: pm.styleUrl,
                                             coordinate: pm.hasPoint ? pm.coordinate : nil,
                                             extendedData: pm.extendedData,
                                             photoLinks: pm.photoLinks,
                                             sourceID: pm.sourceID)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd PinfoldCore && swift test --filter StableKeyTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Run the full PinfoldCore suite (no regressions)**

Run: `cd PinfoldCore && swift test`
Expected: PASS — all existing parser/model tests still green.

- [ ] **Step 7: Commit**

```bash
git add PinfoldCore/Sources/PinfoldCore/Model/KMLPlacemark.swift \
        PinfoldCore/Sources/PinfoldCore/Parsing/KMLParser.swift \
        PinfoldCore/Tests/PinfoldCoreTests/StableKeyTests.swift
git commit -m "feat(core): add stable placemark key from author id or name+coord hash"
```

---

## Task 2: `EntryMetadata` favorite/visited fields + custom Codable

**Files:**
- Modify: `App/Model/EntryMetadata.swift`
- Test: `AppTests/EntryMetadataTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `AppTests/EntryMetadataTests.swift` (inside the existing test struct; if unsure of the struct name, open the file and add these `@Test` methods to it):

```swift
    @Test func roundTripsFavoriteAndVisitedKeys() throws {
        let meta = EntryMetadata(
            id: UUID(), displayName: "Trip", sourceFilename: "trip.kml",
            importDate: Date(timeIntervalSince1970: 1000), pointCount: 3,
            contentSHA256: "deadbeef", trashedAt: nil,
            favoriteKeys: ["id:a", "h:1234"], visitedKeys: ["id:b"]
        )
        let decoded = try EntryMetadata.decoded(from: meta.encoded())
        #expect(decoded.favoriteKeys == ["id:a", "h:1234"])
        #expect(decoded.visitedKeys == ["id:b"])
        #expect(decoded == meta)
    }

    @Test func legacyJSONWithoutNewKeysDecodesToEmptySets() throws {
        // A sidecar written before this feature existed.
        let legacy = """
        {"contentSHA256":"abc","displayName":"Old","id":"\(UUID().uuidString)",\
        "importDate":0,"pointCount":1,"sourceFilename":"old.kml"}
        """
        let decoded = try EntryMetadata.decoded(from: Data(legacy.utf8))
        #expect(decoded.favoriteKeys.isEmpty)
        #expect(decoded.visitedKeys.isEmpty)
    }

    @Test func encodesKeysAsSortedArraysForStableOutput() throws {
        let meta = EntryMetadata(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 0,
            contentSHA256: "x", trashedAt: nil,
            favoriteKeys: ["z", "a", "m"], visitedKeys: []
        )
        let json = String(data: try meta.encoded(), encoding: .utf8)!
        // Sorted-array encoding must place "a" before "m" before "z" in the output.
        let a = try #require(json.range(of: #""a""#))
        let m = try #require(json.range(of: #""m""#))
        let z = try #require(json.range(of: #""z""#))
        #expect(a.lowerBound < m.lowerBound)
        #expect(m.lowerBound < z.lowerBound)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh -only-testing:PinfoldTests/EntryMetadataTests`
Expected: FAIL to compile — `EntryMetadata` has no `favoriteKeys`/`visitedKeys`.

> Note: the App test target is `PinfoldTests` (see `CLAUDE.md` filter example). If `EntryMetadataTests` lives in a differently-named suite, adjust the `-only-testing` filter to `PinfoldTests/<SuiteName>`.

- [ ] **Step 3: Add the fields + custom Codable**

Replace the body of `App/Model/EntryMetadata.swift` (keep the existing doc comment above the struct):

```swift
struct EntryMetadata: Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var sourceFilename: String
    var importDate: Date
    var pointCount: Int
    var contentSHA256: String
    var trashedAt: Date?
    /// Stable keys (see `KMLPlacemark.stableKey`) of placemarks marked favorite.
    var favoriteKeys: Set<String> = []
    /// Stable keys of placemarks marked visited/seen.
    var visitedKeys: Set<String> = []

    init(
        id: UUID, displayName: String, sourceFilename: String, importDate: Date,
        pointCount: Int, contentSHA256: String, trashedAt: Date?,
        favoriteKeys: Set<String> = [], visitedKeys: Set<String> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceFilename = sourceFilename
        self.importDate = importDate
        self.pointCount = pointCount
        self.contentSHA256 = contentSHA256
        self.trashedAt = trashedAt
        self.favoriteKeys = favoriteKeys
        self.visitedKeys = visitedKeys
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourceFilename, importDate, pointCount
        case contentSHA256, trashedAt, favoriteKeys, visitedKeys
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        sourceFilename = try c.decode(String.self, forKey: .sourceFilename)
        importDate = try c.decode(Date.self, forKey: .importDate)
        pointCount = try c.decode(Int.self, forKey: .pointCount)
        contentSHA256 = try c.decode(String.self, forKey: .contentSHA256)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        favoriteKeys = Set(try c.decodeIfPresent([String].self, forKey: .favoriteKeys) ?? [])
        visitedKeys = Set(try c.decodeIfPresent([String].self, forKey: .visitedKeys) ?? [])
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(sourceFilename, forKey: .sourceFilename)
        try c.encode(importDate, forKey: .importDate)
        try c.encode(pointCount, forKey: .pointCount)
        try c.encode(contentSHA256, forKey: .contentSHA256)
        try c.encodeIfPresent(trashedAt, forKey: .trashedAt)
        // Encode sets as sorted arrays so the JSON is stable/diff-friendly (a Set's
        // array order is otherwise nondeterministic, causing spurious sync churn).
        try c.encode(favoriteKeys.sorted(), forKey: .favoriteKeys)
        try c.encode(visitedKeys.sorted(), forKey: .visitedKeys)
    }

    /// Encodes to pretty-printed, key-sorted JSON for stable, diff-friendly files.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Decodes from the JSON produced by `encoded()`.
    static func decoded(from data: Data) throws -> EntryMetadata {
        try JSONDecoder().decode(EntryMetadata.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/EntryMetadataTests`
Expected: PASS (existing tests + the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add App/Model/EntryMetadata.swift AppTests/EntryMetadataTests.swift
git commit -m "feat: persist favorite/visited placemark keys in metadata.json"
```

---

## Task 3: Read-modify-write metadata helper + Catalog clobber fix

**Files:**
- Modify: `App/Model/StorageLocations.swift`
- Modify: `App/Services/Catalog.swift:94-98`
- Test: `AppTests/StorageLocationsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AppTests/StorageLocationsTests.swift` (add to the existing suite):

```swift
    @Test func updateMetadataPreservesUntouchedFields() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "entry-1"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        let meta = EntryMetadata(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 1,
            contentSHA256: "x", trashedAt: nil,
            favoriteKeys: ["id:keep"], visitedKeys: []
        )
        try storage.writeMetadata(meta, forFolderNamed: folder)

        // Mutate only trashedAt — favoriteKeys must survive.
        let stamp = Date(timeIntervalSince1970: 555)
        try storage.updateMetadata(forFolderNamed: folder) { $0.trashedAt = stamp }

        let reloaded = try #require(try storage.readMetadata(forFolderNamed: folder))
        #expect(reloaded.trashedAt == stamp)
        #expect(reloaded.favoriteKeys == ["id:keep"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:PinfoldTests/StorageLocationsTests`
Expected: FAIL to compile — `updateMetadata(forFolderNamed:_:)` does not exist.

- [ ] **Step 3: Add the helper to `StorageLocations`**

In `App/Model/StorageLocations.swift`, in the `// MARK: - Sidecar I/O` section (after `readMetadata(forFolderNamed:)` around line 151), add:

```swift
    /// Reads the sidecar, applies `mutate`, and writes it back, preserving every field
    /// the caller does not touch. No-op if the sidecar is absent. Use this instead of
    /// reconstructing `EntryMetadata` from an in-memory `CatalogEntry` (which does not
    /// carry the favorite/visited sets and would clobber them).
    func updateMetadata(forFolderNamed name: String, _ mutate: (inout EntryMetadata) -> Void) throws {
        guard var meta = try readMetadata(forFolderNamed: name) else { return }
        mutate(&meta)
        try writeMetadata(meta, forFolderNamed: name)
    }
```

- [ ] **Step 4: Switch `Catalog.writeTrashedAt` to the helper**

In `App/Services/Catalog.swift`, replace `writeTrashedAt` (lines 94-98):

```swift
    private func writeTrashedAt(_ date: Date?, to entry: CatalogEntry) {
        try? storage.updateMetadata(forFolderNamed: entry.storageFolderName) { $0.trashedAt = date }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/StorageLocationsTests`
Then: `scripts/test.sh -only-testing:PinfoldTests/CatalogTests`
Expected: PASS for both (trash/restore still works via the new helper).

- [ ] **Step 6: Commit**

```bash
git add App/Model/StorageLocations.swift App/Services/Catalog.swift AppTests/StorageLocationsTests.swift
git commit -m "feat: read-modify-write metadata helper; stop clobbering on trash/restore"
```

---

## Task 4: `PlacemarkAnnotations` store

**Files:**
- Create: `App/Services/PlacemarkAnnotations.swift`
- Test: `AppTests/PlacemarkAnnotationsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AppTests/PlacemarkAnnotationsTests.swift`:

```swift
import Testing
import Foundation
import PinfoldCore
@testable import Pinfold

@Suite(.serialized) @MainActor struct PlacemarkAnnotationsTests {

    private func makeEntryAndStorage() throws -> (CatalogEntry, StorageLocations) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "entry-1"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        let meta = EntryMetadata(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 1,
            contentSHA256: "x", trashedAt: nil
        )
        try storage.writeMetadata(meta, forFolderNamed: folder)
        return (CatalogEntry(metadata: meta, storageFolderName: folder), storage)
    }

    private func point(_ source: String) -> KMLPlacemark {
        KMLPlacemark(id: "p1", name: "N", descriptionHTML: nil, styleUrl: nil,
                     coordinate: nil, extendedData: [], photoLinks: [], sourceID: source)
    }

    @Test func toggleFavoriteUpdatesStateAndPersists() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let p = point("a")

        #expect(store.isFavorite(p) == false)
        store.toggleFavorite(p)
        #expect(store.isFavorite(p) == true)

        // Persisted to disk and re-read by a fresh store.
        let reopened = PlacemarkAnnotations(entry: entry, storage: storage)
        #expect(reopened.isFavorite(p) == true)
    }

    @Test func toggleVisitedIsIndependentOfFavorite() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let p = point("b")
        store.toggleFavorite(p)
        store.toggleVisited(p)
        #expect(store.isFavorite(p) == true)
        #expect(store.isVisited(p) == true)
        store.toggleFavorite(p)            // un-favorite, still visited
        #expect(store.isFavorite(p) == false)
        #expect(store.isVisited(p) == true)
    }

    @Test func writeThroughPreservesTrashedAt() throws {
        let (entry, storage) = try makeEntryAndStorage()
        try storage.updateMetadata(forFolderNamed: entry.storageFolderName) {
            $0.trashedAt = Date(timeIntervalSince1970: 42)
        }
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        store.toggleVisited(point("c"))
        let reloaded = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(reloaded.trashedAt == Date(timeIntervalSince1970: 42))
        #expect(reloaded.visitedKeys.contains("id:c"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:PinfoldTests/PlacemarkAnnotationsTests`
Expected: FAIL to compile — `PlacemarkAnnotations` does not exist.

- [ ] **Step 3: Implement the store**

Create `App/Services/PlacemarkAnnotations.swift`:

```swift
import Foundation
import Observation
import PinfoldCore

/// The favorite/visited state for the *currently open* KML file.
///
/// Owned by `KMLDetailView` for one entry and injected into the environment so every
/// descendant (rows, detail view, map, preview card) reads the same instance. State is
/// keyed by `KMLPlacemark.stableKey` and persisted to the entry's `metadata.json`.
///
/// Toggling mutates the in-memory set (instant UI via `@Observable`) and synchronously
/// writes through to the sidecar via `StorageLocations.updateMetadata` — it never reloads
/// the catalogue or re-parses the open document. The sidecar is sub-KB JSON, so the
/// main-actor write is cheap and serializes concurrent toggles for free.
@MainActor @Observable final class PlacemarkAnnotations {
    private(set) var favoriteKeys: Set<String>
    private(set) var visitedKeys: Set<String>

    @ObservationIgnored private let storage: StorageLocations
    @ObservationIgnored private let folderName: String

    init(entry: CatalogEntry, storage: StorageLocations) {
        self.storage = storage
        self.folderName = entry.storageFolderName
        let meta = try? storage.readMetadata(forFolderNamed: entry.storageFolderName)
        self.favoriteKeys = meta?.favoriteKeys ?? []
        self.visitedKeys = meta?.visitedKeys ?? []
    }

    func isFavorite(_ placemark: KMLPlacemark) -> Bool { favoriteKeys.contains(placemark.stableKey) }
    func isVisited(_ placemark: KMLPlacemark) -> Bool { visitedKeys.contains(placemark.stableKey) }

    func toggleFavorite(_ placemark: KMLPlacemark) {
        toggle(&favoriteKeys, key: placemark.stableKey)
        persist()
    }

    func toggleVisited(_ placemark: KMLPlacemark) {
        toggle(&visitedKeys, key: placemark.stableKey)
        persist()
    }

    private func toggle(_ set: inout Set<String>, key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    private func persist() {
        try? storage.updateMetadata(forFolderNamed: folderName) { meta in
            meta.favoriteKeys = favoriteKeys
            meta.visitedKeys = visitedKeys
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/PlacemarkAnnotationsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add App/Services/PlacemarkAnnotations.swift AppTests/PlacemarkAnnotationsTests.swift
git commit -m "feat: PlacemarkAnnotations store with write-through to metadata.json"
```

---

## Task 5: Inject the store + leading swipe actions in `KMLDetailView`

**Files:**
- Modify: `App/Views/KMLDetailView.swift`

This task wires the store into the view tree and adds the leading-edge swipe controls. No new unit test (SwiftUI view wiring); verified by build + the existing detail tests still compiling, then manual smoke in Task 9.

- [ ] **Step 1: Create + inject the store, keyed to the entry**

In `App/Views/KMLDetailView.swift`, add state and build the store once the entry/storage are known. Add after the existing `@State private var searchText = ""`:

```swift
    @State private var annotations: PlacemarkAnnotations?
```

In `body`, install the store into the environment around the content. Change the `Group { ... }` wrapper so the environment is attached. Replace the `else if let document { contentList(document) }` branch usage by ensuring the whole `Group` carries the store; simplest is to attach on the outer view with the `.environment` modifier guarded by the store:

Add, right after `.task { await loadDocument() }`:

```swift
        .environment(annotations)
```

And create the store as part of `loadDocument()` — at the start of that method, before the detached parse, add:

```swift
        if annotations == nil {
            annotations = PlacemarkAnnotations(entry: entry, storage: storage)
        }
```

> `.environment(_:)` has an overload taking an optional `Observable` object, so passing the `PlacemarkAnnotations?` `@State` directly is valid. Descendants read it as `@Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?`. Because placemark rows render only inside `contentList(document)` — which appears after `loadDocument()` has assigned both `document` and `annotations` — the store is always present when a row needs it. `KMLDetailView` uses its own `annotations` `@State` for the swipe actions (no environment read needed in this view).

- [ ] **Step 2: Add swipe actions to the placemark row**

Replace `placemarkLink(_:document:)` (lines ~205-213) with a version that attaches leading swipe actions:

```swift
    private func placemarkLink(_ placemark: KMLPlacemark, document: KMLDocument) -> some View {
        NavigationLink(destination: PlacemarkDetailView(
            placemark: placemark,
            document: document,
            entry: entry
        )) {
            PlacemarkRow(placemark: placemark, document: document, entry: entry)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let annotations {
                Button {
                    annotations.toggleFavorite(placemark)
                } label: {
                    let on = annotations.isFavorite(placemark)
                    Label(on ? "Unfavorite" : "Favorite", systemImage: on ? "star.slash" : "star")
                }
                .tint(.yellow)

                Button {
                    annotations.toggleVisited(placemark)
                } label: {
                    let on = annotations.isVisited(placemark)
                    Label(on ? "Mark Unseen" : "Mark Seen", systemImage: on ? "eye.slash" : "eye")
                }
                .tint(.blue)
            }
        }
    }
```

- [ ] **Step 3: Build the app**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED. (No behavior to assert yet beyond compilation; the star/strikethrough rendering comes in Task 6.)

- [ ] **Step 4: Commit**

```bash
git add App/Views/KMLDetailView.swift
git commit -m "feat: own PlacemarkAnnotations in KMLDetailView and add leading swipe actions"
```

---

## Task 6: Star + strikethrough in `PlacemarkRow`

**Files:**
- Modify: `App/Views/PlacemarkRow.swift`

- [ ] **Step 1: Read the store and apply the styling**

In `App/Views/PlacemarkRow.swift`, add the environment store and update `labelStack`. Add to the `// MARK: - Environment` block:

```swift
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?
```

Add computed helpers in `// MARK: - Properties` area:

```swift
    private var isFavorite: Bool { annotations?.isFavorite(placemark) ?? false }
    private var isVisited: Bool { annotations?.isVisited(placemark) ?? false }
```

Replace `labelStack` so the star leads the title and visited strikes it through:

```swift
    private var labelStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
                Text(placemark.name ?? "Untitled")
                    .font(.body)
                    .strikethrough(isVisited)
                    .foregroundStyle(isVisited ? .secondary : .primary)
                    .lineLimit(1)
            }
            if let html = placemark.descriptionHTML, !html.isEmpty {
                let preview = AttributedHTML.plainText(html).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
```

- [ ] **Step 2: Build the app**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Views/PlacemarkRow.swift
git commit -m "feat: show leading star and strikethrough in placemark rows"
```

---

## Task 7: Star before title + menu toggles in `PlacemarkDetailView`

**Files:**
- Modify: `App/Views/PlacemarkDetailView.swift`

- [ ] **Step 1: Read the store**

In `App/Views/PlacemarkDetailView.swift`, add to the `// MARK: - Environment` block:

```swift
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?
```

- [ ] **Step 2: Show the star before the title in the header**

In `contentStack`, place a star before the title row. Replace the `StyleIcon` header block at the top of `contentStack` with a header row that pairs the star with the title text:

```swift
            // Style icon + favorite star header
            HStack(spacing: 8) {
                StyleIcon(placemark: placemark, document: document, entry: entry, size: 48)
                if annotations?.isFavorite(placemark) == true {
                    Image(systemName: "star.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
                Text(placemark.name ?? "Untitled")
                    .font(.title3.bold())
                    .strikethrough(annotations?.isVisited(placemark) == true)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
```

> The large navigation title (`navigationTitle(placemark.name ...)`) stays as-is for the nav bar; this inline header is what carries the leading star, satisfying "star before the title."

- [ ] **Step 3: Add Favorite/Seen toggles to the three-dots menu**

In `toolbarMenu`, prepend the two toggles and a divider before the existing Copy/Share actions. Replace the `Menu { ... }` contents so it begins with:

```swift
            Menu {
                if let annotations {
                    Button {
                        annotations.toggleFavorite(placemark)
                    } label: {
                        let on = annotations.isFavorite(placemark)
                        Label(on ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: on ? "star.slash" : "star")
                    }
                    Button {
                        annotations.toggleVisited(placemark)
                    } label: {
                        let on = annotations.isVisited(placemark)
                        Label(on ? "Mark as Unseen" : "Mark as Seen",
                              systemImage: on ? "eye.slash" : "eye")
                    }
                    Divider()
                }

                if let coordStr = coordinateString {
                    // ... existing Copy Coordinates / Share buttons unchanged ...
                }

                // ... existing Copy Name button unchanged ...
            } label: {
                Image(systemName: "ellipsis.circle")
            }
```

> Keep the existing Copy Coordinates, Share, and Copy Name buttons exactly as they are; only the favorite/seen buttons and `Divider()` are added at the top.

- [ ] **Step 4: Build the app**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Views/PlacemarkDetailView.swift
git commit -m "feat: favorite star and favorite/seen menu toggles on placemark detail"
```

---

## Task 8: Reflect favorite/visited on the map

**Files:**
- Modify: `App/Support/PlacemarkPinImage.swift`
- Modify: `App/Views/PlacemarkMapRepresentable.swift`
- Modify: `App/Views/PlacemarkMapView.swift`
- Test: `AppTests/PlacemarkPinImageTests.swift`

- [ ] **Step 1: Write the failing test for the decorated pin**

Append to `AppTests/PlacemarkPinImageTests.swift` (add to the existing suite — match its `@Suite`/`@MainActor` attributes):

```swift
    @Test func decoratedReturnsImageForEveryStateCombo() {
        let base = PlacemarkPinImage.fallbackImage(tint: .systemBlue)
        for favorite in [false, true] {
            for visited in [false, true] {
                let decorated = PlacemarkPinImage.decorated(base, isFavorite: favorite, isVisited: visited)
                #expect(decorated.size.width > 0)
                #expect(decorated.size.height > 0)
            }
        }
    }

    @Test func decoratedWithNoFlagsReturnsBaseUnchanged() {
        let base = PlacemarkPinImage.fallbackImage(tint: .systemBlue)
        let decorated = PlacemarkPinImage.decorated(base, isFavorite: false, isVisited: false)
        #expect(decorated.size == base.size)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:PinfoldTests/PlacemarkPinImageTests`
Expected: FAIL to compile — `decorated(_:isFavorite:isVisited:)` does not exist.

- [ ] **Step 3: Add `decorated(...)` to `PlacemarkPinImage`**

In `App/Support/PlacemarkPinImage.swift`, add:

```swift
    /// Returns `base` with a small star badge composited at the top-right when favorite,
    /// and at reduced opacity when visited. Returns `base` unchanged when neither applies.
    static func decorated(_ base: UIImage, isFavorite: Bool, isVisited: Bool) -> UIImage {
        guard isFavorite || isVisited else { return base }

        let badge = dimension * 0.55
        // Extend the canvas up-and-right so the badge isn't clipped.
        let inset = isFavorite ? badge / 2 : 0
        let canvas = CGSize(width: base.size.width + inset, height: base.size.height + inset)

        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            let baseOrigin = CGPoint(x: 0, y: inset)
            base.draw(in: CGRect(origin: baseOrigin, size: base.size),
                      blendMode: .normal, alpha: isVisited ? 0.45 : 1.0)

            if isFavorite {
                let starConfig = UIImage.SymbolConfiguration(pointSize: badge, weight: .bold)
                let star = UIImage(systemName: "star.fill", withConfiguration: starConfig)?
                    .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
                let starRect = CGRect(x: canvas.width - badge, y: 0, width: badge, height: badge)
                star?.draw(in: starRect)
            }
        }
    }
```

- [ ] **Step 4: Run the pin-image tests to verify they pass**

Run: `scripts/test.sh -only-testing:PinfoldTests/PlacemarkPinImageTests`
Expected: PASS.

- [ ] **Step 5: Thread the sets through the map representable**

In `App/Views/PlacemarkMapRepresentable.swift`:

(a) Add two stored properties next to the existing lets (after `let clusterPins: Bool`):

```swift
    let favoriteKeys: Set<String>
    let visitedKeys: Set<String>
```

(b) In `makeUIView`, decorate each pin image using the placemark's `stableKey`. Replace the annotation-building closure:

```swift
        let annotations = placemarks.compactMap { placemark -> PlacemarkAnnotation? in
            guard let coordinate = placemark.coordinate else { return nil }
            let base = PlacemarkPinImage.image(
                for: placemark, document: document, entry: entry,
                resourceCache: resourceCache, storage: storage
            )
            let image = PlacemarkPinImage.decorated(
                base,
                isFavorite: favoriteKeys.contains(placemark.stableKey),
                isVisited: visitedKeys.contains(placemark.stableKey)
            )
            return PlacemarkAnnotation(
                placemarkID: placemark.id,
                coordinate: CLLocationCoordinate2D(
                    latitude: coordinate.latitude, longitude: coordinate.longitude
                ),
                title: placemark.name,
                image: image
            )
        }
        mapView.addAnnotations(annotations)
```

> The map screen is pushed fresh from `KMLDetailView`; pins are built in `makeUIView` from the sets passed at construction. Toggling on the detail screen and returning rebuilds the map with current sets. (Live in-place pin refresh while the map is open is out of scope — the sets are captured at present-time, matching how `placemarks`/`clusterPins` are already handled.)

- [ ] **Step 6: Pass the sets from `PlacemarkMapView`**

In `App/Views/PlacemarkMapView.swift`:

(a) Add the store to the environment block:

```swift
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?
```

(b) Pass the sets into `PlacemarkMapRepresentable(...)` in `body` (add the two arguments after `clusterPins:`):

```swift
            PlacemarkMapRepresentable(
                placemarks: placemarks,
                document: document,
                entry: entry,
                resourceCache: resourceCache,
                storage: storage,
                showsUserLocation: locationAuth.isAuthorized,
                clusterPins: settings.clusterMapPins,
                favoriteKeys: annotations?.favoriteKeys ?? [],
                visitedKeys: annotations?.visitedKeys ?? [],
                selectedID: $selectedPlacemarkID
            )
```

(c) Mirror the star/strikethrough in `PlacemarkPreviewCard`. The card is a private struct in the same file; give it access to the store and update its title row. Add to `PlacemarkPreviewCard`'s environment block:

```swift
        @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?
```

Replace the card's title `Text(...)` with a star-leading, strikethrough-aware row:

```swift
                    HStack(spacing: 4) {
                        if annotations?.isFavorite(placemark) == true {
                            Image(systemName: "star.fill")
                                .font(.footnote)
                                .foregroundStyle(.yellow)
                        }
                        Text(placemark.name ?? "Untitled")
                            .font(.headline)
                            .strikethrough(annotations?.isVisited(placemark) == true)
                            .lineLimit(1)
                    }
```

- [ ] **Step 7: Build the app**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add App/Support/PlacemarkPinImage.swift App/Views/PlacemarkMapRepresentable.swift \
        App/Views/PlacemarkMapView.swift AppTests/PlacemarkPinImageTests.swift
git commit -m "feat: reflect favorite (star badge) and visited (dimmed) on map pins and preview"
```

---

## Task 9: Full verification gate

**Files:** none (verification only).

- [ ] **Step 1: Lint at zero errors**

Run: `swiftlint lint`
Expected: 0 errors (pre-existing warnings are an accepted backlog). Fix any new errors introduced by the changes; annotate genuinely-intentional violations inline rather than loosening rules.

- [ ] **Step 2: Parser package tests**

Run: `cd PinfoldCore && swift test`
Expected: PASS (all, including `StableKeyTests`).

- [ ] **Step 3: Full app test suite**

Run: `scripts/test.sh`
Expected: PASS (including `EntryMetadataTests`, `StorageLocationsTests`, `CatalogTests`, `PlacemarkAnnotationsTests`, `PlacemarkPinImageTests`).

- [ ] **Step 4: Manual smoke (simulator)**

Run: `scripts/build.sh` then launch in the iPhone 17 / iOS 26.5 simulator (or use the `run-sim` skill). Verify:
- Open a sample KML (e.g. from `samples/`). Swipe a row right → Favorite and Mark Seen buttons appear.
- Tap Favorite → a yellow star appears before the title; row does NOT move.
- Tap Mark Seen → the title is struck through and dimmed; row does NOT move.
- Open the point page → star shows before the inline title; three-dots menu shows Remove from Favorites / Mark as Unseen; toggling updates the UI.
- Open the map → favorite pins carry a star badge, visited pins are dimmed; the preview card mirrors the star/strikethrough.
- Close and reopen the file → favorite/visited state persists (re-read from `metadata.json`).

- [ ] **Step 5: Final commit (if any lint/smoke fixes were made)**

```bash
git add -A
git commit -m "chore: lint + smoke fixes for favorite/visited feature"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** §1 → Task 1; §2 → Task 2; §3 → Task 3; §4 → Task 4; §5 (no reorder) → unchanged, asserted in Task 9 smoke; §6 controls → Tasks 5/6/7; §7 map → Task 8; §9 tests → distributed across tasks + Task 9 gate.
- **Type consistency:** `stableKey` (Task 1) is the single key used by `EntryMetadata.favoriteKeys/visitedKeys` (Task 2), `PlacemarkAnnotations` (Task 4), and the map decoration (Task 8). `updateMetadata(forFolderNamed:_:)` is defined in Task 3 and reused in Task 4's `persist()`. `decorated(_:isFavorite:isVisited:)` is defined in Task 8 Step 3 and called in Step 5.
- **If `EnvironmentKeys.swift` convenience injector is desired:** `.environment(store)` for an `@Observable` works without a custom key, so no `EnvironmentKey` is required for `PlacemarkAnnotations`; the file is listed only as optional.
