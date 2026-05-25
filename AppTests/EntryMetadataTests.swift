import Testing
import Foundation
@testable import Pinfold

/// Tests for `EntryMetadata` — JSON round-tripping of the synced sidecar.
@Suite struct EntryMetadataTests {

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
