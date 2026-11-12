import CoreLocation
import PinfoldCore
import SwiftUI

extension KMLDetailView {
    // MARK: - Load document

    func loadDocument() async {
        annotations = PlacemarkAnnotations(entry: entry, storage: storage)
        let fileURL = storage.originalFile(for: entry)
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
        } catch {
            if Task.isCancelled {
                return
            }
            loadError = error
        }
    }
}
