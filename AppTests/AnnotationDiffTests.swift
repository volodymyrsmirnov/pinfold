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

    // MARK: - Extra points (A2b)

    private func multiPoint(source: String, extras: [Coordinate]) -> KMLPlacemark {
        KMLPlacemark(
            id: "p-\(source)", name: "N", descriptionHTML: nil, styleUrl: nil,
            coordinate: Coordinate(longitude: 1, latitude: 2), hasPoint: true,
            geometries: extras.map { KMLGeometry.point($0) },
            extendedData: [], photoLinks: [], sourceID: source
        )
    }

    /// Extra points share the placemark's key, so the one key-level diff adds and removes
    /// the whole group; `extraPoints(of:)` says how many pins the group has.
    @Test func extraPointsAreAddedAndRemovedWithTheirPlacemark() {
        let extras = [Coordinate(longitude: 3, latitude: 4), Coordinate(longitude: 5, latitude: 6)]
        let multi = multiPoint(source: "m", extras: extras)
        #expect(PlacemarkMapRepresentable.extraPoints(of: multi) == extras)

        let add = PlacemarkMapRepresentable.annotationDiff(currentKeys: [], desired: [multi])
        #expect(add.toAdd.map(\.stableKey) == ["id:m"])
        #expect(PlacemarkMapRepresentable.extraPoints(of: add.toAdd[0]).count == 2)

        let remove = PlacemarkMapRepresentable.annotationDiff(currentKeys: ["id:m"], desired: [])
        #expect(remove.toRemove == ["id:m"])
    }

    // MARK: - Decoration diff and pin batching (D6)

    @Test func decorationDiff_isOnlyChangedKeys() {
        let changed = PlacemarkMapRepresentable.decorationDiff(
            oldFavorites: ["a", "b"], newFavorites: ["b", "c"],
            oldVisited: ["x"], newVisited: ["x", "y"]
        )
        #expect(changed == ["a", "c", "y"])
        let none = PlacemarkMapRepresentable.decorationDiff(
            oldFavorites: ["a"], newFavorites: ["a"], oldVisited: ["b"], newVisited: ["b"]
        )
        #expect(none.isEmpty)
    }

    @Test func pendingPinsDrainInBatchesAndHonourRemoval() {
        var pending = PendingPins()
        let placemarks = (0 ..< 1200).map { multiPoint(source: "k\($0)", extras: []) }
        pending.append(placemarks)
        #expect(pending.keys.count == 1200)
        pending.remove(key: "id:k5")
        #expect(!pending.keys.contains("id:k5"))
        #expect(pending.takeBatch().count == PendingPins.batchSize)
        #expect(pending.takeBatch().count == PendingPins.batchSize)
        #expect(pending.takeBatch().count == 1199 - 2 * PendingPins.batchSize)
        #expect(pending.isEmpty)
    }

    /// A multi-point placemark always shows its pins, even though it carries geometries.
    @Test func multiPointPlacemarkShowsPins() {
        let multi = multiPoint(source: "m", extras: [Coordinate(longitude: 3, latitude: 4)])
        #expect(PlacemarkMapRepresentable.shouldShowPin(multi))
    }
}
