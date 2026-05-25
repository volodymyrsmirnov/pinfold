import Testing
import Foundation
@testable import Pinfold

/// Tests for `StorageLocations.migrateEntryFolders(from:to:)` — moving per-entry folders
/// between roots when the iCloud sync toggle flips the active storage root.
@Suite struct StorageMigrationTests {

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

        try StorageLocations.migrateEntryFolders(from: old, to: new)

        #expect(exists(new.appendingPathComponent("a/f.kml")))
        #expect(exists(new.appendingPathComponent("b/f.kml")))
        #expect(!exists(old.appendingPathComponent("a")))
        #expect(!exists(old.appendingPathComponent("b")))
    }

    @Test func migrate_createsNewRootIfAbsent() throws {
        let old = makeTempRoot()
        let new = makeTempRoot() // does not exist yet
        try seed(old, folder: "a")

        try StorageLocations.migrateEntryFolders(from: old, to: new)

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
