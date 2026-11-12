import SwiftUI

extension RootView {
    // MARK: - Session restoration

    /// Writes the selection + route-stack half of the resume snapshot. `KMLDetailView`
    /// owns the other half (transient list state + scroll anchor — only it can read live
    /// row geometry); both fire on the same `.inactive` transition, and the same-folder
    /// preserve rule in `AppSettings` makes their order irrelevant.
    func saveResumeState() {
        guard settings.restoreSessionEnabled else { return }
        settings.resumeEntryFolderName = selectedEntry?.storageFolderName
        // While a restore bundle is still unconsumed (the restore parse is in flight), the
        // live path is still empty — overwriting the saved routes with it would lose the
        // stack a kill in this window was supposed to preserve.
        if let pending = pendingRestore, pending.entryFolderName == selectedEntry?.storageFolderName {
            return
        }
        settings.resumeRoutes = EntryRoute.encodeForResume(router.path)
    }

    /// Rebuilds the last session's selection at launch. Restore only when nothing else has
    /// routed yet — a live deep link (Spotlight tap, App Intent, "Open in Pinfold") that
    /// already drove a selection or set a pending key wins over restore. A saved folder
    /// that no longer resolves (deleted, trashed, storage root switched) clears the stale
    /// state and lands on the catalogue — silent, like every deep-link miss.
    func restoreSessionIfNeeded() {
        guard settings.restoreSessionEnabled,
              !suppressRestore,
              selectedEntryID == nil,
              pendingPlacemarkKey == nil,
              let folderName = settings.resumeEntryFolderName
        else { return }
        guard let entry = catalog.active.first(where: { $0.storageFolderName == folderName }) else {
            settings.resumeEntryFolderName = nil
            return
        }
        pendingRestore = RestoreBundle(
            entryFolderName: folderName,
            routes: EntryRoute.decodeForResume(settings.resumeRoutes),
            searchText: settings.resumeSearchText ?? "",
            collapsedFolderIDs: Set(settings.resumeCollapsedFolderIDs ?? []),
            nearestFirst: settings.resumeNearestFirst,
            scrollAnchorRowID: settings.resumeScrollAnchorRowID
        )
        selectedEntryID = entry.id
    }
}
