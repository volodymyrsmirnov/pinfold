import Foundation

extension ImportCoordinator {
    /// Enqueues a fetched new online list (`result.subscription` set): the commit writes the
    /// subscription into the sidecar. Interactive (the person tapped Subscribe), so a failure
    /// raises the error alert; it never prompts as a duplicate.
    func enqueueSubscribed(_ result: ImportResult, catalog: Catalog, cache: ResourceCache) {
        if let url = result.subscription?.url {
            pendingSubscriptionURLs.insert(url)
        }
        append([PendingImport(source: .subscribed(result), interactive: true)], catalog: catalog, cache: cache)
    }

    /// Whether a new online list following `url` is queued, being committed, or committed but
    /// not shown by `catalog` yet. A committed list is forgotten once `catalog` shows it (or its
    /// folder is gone).
    func isSubscribing(to url: URL, in catalog: Catalog) -> Bool {
        if let committed = committedSubscriptions[url] {
            let shown = catalog.entries.contains { $0.id == committed.id }
            let deleted = !FileManager.default.fileExists(atPath: catalog.storage.folder(for: committed).path)
            guard shown || deleted else { return true }
            committedSubscriptions[url] = nil
        }
        return pendingSubscriptionURLs.contains(url)
    }
}
