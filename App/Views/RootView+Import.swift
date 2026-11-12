import os
import SwiftUI

extension RootView {
    /// Hands the share-extension inbox to the import queue, if the App Group is available.
    /// `async` only so existing `await` call sites keep compiling; it enqueues and returns.
    func drainInbox() async {
        guard let inboxURL = AppGroup.inboxURL else { return }
        PendingImportInbox(
            inboxURL: inboxURL,
            coordinator: importCoordinator,
            catalog: catalog,
            cache: resourceCache
        ).drain()
    }

    // MARK: - Document open ("Open in Pinfold")

    /// The app-sandbox `Documents/Inbox` directory that iOS copies opened documents into
    /// (the app declares the KML/KMZ types with open-in-place disabled). Distinct from the
    /// App Group inbox the share extension uses.
    var documentsInboxURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Handles a URL handed to the app via the file-type association or a custom scheme.
    /// A file URL is enqueued directly on the shared import queue — it is authoritative and
    /// already in our sandbox, so relying only on a directory scan could silently drop it —
    /// then both inboxes are scanned for any stragglers. The queue ignores a path it already
    /// holds, so the scan cannot import the same file a second time (B16). The sandbox copy is
    /// deleted on success, a skipped duplicate or a permanent failure, and kept (and retried
    /// by a later scan of `Documents/Inbox`) on a transient failure.
    func handleOpenURL(_ url: URL) async {
        suppressRestore = true
        pendingRestore = nil
        if url.isFileURL {
            importCoordinator.enqueueOwned(
                [ImportCoordinator.OwnedFile(url: url)],
                catalog: catalog,
                    cache: resourceCache
            )
        }
        await drainDocumentsInbox()
        await drainInbox()
    }

    /// Drains the app's `Documents/Inbox` (files opened via the KML/KMZ file-type association).
    func drainDocumentsInbox() async {
        guard let documentsInboxURL else { return }
        PendingImportInbox(
            inboxURL: documentsInboxURL,
            coordinator: importCoordinator,
            catalog: catalog,
            cache: resourceCache
        ).drain()
    }
}
