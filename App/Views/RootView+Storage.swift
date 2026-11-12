import os
import SwiftUI

extension RootView {
    /// One-time startup: resolve the active root, drain the inbox, reload, start watching.
    func bootstrap() async {
        // Publish the live services so out-of-tree App Intents can resolve entities and route.
        AppDependencies.shared.catalog = catalog
        AppDependencies.shared.router = router
        await applyStorage(migrate: false)
        // The active root is now resolved: let queued imports (an "Open in" that raced launch)
        // commit into it.
        importCoordinator.release(catalog: catalog, cache: resourceCache)
        await drainInbox()
        await drainDocumentsInbox()
        await catalog.reload()
        didBootstrap = true
        // Replay a deep link that raced bootstrap (see `pendingColdLaunchTarget`) — it must
        // win over session restore, which `restoreSessionIfNeeded`'s selection guard then
        // enforces automatically.
        if let target = pendingColdLaunchTarget {
            pendingColdLaunchTarget = nil
            if let entry = catalog.active.first(where: { $0.storageFolderName == target.folderName }) {
                pendingPlacemarkKey = target.placemarkKey
                pendingRestore = nil
                selectedEntryID = entry.id
            } else {
                Self.routingLogger.info(
                    "Cold-launch deep link to missing entry '\(target.folderName, privacy: .public)' — ignored."
                )
            }
        }
        restoreSessionIfNeeded()
        // Camera-store hygiene: drop cameras for files no longer anywhere in the catalogue
        // (active OR trashed — restoring from the trash keeps the camera). Only kicks in
        // past the cap; below it stale entries are harmless bytes.
        MapCameraStore().pruneIfNeeded(keeping: Set(catalog.entries.map(\.storageFolderName)))
    }

    /// Resolves the active root from the current sync preference, points the catalogue at
    /// it, and (re)starts the watcher.
    ///
    /// - Parameter migrate: `true` for the toggle path (move existing files into the new
    ///   root, choosing the iCloud-aware file API); `false` for launch (the files are
    ///   already where the resolved root expects them).
    func applyStorage(migrate: Bool) async {
        let (storage, ubiquitous) = await resolveStorage()
        if ubiquitous {
            // Earlier builds could upload the local cache root into iCloud as a fake entry
            // folder; remove that leftover (only when its shape matches exactly).
            await removeStrayCacheFolder(inSyncedRoot: storage.root)
        }
        if migrate {
            let from = catalog.storage
            let wasUbiquitous = rootIsUbiquitous
            // Run the move off-main, then surface any per-folder failures. We do NOT swallow
            // the report: a folder that fails to move stays in the old root and would silently
            // vanish from the catalogue otherwise. An enumeration/setup error (the only thrown
            // path) aborts the switch: repointing without moving would make every entry vanish
            // silently, so the old root and the previous sync setting are kept and the user is told.
            let report: StorageLocations.MigrationReport
            do {
                report = try await Task.detached {
                    try StorageLocations.migrateEntries(
                        from: from,
                        to: storage,
                        fromUbiquitous: wasUbiquitous,
                        toUbiquitous: ubiquitous
                    )
                }.value
            } catch {
                Self.migrationLogger.error(
                    "Storage migration failed: \(error.localizedDescription, privacy: .public)"
                )
                migrationAlert.reportFailure(error)
                revertingSyncSetting = true
                settings.syncEnabled.toggle()
                return
            }
            if !report.failed.isEmpty {
                // Log each underlying error so failed folders are diagnosable from the
                // console; the user-facing alert below only carries the entry names.
                for failure in report.failed {
                    Self.migrationLogger.error(
                        """
                        Failed to migrate entry folder \
                        '\(failure.folderName, privacy: .public)': \
                        \(failure.error.localizedDescription, privacy: .public)
                        """
                    )
                }
                // Map failed folder names to display names via the still-current (pre-repoint)
                // catalogue; fall back to the raw folder name when no entry is loaded for it.
                let byFolder = Dictionary(
                    catalog.entries.map { ($0.storageFolderName, $0.displayName) },
                    uniquingKeysWith: { first, _ in first }
                )
                let names = report.failed.map { byFolder[$0.folderName] ?? $0.folderName }
                migrationAlert.report(failedNames: names)
            }
        }
        await catalog.setStorage(storage)
        rootIsUbiquitous = ubiquitous
        startWatcher(root: storage.root, ubiquitous: ubiquitous)
    }

    /// Returns the storage layout for the current preference, plus whether it is the iCloud
    /// (ubiquitous) container. Falls back to local storage when sync is off or iCloud is
    /// unavailable.
    func resolveStorage() async -> (StorageLocations, Bool) {
        guard settings.syncEnabled else { return (.applicationSupport, false) }
        let documentsURL = await Task.detached { UbiquityContainer.documentsURL() }.value
        guard let documentsURL else { return (.applicationSupport, false) }
        return (.synced(root: documentsURL), true)
    }

    /// Starts a fresh watcher on `root`, replacing any previous one.
    func startWatcher(root: URL, ubiquitous: Bool) {
        let watcher = CatalogWatcher { [catalog] in
            Task { await catalog.reload() }
        }
        watcher.start(root: root, ubiquitous: ubiquitous)
        self.watcher = watcher
    }
}

/// Runs the stray-cache cleanup off the main actor (it takes a file-coordination lock).
/// A `nonisolated` free function so the `Task.detached` closure is compiled outside the view.
private nonisolated func removeStrayCacheFolder(inSyncedRoot root: URL) async {
    await Task.detached {
        StorageLocations.removeStrayCacheFolder(inSyncedRoot: root)
    }.value
}
