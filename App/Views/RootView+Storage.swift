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
        await reconcileDerivedState()
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
        // Serialised with every other application (launch, toggle, re-resolve).
        await storageQueue.run { await applyStorageNow(migrate: migrate) }
    }

    /// The body of `applyStorage`; only ever runs inside `storageQueue`.
    private func applyStorageNow(migrate: Bool) async {
        let resolution = await resolveStorage()
        let storage = resolution.storage
        let ubiquitous = resolution.isUbiquitous
        if ubiquitous {
            // Earlier builds could upload the local cache root into iCloud as a fake entry
            // folder; remove that leftover (only when its shape matches exactly).
            await removeStrayCacheFolder(inSyncedRoot: storage.root)
        }
        if migrate {
            guard await migrateForToggle(to: storage, ubiquitous: ubiquitous) else { return }
        } else {
            let previous: SyncStatus.State? = syncStatus.hasResolved ? syncStatus.state : nil
            if StorageResolver.shouldRecover(previous: previous, resolved: resolution.status) {
                guard await recoverStrandedEntries(into: storage) else { return }
            }
        }
        await catalog.setStorage(storage)
        rootIsUbiquitous = ubiquitous
        syncStatus.state = resolution.status
        syncStatus.identityToken = resolution.identityToken
        syncStatus.hasResolved = true
        startWatcher(root: storage.root, ubiquitous: ubiquitous)
    }

    /// Re-resolves the root when the iCloud situation may have changed (account switch, scene
    /// becoming active) and repoints only if the outcome differs from what is running.
    func reresolveStorageIfNeeded() async {
        guard didBootstrap, settings.syncEnabled else { return }
        // Queued behind any in-flight application; state is re-checked once it is our turn
        // (a toggle may have run and already repointed the root meanwhile).
        await storageQueue.run {
            guard settings.syncEnabled else { return }
            let resolution = await resolveStorage()
            guard resolution.status != syncStatus.state
                || resolution.identityToken != syncStatus.identityToken else { return }
            await applyStorageNow(migrate: false)
        }
    }

    /// Moves the existing entries from the current root into `storage` (the toggle path).
    /// Returns `false` when the switch was aborted and the sync setting reverted.
    private func migrateForToggle(to storage: StorageLocations, ubiquitous: Bool) async -> Bool {
        let from = catalog.storage
        let wasUbiquitous = rootIsUbiquitous
        // Run the move off-main, then surface any per-folder failures. We do NOT swallow
        // the report: a folder that fails to move stays in the old root and would silently
        // vanish from the catalogue otherwise. An enumeration/setup error (the only thrown
        // path) aborts the switch: repointing without moving would make every entry vanish
        // silently, so the old root and the previous sync setting are kept and the user is told.
        do {
            let report = try await Task.detached {
                try StorageLocations.migrateEntries(
                    from: from,
                    to: storage,
                    fromUbiquitous: wasUbiquitous,
                    toUbiquitous: ubiquitous
                )
            }.value
            reportMigrationFailures(report)
            return true
        } catch {
            Self.migrationLogger.error(
                "Storage migration failed: \(error.localizedDescription, privacy: .public)"
            )
            migrationAlert.reportFailure(error)
            revertingSyncSetting = true
            settings.syncEnabled.toggle()
            return false
        }
    }

    /// Moves entries stranded in the local root into the iCloud root now that it is reachable
    /// (sync was on while iCloud was unavailable, so imports landed locally). Returns `false`
    /// when the move could not even start; the app then stays on the local root.
    private func recoverStrandedEntries(into storage: StorageLocations) async -> Bool {
        let local = StorageLocations.applicationSupport
        guard await hasStrandedEntries(in: local) else { return true }
        do {
            let report = try await recoverStranded(from: local, to: storage)
            reportMigrationFailures(report)
            return true
        } catch {
            Self.migrationLogger.error(
                "Stranded-entry recovery failed: \(error.localizedDescription, privacy: .public)"
            )
            migrationAlert.reportFailure(error)
            return false
        }
    }

    private func reportMigrationFailures(_ report: StorageLocations.MigrationReport) {
        guard !report.failed.isEmpty else { return }
        // Log each underlying error so failed folders are diagnosable from the console; the
        // user-facing alert below only carries the entry names.
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
        migrationAlert.report(failedNames: report.failed.map { byFolder[$0.folderName] ?? $0.folderName })
    }

    /// Resolves the storage layout for the current preference: local when sync is off, iCloud
    /// when it is on and reachable, local with an `.unavailable` status when it is on but not.
    func resolveStorage() async -> StorageResolution {
        let resolver = StorageResolver(ubiquity: SystemUbiquity(), local: .applicationSupport)
        return await resolveOffMain(resolver, syncEnabled: settings.syncEnabled)
    }

    /// Reconciles the Spotlight index and the local cache with the catalogue after the first
    /// load. Safe to skip: every step is a no-op when the catalogue could not be read.
    func reconcileDerivedState() async {
        await LaunchReconciler().reconcileSpotlight(
            entries: catalog.entries, storage: catalog.storage, status: syncStatus.state
        )
        await pruneOrphanedCache(storage: catalog.storage, status: syncStatus.state)
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

/// Runs the (blocking) resolution off the main actor.
private nonisolated func resolveOffMain(_ resolver: StorageResolver, syncEnabled: Bool) async -> StorageResolution {
    await Task.detached { resolver.resolve(syncEnabled: syncEnabled) }.value
}

private nonisolated func hasStrandedEntries(in local: StorageLocations) async -> Bool {
    await Task.detached { StorageResolver.hasStrandedEntries(in: local) }.value
}

private nonisolated func recoverStranded(
    from local: StorageLocations, to synced: StorageLocations
) async throws -> StorageLocations.MigrationReport {
    try await Task.detached { try StorageResolver.recoverStranded(from: local, to: synced) }.value
}

private nonisolated func pruneOrphanedCache(storage: StorageLocations, status: SyncStatus.State) async {
    await Task.detached(priority: .utility) {
        LaunchReconciler.pruneCache(storage: storage, status: status)
    }.value
}
