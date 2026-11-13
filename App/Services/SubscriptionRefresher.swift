import Foundation
import Observation
import os

/// Why refreshing an online list failed. The description is what the list shows and records.
enum SubscriptionError: Error, LocalizedError, Equatable {
    case http(Int), tooLarge, notSupported, linkOnly, network(String), writeFailed(String), readOnly

    var errorDescription: String? {
        switch self {
        case let .http(status):
            String(localized: "The server returned an error (HTTP \(status)).")
        case .tooLarge:
            String(localized: "The file is larger than 50 MB.")
        case .notSupported:
            String(localized: "The server didn't return a KML, KMZ, GPX or GeoJSON file.")
        case .linkOnly:
            String(localized: "The server returned a file that only links to other files.")
        case let .network(reason):
            reason
        case let .writeFailed(reason):
            String(localized: "The update couldn't be saved: \(reason)")
        case .readOnly:
            String(localized: "This list can't be changed on this device right now.")
        }
    }

    /// Maps a fetch failure (`DownloadError`, cancellation or anything else) to a refresh error.
    init(fetchError error: Error) {
        switch error {
        case let DownloadError.httpStatus(status): self = .http(status)
        case DownloadError.tooLarge: self = .tooLarge
        case DownloadError.redirectedToOtherHost:
            self = .network(String(localized: "The server redirected to a different host."))
        case let DownloadError.transport(underlying): self = .network(underlying.localizedDescription)
        case is CancellationError: self = .network(String(localized: "The check was cancelled."))
        default: self = .network(error.localizedDescription)
        }
    }
}

/// Keeps online lists up to date while the app is open: at launch, when the scene becomes
/// active, and on an in-session timer (`SubscriptionRefresher+Timer.swift`). Never runs in the
/// background.
///
/// Fetches run in parallel (at most `maxParallelFetches`); everything that touches storage (the
/// refresh state and content writes, Stop Updating) runs through the `StorageApplyQueue`, so it
/// is serialised and never interleaves with a storage application. Each write re-reads the live
/// entry and `catalog.storage` first, so a list that was deleted, stopped or re-pointed while
/// its fetch was in flight is left alone.
@MainActor @Observable final class SubscriptionRefresher {
    enum Phase: Equatable { case idle, refreshing, failed(String) }

    typealias Fetcher = @Sendable (URL, _ etag: String?, _ lastModified: String?) async throws -> ConditionalResponse

    nonisolated static let maxBytes = 50 * 1024 * 1024
    nonisolated static let timeout: TimeInterval = 30
    static let maxParallelFetches = 3

