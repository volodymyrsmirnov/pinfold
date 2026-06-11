import Foundation
@testable import Pinfold
import Testing

/// Tests for `EntryMetadata` — JSON round-tripping of the synced sidecar.
struct EntryMetadataTests {
    @Test func roundTrips_throughJSON() throws {
        let original = EntryMetadata(
            id: UUID(),
            displayName: "Rome Trip",
            sourceFilename: "Rome.kml",
            importDate: Date(timeIntervalSince1970: 1_700_000_000),
            pointCount: 12,
            contentSHA256: "abc123",
            trashedAt: nil
        )

        let data = try original.encoded()
        let decoded = try EntryMetadata.decoded(from: data)

        #expect(decoded == original)
    }

    @Test func decodesTrashedAt_whenPresent() throws {
        let trashed = EntryMetadata(
            id: UUID(),
            displayName: "Old",
            sourceFilename: "Old.kml",
            importDate: Date(timeIntervalSince1970: 1_700_000_000),
            pointCount: 0,
            contentSHA256: "deadbeef",
            trashedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )

        let decoded = try EntryMetadata.decoded(from: trashed.encoded())

        #expect(decoded.trashedAt == Date(timeIntervalSince1970: 1_700_100_000))
    }

    @Test func decode_rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try EntryMetadata.decoded(from: Data("not json".utf8))
        }
    }

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
        let legacy = """
        {"contentSHA256":"abc","displayName":"Old","id":"\(UUID().uuidString)",\
        "importDate":0,"pointCount":1,"sourceFilename":"old.kml"}
        """
        let decoded = try EntryMetadata.decoded(from: Data(legacy.utf8))
        #expect(decoded.favoriteKeys.isEmpty)
        #expect(decoded.visitedKeys.isEmpty)
    }

    @Test func mergeConflict_unionsFavoriteAndVisitedKeys() {
        let importDate = Date(timeIntervalSince1970: 1000)
        let id = UUID()
        let current = EntryMetadata(
            id: id, displayName: "Current", sourceFilename: "cur.kml",
            importDate: importDate, pointCount: 5, contentSHA256: "cur-sha",
            trashedAt: nil, favoriteKeys: ["a"], visitedKeys: []
        )
        // Conflicts carry differing scalars (which must be ignored) and disjoint key sets.
        let conflictFav = EntryMetadata(
            id: UUID(), displayName: "Other1", sourceFilename: "o1.kml",
            importDate: Date(timeIntervalSince1970: 9999), pointCount: 1, contentSHA256: "o1",
            trashedAt: nil, favoriteKeys: ["b"], visitedKeys: []
        )
        let conflictVisited = EntryMetadata(
            id: UUID(), displayName: "Other2", sourceFilename: "o2.kml",
            importDate: Date(timeIntervalSince1970: 8888), pointCount: 2, contentSHA256: "o2",
            trashedAt: nil, favoriteKeys: [], visitedKeys: ["c"]
        )

        let merged = current.merging(conflicts: [conflictFav, conflictVisited])

        #expect(merged.favoriteKeys == ["a", "b"])
        #expect(merged.visitedKeys == ["c"])
        // Scalars keep CURRENT's values.
        #expect(merged.id == id)
        #expect(merged.displayName == "Current")
        #expect(merged.sourceFilename == "cur.kml")
        #expect(merged.importDate == importDate)
        #expect(merged.pointCount == 5)
        #expect(merged.contentSHA256 == "cur-sha")
    }

    @Test func mergeConflict_trashedAt_allNilStaysNil() {
        let current = EntryMetadata(
            id: UUID(), displayName: "C", sourceFilename: "c.kml",
            importDate: .now, pointCount: 0, contentSHA256: "x", trashedAt: nil
        )
        let conflict = EntryMetadata(
            id: UUID(), displayName: "O", sourceFilename: "o.kml",
            importDate: .now, pointCount: 0, contentSHA256: "y", trashedAt: nil
        )
        #expect(current.merging(conflicts: [conflict]).trashedAt == nil)
    }

    @Test func mergeConflict_trashedAt_conflictTrashWinsOverUnawareCurrent() {
        let current = EntryMetadata(
            id: UUID(), displayName: "C", sourceFilename: "c.kml",
            importDate: .now, pointCount: 0, contentSHA256: "x", trashedAt: nil
        )
        let trashDate = Date(timeIntervalSince1970: 5000)
        let conflict = EntryMetadata(
            id: UUID(), displayName: "O", sourceFilename: "o.kml",
            importDate: .now, pointCount: 0, contentSHA256: "y", trashedAt: trashDate
        )
        #expect(current.merging(conflicts: [conflict]).trashedAt == trashDate)
    }

    @Test func mergeConflict_trashedAt_takesLaterOfBoth() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        let current = EntryMetadata(
            id: UUID(), displayName: "C", sourceFilename: "c.kml",
            importDate: .now, pointCount: 0, contentSHA256: "x", trashedAt: earlier
        )
        let conflict = EntryMetadata(
            id: UUID(), displayName: "O", sourceFilename: "o.kml",
            importDate: .now, pointCount: 0, contentSHA256: "y", trashedAt: later
        )
        #expect(current.merging(conflicts: [conflict]).trashedAt == later)
    }

    @Test func mergeConflict_trashedAt_keepsCurrentWhenItIsLater() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        let current = EntryMetadata(
            id: UUID(), displayName: "C", sourceFilename: "c.kml",
            importDate: .now, pointCount: 0, contentSHA256: "x", trashedAt: later
        )
        let conflict = EntryMetadata(
            id: UUID(), displayName: "O", sourceFilename: "o.kml",
            importDate: .now, pointCount: 0, contentSHA256: "y", trashedAt: earlier
        )
        #expect(current.merging(conflicts: [conflict]).trashedAt == later)
    }

    @Test func encodesKeysAsSortedArraysForStableOutput() throws {
        let meta = EntryMetadata(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 0,
            contentSHA256: "x", trashedAt: nil,
            favoriteKeys: ["z", "a", "m"], visitedKeys: []
        )
        let decoded = try EntryMetadata.decoded(from: meta.encoded())
        #expect(decoded.favoriteKeys.sorted() == ["a", "m", "z"])
    }
}
