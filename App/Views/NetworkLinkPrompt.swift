import PinfoldCore
import SwiftUI

/// What the file screen offers for a document that points at other files: the links that can
/// actually be fetched (`http(s)`), and the hosts they live on. Building an offer never
/// touches the network.
struct NetworkLinkOffer: Equatable {
    let links: [KMLNetworkLink]
    /// The document's own placemarks. A file with none and a single link is replaced by it.
    let placemarkCount: Int

    /// `nil` unless the document has at least one fetchable network link.
    init?(document: KMLDocument) {
        var seen = Set<URL>()
        let fetchable = document.networkLinks.filter { link in
            guard let url = NetworkLinkSnapshotService.fetchURL(for: link) else { return false }
            return seen.insert(url).inserted
        }
        guard !fetchable.isEmpty else { return nil }
        links = fetchable
        placemarkCount = document.placemarkCount
    }

    /// Distinct lowercase hosts of the links, sorted.
    var hosts: [String] {
        let all = links.compactMap { NetworkLinkSnapshotService.fetchURL(for: $0)?.host?.lowercased() }
        return Array(Set(all)).sorted()
    }

    var isSingle: Bool {
        links.count == 1
    }

    /// Subscribing turns this very list into the online list: its only content is the one link.
    var replacesThisList: Bool {
        isSingle && placemarkCount == 0
    }

    /// "Subscribe" when this list becomes the online list, else how many new lists it makes.
    var buttonTitle: String {
        if replacesThisList {
            return String(localized: "Subscribe")
        }
        return links.count == 1
            ? String(localized: "Subscribe to 1 List")
            : String(localized: "Subscribe to \(links.count) Lists")
    }
}

/// Where an in-progress subscribe stands.
enum NetworkLinkStatus: Equatable {
    case idle
    case subscribing
    case finished(String)
    /// Some links were added and some failed; the button stays so the person can retry.
    case partial(String)
    /// Another subscribe is adding the list; the button stays, as that one may still fail.
    case pending(String)
    case failed(String)

    /// The single link's list is already being added by another subscribe. A retry is safe: it
    /// finds the list being added, or the one it made.
    static let alreadyBeingAdded = NetworkLinkStatus.pending(String(localized: "This list is already being added."))

    /// The status after subscribing each link of an offer: `added` new lists, `failed` links
    /// that couldn't be added (`firstError` the first reason). `nil` when nothing was added or
    /// failed, so the caller opens a list that already follows a link, or goes idle.
    static func afterSubscribingEach(added: Int, failed: Int, firstError: String?) -> NetworkLinkStatus? {
        let addedText = added == 1 ? String(localized: "Added 1 list.") : String(localized: "Added \(added) lists.")
        switch (added > 0, failed > 0) {
        case (true, false):
            return .finished(addedText)
        case (true, true):
            let reason = firstError ?? ""
            return .partial(String(localized: "\(addedText) \(failed) couldn't be added: \(reason)"))
        case (false, true):
            return firstError.map { .failed($0) }
        case (false, false):
            return nil
        }
    }
}

/// A card offering to subscribe to the files a network-link document points at. Nothing is
/// fetched until the person taps the button; the text names the hosts.
struct NetworkLinkPrompt: View {
    /// The button is offered until a subscribe runs, and again after one failed in full or in
    /// part (a retry finds the links already added as existing lists) or found its list being
    /// added by another subscribe that may still fail; once it finished, tapping again would
    /// only subscribe the same links twice.
    static func showsButton(for status: NetworkLinkStatus) -> Bool {
        switch status {
        case .idle, .partial, .pending, .failed: true
        case .subscribing, .finished: false
        }
    }

    let offer: NetworkLinkOffer
    let status: NetworkLinkStatus
    let isReadOnly: Bool
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This file links to online data", systemImage: "globe")
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            statusView
            if Self.showsButton(for: status) {
                Button(offer.buttonTitle, action: onSubscribe)
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
        return String(localized: """
        Subscribe to keep it updated from \(hosts). Pinfold checks for changes while the app is open. \
        The host can see this device's IP address.
        """)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .subscribing:
            ProgressView("Subscribing\u{2026}")
        case let .finished(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .partial(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        case let .pending(message):
            Label(message, systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
