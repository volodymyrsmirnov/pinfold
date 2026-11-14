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
            loadedSHA: loadedSHA, live: live.contentSHA256, documentLoaded: document != nil,
            loadFailed: loadError != nil
        )
        guard action == .reload else { return }
        await reloadDocument(for: live, clearing: false)
    }

    /// Raises the alert only while this screen is on top: an error that arrives after a page or
    /// the map was pushed over it would otherwise surface on the wrong screen. The row's warning
    /// glyph still records the failure.
    func showRefreshError(_ message: String?) {
        if isOnScreen {
            refreshError = message
        }
    }
}