    /// The conditional GET used outside tests: 50 MB cap, 30 s timeout, no cross-host redirects.
    nonisolated static let liveFetcher: Fetcher = { url, etag, lastModified in
        try await BoundedDownloader.fetchConditional(
            url, etag: etag, lastModified: lastModified, maxBytes: maxBytes, timeout: timeout,
            followCrossHostRedirects: false
        )
    }

    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "subscription"
    )

    /// Lists being refreshed or whose last refresh this session failed, keyed by
    /// `storageFolderName`. A missing key is idle.
    private(set) var phases: [String: Phase] = [:]
    /// Bumps whenever a cached refresh state changes, so `lastSuccess`/`phase` readers update.
    private var stateRevision = 0

    @ObservationIgnored let catalog: Catalog
    @ObservationIgnored let network: NetworkStatus?
    @ObservationIgnored let clock: () -> Date
    @ObservationIgnored private let cache: ResourceCache
    @ObservationIgnored private let fetcher: Fetcher
    /// Shared with `SubscriptionService`, whose subscribe writes are serialised with refreshes.
    /// Never call `refreshNow`, `refreshDue` or `stopUpdating` from inside one of its
    /// operations: they wait on this queue themselves.
    @ObservationIgnored let storageQueue: StorageApplyQueue
    @ObservationIgnored private let fetchSlots = FetchSlots(limit: maxParallelFetches)
    /// Refresh states read from `resources/`, keyed by the resources directory path.
    @ObservationIgnored private var states: [String: SubscriptionState] = [:]
    /// The running refresh of each list, keyed by `storageFolderName`.
    @ObservationIgnored private var inFlight: [String: Task<Result<Void, SubscriptionError>, Never>] = [:]
    @ObservationIgnored private(set) var isStarted = false
    @ObservationIgnored var isSceneActive = true
    /// Bumped by every `sceneDidResignActive`. Capture it when the scene becomes active and pass
    /// it to the deferred `sceneDidBecomeActive(token:)`, which ignores it once it is stale.
    @ObservationIgnored private(set) var activationToken = 0
    /// The due check started by `start`, `sceneDidBecomeActive` or the device coming back online.
    @ObservationIgnored var activationTask: Task<Void, Never>?

    /// Timer state, owned by `SubscriptionRefresher+Timer.swift`.
    @ObservationIgnored var timerTask: Task<Void, Never>?
    /// When the armed timer fires; `nil` when no timer is armed.
    @ObservationIgnored var nextFireDate: Date?
    /// Identifies the latest catalogue/network observation; older ones are ignored.
    @ObservationIgnored var observationGeneration = 0
    @ObservationIgnored var lastSeenOnline = true

    /// - Parameter storageQueue: The app's storage queue, so refresh writes never interleave
    ///   with a storage application. Tests get a private one.
    init(
        catalog: Catalog,
        cache: ResourceCache,
        network: NetworkStatus?,
        fetcher: Fetcher? = nil,
        clock: @escaping () -> Date = { .now },
        storageQueue: StorageApplyQueue = StorageApplyQueue()
    ) {
        self.catalog = catalog
        self.cache = cache
        self.network = network
        self.fetcher = fetcher ?? Self.liveFetcher
        self.clock = clock
        self.storageQueue = storageQueue
    }

    // MARK: - Reading state

    func phase(for entry: CatalogEntry) -> Phase {
        if let phase = phases[entry.storageFolderName] {
            return phase
        }
        guard entry.isOnline, let error = state(for: entry).lastError else { return .idle }
        return .failed(error)
    }

    func lastSuccess(for entry: CatalogEntry) -> Date? {
        guard entry.isOnline else { return nil }
        return state(for: entry).lastSuccessAt
    }

    /// The entry's refresh state in the current root, read once and then cached.
    func state(for entry: CatalogEntry) -> SubscriptionState {
        _ = stateRevision
        let dir = catalog.storage.resourcesDirectory(for: entry)
        if let cached = states[dir.path] {
            return cached
        }
        let state = SubscriptionStateStore.read(in: dir)
        states[dir.path] = state
        return state
    }

    private func store(_ state: SubscriptionState, in dir: URL) {
        SubscriptionStateStore.write(state, in: dir)
        states[dir.path] = state
        stateRevision &+= 1
    }

    /// Records the fetch a subscribe just made for the list in `folder` (run it inside
    /// `storageQueue`), replacing any state cached while the list was a normal one.
    func recordSubscribed(_ state: SubscriptionState, folder: String) {
        store(state, in: catalog.storage.resourcesDirectory(forFolderNamed: folder))
    }

    private func liveEntry(_ folder: String) -> CatalogEntry? {
        catalog.entries.first { $0.storageFolderName == folder }
    }

    // MARK: - Lifecycle

    /// Called once after bootstrap: from here on due lists are checked and the timer runs.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        activationTask = Task { await refreshDue() }
    }

    /// Checks due lists and arms the timer (the app came to the foreground).
    ///
    /// - Parameter token: The `activationToken` read when the scene became active, for a call
    ///   made after other work (re-resolve, inbox drains, reload). If the scene resigned
    ///   meanwhile, the call is stale and does nothing, so no timer or fetch starts outside
    ///   the foreground.
    func sceneDidBecomeActive(token: Int? = nil) {
        if let token, token != activationToken {
            return
        }
        isSceneActive = true
        guard isStarted else { return }
        activationTask = Task { await refreshDue() }
    }

    /// Cancels the timer (the app left the foreground). In-flight refreshes finish.
    func sceneDidResignActive() {
        isSceneActive = false
        activationToken &+= 1
        observationGeneration &+= 1
        cancelTimer()
    }

    // MARK: - Refreshing

    /// Refreshes every due list that is not already being refreshed, then re-arms the timer.
    /// Skipped while offline (the timer re-arms when the device comes back online).
    func refreshDue() async {
        guard isStarted else { return }
        // Never pick lists while a storage application is running: wait for it to finish.
        await storageQueue.run {}
        // The app may have left the foreground while waiting: start no fetch then.
        guard isSceneActive else { return }
        guard network?.isOnline != false else {
            rearm()
            return
        }
        let now = clock()
        let due = catalog.entries.filter { entry in
            inFlight[entry.storageFolderName] == nil
                && SubscriptionSchedule.isDue(entry, state: state(for: entry), now: now)
        }
        let tasks = due.map { begin($0) }
        for task in tasks {
            _ = await task.value
        }
        rearm()
    }

    /// Refreshes `entry` now, whether or not it is due. Joins a refresh already in flight.
    @discardableResult
    func refreshNow(_ entry: CatalogEntry) async -> Result<Void, SubscriptionError> {
        let folder = entry.storageFolderName
        if let running = inFlight[folder] {
            return await running.value
        }
        let live = liveEntry(folder) ?? entry
        guard live.isOnline else { return .success(()) }
        guard !live.isReadOnly else { return .failure(.readOnly) }
        return await begin(live).value
    }

    /// Starts refreshing `entry` (or returns its running refresh) and marks it in flight.
    private func begin(_ entry: CatalogEntry) -> Task<Result<Void, SubscriptionError>, Never> {
        let folder = entry.storageFolderName
        if let running = inFlight[folder] {
            return running
        }
        phases[folder] = .refreshing
        let task = Task { await self.run(entry) }
        inFlight[folder] = task
        return task
    }

    private func run(_ entry: CatalogEntry) async -> Result<Void, SubscriptionError> {
        let folder = entry.storageFolderName
        let result: Result<Void, SubscriptionError>
        if let subscription = entry.subscription {
            let attemptAt = clock()
            await fetchSlots.acquire()
            let outcome = await fetch(subscription, for: entry)
            fetchSlots.release()
            result = await storageQueue.run {
                await self.record(outcome, folder: folder, subscription: subscription, attemptAt: attemptAt)
            }
        } else {
            result = .success(())
        }
        switch result {
        case .success:
            phases.removeValue(forKey: folder)
        case let .failure(error):
            phases[folder] = .failed(error.localizedDescription)
            Self.logger.error(
                "Refresh of \(folder, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        inFlight.removeValue(forKey: folder)
        rearm()
        return result
    }

    /// Fetches the subscription with the stored validators and classifies the response.
    private func fetch(_ subscription: Subscription, for entry: CatalogEntry) async -> FetchOutcome {
        let validators = state(for: entry)
        let response: ConditionalResponse
        do {
            response = try await fetcher(subscription.url, validators.etag, validators.lastModified)
        } catch {
            return .failed(SubscriptionError(fetchError: error))
        }
        guard case let .data(data) = response.body else { return .unchanged(response) }
        let currentSHA = liveEntry(entry.storageFolderName)?.contentSHA256 ?? entry.contentSHA256
        switch await classifyOffMain(data, filename: entry.sourceFilename, currentSHA: currentSHA) {
        case .same: return .unchanged(response)
        case let .changed(result): return .changed(result, response)
        case let .failed(error): return .failed(error)
        }
    }

    /// Records a fetch outcome against the live entry; runs inside the storage queue. A list
    /// that is gone, no longer online, now follows another URL, or is read-only (sidecar not
    /// downloaded or unreadable) is left untouched: nothing is written and no error recorded.
    private func record(
        _ outcome: FetchOutcome, folder: String, subscription: Subscription, attemptAt: Date
    ) async -> Result<Void, SubscriptionError> {
        guard let live = liveEntry(folder), live.subscription?.url == subscription.url, !live.isReadOnly else {
            return .success(())
        }
        let storage = catalog.storage
        let dir = storage.resourcesDirectory(for: live)
        var state = state(for: live)
        state.lastAttemptAt = attemptAt
        let failure: SubscriptionError?
        switch outcome {
        case let .unchanged(response):
            // A 304 often omits the validators: keep the stored ones then.
            state.etag = response.etag ?? state.etag
            state.lastModified = response.lastModified ?? state.lastModified
            state.httpExpires = response.httpExpires
            failure = nil
        case let .changed(result, response):
            do {
                _ = try await SubscriptionContentWriter.applyAndReindex(
                    result, to: live, storage: storage, cache: cache
                )
                failure = nil
                state.etag = response.etag
                state.lastModified = response.lastModified
                state.httpExpires = response.httpExpires
                state.serverMinRefreshPeriod = result.networkLinkControl?.minRefreshPeriod
                state.serverExpires = result.networkLinkControl?.expires
            } catch {
                failure = .writeFailed(error.localizedDescription)
            }
        case let .failed(error):
            failure = error
        }
        if let failure {
            state.lastError = failure.localizedDescription
            store(state, in: dir)
            return .failure(failure)
        }
        state.lastError = nil
        state.lastSuccessAt = clock()
        store(state, in: dir)
        if case .changed = outcome {
            await catalog.reload()
        }
        return .success(())
    }

    // MARK: - Stop Updating

    /// Turns the online list back into a normal list: clears the synced subscription, removes
    /// this device's refresh state, reloads and re-arms. Serialised with refresh writes, so an
    /// in-flight refresh finishing afterwards finds no subscription and writes nothing.
    func stopUpdating(_ entry: CatalogEntry) async throws {
        let folder = entry.storageFolderName
        let error: SubscriptionError? = await storageQueue.run {
            let storage = self.catalog.storage
            if (self.liveEntry(folder) ?? entry).isReadOnly {
                return .readOnly
            }
            do {
                try storage.updateExistingMetadata(forFolderNamed: folder) { $0.subscription = nil }
            } catch {
                return .writeFailed(error.localizedDescription)
            }
            let dir = storage.resourcesDirectory(forFolderNamed: folder)
            SubscriptionStateStore.remove(in: dir)
            self.states.removeValue(forKey: dir.path)
            self.stateRevision &+= 1
            self.phases.removeValue(forKey: folder)
            await self.catalog.reload()
            return nil
        }
        if let error {
            throw error
        }
        rearm()
    }
}

// MARK: - Fetch outcome

private enum FetchOutcome {
    /// `304`, or a `200` whose bytes match the current original.
    case unchanged(ConditionalResponse)
    case changed(ImportResult, ConditionalResponse)
    case failed(SubscriptionError)
}

private enum Classified: Sendable {
    case same
    case changed(ImportResult)
    case failed(SubscriptionError)
}

/// Hashes and validates fetched bytes off the main actor. Bytes equal to the current original
/// are `.same` and never parsed. A `nonisolated` free function so the detached closure is
/// compiled outside any actor-isolated caller (see FavoritesView.swift).
private nonisolated func classifyOffMain(_ data: Data, filename: String, currentSHA: String) async -> Classified {
    await Task.detached(priority: .utility) {
        if ImportService.sha256Hex(data) == currentSHA {
            return .same
        }
        let result: ImportResult
        do {
            result = try ImportService.prepare(data: data, sourceFilename: filename)
        } catch {
            return .failed(.notSupported)
        }
        if result.placemarkCount == 0, result.networkLinkCount > 0 {
            return .failed(.linkOnly)
        }
        return .changed(result)
    }.value
}

// MARK: - Fetch slots

/// A main-actor counting semaphore bounding how many fetches run at once.
@MainActor private final class FetchSlots {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
