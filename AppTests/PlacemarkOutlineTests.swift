import CoreLocation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `PlacemarkOutline.build(from:matching:collapsed:)` — the pure value type
/// that flattens a `KMLContainer` tree into a depth-tagged row list and the matching
/// mappable-placemark list. No SwiftUI, no shared mutable state, so no `.serialized`.
///
/// Folder identity is a **tree path of child indices** (root = `""`, its first child
/// folder = `"0"`, that folder's second child folder = `"0/1"`, …). This is stable
/// across rebuilds as long as the parsed tree shape is unchanged, which is what keys
/// the collapse state. Placemark row id is the placemark's `stableKey`.
struct PlacemarkOutlineTests {
    // MARK: - Helpers

    private func placemark(
        id: String, name: String?, hasCoordinate: Bool = true
    ) -> KMLPlacemark {
        KMLPlacemark(
            id: id,
            name: name,
            descriptionHTML: nil,
            styleUrl: nil,
            coordinate: hasCoordinate ? Coordinate(longitude: 1, latitude: 2) : nil,
            extendedData: [],
            photoLinks: [],
            sourceID: id // makes stableKey == "id:<id>", predictable
        )
    }

    /// Builds a document with shape:
    /// root: [r1]
    ///   folder "A" (path "0"): [a1]
    ///     folder "A.1" (path "0/0"): [a11]
    ///   folder "B" (path "1"): [b1]
    private func sampleRoot() -> KMLContainer {
        let a1Folder = KMLContainer(
            id: "fA1", name: "A.1", children: [],
            placemarks: [placemark(id: "a11", name: "Alpha Eleven")]
        )
        let aFolder = KMLContainer(
            id: "fA", name: "A", children: [a1Folder],
            placemarks: [placemark(id: "a1", name: "Alpha One")]
        )
        let bFolder = KMLContainer(
            id: "fB", name: "B", children: [],
            placemarks: [placemark(id: "b1", name: "Beta One")]
        )
        return KMLContainer(
            id: "root", name: nil, children: [aFolder, bFolder],
            placemarks: [placemark(id: "r1", name: "Root One")]
        )
    }

    // MARK: - Empty query flattens full tree

    @Test func rows_emptyQuery_flattensFullTreeWithDepths() {
        let outline = PlacemarkOutline.build(from: sampleRoot(), matching: "", collapsed: [])

        // Document order: root placemark, folder A, A's placemark, folder A.1, its
        // placemark, folder B, B's placemark.
        let ids = outline.rows.map(\.id)
        #expect(ids == ["id:r1", "0", "id:a1", "0/0", "id:a11", "1", "id:b1"])

        let depths = outline.rows.map(\.depth)
        // r1 at root depth 0; folder A depth 0; a1 depth 1; folder A.1 depth 1;
        // a11 depth 2; folder B depth 0; b1 depth 1.
        #expect(depths == [0, 0, 1, 1, 2, 0, 1])

        // Folder rows carry folder kind; placemark rows carry placemark kind.
        #expect(outline.rows[1].isFolder)
        #expect(outline.rows[0].isPlacemark)
    }

    // MARK: - Query filters to matches + ancestor folders

    @Test func rows_query_filtersToMatchesKeepingAncestorFolders() {
        let outline = PlacemarkOutline.build(from: sampleRoot(), matching: "Eleven", collapsed: [])

        // Only a11 matches. Its ancestor folders A (0) and A.1 (0/0) must remain;
        // folder B and the root placemark must be gone.
        let ids = outline.rows.map(\.id)
        #expect(ids == ["0", "0/0", "id:a11"])
        #expect(outline.rows[0].depth == 0) // folder A
        #expect(outline.rows[1].depth == 1) // folder A.1
        #expect(outline.rows[2].depth == 2) // placemark a11
    }

    // MARK: - Match semantics equal placemarksMatching

    @Test func rows_query_matchSemanticsSameAsPlacemarkSearch() {
        let root = sampleRoot()
        let doc = KMLDocument(
            name: nil, descriptionHTML: nil, root: root, styles: [:], styleMaps: [:]
        )
        // Case- and diacritic-insensitive query the same way placemarksMatching is.
        for query in ["alpha", "ALPHA", "AlPhA"] {
            let outline = PlacemarkOutline.build(from: root, matching: query, collapsed: [])
            let outlineKeys = Set(outline.mappablePlacemarks.map(\.stableKey))
            let searchKeys = Set(
                placemarksMatching(query, in: doc)
                    .filter { $0.coordinate != nil }
                    .map(\.stableKey)
            )
            #expect(outlineKeys == searchKeys)
        }
    }

    // MARK: - Collapsed folders hide descendants

    @Test func rows_collapsedFolders_hideDescendants() {
        // Collapse folder A (path "0"): its placemark, its child folder, and that
        // child's placemark all vanish; the folder A row itself stays.
        let outline = PlacemarkOutline.build(from: sampleRoot(), matching: "", collapsed: ["0"])

        let ids = outline.rows.map(\.id)
        #expect(ids == ["id:r1", "0", "1", "id:b1"])
    }

    @Test func rows_collapsedSet_ignoredWhileSearching() {
        // Force-expanded while searching: even though A is collapsed, a search keeps
        // the matching descendant visible (collapsed set is ignored for non-empty query).
        let outline = PlacemarkOutline.build(
            from: sampleRoot(), matching: "Eleven", collapsed: ["0"]
        )
        let ids = outline.rows.map(\.id)
        #expect(ids == ["0", "0/0", "id:a11"])
    }

