import PinfoldCore
import SwiftUI

extension KMLDetailView {
    /// The catalogue's current value of this entry. `entry` is whatever the parent passed in
    /// and can be stale after a refresh rewrote the original.
    var liveEntry: CatalogEntry {
        catalog?.entries.first { $0.id == entry.id } ?? entry
    }

    /// Re-reads the document from `updated`'s original and rebuilds the list. A replaced
    /// network-link original clears the list first; an online refresh keeps the old rows on
    /// screen until the new document arrives.
    func reloadDocument(for updated: CatalogEntry, clearing: Bool = true) async {
        loadedEntryID = updated.id
        if clearing {
            document = nil
            outline = nil
        }
        await loadDocument(for: updated)
        if let document, !Task.isCancelled {
            await refreshNotices(for: document)
        }
    }

    /// The key of the content reload `.task`: this entry and its live content hash.
    var contentKey: DocumentLoad.ContentKey {
        DocumentLoad.ContentKey(entryID: entry.id, sha: liveEntry.contentSHA256)
    }

    /// Reloads if the loaded document is stale. Runs in the `.task` keyed by `contentKey`, so a
    /// newer change cancels an older reload before it can publish, and again when the view
    /// re-appears; the first load calls it once more when it finishes, so a change that landed
    /// during that load is not lost.
    func reloadIfContentChanged(to live: CatalogEntry) async {
        let action = DocumentLoad.contentAction(
            loadedSHA: loadedSHA, live: live.contentSHA256, documentLoaded: document != nil
        )
        guard action == .reload else { return }
        await reloadDocument(for: live, clearing: false)
    }

    /// The ⋯ menu for an online list: Refresh Now / Copy URL / Stop Updating. While a refresh
    /// runs the label is a spinner and Refresh Now is disabled.
    @ViewBuilder
    var onlineMenu: some View {
        if let refresher, let subscription = liveEntry.subscription {
            let live = liveEntry
            let refreshing = refresher.phase(for: live) == .refreshing
            Menu {
                Button {
                    Task { refreshError = await refresher.refreshNowMessage(live) }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .disabled(live.isReadOnly || refreshing)
                Button {
                    UIPasteboard.general.url = subscription.url
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
                Button {
                    stopUpdatingTarget = live
                } label: {
                    Label("Stop Updating", systemImage: "xmark.circle")
                }
                .disabled(live.isReadOnly)
            } label: {
                // Fixed frame so the toolbar pill keeps its size when the glyph becomes a spinner.
                Group {
                    if refreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .frame(width: 24, height: 24)
            }
            .stopUpdatingConfirmation(target: $stopUpdatingTarget) { target in
                Task { refreshError = await refresher.stopUpdatingMessage(target) }
            }
            .accessibilityLabel("Online list")
        }
    }
}
