import SwiftUI

/// A banner offering to download the remote images a file links to, shown under the
/// "Ask" policy until the user decides. Self-contained: the caller supplies what is pending
/// (`ResourceCache.pendingConsent(in:)`) and the actions.
struct RemoteImagesConsentBanner: View {
    /// The images waiting for consent.
    let pending: ResourceCache.PendingConsent
    /// Called when the user allows the downloads.
    let onAllow: () -> Void
    /// Called when the user chooses not to download now.
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "photo.badge.arrow.down")
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Not Now", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Download", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        pending.count == 1 ? "Download 1 image?" : "Download \(pending.count) images?"
    }

    private var detail: String {
        let hosts = pending.hosts.joined(separator: ", ")
        return "This file links to images on \(hosts). Downloading reveals this device's IP address to those hosts."
    }
}
