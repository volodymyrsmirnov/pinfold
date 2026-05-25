import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `placemarksMatching(_:in:)` in `PlacemarkSearch.swift`.
///
/// Exercises empty-query pass-through, case-insensitive matching, nil-name exclusion,
/// multi-folder traversal, and no-match results.
struct PlacemarkSearchTests {
    // MARK: - Helpers

    private func makePlacemark(id: String, name: String?) -> KMLPlacemark {
        KMLPlacemark(
            id: id,
            name: name,
            descriptionHTML: nil,
            styleUrl: nil,
            coordinate: nil,
            extendedData: [],
            photoLinks: []
        )
    }

    /// Builds a `KMLDocument` with a two-level hierarchy:
    /// - root container holds `rootPlacemarks`
    /// - one child folder holds `childPlacemarks`
    private func makeDocument(
        rootPlacemarks: [KMLPlacemark],
        childPlacemarks: [KMLPlacemark] = []
    ) -> KMLDocument {
        let childContainer = KMLContainer(
            id: "folder1",
            name: "Folder",
            children: [],
            placemarks: childPlacemarks
        )
        let root = KMLContainer(
            id: "root",
            name: nil,
            children: [childContainer],
            placemarks: rootPlacemarks
        )
        return KMLDocument(
            name: nil,
            descriptionHTML: nil,
            root: root,
            styles: [:],
            styleMaps: [:]
        )
    }

    // MARK: - Empty query

    @Test func emptyQuery_returnsAllPlacemarks() {
        let p1 = makePlacemark(id: "p1", name: "Alpha")
        let p2 = makePlacemark(id: "p2", name: "Beta")
        let p3 = makePlacemark(id: "p3", name: "Gamma")
        let doc = makeDocument(rootPlacemarks: [p1, p2], childPlacemarks: [p3])

        let results = placemarksMatching("", in: doc)

        #expect(results.count == 3)
    }

    @Test func whitespaceOnlyQuery_returnsAllPlacemarks() {
        let p1 = makePlacemark(id: "p1", name: "Alpha")
        let p2 = makePlacemark(id: "p2", name: "Beta")
        let doc = makeDocument(rootPlacemarks: [p1, p2])

        let results = placemarksMatching("   ", in: doc)

        #expect(results.count == 2)
    }

    // MARK: - Case-insensitive matching

    @Test func search_matchesByNameCaseInsensitive() {
        let p1 = makePlacemark(id: "p1", name: "Eiffel Tower")
        let p2 = makePlacemark(id: "p2", name: "Colosseum")
        let doc = makeDocument(rootPlacemarks: [p1, p2])

        let lower = placemarksMatching("eiffel", in: doc)
        let upper = placemarksMatching("EIFFEL", in: doc)
        let mixed = placemarksMatching("EiFfEl", in: doc)

        #expect(lower.count == 1)
        #expect(lower[0].id == "p1")
        #expect(upper.count == 1)
        #expect(mixed.count == 1)
    }

    // MARK: - Nil-name exclusion

    @Test func search_excludesPlacemarksWithNilName() {
        let p1 = makePlacemark(id: "p1", name: nil)
        let p2 = makePlacemark(id: "p2", name: "Named")
        let doc = makeDocument(rootPlacemarks: [p1, p2])

        let results = placemarksMatching("Named", in: doc)

        #expect(results.count == 1)
        #expect(results[0].id == "p2")
    }

    @Test func search_queryNonEmpty_nilNamePlacemarkNotReturned() {
        let p1 = makePlacemark(id: "p1", name: nil)
        let doc = makeDocument(rootPlacemarks: [p1])

        let results = placemarksMatching("any", in: doc)

        #expect(results.isEmpty)
    }

    // MARK: - Multi-folder traversal

    @Test func search_traversesNestedFolders() {
        let p1 = makePlacemark(id: "p1", name: "Root Point")
        let p2 = makePlacemark(id: "p2", name: "Child Point")
        let doc = makeDocument(rootPlacemarks: [p1], childPlacemarks: [p2])

        let results = placemarksMatching("point", in: doc)

        #expect(results.count == 2)
        let ids = results.map(\.id)
        #expect(ids.contains("p1"))
        #expect(ids.contains("p2"))
    }

    // MARK: - No match

    @Test func search_noMatch_returnsEmpty() {
        let p1 = makePlacemark(id: "p1", name: "Alpha")
        let doc = makeDocument(rootPlacemarks: [p1])

        let results = placemarksMatching("xyz", in: doc)

        #expect(results.isEmpty)
    }

    // MARK: - Partial match

    @Test func search_partialSubstring_matches() {
        let p1 = makePlacemark(id: "p1", name: "Notre-Dame Cathedral")
        let p2 = makePlacemark(id: "p2", name: "Westminster Abbey")
        let doc = makeDocument(rootPlacemarks: [p1, p2])

        let results = placemarksMatching("Dame", in: doc)

        #expect(results.count == 1)
        #expect(results[0].id == "p1")
    }

    // MARK: - filteredContainer

    @Test func filteredContainer_emptyQuery_returnsContainerUnchanged() {
        let p1 = makePlacemark(id: "p1", name: "Alpha")
        let p2 = makePlacemark(id: "p2", name: "Beta")
        let doc = makeDocument(rootPlacemarks: [p1], childPlacemarks: [p2])

        let result = filteredContainer(doc.root, matching: "")

        #expect(result == doc.root)
    }

    @Test func filteredContainer_preservesFolderGrouping() {
        let p1 = makePlacemark(id: "p1", name: "Root Castle")
        let p2 = makePlacemark(id: "p2", name: "Child Castle")
        let doc = makeDocument(rootPlacemarks: [p1], childPlacemarks: [p2])

        let result = filteredContainer(doc.root, matching: "castle")

        #expect(result?.placemarks.map(\.id) == ["p1"])
        #expect(result?.children.count == 1)
        #expect(result?.children.first?.id == "folder1")
        #expect(result?.children.first?.placemarks.map(\.id) == ["p2"])
    }

    @Test func filteredContainer_prunesFoldersWithoutMatches() {
        let p1 = makePlacemark(id: "p1", name: "Root Castle")
        let p2 = makePlacemark(id: "p2", name: "Child Bridge")
        let doc = makeDocument(rootPlacemarks: [p1], childPlacemarks: [p2])

        let result = filteredContainer(doc.root, matching: "castle")

        #expect(result?.placemarks.map(\.id) == ["p1"])
        #expect(result?.children.isEmpty == true)
    }

    @Test func filteredContainer_noMatchAnywhere_returnsNil() {
        let p1 = makePlacemark(id: "p1", name: "Alpha")
        let p2 = makePlacemark(id: "p2", name: "Beta")
        let doc = makeDocument(rootPlacemarks: [p1], childPlacemarks: [p2])

        let result = filteredContainer(doc.root, matching: "xyz")

        #expect(result == nil)
    }

    @Test func filteredContainer_matchOnlyInChild_keepsChildDropsRootPlacemarks() {
        let p1 = makePlacemark(id: "p1", name: "Alpha")
        let p2 = makePlacemark(id: "p2", name: "Beta Bridge")
        let doc = makeDocument(rootPlacemarks: [p1], childPlacemarks: [p2])

        let result = filteredContainer(doc.root, matching: "bridge")

        #expect(result?.placemarks.isEmpty == true)
        #expect(result?.children.first?.placemarks.map(\.id) == ["p2"])
    }
}
