import CoreLocation
import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// Applies the one-shot `initialRestore` payload against the freshly loaded document.
    /// See the load `.task` for sequencing; kept out of the closure to keep its SIL small.
    func applyInitialRestore() {
        guard let initialRestore, let document else {
            if initialRestore != nil {
                onConsumeRestore()
            }
            return
        }
        if initialRestore.entryFolderName != nil {
            // Session restore: seed the saved transient state. (Deep-link bundles have a
            // nil folder name and leave the fresh defaults alone.)
            searchText = initialRestore.searchText
            collapsedFolderIDs = initialRestore.collapsedFolderIDs
            nearestFirst = initialRestore.nearestFirst
            pendingScrollRowID = initialRestore.scrollAnchorRowID
        }
        let valid = EntryRoute.validatedForRestore(initialRestore.routes) {
            document.root.firstPlacemark(withStableKey: $0) != nil
        }
        router?.path = valid
        onConsumeRestore()
    }

    /// Applies the one-shot scroll anchor with a verified retry. `ScrollViewReader
    /// .scrollTo` right after a `List`'s data lands is flaky (the collection view may not
    /// have realized the target yet), so the target row's live geometry is checked and the
    /// scroll re-issued — bounded — until it took. The successful landing offset is stored
    /// in `rowFrames.restoredTopOffset` to calibrate the save-side anchor reference.
    ///
    /// An anchor that doesn't resolve in the current outline is dropped — EXCEPT while a
    /// nearest-first restore is still waiting for its location fix (the anchor was recorded
    /// against the flat nearest outline, whose row ids only exist after the re-sort; the
    /// outline rebuild on fix arrival re-fires this task via its `outlineGeneration` id).
    func applyPendingScroll(using proxy: ScrollViewProxy) async {
        guard let target = pendingScrollRowID, let outline else { return }
        guard outline.rows.contains(where: { $0.id == target }) else {
            if !(nearestFirst && locationAuth.lastLocation == nil) {
                pendingScrollRowID = nil
            }
            return
        }
        for _ in 0 ..< 8 {
            proxy.scrollTo(target, anchor: .top)
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled {
                return
            }
            guard let frame = rowFrames.frames[target],
                  let listTop = rowFrames.listFrame?.minY else { continue }
            let offset = frame.minY - listTop
            // Settled with the row's top in the list's top region → done. The window
            // tolerates the inset-grouped content-top padding; the exact landing offset is
            // recorded so the save side anchors against the same reference line.
            if offset >= -4, offset < 120 {
                rowFrames.restoredTopOffset = offset
                pendingScrollRowID = nil
                return
            }
        }
    }

    /// Writes the transient list state + scroll anchor to the resume slice. The scroll
    /// anchor is computed from live row geometry captured by `rowFrames` (see the geometry
    /// instrumentation in `contentList`/`outlineRow` and `applyPendingScroll`); `anchorRowID()`
    /// returns nil — and only the transient state is saved — until that geometry has been observed.
    func saveResumeSlice() {
        guard let settings, settings.restoreSessionEnabled, document != nil else { return }
        // Assert the folder name before writing the slice so the two `.inactive` writers
        // (RootView owns selection + routes) are order-independent even when the stored
        // folder is stale — e.g. the restore toggle was enabled mid-session, leaving the
        // folder nil: if RootView's nil→folder write ran AFTER this slice write, its
        // clear-on-different-folder cascade would wipe the slice just saved. Same-value
        // re-writes preserve the slice, so the steady state is untouched.
        settings.resumeEntryFolderName = entry.storageFolderName
        settings.resumeSearchText = searchText
        settings.resumeCollapsedFolderIDs = Array(collapsedFolderIDs)
        settings.resumeNearestFirst = nearestFirst
        // A pushed screen empties `rowFrames` (covered rows fire onDisappear), so a nil
        // anchor here usually means "geometry unobservable", not "scrolled to the top".
        // Keep the previously saved anchor in that case — within the same file it is
        // strictly better than nil, and a folder change already clears the slice.
        if let anchor = rowFrames.anchorRowID() {
            settings.resumeScrollAnchorRowID = anchor
        }
    }
}
