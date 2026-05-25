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
}
