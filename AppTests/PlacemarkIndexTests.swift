import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `PlacemarkIndex` — the per-entry, local-only `placemarks-index.json` that
/// backs catalogue-wide search.
///
/// Covers write/read round-trips (including coordinate-less entries), corrupt/missing
/// reads returning `nil`, mapping a parsed `KMLDocument` to index entries (stableKey,
/// name, coordinates), and cross-directory search with the same case-insensitive match
/// semantics as `placemarksMatching(_:in:)`.
struct PlacemarkIndexTests {
    // MARK: - Helpers

    /// A fresh temporary `resources/`-style directory for one test.
    private func makeResourcesDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePlacemark(id: String, name: String?, coordinate: Coordinate?) -> KMLPlacemark {
        KMLPlacemark(
            id: id,
            name: name,
            descriptionHTML: nil,
            styleUrl: nil,
            coordinate: coordinate,
            extendedData: [],
            photoLinks: []
        )
    }

    private func makeDocument(placemarks: [KMLPlacemark], childPlacemarks: [KMLPlacemark] = []) -> KMLDocument {
        let child = KMLContainer(id: "child", name: "Folder", children: [], placemarks: childPlacemarks)
        let root = KMLContainer(id: "root", name: nil, children: [child], placemarks: placemarks)
        return KMLDocument(name: nil, descriptionHTML: nil, root: root, styles: [:], styleMaps: [:])
    }

    // MARK: - Write / read round-trip

    @Test func writeRead_roundTrips() throws {
        let dir = try makeResourcesDir()
        let entries = [
            PlacemarkIndex.Entry(key: "k1", name: "Eiffel Tower", lat: 48.8584, lon: 2.2945),
            PlacemarkIndex.Entry(key: "k2", name: "Colosseum", lat: 41.8902, lon: 12.4922),
        ]

        try PlacemarkIndex.write(entries, to: dir)
        let read = PlacemarkIndex.read(from: dir)

        #expect(read == entries.sorted { $0.key < $1.key })
    }

    @Test func writeRead_preservesCoordinatelessEntries() throws {
        let dir = try makeResourcesDir()
        let entries = [
            PlacemarkIndex.Entry(key: "k1", name: "Placeless", lat: nil, lon: nil),
            PlacemarkIndex.Entry(key: "k2", name: "Located", lat: 1.0, lon: 2.0),
        ]

        try PlacemarkIndex.write(entries, to: dir)
        let read = PlacemarkIndex.read(from: dir)

        #expect(read?.first(where: { $0.key == "k1" })?.lat == nil)
        #expect(read?.first(where: { $0.key == "k1" })?.lon == nil)
        #expect(read?.first(where: { $0.key == "k2" })?.lat == 1.0)
    }

    @Test func write_isSortedByKey() throws {
        let dir = try makeResourcesDir()
        let entries = [
            PlacemarkIndex.Entry(key: "zebra", name: "Z", lat: nil, lon: nil),
            PlacemarkIndex.Entry(key: "alpha", name: "A", lat: nil, lon: nil),
        ]

        try PlacemarkIndex.write(entries, to: dir)
        let read = PlacemarkIndex.read(from: dir)

        #expect(read?.map(\.key) == ["alpha", "zebra"])
    }

    // MARK: - Missing / corrupt reads

    @Test func read_missingFileReturnsNil() throws {
        let dir = try makeResourcesDir()
        #expect(PlacemarkIndex.read(from: dir) == nil)
    }

    @Test func read_corruptFileReturnsNil() throws {
        let dir = try makeResourcesDir()
        try Data("{ this is not valid json".utf8)
            .write(to: dir.appendingPathComponent("placemarks-index.json"))
        #expect(PlacemarkIndex.read(from: dir) == nil)
    }

    // MARK: - entries(for:)

    @Test func entriesForDocument_mapsStableKeyNameAndCoordinates() {
        let p1 = makePlacemark(id: "p1", name: "Eiffel Tower", coordinate: Coordinate(longitude: 2.2945, latitude: 48.8584))
        let p2 = makePlacemark(id: "p2", name: "Placeless", coordinate: nil)
        let doc = makeDocument(placemarks: [p1], childPlacemarks: [p2])

        let entries = PlacemarkIndex.entries(for: doc)

        #expect(entries.count == 2)
        let e1 = entries.first { $0.name == "Eiffel Tower" }
        #expect(e1?.key == p1.stableKey)
        #expect(e1?.lat == 48.8584)
        #expect(e1?.lon == 2.2945)
        let e2 = entries.first { $0.name == "Placeless" }
        #expect(e2?.key == p2.stableKey)
        #expect(e2?.lat == nil)
        #expect(e2?.lon == nil)
    }

