import Foundation

extension StorageLocations {
    /// The outcome of a root migration: which per-entry folders moved and which couldn't.
    ///
    /// Migration is best-effort *per folder* — a single failing folder must not strand the
    /// rest in the old root — so the result is a report rather than a thrown error. The caller
    /// repoints storage to the new root regardless (the moved majority lives there) and surfaces
    /// `failed` to the user, whose files remain readable in the previous location.
    struct MigrationReport {
        var moved: [String] = []
        var failed: [MigrationFailure] = []
    }

    /// A single per-folder migration failure: the folder that could not be moved and why.
    struct MigrationFailure {
        let folderName: String
        let error: Error
    }

    /// Moves every per-entry folder from `old.root` into `new.root`, so nothing disappears
    /// from the catalogue when the iCloud sync toggle changes the active root, and keeps each
    /// entry's derivable `resources/` cache **local**.
    ///
    /// Per entry, the cache is relocated between `old.resourcesDirectory(forFolderNamed:)` and
    /// `new.resourcesDirectory(forFolderNamed:)` with a plain move (a failed cache move just
    /// drops the cache; it is rebuilt from the original). When the old cache sits inside the
    /// entry folder (local mode) it is moved out *before* the folder is published, so it is never
    /// uploaded; when the new cache sits inside the entry folder (back to local mode) it is moved
    /// in *after* the folder has arrived. A cache that rides inside the folder on both sides
    /// needs no separate move.
    ///
    /// The folder itself picks the right file API:
    /// - **local → iCloud** (`toUbiquitous`): `setUbiquitous(true,…)` (plain `moveItem` into
    ///   iCloud is unsupported).
    /// - **iCloud → local** (`fromUbiquitous`): `setUbiquitous(false,…)`.
    /// - **otherwise**: `moveItem`.
    ///
    /// Which names count as entries is `entryFolderNames(in:)`: every folder except the reserved
    /// `resources` cache root, so the local cache root (which sits inside the local root in synced
    /// mode) is never moved as if it were an entry.
    ///
    /// Creates the new root if absent. A destination that holds only a derivable `resources`
    /// cache is replaced by the moving entry; any other pre-existing destination is left alone
    /// (never overwritten) and recorded as a failure so the user is told. Per-folder
    /// failures are collected and the loop continues. Returns an empty report when the roots are
    /// equal or the old root is absent. Only throws for failures *before* the per-folder loop.
    @discardableResult
    static func migrateEntries(
        from old: StorageLocations,
        to new: StorageLocations,
        fromUbiquitous: Bool,
        toUbiquitous: Bool
    ) throws -> MigrationReport {
        var report = MigrationReport()
        guard old.root.standardizedFileURL != new.root.standardizedFileURL else { return report }
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.root.path) else { return report }
        try fm.createDirectory(at: new.root, withIntermediateDirectories: true)

