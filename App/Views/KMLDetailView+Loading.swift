import CoreLocation
import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// The document's own description as sheet content, when it has visible text or images.
    var documentInfo: DescriptionSheetContent? {
        guard let html = document?.descriptionHTML, !html.isEmpty else { return nil }
        guard Self.folderPreview(html) != nil || html.contains("<img") else { return nil }
        return DescriptionSheetContent(id: "document", title: document?.name ?? entry.displayName, html: html)
    }

    // MARK: - Load document

    /// Loads and parses `target`'s original (default: this view's entry). A replaced network-link
    /// original passes the updated entry, whose `sourceFilename` may differ from the view's copy.
    ///
    /// Deliberately does not refresh notices: the caller does that after any session restore has
    /// been applied (`refreshNotices`), so the first outline is built from the restored state.
    func loadDocument(for target: CatalogEntry? = nil) async {
        let target = target ?? entry
        annotations = PlacemarkAnnotations(entry: target, storage: storage)
        let fileURL = storage.originalFile(for: target)
        do {
            // Materializes an iCloud placeholder first (no-op for local files), then parses the
            // document only. Off-main; a spinner shows meanwhile.
            let parsed = try await loadDocumentOffMain(fileURL)
            if Task.isCancelled {
                return
            }
            document = parsed
            consentDismissed = false
            // "Clear Downloaded Images" promises the images return the next time the entry is
            // opened; this also lets the consent banner's Allow fetch again after a clear.
            resumeDeferredDownloads(resourceCache, in: storage.resourcesDirectory(for: target))
        } catch {
            if Task.isCancelled {
                return
            }
            loadError = DocumentLoad.reportableError(error)
        }
    }
}
