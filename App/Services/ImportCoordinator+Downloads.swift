import Foundation

extension ImportCoordinator {
    /// Enqueues a file the app downloaded itself (a network-link snapshot), as a new entry.
    /// Interactive: a failure raises the error alert and an active duplicate prompts, since the
    /// person asked for the download. Shares the queue, dedup, commit and reload path with every
    /// other arrival.
    func enqueueDownloaded(_ data: Data, filename: String, catalog: Catalog, cache: ResourceCache) {
        enqueuePrepared([(data, filename)], interactive: true, catalog: catalog, cache: cache)
    }
}
