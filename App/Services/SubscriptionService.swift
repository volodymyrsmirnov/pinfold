import Foundation
import PinfoldCore

/// The address an online list follows.
enum SubscriptionURL {
    /// `text` trimmed, as an `https` URL: only `http`/`https` (any letter case) with a host are
    /// accepted, and `http` is upgraded. `nil` for anything else (`webcal:`, `file:`, a bare
    /// host, an empty string).
    static func normalise(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host?.isEmpty == false,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        return components.url
    }
}

/// Turns a URL or a `<NetworkLink>` into an online list, on the person's tap. Nothing here
/// runs on its own.
///
/// Every sidecar write runs through the refresher's `StorageApplyQueue`, so it never
/// interleaves with a refresh write or a storage application.
@MainActor struct SubscriptionService {
    enum Outcome: Equatable {
        /// A list already follows the URL; nothing was fetched.
        case existing(UUID)
        /// A normal list with the same content became the online list.
        case converted(UUID)
        /// A new list is on the import queue.
        case enqueued
    }

    let catalog: Catalog
    let coordinator: ImportCoordinator
    let cache: ResourceCache
    let refresher: SubscriptionRefresher
    private let fetcher: SubscriptionRefresher.Fetcher

    init(
        catalog: Catalog,
        coordinator: ImportCoordinator,
        cache: ResourceCache,
        refresher: SubscriptionRefresher,
        fetcher: SubscriptionRefresher.Fetcher? = nil
    ) {
        self.catalog = catalog
        self.coordinator = coordinator
        self.cache = cache
        self.refresher = refresher
        self.fetcher = fetcher ?? SubscriptionRefresher.liveFetcher
    }

    // MARK: - Subscribe

    /// Subscribes to `url` (already normalised): selects a list that already follows it, else
    /// fetches it, then turns a normal list with the same content into the online list, else
    /// enqueues a new list. `link`'s refresh hints are copied into the subscription.
    func subscribe(
        to url: URL, origin: Subscription.Origin, link: KMLNetworkLink? = nil
    ) async throws(SubscriptionError) -> Outcome {
        if let existing = catalog.entries.first(where: { !$0.isTrashed && $0.subscription?.url == url }) {
            return .existing(existing.id)
        }
        let fetched = try await fetch(url, filename: Self.filename(for: url, link: link))
        let subscription = makeSubscription(url, origin: origin, link: link)
        if let match = convertibleList(sha: fetched.result.contentSHA256) {
            let converted = try await convert(match, to: subscription, state: fetched.state)
            if converted {
                return .converted(match.id)
            }
        }
        var result = fetched.result
        result.subscription = subscription
        result.subscriptionState = fetched.state
        coordinator.enqueueSubscribed(result, catalog: catalog, cache: cache)
        return .enqueued
    }

    /// The single-link card: `entry` (a file holding just this link) becomes the online list.
    /// Its original is replaced by the fetched file, keeping its name, notes and other
    /// annotations, and it follows `link` from now on.
    func subscribeInPlace(_ entry: CatalogEntry, link: KMLNetworkLink) async throws(SubscriptionError) {
        let folder = entry.storageFolderName
        guard let url = NetworkLinkSnapshotService.fetchURL(for: link) else { throw .notSupported }
        guard !(liveEntry(folder) ?? entry).isReadOnly else { throw .readOnly }
        let fetched = try await fetch(url, filename: Self.filename(for: url, link: link))
        let subscription = makeSubscription(url, origin: .networkLink, link: link)
        let catalog = catalog, cache = cache, refresher = refresher
        let error: SubscriptionError? = await refresher.storageQueue.run {
            guard let live = catalog.entries.first(where: { $0.storageFolderName == folder }), !live.isReadOnly else {
                return .readOnly
            }
            let storage = catalog.storage
            let updated: CatalogEntry
            do {
                updated = try await SubscriptionContentWriter.apply(
                    fetched.result, to: live, storage: storage, cache: cache
                )
            } catch {
                return .writeFailed(error.localizedDescription)
            }
            PlacemarkIndexStore.shared.invalidate(
                resourcesDir: storage.resourcesDirectory(for: live), sidecar: storage.metadataFile(for: live)
            )
            if !live.isTrashed {
                SpotlightIndexer.index(entry: updated, indexEntries: fetched.result.indexEntries)
            }
            // The content is in place either way; a failed subscription write leaves a normal
            // list holding the fetched copy.
            var failure: SubscriptionError?
            do {
                try storage.updateExistingMetadata(forFolderNamed: folder) { $0.subscription = subscription }
                refresher.recordSubscribed(fetched.state, folder: folder)
            } catch {
                failure = .writeFailed(error.localizedDescription)
            }
            await catalog.reload()
            return failure
        }
        if let error {
            throw error
        }
    }