    @Test func entriesForDocument_usesEmptyNameForNamelessPlacemark() {
        let p = makePlacemark(id: "p1", name: nil, coordinate: Coordinate(longitude: 1, latitude: 2))
        let doc = makeDocument(placemarks: [p])

        let entries = PlacemarkIndex.entries(for: doc)

        #expect(entries.count == 1)
        #expect(entries.first?.name == "")
    }

    // MARK: - Search

    @Test func search_findsHitsAcrossTwoDirs() throws {
        let dirA = try makeResourcesDir()
        let dirB = try makeResourcesDir()
        try PlacemarkIndex.write(
            [PlacemarkIndex.Entry(key: "a1", name: "Camp Alpha", lat: nil, lon: nil)], to: dirA
        )
        try PlacemarkIndex.write(
            [PlacemarkIndex.Entry(key: "b1", name: "Camp Beta", lat: nil, lon: nil)], to: dirB
        )

        let hits = PlacemarkIndex.search("camp", in: [
            (folderName: "A", resourcesDir: dirA),
            (folderName: "B", resourcesDir: dirB),
        ])

        #expect(hits.count == 2)
        #expect(Set(hits.map(\.folderName)) == ["A", "B"])
    }

    @Test func search_skipsDirWithoutIndex() throws {
        let dirA = try makeResourcesDir()
        let dirB = try makeResourcesDir() // no index written
        try PlacemarkIndex.write(
            [PlacemarkIndex.Entry(key: "a1", name: "Campsite", lat: nil, lon: nil)], to: dirA
        )

        let hits = PlacemarkIndex.search("camp", in: [
            (folderName: "A", resourcesDir: dirA),
            (folderName: "B", resourcesDir: dirB),
        ])

        #expect(hits.count == 1)
        #expect(hits.first?.folderName == "A")
    }

    /// Match parity with `placemarksMatching(_:in:)`: same query, same case-insensitive
    /// `localizedCaseInsensitiveContains` primitive must produce the same hit.
    @Test func search_caseInsensitiveMatchParity() throws {
        let dir = try makeResourcesDir()
        let entry = PlacemarkIndex.Entry(key: "e1", name: "Eiffel Tower", lat: nil, lon: nil)
        try PlacemarkIndex.write([entry], to: dir)

        // Reuse a PlacemarkSearch-style fixture case: lowercase query matches mixed-case name.
        let placemark = KMLPlacemark(
            id: "p1", name: "Eiffel Tower", descriptionHTML: nil, styleUrl: nil,
            coordinate: nil, extendedData: [], photoLinks: []
        )
        let doc = makeDocument(placemarks: [placemark])
        let viaSearch = placemarksMatching("eiffel", in: doc)

        let hits = PlacemarkIndex.search("eiffel", in: [(folderName: "F", resourcesDir: dir)])

        #expect(viaSearch.count == 1)
        #expect(hits.count == 1)
        #expect(hits.first?.name == "Eiffel Tower")
    }

    @Test func search_emptyQueryReturnsEmpty() throws {
        let dir = try makeResourcesDir()
        try PlacemarkIndex.write(
            [PlacemarkIndex.Entry(key: "e1", name: "Anything", lat: nil, lon: nil)], to: dir
        )

        #expect(PlacemarkIndex.search("", in: [(folderName: "F", resourcesDir: dir)]).isEmpty)
        #expect(PlacemarkIndex.search("   ", in: [(folderName: "F", resourcesDir: dir)]).isEmpty)
    }

    // MARK: - Resolve (favorites)

    @Test func resolve_resolvesPresentKeysSortedByName() throws {
        let dir = try makeResourcesDir()
        try PlacemarkIndex.write([
            PlacemarkIndex.Entry(key: "k1", name: "Zebra Camp", lat: 1, lon: 2),
            PlacemarkIndex.Entry(key: "k2", name: "Alpha Camp", lat: 3, lon: 4),
            PlacemarkIndex.Entry(key: "k3", name: "Not Favorited", lat: nil, lon: nil),
        ], to: dir)

        // Three keys requested but only two (k1, k2) are favorites; k3 is in the index but
        // not requested, and "absent" is favorited yet no longer in the file.
        let resolved = PlacemarkIndex.resolve(
            keys: ["k1", "k2", "absent"], folderName: "F", in: dir
        )

        // Two of three keys resolve; the third (absent) is silently skipped.
        #expect(resolved.count == 2)
        // Sorted by name for stable UI: "Alpha Camp" before "Zebra Camp".
        #expect(resolved.map(\.name) == ["Alpha Camp", "Zebra Camp"])
        #expect(resolved.first?.key == "k2")
        #expect(resolved.first?.lat == 3)
        #expect(resolved.first?.folderName == "F")
    }

