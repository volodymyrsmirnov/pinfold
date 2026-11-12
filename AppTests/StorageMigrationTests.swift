import Foundation
@testable import Pinfold
import Testing

/// Tests for `StorageLocations.migrateEntries(from:to:fromUbiquitous:toUbiquitous:)` — moving per-entry folders
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

    /// Single-root (local) migration between two plain roots; the cache rides inside each
    /// entry folder on both sides.
    @discardableResult
    private func migrate(_ old: URL, _ new: URL) throws -> StorageLocations.MigrationReport {
        try StorageLocations.migrateEntries(
            from: StorageLocations(root: old),
            to: StorageLocations(root: new),
            fromUbiquitous: false,
            toUbiquitous: false
        )
    }

    private func seedCache(_ locations: StorageLocations, folder: String) throws {
        let dir = locations.resourcesDirectory(forFolderNamed: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: dir.appendingPathComponent("icon.png"))
    }

    @Test func migrate_movesFoldersToNewRoot() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "a")
        try seed(old, folder: "b")

        _ = try migrate(old, new)

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

        let report = try migrate(old, new)

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

        let report = try migrate(old, new)

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

        let report = try migrate(old, new)

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

        _ = try migrate(old, new)

        #expect(exists(new.appendingPathComponent("a/f.kml")))
    }

    /// If a folder of the same name already exists at the destination, keep the
    /// destination copy and do not throw (the destination root is authoritative).
    @Test func migrate_skipsFoldersAlreadyAtDestination() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "a", file: "old.kml")
        try seed(new, folder: "a", file: "new.kml")

        try migrate(old, new)

        #expect(exists(new.appendingPathComponent("a/new.kml")))
        #expect(!exists(new.appendingPathComponent("a/old.kml")))
    }

    @Test func migrate_noThrowWhenOldRootAbsent() throws {
        let old = makeTempRoot() // never created
        let new = makeTempRoot()
        try migrate(old, new)
        // Nothing to assert beyond "did not throw".
    }

    @Test func migrate_noOpWhenRootsEqual() throws {
        let root = makeTempRoot()
        try seed(root, folder: "a")
        try migrate(root, root)
        #expect(exists(root.appendingPathComponent("a/f.kml")))
    }

    // MARK: - Cache stays local (B3)

    @Test func migrate_localToSplit_keepsCacheLocal() throws {
        let oldRoot = makeTempRoot()
        let iCloud = makeTempRoot()
        let cacheRoot = makeTempRoot()
        let old = StorageLocations(root: oldRoot)
        let new = StorageLocations(root: iCloud, cacheRoot: cacheRoot)
        try seed(oldRoot, folder: "a")
        try seedCache(old, folder: "a")

        let report = try StorageLocations.migrateEntries(
            from: old, to: new, fromUbiquitous: false, toUbiquitous: false
        )

        #expect(report.failed.isEmpty)
        #expect(exists(iCloud.appendingPathComponent("a/f.kml")))
        #expect(!exists(iCloud.appendingPathComponent("a/resources")))
        #expect(exists(cacheRoot.appendingPathComponent("a/resources/icon.png")))
    }

    @Test func migrate_splitToLocal_bringsCacheBackBesideEntry() throws {
        let iCloud = makeTempRoot()
        let cacheRoot = makeTempRoot()
        let newRoot = makeTempRoot()
        let old = StorageLocations(root: iCloud, cacheRoot: cacheRoot)
        let new = StorageLocations(root: newRoot)
        try seed(iCloud, folder: "a")
        try seedCache(old, folder: "a")

        let report = try StorageLocations.migrateEntries(
            from: old, to: new, fromUbiquitous: false, toUbiquitous: false
        )

        #expect(report.failed.isEmpty)
        #expect(exists(newRoot.appendingPathComponent("a/f.kml")))
        #expect(exists(newRoot.appendingPathComponent("a/resources/icon.png")))
        #expect(!exists(cacheRoot.appendingPathComponent("a/resources")))
    }

    @Test func migrate_onOffOn_neverMovesTheCacheRootAsAnEntry() throws {
        let local = makeTempRoot()
        let iCloud = makeTempRoot()
        let localMode = StorageLocations(root: local)
        let syncedMode = StorageLocations(root: iCloud, cacheRoot: local.appendingPathComponent("resources"))
        try seed(local, folder: "a")
        try seedCache(localMode, folder: "a")

        for _ in 0 ..< 2 {
            try StorageLocations.migrateEntries(
                from: localMode, to: syncedMode, fromUbiquitous: false, toUbiquitous: false
            )
            let syncedChildren = try FileManager.default.contentsOfDirectory(atPath: iCloud.path)
            #expect(syncedChildren == ["a"])
            #expect(exists(local.appendingPathComponent("resources/a/resources/icon.png")))

            try StorageLocations.migrateEntries(
                from: syncedMode, to: localMode, fromUbiquitous: false, toUbiquitous: false
            )
            #expect(exists(local.appendingPathComponent("a/f.kml")))
            #expect(exists(local.appendingPathComponent("a/resources/icon.png")))
            #expect(!exists(iCloud.appendingPathComponent("a")))
        }
    }

    @Test func entryFolderNames_excludesReservedResourcesFolder() throws {
        let root = makeTempRoot()
        try seed(root, folder: "a")
        try seed(root, folder: "resources")

        let names = try StorageLocations(root: root).entryFolderNames()

        #expect(names == ["a"])
    }

    @Test func migrate_legacyNonUUIDFolderStillMoves() throws {
        let old = makeTempRoot()
        let new = makeTempRoot()
        try seed(old, folder: "My Trip 2019")

        let report = try migrate(old, new)

        #expect(report.moved == ["My Trip 2019"])
        #expect(exists(new.appendingPathComponent("My Trip 2019/f.kml")))
    }

    // MARK: - removeStrayCacheFolder

    private func makeStray(_ root: URL, entries: [String: [String]]) throws {
        let fm = FileManager.default
        for (folder, children) in entries {
            for child in children {
                try fm.createDirectory(
                    at: root.appendingPathComponent("resources/\(folder)/\(child)"),
                    withIntermediateDirectories: true
                )
            }
            if children.isEmpty {
                try fm.createDirectory(
                    at: root.appendingPathComponent("resources/\(folder)"),
                    withIntermediateDirectories: true
                )
            }
        }
    }

    @Test func removeStrayCacheFolder_onlyWhenShapeMatches() throws {
        let fm = FileManager.default

        // Matching shape: every child is a folder holding only a `resources` subfolder.
        let good = makeTempRoot()
        try makeStray(good, entries: ["one": ["resources"], "two": ["resources"]])
        #expect(StorageLocations.removeStrayCacheFolder(inSyncedRoot: good))
        #expect(!exists(good.appendingPathComponent("resources")))

        // A loose file directly inside `resources`.
        let looseFile = makeTempRoot()
        try makeStray(looseFile, entries: ["one": ["resources"]])
        try Data("x".utf8).write(to: looseFile.appendingPathComponent("resources/notes.txt"))
        #expect(!StorageLocations.removeStrayCacheFolder(inSyncedRoot: looseFile))
        #expect(exists(looseFile.appendingPathComponent("resources/one/resources")))

        // A child folder that holds something other than `resources`.
        let extraFile = makeTempRoot()
        try makeStray(extraFile, entries: ["one": ["resources"]])
        try Data("x".utf8).write(to: extraFile.appendingPathComponent("resources/one/map.kml"))
        #expect(!StorageLocations.removeStrayCacheFolder(inSyncedRoot: extraFile))
        #expect(exists(extraFile.appendingPathComponent("resources/one/map.kml")))

        // A child folder with an extra subfolder.
        let extraDir = makeTempRoot()
        try makeStray(extraDir, entries: ["one": ["resources", "other"]])
        #expect(!StorageLocations.removeStrayCacheFolder(inSyncedRoot: extraDir))
        #expect(exists(extraDir.appendingPathComponent("resources/one/other")))

        // No such folder at all is a quiet no-op.
        let none = makeTempRoot()
        try fm.createDirectory(at: none, withIntermediateDirectories: true)
        #expect(!StorageLocations.removeStrayCacheFolder(inSyncedRoot: none))
    }
}
