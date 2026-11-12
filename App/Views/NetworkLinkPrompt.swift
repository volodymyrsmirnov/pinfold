import PinfoldCore
import SwiftUI

/// What the file screen offers for a document that only points at other files: the links that
/// can actually be fetched (`http(s)`), and the hosts they live on. Building an offer never
/// touches the network.
struct NetworkLinkOffer: Equatable {
    let links: [KMLNetworkLink]

    /// `nil` unless the document has no placemarks and at least one fetchable network link.
    init?(document: KMLDocument) {
        guard document.placemarkCount == 0 else { return nil }
        var seen = Set<URL>()
        let fetchable = document.networkLinks.filter { link in
            guard let url = NetworkLinkSnapshotService.fetchURL(for: link) else { return false }
            return seen.insert(url).inserted
        }
        guard !fetchable.isEmpty else { return nil }
        links = fetchable
    }

    /// Distinct lowercase hosts of the links, sorted.
    var hosts: [String] {
        let all = links.compactMap { NetworkLinkSnapshotService.fetchURL(for: $0)?.host?.lowercased() }
        return Array(Set(all)).sorted()
    }

    var isSingle: Bool {
        links.count == 1
    }
}

/// Where an in-progress snapshot stands.
enum NetworkLinkStatus: Equatable {
    case idle
    case downloading
    case finished(String)
    case failed(String)
}

/// A card asking whether to download a one-time copy of the files a network-link document
/// points at. Nothing is downloaded until the person taps the button; the text names the hosts.
struct NetworkLinkPrompt: View {
    let offer: NetworkLinkOffer
    let status: NetworkLinkStatus
    let isReadOnly: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This file links to online data", systemImage: "icloud.and.arrow.down")
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            statusView
            if status != .downloading {
                Button(buttonTitle, action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .disabled(isReadOnly)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let hosts = offer.hosts.joined(separator: ", ")
        let action = offer.isSingle
            ? "Download a one-time copy from \(hosts) to replace this file with its contents."
            : "Download one-time copies of its \(offer.links.count) files from \(hosts), each added as a new file."
        let privacy = "Downloading reveals this device's IP address to the host."
        return "Pinfold never fetches this automatically. \(action) \(privacy)"
    }

    private var buttonTitle: String {
        offer.isSingle ? "Download Copy" : "Download \(offer.links.count) Files"
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .downloading:
            ProgressView("Downloading\u{2026}")
        case let .finished(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
