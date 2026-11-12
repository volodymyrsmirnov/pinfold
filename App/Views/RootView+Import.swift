import os
import SwiftUI

extension RootView {
    /// Drains the share-extension inbox into the active root, if the App Group is available.
    func drainInbox() async {
        guard let inboxURL = AppGroup.inboxURL else { return }
        let inbox = PendingImportInbox(
            inboxURL: inboxURL,
            catalog: catalog,
            storage: catalog.storage,
            cache: resourceCache,
            failureLog: importFailureLog
        )
        await inbox.drain()
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
    /// A file URL is imported directly — it is authoritative and already in our sandbox, so
    /// relying only on a directory scan could silently drop it — then both inboxes are
    /// drained for any stragglers.
    func handleOpenURL(_ url: URL) async {
        suppressRestore = true
        pendingRestore = nil
        if url.isFileURL {
            await importFile(at: url)
        }
        await drainDocumentsInbox()
        await drainInbox()
    }

    /// Imports a single opened file, deduping by content hash, reporting failures to the log.
    ///
    /// Failure handling mirrors `PendingImportInbox.drain`:
    /// - **Read / parse failure** is permanent (bad bytes), so the sandbox copy is deleted and
    ///   the failure recorded — retrying never helps.
    /// - **Commit (I/O) failure** is potentially transient, so the sandbox copy is KEPT. The
    ///   opened document is a copy iOS placed in `Documents/Inbox` (open-in-place is disabled
    ///   for our KML/KMZ types), and `handleOpenURL` always drains that inbox afterwards, so a
    ///   kept file is retried by `drainDocumentsInbox`. If a future caller ever passes a URL
    ///   from outside `Documents/Inbox`, the kept file simply isn't retried automatically — but
    ///   the failure is still surfaced to the user, so nothing is lost silently.
    /// On success the sandbox copy is deleted.
    func importFile(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        let result: ImportResult
        do {
            data = try Data(contentsOf: url)
            result = try ImportService.prepare(data: data, sourceFilename: url.lastPathComponent)
        } catch {
            // Read or parse failure — permanent. Record and delete the copy; the underlying
            // cause goes to the console log.
            Self.importLogger.error(
                """
                Failed to read or parse opened file \
                '\(url.lastPathComponent, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
            importFailureLog.record(
                filename: url.lastPathComponent,
                reason: String(
                    localized: "Not a valid KML or KMZ file.",
                    comment: "Import failure reason: the file could not be read or parsed."
                )
            )
            try? FileManager.default.removeItem(at: url)
            return
        }

        if catalog.entry(withSHA256: result.contentSHA256) == nil {
            do {
                try ImportService.commit(result, storage: catalog.storage, cache: resourceCache)
                await catalog.reload()
            } catch {
                // Commit (I/O) failure — potentially transient. Record a friendly reason (the
                // raw error is developer-speak) but KEEP the copy so the Documents-inbox drain
                // can retry it; the underlying error goes to the console log.
                Self.importLogger.error(
                    """
                    Transient failure importing opened file \
                    '\(url.lastPathComponent, privacy: .public)': \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                importFailureLog.record(
                    filename: url.lastPathComponent,
                    reason: String(
                        localized: "Couldn't save the file. It will be retried automatically.",
                        comment: "Import failure reason: a transient I/O error; the import will be retried."
                    )
                )
                return
            }
        }
        // Imported or deduped — the sandbox copy is safe to delete.
        try? FileManager.default.removeItem(at: url)
    }

    /// Drains the app's `Documents/Inbox` (files opened via the KML/KMZ file-type association).
    func drainDocumentsInbox() async {
        guard let documentsInboxURL else { return }
        let inbox = PendingImportInbox(
            inboxURL: documentsInboxURL,
            catalog: catalog,
            storage: catalog.storage,
            cache: resourceCache,
            failureLog: importFailureLog
        )
        await inbox.drain()
    }
}
