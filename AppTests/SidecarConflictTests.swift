import Foundation
@testable import Pinfold
import Testing

/// Tests for the iCloud conflict-resolution path of `StorageLocations.readSidecar`, driven
/// through the injectable `conflictVersions` / `removeOtherVersions` seam (E3).
struct SidecarConflictTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = 0
        private var removeCalls = 0
        func markResolved() {
            lock.withLock { resolved += 1 }
        }

        func removed() {
            lock.withLock { removeCalls += 1 }
        }

        var resolvedCount: Int {
            lock.withLock { resolved }
        }

        var removeCount: Int {
            lock.withLock { removeCalls }
        }
    }

    private func makeMeta(favorites: Set<String> = [], trashedAt: Date? = nil) -> EntryMetadata {
        EntryMetadata(
            id: UUID(), displayName: "Trip", sourceFilename: "trip.kml",
            importDate: Date(timeIntervalSince1970: 1), pointCount: 1, contentSHA256: "sha",
            trashedAt: trashedAt, favoriteKeys: favorites
        )
    }

    private func makeStorage(
        current: EntryMetadata,
        versions: [Data?],
        recorder: Recorder
    ) throws -> StorageLocations {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var storage = StorageLocations(root: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("f", isDirectory: true), withIntermediateDirectories: true
        )
        try storage.writeMetadata(current, forFolderNamed: "f")
        storage.conflictVersions = { _ in
            versions.map { data in
                ConflictVersion(read: { data }, markResolved: { recorder.markResolved() })
            }
        }
        storage.removeOtherVersions = { _ in recorder.removed() }
        return storage
    }

    @Test func conflictingFavoritesAreUnionedAndWrittenBack() throws {
        let recorder = Recorder()
        let other = try makeMeta(favorites: ["b"]).encoded()
        let storage = try makeStorage(current: makeMeta(favorites: ["a"]), versions: [other], recorder: recorder)

        guard case let .ok(meta) = storage.readSidecar(forFolderNamed: "f") else {
            Issue.record("expected .ok")
            return
        }

        #expect(meta.favoriteKeys == ["a", "b"])
        // Written back: a plain read of the file now holds the union.
        let onDisk = try EntryMetadata.decoded(from: Data(contentsOf: storage.metadataFile(forFolderNamed: "f")))
        #expect(onDisk.favoriteKeys == ["a", "b"])
    }

    @Test func undecodableConflictIsLeftUnresolved() throws {
        let recorder = Recorder()
        let good = try makeMeta(favorites: ["b"]).encoded()
        let storage = try makeStorage(
            current: makeMeta(favorites: ["a"]),
            versions: [good, Data("from a newer schema".utf8)],
            recorder: recorder
        )

        guard case let .ok(meta) = storage.readSidecar(forFolderNamed: "f") else {
            Issue.record("expected .ok")
            return
        }

        #expect(meta.favoriteKeys == ["a", "b"])
        #expect(recorder.resolvedCount == 1, "only the decoded version is marked resolved")
        #expect(recorder.removeCount == 0, "an undecodable version must never be discarded")
    }

    @Test func allDecodable_removesOtherVersions() throws {
        let recorder = Recorder()
        let one = try makeMeta(favorites: ["b"]).encoded()
        let two = try makeMeta(favorites: ["c"]).encoded()
        let storage = try makeStorage(current: makeMeta(favorites: ["a"]), versions: [one, two], recorder: recorder)

        _ = storage.readSidecar(forFolderNamed: "f")

        #expect(recorder.resolvedCount == 2)
        #expect(recorder.removeCount == 1)
    }

    @Test func writeFailure_stillReturnsTheMergedValue() throws {
        let recorder = Recorder()
        let other = try makeMeta(favorites: ["b"]).encoded()
        let storage = try makeStorage(current: makeMeta(favorites: ["a"]), versions: [other], recorder: recorder)
        let folder = storage.root.appendingPathComponent("f")
        // Read-only folder: the sidecar still reads, but the merged write-back fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        guard case let .ok(meta) = storage.readSidecar(forFolderNamed: "f") else {
            Issue.record("expected .ok")
            return
        }

        #expect(meta.favoriteKeys == ["a", "b"])
        #expect(recorder.resolvedCount == 0, "nothing is resolved when the merge was not persisted")
        #expect(recorder.removeCount == 0)
    }

    @Test func noConflicts_isInert() throws {
        let recorder = Recorder()
        let current = makeMeta(favorites: ["a"])
        let storage = try makeStorage(current: current, versions: [], recorder: recorder)
        let before = try Data(contentsOf: storage.metadataFile(forFolderNamed: "f"))

        let result = storage.readSidecar(forFolderNamed: "f")

        #expect(result == .ok(current))
        #expect(try Data(contentsOf: storage.metadataFile(forFolderNamed: "f")) == before)
        #expect(recorder.resolvedCount == 0)
        #expect(recorder.removeCount == 0)
    }
}
