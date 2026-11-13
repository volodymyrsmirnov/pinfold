import Foundation

extension ImportCoordinator {
    /// Enqueues a fetched new online list (`result.subscription` set): the commit writes the
    /// subscription into the sidecar. Interactive (the person tapped Subscribe), so a failure
    /// raises the error alert; it never prompts as a duplicate.
    func enqueueSubscribed(_ result: ImportResult, catalog: Catalog, cache: ResourceCache) {
        append([PendingImport(source: .subscribed(result), interactive: true)], catalog: catalog, cache: cache)
    }
}
