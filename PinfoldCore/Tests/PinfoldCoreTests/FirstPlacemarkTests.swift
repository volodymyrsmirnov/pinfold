@testable import PinfoldCore
import Testing

struct FirstPlacemarkTests {
    private func placemark(id: String, name: String) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: name, descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: 0, latitude: 0),
            extendedData: [], photoLinks: [], sourceID: nil
        )
    }

    @Test func findsPlacemarkByStableKeyAcrossNestedFolders() {
        let target = placemark(id: "p2", name: "Gullfoss")
        let root = KMLContainer(
            id: "d", name: "Doc",
            children: [
                KMLContainer(id: "f1", name: "Folder", children: [], placemarks: [target]),
            ],
            placemarks: [placemark(id: "p1", name: "Reykjavik")]
        )
        let found = root.firstPlacemark(withStableKey: target.stableKey)
        #expect(found?.id == "p2")
    }

    @Test func returnsNilForAbsentKey() {
        let root = KMLContainer(
            id: "d", name: "Doc", children: [],
            placemarks: [placemark(id: "p1", name: "Reykjavik")]
        )
        #expect(root.firstPlacemark(withStableKey: "id:does-not-exist") == nil)
    }

    @Test func returnsFirstOccurrenceForDuplicateKey() {
        // Identical name+coordinate ⇒ identical stableKey (a repeated POI).
        let first = placemark(id: "p1", name: "Dup")
        let second = placemark(id: "p2", name: "Dup")
        #expect(first.stableKey == second.stableKey)
        let root = KMLContainer(
            id: "d", name: "Doc", children: [],
            placemarks: [first, second]
        )
        #expect(root.firstPlacemark(withStableKey: first.stableKey)?.id == "p1")
    }
}
