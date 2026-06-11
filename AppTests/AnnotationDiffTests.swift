@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `PlacemarkMapRepresentable.annotationDiff(currentKeys:desired:)`. Pure
/// set arithmetic keyed by `stableKey` — no MapKit view, no shared state, so no
/// `.serialized` requirement.
struct AnnotationDiffTests {
    /// A placemark whose `stableKey` resolves to `"id:<source>"` (author-supplied id),
    /// giving us a predictable, collision-controllable key for these tests.
    private func placemark(source: String, name: String = "N") -> KMLPlacemark {
        KMLPlacemark(
            id: "p-\(source)", name: name, descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: 1, latitude: 2),
            extendedData: [], photoLinks: [], sourceID: source
        )
    }

    @Test func additionsOnly() {
        let a = placemark(source: "a")
        let b = placemark(source: "b")
        let diff = PlacemarkMapRepresentable.annotationDiff(currentKeys: [], desired: [a, b])
        #expect(Set(diff.toAdd.map(\.stableKey)) == ["id:a", "id:b"])
        #expect(diff.toRemove.isEmpty)
    }

    @Test func removalsOnly() {
        let a = placemark(source: "a")
        let diff = PlacemarkMapRepresentable.annotationDiff(
            currentKeys: ["id:a", "id:b"], desired: [a]
        )
        #expect(diff.toAdd.isEmpty)
        #expect(diff.toRemove == ["id:b"])
    }

    @Test func mixedAddAndRemove() {
        let a = placemark(source: "a")
        let c = placemark(source: "c")
        let diff = PlacemarkMapRepresentable.annotationDiff(
            currentKeys: ["id:a", "id:b"], desired: [a, c]
        )
        #expect(diff.toAdd.map(\.stableKey) == ["id:c"])
        #expect(diff.toRemove == ["id:b"])
    }

    @Test func noChangeYieldsEmptyDiff() {
        let a = placemark(source: "a")
        let b = placemark(source: "b")
        let diff = PlacemarkMapRepresentable.annotationDiff(
            currentKeys: ["id:a", "id:b"], desired: [a, b]
        )
        #expect(diff.toAdd.isEmpty)
        #expect(diff.toRemove.isEmpty)
    }

    /// Two desired placemarks sharing a stableKey must be deduplicated deterministically
    /// (last wins): only one annotation is added for that key.
    @Test func duplicateStableKeyHandledDeterministically() {
        let first = placemark(source: "dup", name: "First")
        let second = placemark(source: "dup", name: "Second")
        let diff = PlacemarkMapRepresentable.annotationDiff(
            currentKeys: [], desired: [first, second]
        )
        #expect(diff.toAdd.count == 1)
        #expect(diff.toAdd.first?.stableKey == "id:dup")
        // Last wins: the surviving placemark is `second`.
        #expect(diff.toAdd.first?.name == "Second")
        #expect(diff.toRemove.isEmpty)
    }

    /// A duplicate stableKey that is already on the map yields no add and no remove.
    @Test func duplicateStableKeyAlreadyPresentYieldsEmptyDiff() {
        let first = placemark(source: "dup", name: "First")
        let second = placemark(source: "dup", name: "Second")
        let diff = PlacemarkMapRepresentable.annotationDiff(
            currentKeys: ["id:dup"], desired: [first, second]
        )
        #expect(diff.toAdd.isEmpty)
        #expect(diff.toRemove.isEmpty)
    }
}
