import Foundation
@testable import Pinfold
import Testing

/// Tests for `StorageLocations.migrateEntryFolders(from:to:)` — moving per-entry folders
/// between roots when the iCloud sync toggle flips the active storage root.
struct StorageMigrationTests {
    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func seed(_ root: URL, folder: String, file: String = "f.kml") throws {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: dir.appendingPathComponent(file))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func migrate_movesFoldersToNewRoot() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "a")
        try seed(old, folder: "b")

        _ = try StorageLocations.migrateEntryFolders(from: old, to: new)

        #expect(exists(new.appendingPathComponent("a/f.kml")))
        #expect(exists(new.appendingPathComponent("b/f.kml")))
        #expect(!exists(old.appendingPathComponent("a")))
        #expect(!exists(old.appendingPathComponent("b")))
    }

    /// Removes all permissions from a folder so `moveItem` fails with a permission error —
    /// a genuine per-folder failure that is NOT the "destination already exists" skip case.
    /// Returns a closure that restores permissions (so the temp dir can be cleaned up).
    @discardableResult
    private func makeUnmovable(_ root: URL, folder: String) -> () -> Void {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    }

    @Test func migrate_continuesPastFailingFolder() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "a")
        try seed(old, folder: "b")
        try seed(old, folder: "c")
        // Force the middle folder "b" to fail its move with a real (non-skip) error.
        let restore = makeUnmovable(old, folder: "b")
        defer { restore() }

        let report = try StorageLocations.migrateEntryFolders(from: old, to: new)

        // a and c moved; b was blocked.
        #expect(exists(new.appendingPathComponent("a/f.kml")))
        #expect(exists(new.appendingPathComponent("c/f.kml")))
        #expect(!exists(old.appendingPathComponent("a")))
        #expect(!exists(old.appendingPathComponent("c")))
        // The failing folder remains in the old root (its files are not stranded silently —
        // they stay readable in the previous location).
        #expect(exists(old.appendingPathComponent("b")))
        #expect(report.failed.map(\.folderName) == ["b"])
        #expect(Set(report.moved) == ["a", "c"])
    }

    @Test func migrate_reportsMovedAndFailed() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "ok")
        try seed(old, folder: "boom")
        let restore = makeUnmovable(old, folder: "boom")
        defer { restore() }

        let report = try StorageLocations.migrateEntryFolders(from: old, to: new)

        #expect(report.moved == ["ok"])
        #expect(report.failed.count == 1)
        let failure = try #require(report.failed.first)
        #expect(failure.folderName == "boom")
    }

    @Test func migrate_cleansUpEmptiedSourceFolders() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "a")
        try seed(old, folder: "b")

        let report = try StorageLocations.migrateEntryFolders(from: old, to: new)

        #expect(report.failed.isEmpty)
        // After a fully successful migration no per-entry folders remain in the old root.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: old, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        #expect(leftovers.isEmpty)
    }

    @Test func migrate_createsNewRootIfAbsent() throws {
        let old = makeTempRoot()
        let new = makeTempRoot() // does not exist yet
        try seed(old, folder: "a")

        _ = try StorageLocations.migrateEntryFolders(from: old, to: new)

        #expect(exists(new.appendingPathComponent("a/f.kml")))
    }

    /// If a folder of the same name already exists at the destination, keep the
    /// destination copy and do not throw (the destination root is authoritative).
    @Test func migrate_skipsFoldersAlreadyAtDestination() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "a", file: "old.kml")
        try seed(new, folder: "a", file: "new.kml")

        try StorageLocations.migrateEntryFolders(from: old, to: new)

        #expect(exists(new.appendingPathComponent("a/new.kml")))
        #expect(!exists(new.appendingPathComponent("a/old.kml")))
    }

    @Test func migrate_noThrowWhenOldRootAbsent() throws {
        let old = makeTempRoot() // never created
        let new = makeTempRoot()
        try StorageLocations.migrateEntryFolders(from: old, to: new)
        // Nothing to assert beyond "did not throw".
    }

    @Test func migrate_noOpWhenRootsEqual() throws {
        let root = makeTempRoot()
        try seed(root, folder: "a")
        try StorageLocations.migrateEntryFolders(from: root, to: root)
        #expect(exists(root.appendingPathComponent("a/f.kml")))
    }
}