    // MARK: - Steps

    private struct Fetched {
        let result: ImportResult
        /// The refresh state this fetch leaves behind: validators, server hints, success now.
        let state: SubscriptionState
    }

    /// Fetches `url` unconditionally and validates the bytes as any supported format. A file
    /// with no placemarks of its own that only links to other files is rejected.
    private func fetch(_ url: URL, filename: String) async throws(SubscriptionError) -> Fetched {
        let attemptAt = refresher.clock()
        let response: ConditionalResponse
        do {
            response = try await fetcher(url, nil, nil)
        } catch {
            throw SubscriptionError(fetchError: error)
        }
        // No validators were sent, so a 304 is a server error.
        guard case let .data(data) = response.body else { throw .notSupported }
        guard data.count <= SubscriptionRefresher.maxBytes else { throw .tooLarge }
        let result = try await prepareSubscribedOffMain(data, filename: filename).get()
        let state = SubscriptionState(
            lastAttemptAt: attemptAt, lastSuccessAt: refresher.clock(), etag: response.etag,
            lastModified: response.lastModified,
            serverMinRefreshPeriod: result.networkLinkControl?.minRefreshPeriod,
            serverExpires: result.networkLinkControl?.expires, httpExpires: response.httpExpires
        )
        return Fetched(result: result, state: state)
    }

    private func makeSubscription(_ url: URL, origin: Subscription.Origin, link: KMLNetworkLink?) -> Subscription {
        Subscription(
            url: url, origin: origin, subscribedAt: refresher.clock(),
            refreshMode: link?.refreshMode, refreshInterval: link?.refreshInterval
        )
    }

    /// A normal list the person can see and change with these bytes; it becomes the online one.
    private func convertibleList(sha: String) -> CatalogEntry? {
        catalog.entries.first { !$0.isTrashed && !$0.isOnline && !$0.isReadOnly && $0.contentSHA256 == sha }
    }

    /// Writes `subscription` into `match`'s sidecar (keeping everything else) and records the
    /// fetch. `false` when the list stopped matching while the fetch ran (a new list is made
    /// instead).
    private func convert(
        _ match: CatalogEntry, to subscription: Subscription, state: SubscriptionState
    ) async throws(SubscriptionError) -> Bool {
        let folder = match.storageFolderName
        let catalog = catalog, refresher = refresher
        let outcome: Result<Bool, SubscriptionError> = await refresher.storageQueue.run {
            guard let live = catalog.entries.first(where: { $0.storageFolderName == folder }),
                  !live.isTrashed, !live.isOnline, !live.isReadOnly, live.contentSHA256 == match.contentSHA256
            else { return .success(false) }
            do {
                try catalog.storage.updateExistingMetadata(forFolderNamed: folder) { $0.subscription = subscription }
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
            refresher.recordSubscribed(state, folder: folder)
            await catalog.reload()
            return .success(true)
        }
        return try outcome.get()
    }

    private func liveEntry(_ folder: String) -> CatalogEntry? {
        catalog.entries.first { $0.storageFolderName == folder }
    }

    /// The name to store the download under (`ImportService.prepare` fixes the extension by
    /// content): a link's own naming, else the URL's last path component, else its host. The
    /// list's name is the document name, else this name's stem (the import naming).
    static func filename(for url: URL, link: KMLNetworkLink?) -> String {
        if let link {
            return NetworkLinkSnapshotService.filename(for: link, url: url)
        }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" {
            return last
        }
        return url.host ?? "online-list"
    }
}

// MARK: - Off-main work

/// Validates fetched bytes off the main actor. A `nonisolated` free function so the detached
/// closure is compiled outside any actor-isolated caller (see FavoritesView.swift).
private nonisolated func prepareSubscribedOffMain(
    _ data: Data, filename: String
) async -> Result<ImportResult, SubscriptionError> {
    await Task.detached(priority: .userInitiated) {
        let result: ImportResult
        do {
            result = try ImportService.prepare(data: data, sourceFilename: filename)
        } catch is CancellationError {
            return .failure(SubscriptionError(fetchError: CancellationError()))
        } catch {
            return .failure(.notSupported)
        }
        if result.placemarkCount == 0, result.networkLinkCount > 0 {
            return .failure(.linkOnly)
        }
        return .success(result)
    }.value
}
