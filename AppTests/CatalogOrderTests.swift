import Foundation
@testable import Pinfold
import Testing

/// Tests for `CatalogOrder` — the newest-first order of the catalogue's active list.
struct CatalogOrderTests {
    private func entry(name: String, date: TimeInterval, id: UUID = UUID()) -> CatalogEntry {
        CatalogEntry(
            id: id,
            displayName: name,
            sourceFilename: "\(name).kml",
            importDate: Date(timeIntervalSince1970: date),
            pointCount: 1,
            contentSHA256: "sha",
            storageFolderName: id.uuidString,
            trashedAt: nil
        )
    }

    @Test func ordersNewestFirst() {
        let old = entry(name: "Old", date: 1)
        let new = entry(name: "New", date: 100)
        let mid = entry(name: "Mid", date: 50)

        let sorted = CatalogOrder.newestFirst([old, new, mid])

        #expect(sorted.map(\.displayName) == ["New", "Mid", "Old"])
    }

    @Test func tieBreaksByNameThenIDDeterministically() throws {
        // Same import date — tie-break must be stable: by displayName, then id.
        let idA = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let idB = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let zebra = entry(name: "Zebra", date: 5)
        // Two entries that share both date and name — only id can break the tie.
        let alphaLow = entry(name: "Alpha", date: 5, id: idA)
        let alphaHigh = entry(name: "Alpha", date: 5, id: idB)

        let sorted = CatalogOrder.newestFirst([zebra, alphaHigh, alphaLow])

        #expect(sorted.map(\.displayName) == ["Alpha", "Alpha", "Zebra"])
        // Among equal name+date, the lower id sorts first — deterministic regardless of input order.
        #expect(sorted.map(\.id) == [idA, idB, zebra.id])
    }
}
