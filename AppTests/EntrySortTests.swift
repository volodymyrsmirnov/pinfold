import Foundation
@testable import Pinfold
import Testing

/// Tests for `EntrySort` — the presentation-level catalogue ordering applied to the active
/// list (the on-disk storage order is unchanged; sorting happens in the view).
struct EntrySortTests {
    private func entry(
        name: String,
        date: TimeInterval,
        points: Int,
        id: UUID = UUID()
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            displayName: name,
            sourceFilename: "\(name).kml",
            importDate: Date(timeIntervalSince1970: date),
            pointCount: points,
            contentSHA256: "sha",
            storageFolderName: id.uuidString,
            trashedAt: nil
        )
    }

    @Test func dateDesc_ordersNewestFirst() {
        let old = entry(name: "Old", date: 1, points: 1)
        let new = entry(name: "New", date: 100, points: 1)
        let mid = entry(name: "Mid", date: 50, points: 1)

        let sorted = EntrySort.dateDesc.apply(to: [old, new, mid])

        #expect(sorted.map(\.displayName) == ["New", "Mid", "Old"])
    }

    @Test func nameAsc_ordersAlphabeticallyCaseInsensitive() {
        let banana = entry(name: "banana", date: 1, points: 1)
        let apple = entry(name: "Apple", date: 2, points: 1)
        let cherry = entry(name: "Cherry", date: 3, points: 1)

        let sorted = EntrySort.nameAsc.apply(to: [banana, apple, cherry])

        #expect(sorted.map(\.displayName) == ["Apple", "banana", "Cherry"])
    }

    @Test func pointCountDesc_ordersMostPointsFirst() {
        let small = entry(name: "Small", date: 1, points: 3)
        let big = entry(name: "Big", date: 2, points: 99)
        let mid = entry(name: "Mid", date: 3, points: 20)

        let sorted = EntrySort.pointCountDesc.apply(to: [small, big, mid])

        #expect(sorted.map(\.displayName) == ["Big", "Mid", "Small"])
    }

    @Test func dateDesc_tieBreaksByNameThenIDDeterministically() throws {
        // Same import date — tie-break must be stable: by displayName, then id.
        let idA = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let idB = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let zebra = entry(name: "Zebra", date: 5, points: 1)
        // Two entries that share both date and name — only id can break the tie.
        let alphaLow = entry(name: "Alpha", date: 5, points: 1, id: idA)
        let alphaHigh = entry(name: "Alpha", date: 5, points: 1, id: idB)

        let sorted = EntrySort.dateDesc.apply(to: [zebra, alphaHigh, alphaLow])

        #expect(sorted.map(\.displayName) == ["Alpha", "Alpha", "Zebra"])
        // Among equal name+date, the lower id sorts first — deterministic regardless of input order.
        #expect(sorted.map(\.id) == [idA, idB, zebra.id])
    }

    @Test func pointCountDesc_tieBreaksByName() {
        let beta = entry(name: "Beta", date: 1, points: 10)
        let alpha = entry(name: "Alpha", date: 2, points: 10)

        let sorted = EntrySort.pointCountDesc.apply(to: [beta, alpha])

        #expect(sorted.map(\.displayName) == ["Alpha", "Beta"])
    }
}
