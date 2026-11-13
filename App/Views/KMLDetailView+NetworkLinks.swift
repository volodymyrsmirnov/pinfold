import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// The subscribe offer for the loaded document, when it has fetchable links and isn't
    /// itself an online list already.
    var networkLinkOffer: NetworkLinkOffer? {
        guard !liveEntry.isOnline else { return nil }
        return document.flatMap { NetworkLinkOffer(document: $0) }
    }

    /// The list section hosting the card. Nothing is fetched until its button is tapped.
    func networkLinkSection(_ offer: NetworkLinkOffer) -> some View {
        Section {
            NetworkLinkPrompt(
                offer: offer,
                status: networkLinkStatus,
                isReadOnly: entry.isReadOnly,
                onSubscribe: { Task { await runSubscribe(offer) } }
            )
        }
    }

    /// Runs the tapped Subscribe: a link-only file with one link becomes the online list; any
    /// other offer subscribes each link as a new list, one after another.
    @MainActor
    func runSubscribe(_ offer: NetworkLinkOffer) async {
        guard let catalog, let importCoordinator, let refresher else { return }
        networkLinkStatus = .subscribing
        let service = SubscriptionService(
            catalog: catalog, coordinator: importCoordinator, cache: resourceCache, refresher: refresher
        )
        if offer.replacesThisList, let link = offer.links.first {
            await subscribeInPlace(service, link: link)
        } else {
            await subscribeEach(service, offer: offer)
        }
    }

    @MainActor
    private func subscribeInPlace(_ service: SubscriptionService, link: KMLNetworkLink) async {
        do {
            switch try await service.subscribeInPlace(entry, link: link) {
            case let .existing(id):
                networkLinkStatus = .idle
                open(id)
            case let .convertedInPlace(written):
                // The written entry, not the catalogue's copy: its reload may have been overtaken.
                networkLinkStatus = .idle
                await reloadDocument(for: written)
            case .converted:
                networkLinkStatus = .idle
                await reloadDocument(for: liveEntry)
            case .enqueued:
                // Another subscribe of the same URL is adding the list; this file stays as is.
                networkLinkStatus = .alreadyBeingAdded
            }
        } catch {
            networkLinkStatus = .failed(error.localizedDescription)
        }
    }

    /// Subscribes the links sequentially. Links a list already follows aren't counted; a
    /// failure is shown alongside what was added (`NetworkLinkStatus.afterSubscribingEach`).
    @MainActor
    private func subscribeEach(_ service: SubscriptionService, offer: NetworkLinkOffer) async {
        var added = 0
        var failed = 0
        var existing: UUID?
        var existingCount = 0
        var firstError: String?
        for link in offer.links {
            guard let url = NetworkLinkSnapshotService.fetchURL(for: link) else { continue }
            do {
                switch try await service.subscribe(to: url, origin: .networkLink, link: link) {
                case let .existing(id):
                    existing = existing ?? id
                    existingCount += 1
                case .converted, .convertedInPlace, .enqueued: added += 1
                }
            } catch {
                failed += 1
                firstError = firstError ?? error.localizedDescription
            }
        }
        if let status = NetworkLinkStatus.afterSubscribingEach(
            added: added, failed: failed, firstError: firstError, existing: existingCount
        ) {
            networkLinkStatus = status
        } else if let existing {
            networkLinkStatus = .idle
            open(existing)
        } else {
            networkLinkStatus = .idle
        }
    }

    /// Selects another list, through the router `RootView` observes.
    @MainActor
    private func open(_ id: UUID) {
        guard let folder = catalog?.entries.first(where: { $0.id == id })?.storageFolderName else { return }
        router?.openEntry(folderName: folder)
    }
}
