import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// The consent banner section, shown while remote images wait for a decision.
    @ViewBuilder
    var remoteImagesSection: some View {
        if pendingConsent.count > 0, !consentDismissed {
            Section {
                RemoteImagesConsentBanner(
                    pending: pendingConsent,
                    onAllow: { Task { await allowRemoteImages() } },
                    onDismiss: { consentDismissed = true }
                )
            }
        }
    }

    /// Records consent for this entry, downloads what was pending, then refreshes the banner.
    @MainActor
    func allowRemoteImages() async {
        let resourcesDir = storage.resourcesDirectory(for: entry)
        await resourceCache.grantConsent(in: resourcesDir)
        refreshPendingConsent()
    }

    func refreshPendingConsent() {
        pendingConsent = resourceCache.pendingConsent(in: storage.resourcesDirectory(for: entry))
    }

    /// Computes the orphaned notes and the consent state once a document has loaded. The
    /// placemark keys are hashed off the main actor, and only when the entry has notes at all.
    @MainActor
    func refreshNotices(for document: KMLDocument) async {
        refreshPendingConsent()
        guard let annotations, !annotations.notes.isEmpty else {
            orphanedNotes = []
            return
        }
        let keys = await placemarkKeys(of: document.root)
        orphanedNotes = annotations.orphanedNotes(validKeys: keys)
    }
}

/// Every placemark's stable key, hashed off the main actor. A `nonisolated` free function so
/// the detached closure is compiled outside the view (see DocumentLoad.swift).
private nonisolated func placemarkKeys(of root: KMLContainer) async -> Set<String> {
    await Task.detached(priority: .utility) {
        Set(root.allPlacemarks.map(\.stableKey))
    }.value
}
