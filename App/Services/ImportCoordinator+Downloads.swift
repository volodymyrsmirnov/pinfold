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

    /// Records that `entry` now follows `url` on disk (`SubscriptionService` converted it), unless
    /// `catalog` already shows it doing so: until it does, `isSubscribing(to:in:)` holds the URL.
    func noteSubscribed(_ url: URL, entry: CatalogEntry, catalog: Catalog) {
        guard !Self.shows(entry, following: url, in: catalog) else { return }
        committedSubscriptions[url] = entry
    }

    /// Whether a new online list following `url` is queued, being committed, or a list
    /// subscribed to it is not shown by `catalog` following it yet. Such a list is forgotten once
    /// `catalog` shows it following the URL, or once its sidecar on disk no longer follows it
    /// (deleted, stopped, or unreadable).
    func isSubscribing(to url: URL, in catalog: Catalog) -> Bool {
        if let committed = committedSubscriptions[url] {
            let shown = Self.shows(committed, following: url, in: catalog)
            guard shown || !Self.followsOnDisk(committed, url, storage: catalog.storage) else { return true }
            committedSubscriptions[url] = nil
        }
        return pendingSubscriptionURLs.contains(url)
    }

    private static func followsOnDisk(_ entry: CatalogEntry, _ url: URL, storage: StorageLocations) -> Bool {
        guard case let .ok(sidecar) = storage.readSidecar(forFolderNamed: entry.storageFolderName) else { return false }
        return sidecar.subscription?.url == url
    }

    private static func shows(_ entry: CatalogEntry, following url: URL, in catalog: Catalog) -> Bool {
        catalog.entries.contains { $0.id == entry.id && $0.subscription?.url == url }
    }
}
