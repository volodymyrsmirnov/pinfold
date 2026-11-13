import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// The snapshot offer for the loaded document, when it has no placemarks but fetchable links.
    var networkLinkOffer: NetworkLinkOffer? {
        document.flatMap { NetworkLinkOffer(document: $0) }
    }

    /// The list section hosting the prompt. Nothing is downloaded until its button is tapped.
    func networkLinkSection(_ offer: NetworkLinkOffer) -> some View {
        Section {
            NetworkLinkPrompt(
                offer: offer,
                status: networkLinkStatus,
                isReadOnly: entry.isReadOnly,
                onDownload: { Task { await runSnapshot(offer) } }
            )
        }
    }

    /// Runs the confirmed snapshot: one link replaces this file's original, several are
    /// enqueued as new entries.
    @MainActor
    func runSnapshot(_ offer: NetworkLinkOffer) async {
        guard let catalog else { return }
        networkLinkStatus = .downloading
        let service = NetworkLinkSnapshotService()
        if offer.isSingle, let link = offer.links.first {
            do {
                let updated = try await service.replaceOriginal(
                    of: entry, with: link, storage: storage, catalog: catalog
                )
                networkLinkStatus = .idle
                await reloadDocument(for: updated)
            } catch {
                networkLinkStatus = .failed(error.localizedDescription)
            }
        } else if let importCoordinator {
            let outcome = await service.enqueueSnapshots(
                for: offer.links, coordinator: importCoordinator, catalog: catalog, cache: resourceCache
            )
            if outcome.enqueued > 0 {
                let count = outcome.enqueued
                networkLinkStatus = .finished(count == 1 ? "Added 1 file." : "Added \(count) files.")
            } else {
                networkLinkStatus = .failed(outcome.failures.first?.localizedDescription ?? "Nothing was downloaded.")
            }
        } else {
            networkLinkStatus = .idle
        }
    }
}
