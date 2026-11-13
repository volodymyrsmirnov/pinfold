import Foundation

extension ImportCoordinator {
    /// Enqueues a file the app downloaded itself (a network-link snapshot), as a new entry.
    /// Interactive: a failure raises the error alert and an active duplicate prompts, since the
    /// person asked for the download. Shares the queue, dedup, commit and reload path with every
    /// other arrival.
    func enqueueDownloaded(_ data: Data, filename: String, catalog: Catalog, cache: ResourceCache) {
        enqueuePrepared([(data, filename)], interactive: true, catalog: catalog, cache: cache)
    }

    /// Enqueues a fetched new online list (`result.subscription` set): the commit writes the
    /// subscription into the sidecar. Interactive (the person tapped Subscribe), so a failure
    /// raises the error alert; it never prompts as a duplicate.
    func enqueueSubscribed(_ result: ImportResult, catalog: Catalog, cache: ResourceCache) {
        append([PendingImport(source: .subscribed(result), interactive: true)], catalog: catalog, cache: cache)
    }
}
