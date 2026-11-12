import Foundation
@testable import Pinfold
import Testing

/// D4: a destination that holds only a (re-created) `resources` cache must not block moving the
/// entry; any other pre-existing destination is reported as a failure, never skipped silently.
struct StorageMigrationConflictTests {
    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func write(_ root: URL, _ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func migrate(_ old: URL, _ new: URL) throws -> StorageLocations.MigrationReport {
        try StorageLocations.migrateEntries(
            from: StorageLocations(root: old), to: StorageLocations(root: new),
            fromUbiquitous: false, toUbiquitous: false
        )
    }

    @Test func destinationWithOnlyResources_isReplacedByTheRealEntry() throws {
        let old = makeTempRoot(), new = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: new) }
        try write(old, "a/f.kml", "real")
        try write(old, "a/metadata.json", "{}")
        try write(new, "a/resources/stale.png")

        let report = try migrate(old, new)

        #expect(report.failed.isEmpty)
        #expect(report.moved == ["a"])
        #expect(try String(contentsOf: new.appendingPathComponent("a/f.kml"), encoding: .utf8) == "real")
        #expect(!exists(old.appendingPathComponent("a")))
    }

    @Test func destinationWithOtherContent_isReportedAsFailureAndLeftUntouched() throws {
        let old = makeTempRoot(), new = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: new) }
        try write(old, "a/old.kml")
        try write(new, "a/new.kml")
        try write(new, "a/resources/icon.png")

        let report = try migrate(old, new)

        #expect(report.failed.map(\.folderName) == ["a"])
        #expect(report.moved.isEmpty)
        #expect(exists(new.appendingPathComponent("a/new.kml")))
        #expect(exists(new.appendingPathComponent("a/resources/icon.png")))
        #expect(exists(old.appendingPathComponent("a/old.kml")))
    }

    @Test func splitRoots_recreatedOldCache_doesNotBlockReverseMigration() throws {
        // Local root (cache inside) <-> synced root with a separate cache root.
        let local = makeTempRoot(), synced = makeTempRoot(), cacheRoot = makeTempRoot()
        defer { for url in [local, synced, cacheRoot] {
            try? FileManager.default.removeItem(at: url)
        } }
        // The entry lives in `synced`; a background refresh re-created `local/a/resources`.
        try write(synced, "a/f.kml", "real")
        try write(local, "a/resources/index.json")

        let report = try StorageLocations.migrateEntries(
            from: StorageLocations(root: synced, cacheRoot: cacheRoot),
            to: StorageLocations(root: local),
            fromUbiquitous: false, toUbiquitous: false
        )

        #expect(report.failed.isEmpty)
        #expect(exists(local.appendingPathComponent("a/f.kml")))
    }
}
