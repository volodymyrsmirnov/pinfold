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
}
