import os
import SwiftUI

extension RootView {
    /// One-time startup: resolve the active root, drain the inbox, reload, start watching.
    func bootstrap() async {
        // Publish the live services so out-of-tree App Intents can resolve entities and route.
        AppDependencies.shared.catalog = catalog
        AppDependencies.shared.router = router
        await applyStorage(migrate: false)
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
        if migrate {
            let from = catalog.storage.root
            let wasUbiquitous = rootIsUbiquitous
            // Run the move off-main, then surface any per-folder failures. We do NOT swallow
            // the report: a folder that fails to move stays in the old root and would silently
            // vanish from the catalogue otherwise. Enumeration/setup errors (the only thrown
            // path) leave `report` nil and are best-effort ignored — the repoint below still
            // happens so the app keeps working against the resolved root.
            let report = try? await Task.detached {
                try StorageLocations.migrateEntryFolders(
                    from: from,
                    to: storage.root,
                    fromUbiquitous: wasUbiquitous,
                    toUbiquitous: ubiquitous
                )
            }.value
            if let report, !report.failed.isEmpty {
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