        for name in try entryFolderNames(in: old.root) {
            let source = old.root.appendingPathComponent(name, isDirectory: true)
            let dest = new.root.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: dest.path), !clearReplaceableDestination(dest) {
                // A real entry already lives there: never overwrite it, never skip silently.
                report.failed.append(MigrationFailure(
                    folderName: name, error: CocoaError(.fileWriteFileExists)
                ))
                continue
            }
            let plan = CacheMovePlan(old: old, new: new, name: name)
            if plan.moveBeforeFolder {
                plan.relocate()
            }
            do {
                try moveFolder(source, to: dest, fromUbiquitous: fromUbiquitous, toUbiquitous: toUbiquitous)
                if plan.moveAfterFolder {
                    plan.relocate()
                }
                report.moved.append(name)
            } catch {
                // Collect and keep going — a single un-movable folder must not strand the rest.
                report.failed.append(MigrationFailure(folderName: name, error: error))
            }
        }
        return report
    }

    /// A destination folder that holds nothing but a derivable `resources` cache (typically
    /// re-created by a background refresh after the entry moved away) is replaceable: the cache
    /// is deleted and the empty folder removed so the real entry can move in. Returns `false`,
    /// touching nothing, when the destination holds anything else.
    private static func clearReplaceableDestination(_ dest: URL) -> Bool {
        let fm = FileManager.default
        guard isRealDirectory(dest),
              let children = try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        else { return false }
        let cache = dest.appendingPathComponent(reservedCacheFolderName, isDirectory: true)
        let onlyCache = children.allSatisfy { $0.lastPathComponent == reservedCacheFolderName && isRealDirectory($0) }
        guard onlyCache else { return false }
        do {
            if !children.isEmpty {
                try fm.removeItem(at: cache)
            }
            try coordinatedRemove(at: dest)
            return true
        } catch {
            return false
        }
    }

    private static func moveFolder(
        _ source: URL, to dest: URL, fromUbiquitous: Bool, toUbiquitous: Bool
    ) throws {
        let fm = FileManager.default
        if toUbiquitous, !fromUbiquitous {
            try fm.setUbiquitous(true, itemAt: source, destinationURL: dest)
        } else if fromUbiquitous, !toUbiquitous {
            try fm.setUbiquitous(false, itemAt: source, destinationURL: dest)
        } else {
            try fm.moveItem(at: source, to: dest)
        }
    }

    /// Where one entry's cache has to go relative to the entry-folder move.
    private struct CacheMovePlan {
        let oldCache: URL
        let newCache: URL
        let oldInsideFolder: Bool
        let newInsideFolder: Bool

        init(old: StorageLocations, new: StorageLocations, name: String) {
            oldCache = old.resourcesDirectory(forFolderNamed: name)
            newCache = new.resourcesDirectory(forFolderNamed: name)
            oldInsideFolder = Self.isInside(oldCache, folder: old.root.appendingPathComponent(name))
            newInsideFolder = Self.isInside(newCache, folder: new.root.appendingPathComponent(name))
        }

        private static func isInside(_ url: URL, folder: URL) -> Bool {
            url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
        }

        private var samePlace: Bool {
            oldCache.standardizedFileURL == newCache.standardizedFileURL
        }

        /// Old cache is inside the folder that is about to be published: take it out first.
        var moveBeforeFolder: Bool {
            !samePlace && (oldInsideFolder && !newInsideFolder)
        }

        /// New cache is inside the folder: it can only go in once the folder exists there.
        var moveAfterFolder: Bool {
            !samePlace && !oldInsideFolder && newInsideFolder
        }

        /// Plain move; any failure drops the (derivable) cache rather than blocking the entry.
        func relocate() {
            let fm = FileManager.default
            guard fm.fileExists(atPath: oldCache.path) else { return }
            do {
                try fm.createDirectory(
                    at: newCache.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: newCache.path) {
                    try fm.removeItem(at: newCache)
                }
                try fm.moveItem(at: oldCache, to: newCache)
            } catch {
                try? fm.removeItem(at: oldCache)
            }
            // Tidy the now-empty per-entry parent in a separate cache root.
            let parent = oldCache.deletingLastPathComponent()
            let parentIsEmpty = (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true
            if !oldInsideFolder, parentIsEmpty {
                try? fm.removeItem(at: parent)
            }
        }
    }

    // MARK: - Stray cache hygiene

    /// Deletes a `<synced root>/resources` folder that an earlier build left behind when the
    /// local cache root (which sat inside the local root) was migrated to iCloud as if it were
    /// an entry. Deliberately conservative — user data lives next to it: the folder is removed
    /// only when **every** child is a real directory whose only content is a `resources`
    /// directory (the exact `<name>/resources` shape of the cache). Anything else, including a
    /// stray file or an extra subfolder, leaves it untouched. Returns whether it was removed.
    ///
    /// Call once after the iCloud root resolves; it runs coordinated and may block, so use it
    /// off the main actor.
    @discardableResult
    static func removeStrayCacheFolder(inSyncedRoot root: URL) -> Bool {
        let fm = FileManager.default
        let stray = root.appendingPathComponent(reservedCacheFolderName, isDirectory: true)
        guard isRealDirectory(stray),
              let children = try? fm.contentsOfDirectory(at: stray, includingPropertiesForKeys: nil)
        else { return false }
        let matchesShape = children.allSatisfy { child in
            guard isRealDirectory(child),
                  let inner = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
            else { return false }
            return inner.allSatisfy {
                $0.lastPathComponent == reservedCacheFolderName && isRealDirectory($0)
            }
        }
        guard matchesShape else { return false }
        return (try? coordinatedRemove(at: stray)) != nil
    }

    /// Directory check that does not follow symlinks.
    private static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