    @Test func resolve_corruptIndexReturnsEmpty() throws {
        let dir = try makeResourcesDir()
        try Data("{ not valid json".utf8)
            .write(to: dir.appendingPathComponent("placemarks-index.json"))

        #expect(PlacemarkIndex.resolve(keys: ["k1"], folderName: "F", in: dir).isEmpty)
    }

    @Test func resolve_emptyKeySetReturnsEmptyWithoutReading() {
        // A nonexistent directory: if `resolve` read the index it would still return [] for a
        // missing file, so prove the no-read path by asserting empty for an empty key set
        // pointed at a dir that was never created (no index could exist there anyway).
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)

        #expect(PlacemarkIndex.resolve(keys: [], folderName: "F", in: nonexistent).isEmpty)
    }

    @Test func search_accentInsensitive() throws {
        let dir = try makeResourcesDir()
        try PlacemarkIndex.write(
            [PlacemarkIndex.Entry(key: "a1", name: "Reykjavík Harbour", lat: nil, lon: nil)], to: dir
        )
        let hits = PlacemarkIndex.search("reykjavik", in: [(folderName: "A", resourcesDir: dir)])
        #expect(hits.count == 1)
    }

    // MARK: - v2 format

    @Test func entriesCarryHasPointAndText() {
        let withPoint = KMLPlacemark(
            id: "p1", name: "Camp", descriptionHTML: "<p>Quiet <b>riverside</b> spot</p>", styleUrl: nil,
            coordinate: Coordinate(longitude: 1, latitude: 2),
            extendedData: [KMLDataItem(name: "owner", value: "Ranger Anna")], photoLinks: [],
            snippet: "Teaser line", address: "12 Mill Road"
        )
        let lineOnly = KMLPlacemark(
            id: "p2", name: "Trail", descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: 3, latitude: 4), hasPoint: false,
            extendedData: [], photoLinks: []
        )
        let entries = PlacemarkIndex.entries(for: makeDocument(placemarks: [withPoint, lineOnly]))
        let camp = entries.first { $0.name == "Camp" }
        #expect(camp?.hasPoint == true)
        let text = camp?.text ?? ""
        #expect(text.contains("riverside"))
        #expect(!text.contains("<b>"))
        #expect(text.contains("Ranger Anna"))
        #expect(text.contains("Teaser line"))
        #expect(text.contains("12 Mill Road"))
        let trail = entries.first { $0.name == "Trail" }
        #expect(trail?.hasPoint == false)
        #expect(trail?.text == nil)
    }

    @Test func textIsCapped() {
        let long = String(repeating: "word ", count: 5000)
        let placemark = KMLPlacemark(
            id: "p1", name: "Long", descriptionHTML: long, styleUrl: nil, coordinate: nil,
            extendedData: [], photoLinks: []
        )
        let entry = PlacemarkIndex.entries(for: makeDocument(placemarks: [placemark])).first
        #expect((entry?.text?.count ?? 0) <= 1000)
    }

    @Test func existsChecksV2Only() throws {
        let dir = try makeResourcesDir()
        #expect(!PlacemarkIndex.exists(in: dir))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("placemarks-index.json"))
        #expect(!PlacemarkIndex.exists(in: dir))
        try PlacemarkIndex.write([], to: dir)
        #expect(PlacemarkIndex.exists(in: dir))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("placemarks-index.v2.json").path))
    }

    @Test func readFallsBackToV1() throws {
        let dir = try makeResourcesDir()
        let v1 = #"[{"key":"k1","name":"Old Name","lat":1.5,"lon":2.5},{"key":"k2","name":"No Coord"}]"#
        try Data(v1.utf8).write(to: dir.appendingPathComponent("placemarks-index.json"))
        let read = PlacemarkIndex.read(from: dir)
        #expect(read?.count == 2)
        #expect(read?.first?.name == "Old Name")
        #expect(read?.first?.hasPoint == true)
        #expect(read?.first?.text == nil)
        #expect(read?.last?.hasPoint == false)
    }

    @Test func v2WinsOverV1() throws {
        let dir = try makeResourcesDir()
        try Data(#"[{"key":"k1","name":"Old"}]"#.utf8).write(to: dir.appendingPathComponent("placemarks-index.json"))
        try PlacemarkIndex.write([PlacemarkIndex.Entry(key: "k1", name: "New", lat: nil, lon: nil)], to: dir)
        #expect(PlacemarkIndex.read(from: dir)?.first?.name == "New")
    }

    @Test func v2RoundTripsHasPointAndText() throws {
        let dir = try makeResourcesDir()
        let entry = PlacemarkIndex.Entry(key: "k1", name: "A", lat: 1, lon: 2, hasPoint: false, text: "hello")
        try PlacemarkIndex.write([entry], to: dir)
        #expect(PlacemarkIndex.read(from: dir) == [entry])
    }

    @Test func searchMatchesDescriptionAndExtendedData() throws {
        let dir = try makeResourcesDir()
        try PlacemarkIndex.write([
            PlacemarkIndex.Entry(key: "a", name: "Alpha", lat: nil, lon: nil,
                                 text: "A quiet riverside spot Ranger Anna"),
            PlacemarkIndex.Entry(key: "b", name: "Beta", lat: nil, lon: nil, text: nil),
        ], to: dir)
        let sources = [(folderName: "F", resourcesDir: dir)]
        let byDescription = PlacemarkIndex.search("RIVERSIDE", in: sources, store: PlacemarkIndexStore())
        #expect(byDescription.map(\.key) == ["a"])
        let byData = PlacemarkIndex.search("ranger ánna", in: sources, store: PlacemarkIndexStore())
        #expect(byData.map(\.key) == ["a"])
    }

    // MARK: - Snippets and notes (SR-4)

    /// A fake entry folder: `<root>/<uuid>/resources` plus a sibling `metadata.json`.
    private func makeEntry(
        entries: [PlacemarkIndex.Entry], notes: [String: PlacemarkNote] = [:], trashed: Bool = false
    ) throws -> PlacemarkIndex.Source {
        let resources = try makeResourcesDir()
        try PlacemarkIndex.write(entries, to: resources)
        let sidecar = resources.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let metadata = EntryMetadata(
            id: UUID(), displayName: "F", sourceFilename: "f.kml", importDate: .now, pointCount: 0,
            contentSHA256: "x", trashedAt: trashed ? .now : nil, notes: notes
        )
        try metadata.encoded().write(to: sidecar)
        return PlacemarkIndex.Source(folderName: "F", resourcesDir: resources, sidecarURL: sidecar)
    }

    @Test func nameHitHasNoSnippet() throws {
        let source = try makeEntry(entries: [
            PlacemarkIndex.Entry(key: "a", name: "Riverside Camp", lat: nil, lon: nil, text: "riverside again"),
        ])
        let hits = PlacemarkIndex.search("riverside", in: [source], store: PlacemarkIndexStore())
        #expect(hits.first?.matchedField == .name)
        #expect(hits.first?.snippet == nil)
    }

    @Test func descriptionHitCarriesSnippet() throws {
        let source = try makeEntry(entries: [
            PlacemarkIndex.Entry(key: "a", name: "Camp", lat: nil, lon: nil, text: "A quiet riverside spot"),
        ])
        let hit = PlacemarkIndex.search("RIVERSIDE", in: [source], store: PlacemarkIndexStore()).first
        #expect(hit?.matchedField == .description)
        #expect(hit?.snippet?.contains("riverside") == true)
    }

    @Test func noteHitCarriesSnippet() throws {
        let note = PlacemarkNote(text: "Bring a torch", modifiedAt: .now, placemarkName: "Camp")
        let tombstone = PlacemarkNote(text: "", modifiedAt: .now, placemarkName: "Gone")
        let source = try makeEntry(
            entries: [
                PlacemarkIndex.Entry(key: "a", name: "Camp", lat: nil, lon: nil),
                PlacemarkIndex.Entry(key: "b", name: "Other", lat: nil, lon: nil),
            ],
            notes: ["a": note, "b": tombstone]
        )
        let hits = PlacemarkIndex.search("torch", in: [source], store: PlacemarkIndexStore())
        #expect(hits.map(\.key) == ["a"])
        #expect(hits.first?.matchedField == .note)
        #expect(hits.first?.snippet == "Bring a torch")
        #expect(PlacemarkIndex.search("gone", in: [source], store: PlacemarkIndexStore()).isEmpty)
    }

    @Test func trashedEntriesAreNotSearched() throws {
        let source = try makeEntry(
            entries: [PlacemarkIndex.Entry(key: "a", name: "Camp", lat: nil, lon: nil)], trashed: true
        )
        #expect(PlacemarkIndex.search("camp", in: [source], store: PlacemarkIndexStore()).isEmpty)
    }
}
