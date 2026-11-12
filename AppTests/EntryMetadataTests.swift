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

    @Test func metadata_tagsRoundTripAndLegacyDecode() throws {
        let meta = EntryMetadata(
            id: UUID(), displayName: "Trip", sourceFilename: "trip.kml",
            importDate: Date(timeIntervalSince1970: 1000), pointCount: 3,
            contentSHA256: "deadbeef", trashedAt: nil,
            favoriteKeys: [], visitedKeys: [], tags: ["food", "art"]
        )
        let decoded = try EntryMetadata.decoded(from: meta.encoded())
        // Encoded sorted, so decode comes back sorted regardless of input order.
        #expect(decoded.tags == ["art", "food"])

        // Legacy sidecar with no `tags` key decodes to an empty array.
        let legacy = """
        {"contentSHA256":"abc","displayName":"Old","id":"\(UUID().uuidString)",\
        "importDate":0,"pointCount":1,"sourceFilename":"old.kml"}
        """
        let legacyDecoded = try EntryMetadata.decoded(from: Data(legacy.utf8))
        #expect(legacyDecoded.tags.isEmpty)
    }

    @Test func mergeConflict_unionsTags() {
        let current = EntryMetadata(
            id: UUID(), displayName: "C", sourceFilename: "c.kml",
            importDate: .now, pointCount: 0, contentSHA256: "x", trashedAt: nil,
            tags: ["art"]
        )
        let conflict = EntryMetadata(
            id: UUID(), displayName: "O", sourceFilename: "o.kml",
            importDate: .now, pointCount: 0, contentSHA256: "y", trashedAt: nil,
            tags: ["food", "art"]
        )
        let merged = current.merging(conflicts: [conflict])
        // Union of {art} and {food, art}, re-sorted.
        #expect(merged.tags == ["art", "food"])
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

    // MARK: - Notes

    private func baseMeta(notes: [String: PlacemarkNote] = [:]) -> EntryMetadata {
        EntryMetadata(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "T",
            sourceFilename: "t.kml", importDate: Date(timeIntervalSince1970: 0), pointCount: 0,
            contentSHA256: "x", trashedAt: nil, notes: notes
        )
    }

    private func note(_ text: String, at t: TimeInterval, name: String? = nil) -> PlacemarkNote {
        PlacemarkNote(text: text, modifiedAt: Date(timeIntervalSince1970: t), placemarkName: name)
    }

    @Test func notesRoundTrip() throws {
        let meta = baseMeta(notes: ["id:a": note("Hello", at: 5, name: "A"), "id:b": note("", at: 6)])
        let decoded = try EntryMetadata.decoded(from: meta.encoded())
        #expect(decoded == meta)
        #expect(decoded.notes["id:a"]?.placemarkName == "A")
    }

    @Test func legacySidecarWithoutNotesDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","displayName":"T","sourceFilename":"t.kml",
         "importDate":0,"pointCount":0,"contentSHA256":"x"}
        """
        let decoded = try EntryMetadata.decoded(from: Data(json.utf8))
        #expect(decoded.notes.isEmpty)
    }

    @Test func merge_newerNoteWinsPerKey() {
        let current = baseMeta(notes: ["k": note("old", at: 1), "j": note("cur", at: 9)])
        let other = baseMeta(notes: ["k": note("new", at: 2), "j": note("stale", at: 3)])
        let merged = current.merging(conflicts: [other])
        #expect(merged.notes["k"]?.text == "new")
        #expect(merged.notes["j"]?.text == "cur")
    }

    @Test func merge_tombstoneBeatsOlderText() {
        let current = baseMeta(notes: ["k": note("text", at: 1)])
        let other = baseMeta(notes: ["k": note("", at: 2)])
        let merged = current.merging(conflicts: [other])
        #expect(merged.notes["k"]?.text == "")
        #expect(merged.notes["k"]?.modifiedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func merge_isCommutativeAndIdempotent() {
        let a = baseMeta(notes: ["k": note("apple", at: 1), "m": note("one", at: 4)])
        let b = baseMeta(notes: ["k": note("banana", at: 1), "n": note("two", at: 2)])
        let ab = a.merging(conflicts: [b])
        let ba = b.merging(conflicts: [a])
        #expect(ab.notes == ba.notes)
        #expect(ab.notes["k"]?.text == "banana")
        #expect(ab.merging(conflicts: [b]).notes == ab.notes)
        #expect(ab.merging(conflicts: [ab]).notes == ab.notes)
    }

    @Test func merge_keepsNotesForUnknownKeys() {
        let current = baseMeta(notes: ["gone:1": note("orphan", at: 1)])
        let merged = current.merging(conflicts: [baseMeta(notes: ["gone:2": note("other", at: 2)])])
        #expect(merged.notes.keys.sorted() == ["gone:1", "gone:2"])
    }

    @Test func encodingIsKeySorted() throws {
        let meta = baseMeta(notes: ["z": note("z", at: 1), "a": note("a", at: 1)])
        let text = try #require(String(data: meta.encoded(), encoding: .utf8))
        let aIdx = try #require(text.range(of: "\"a\" : {"))
        let zIdx = try #require(text.range(of: "\"z\" : {"))
        #expect(aIdx.lowerBound < zIdx.lowerBound)
        #expect(try meta.encoded() == meta.encoded())
    }
}