    // MARK: - Mappable derived from rows

    @Test func mappable_derivedFromRows() {
        // One placemark has no coordinate: it should appear as a row but NOT be mappable.
        let noCoord = placemark(id: "nc", name: "No Coord Alpha", hasCoordinate: false)
        let root = KMLContainer(
            id: "root", name: nil, children: [],
            placemarks: [placemark(id: "r1", name: "Alpha One"), noCoord]
        )
        let outline = PlacemarkOutline.build(from: root, matching: "alpha", collapsed: [])

        // Both rows present (both match "alpha")...
        #expect(outline.rows.map(\.id) == ["id:r1", "id:nc"])
        // ...but only the coordinate-bearing one is mappable.
        #expect(outline.mappablePlacemarks.map(\.stableKey) == ["id:r1"])
    }

    // MARK: - Geometry (point-less) placemarks are mappable

    /// A route file (point-less line/polygon placemarks with a representative coordinate)
    /// must enable the map button: such placemarks carry a `coordinate`, so they appear in
    /// `mappablePlacemarks` exactly like point placemarks. Without this the "map only
    /// routes" case would leave the map button disabled.
    // MARK: - Nearest-first sort

    /// A placemark at an explicit coordinate (for distance ordering).
    private func placemark(id: String, name: String, lat: Double, lon: Double) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: name, descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: lon, latitude: lat),
            extendedData: [], photoLinks: [], sourceID: id
        )
    }

    @Test func nearest_flattensTreeAndSortsByDistanceDroppingFolders() {
        // Three placemarks across two folders, plus one at the root, at increasing distance
        // from (0,0). Nearest-first must ignore folders and emit a flat, distance-ordered list.
        let near = placemark(id: "near", name: "Near", lat: 0, lon: 0.1) // closest
        let mid = placemark(id: "mid", name: "Mid", lat: 0, lon: 0.5)
        let far = placemark(id: "far", name: "Far", lat: 0, lon: 2.0) // farthest
        let folderA = KMLContainer(id: "fA", name: "A", children: [], placemarks: [far])
        let folderB = KMLContainer(id: "fB", name: "B", children: [], placemarks: [mid])
        let root = KMLContainer(
            id: "root", name: nil, children: [folderA, folderB], placemarks: [near]
        )
        let here = CLLocation(latitude: 0, longitude: 0)

        let outline = PlacemarkOutline.build(
            from: root, matching: "", collapsed: [], sort: .nearest(here)
        )

        // Flat list, no folder rows, nearest→farthest.
        let allPlacemarks = outline.rows.allSatisfy(\.isPlacemark)
        #expect(allPlacemarks)
        #expect(outline.rows.map(\.id) == ["id:near", "id:mid", "id:far"])
        #expect(outline.rows.map(\.depth) == [0, 0, 0])
    }

    @Test func nearest_coordinateLessPlacemarksSortLast() {
        let near = placemark(id: "near", name: "Near", lat: 0, lon: 0.1)
        let noCoord = KMLPlacemark(
            id: "nc", name: "No Coord", descriptionHTML: nil, styleUrl: nil,
            coordinate: nil, extendedData: [], photoLinks: [], sourceID: "nc"
        )
        let root = KMLContainer(
            id: "root", name: nil, children: [], placemarks: [noCoord, near]
        )
        let here = CLLocation(latitude: 0, longitude: 0)

        let outline = PlacemarkOutline.build(
            from: root, matching: "", collapsed: [], sort: .nearest(here)
        )

        // Coordinate-bearing placemark first; the coordinate-less one sorts last.
        #expect(outline.rows.map(\.id) == ["id:near", "id:nc"])
    }

    @Test func nearest_respectsSearchQuery() {
        let alpha = placemark(id: "a", name: "Alpha", lat: 0, lon: 0.1)
        let beta = placemark(id: "b", name: "Beta", lat: 0, lon: 0.2)
        let root = KMLContainer(
            id: "root", name: nil, children: [], placemarks: [alpha, beta]
        )
        let here = CLLocation(latitude: 0, longitude: 0)

        let outline = PlacemarkOutline.build(
            from: root, matching: "beta", collapsed: [], sort: .nearest(here)
        )

        // Only the matching placemark survives, still as a flat row.
        #expect(outline.rows.map(\.id) == ["id:b"])
    }

    @Test func mappable_includesPointLessGeometryPlacemarks() {
        let route = KMLPlacemark(
            id: "route", name: "Trail", descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: 5, latitude: 6), hasPoint: false,
            geometries: [.lineString([
                Coordinate(longitude: 5, latitude: 6),
                Coordinate(longitude: 7, latitude: 8),
            ])],
            extendedData: [], photoLinks: [], sourceID: "route"
        )
        let root = KMLContainer(
            id: "root", name: nil, children: [], placemarks: [route]
        )
        let outline = PlacemarkOutline.build(from: root, matching: "", collapsed: [])

        // The route placemark is a row AND is mappable despite having no explicit point.
        #expect(outline.rows.map(\.id) == ["id:route"])
        #expect(outline.mappablePlacemarks.map(\.stableKey) == ["id:route"])
    }
}
