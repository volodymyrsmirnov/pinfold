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
    func loadDocument(for target: CatalogEntry? = nil) async {
        let target = target ?? entry
        annotations = PlacemarkAnnotations(entry: target, storage: storage)
        let fileURL = storage.originalFile(for: target)
        do {
            let parsedKML = try await Task.detached(priority: .userInitiated) {
                // Materialize the original from iCloud first if it is a not-yet-downloaded
                // placeholder (no-op for local files). Off-main; a spinner shows meanwhile.
                let data = try UbiquityContainer.readDownloadingIfNeeded(fileURL)
                return try KMLReader.read(data: data)
            }.value
            if Task.isCancelled {
                return
            }
            document = parsedKML.document
            consentDismissed = false
            await refreshNotices(for: parsedKML.document)
        } catch {
            if Task.isCancelled {
                return
            }
            loadError = error
        }
    }
}
