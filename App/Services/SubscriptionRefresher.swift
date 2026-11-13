import Foundation
import Observation
import os
import PinfoldCore

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
/// Fetches run in parallel (at most `maxParallelFetches`, a slot held from the request until its
/// outcome is recorded, so at most that many responses are in memory); everything that touches
/// storage (the refresh state and content writes, Stop Updating) runs through the
/// `StorageApplyQueue`, so it is serialised and never interleaves with a storage application.
/// Each write re-reads the live entry and `catalog.storage` first, so a list that was deleted,
/// stopped or re-pointed while its fetch was in flight is left alone.
///
/// Known limitation: each window (scene) has its own refresher, timer and storage queue. They are
/// not coordinated; instead the due check and `record` re-read `subscription-state.json` from
/// disk, so a window does not fetch a list another window has just checked, and an outcome older
/// than another window's check is dropped. Two windows can still fetch the same list at the same
/// moment.
@MainActor @Observable final class SubscriptionRefresher {
    enum Phase: Equatable { case idle, refreshing, failed(String) }

    typealias Fetcher = @Sendable (URL, _ etag: String?, _ lastModified: String?) async throws -> ConditionalResponse
    /// Hashes an original on disk: its SHA-256, or `nil` when it can't be read.
    typealias OriginalHasher = @Sendable (URL) async -> String?

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
    @ObservationIgnored let fetcher: Fetcher
    @ObservationIgnored let hashOriginal: OriginalHasher
    /// Shared with `SubscriptionService`, whose subscribe writes are serialised with refreshes.
    /// Never call `refreshNow`, `refreshDue` or `stopUpdating` from inside one of its
    /// operations: they wait on this queue themselves.
    @ObservationIgnored let storageQueue: StorageApplyQueue
    @ObservationIgnored let fetchSlots = FetchSlots(limit: maxParallelFetches)
    /// Refresh states read from `resources/`, keyed by the resources directory path.
    @ObservationIgnored private var states: [String: SubscriptionState] = [:]
    /// The running refresh of each list, keyed by `storageFolderName`.
    @ObservationIgnored private var inFlight: [String: Task<Result<Void, SubscriptionError>, Never>] = [:]
    @ObservationIgnored private(set) var isStarted = false
    @ObservationIgnored var isSceneActive = true
    /// Bumped by every `sceneDidResignActive`. Capture it when the scene becomes active and pass
    /// it to the deferred `sceneDidBecomeActive(token:)`, which ignores it once it is stale.
    @ObservationIgnored private(set) var activationToken = 0
    /// URLs a subscribe is working on, each with the subscribes waiting for it
    /// (`SubscriptionRefresher+Reservations.swift`).
    @ObservationIgnored var subscribeReservations: [URL: [CheckedContinuation<Void, Never>]] = [:]
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
    /// - Parameter hashOriginal: Reads and hashes an original before its fetch; tests hold it.
    init(
        catalog: Catalog,
        cache: ResourceCache,
        network: NetworkStatus?,
        fetcher: Fetcher? = nil,
        clock: @escaping () -> Date = { .now },
        storageQueue: StorageApplyQueue = StorageApplyQueue(),
        hashOriginal: OriginalHasher? = nil
    ) {
        self.catalog = catalog
        self.cache = cache
        self.network = network
        self.fetcher = fetcher ?? Self.liveFetcher
        self.hashOriginal = hashOriginal ?? Self.liveOriginalHasher
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

    /// The entry's refresh state re-read from disk (another window may have written it since it
    /// was cached), updating the cache.
    func reloadedState(for entry: CatalogEntry) -> SubscriptionState {
        let dir = catalog.storage.resourcesDirectory(for: entry)
        let state = SubscriptionStateStore.read(in: dir)
        if states[dir.path] != state {
            states[dir.path] = state
            stateRevision &+= 1
        }
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

    func liveEntry(_ folder: String) -> CatalogEntry? {
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
            guard entry.subscription != nil, inFlight[entry.storageFolderName] == nil else { return false }
            return SubscriptionSchedule.isDue(entry, state: reloadedState(for: entry), now: now)
        }
        let tasks = due.map { begin($0, automatic: true) }
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
        return await begin(live, automatic: false).value
    }

    /// Starts refreshing `entry` (or returns its running refresh) and marks it in flight.
    /// `automatic` is a due check (launch, foreground, timer) rather than Refresh Now.
    private func begin(_ entry: CatalogEntry, automatic: Bool) -> Task<Result<Void, SubscriptionError>, Never> {
        let folder = entry.storageFolderName
        if let running = inFlight[folder] {
            return running
        }
        phases[folder] = .refreshing
        let task = Task { await self.run(entry, automatic: automatic) }
        inFlight[folder] = task
        return task
    }

    private func run(_ entry: CatalogEntry, automatic: Bool) async -> Result<Void, SubscriptionError> {
        let folder = entry.storageFolderName
        var result: Result<Void, SubscriptionError> = .success(())
        if let subscription = entry.subscription {
            let attemptAt = clock()
            // The slot is held from the request until the outcome is recorded (including the
            // wait for the storage queue), so at most `maxParallelFetches` responses are held.
            await fetchSlots.acquire()
            // Things may have changed while waiting for the slot (and, inside `fetch`, while
            // hashing the original): a skipped list is not touched.
            if isStillEligible(folder, subscription: subscription, automatic: automatic),
               let outcome = await fetch(subscription, for: entry, automatic: automatic)
            {
                result = await storageQueue.run {
                    await self.record(outcome, folder: folder, subscription: subscription, attemptAt: attemptAt)
                }
            }
            fetchSlots.release()
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

    /// Whether a refresh that waited (for a fetch slot, or for its original to be hashed)
    /// should still fetch: an automatic one only
    /// while the scene is active and the device online (Refresh Now reports being offline as its
    /// error), and only for a live list that still follows `subscription`'s URL, is not in the
    /// trash and can be written.
    func isStillEligible(_ folder: String, subscription: Subscription, automatic: Bool) -> Bool {
        if automatic, !isSceneActive || network?.isOnline == false {
            return false
        }
        guard let live = liveEntry(folder) else { return false }
        return live.subscription?.url == subscription.url && !live.isTrashed && !live.isReadOnly
    }

    /// Records a fetch outcome against the live entry; runs inside the storage queue. A list
    /// that is gone (out of the catalogue, or its folder deleted while the fetch ran), no longer
    /// online, now follows another URL, or is read-only (sidecar not downloaded or unreadable)
    /// is left untouched: nothing is written and no error recorded.
    private func record(
        _ outcome: FetchOutcome, folder: String, subscription: Subscription, attemptAt: Date
    ) async -> Result<Void, SubscriptionError> {
        guard let live = liveEntry(folder), live.subscription?.url == subscription.url, !live.isReadOnly else {
            return .success(())
        }
        let storage = catalog.storage
        guard !isGone(live, in: storage) else { return .success(()) }
        let dir = storage.resourcesDirectory(for: live)
        var state = reloadedState(for: live)
        if let other = state.lastAttemptAt, other > attemptAt, other <= clock() {
            // Another window checked the list after this fetch started: its outcome stands. A
            // time still in the future is not such a check (the clock was set back since).
            return .success(())
        }
        state.lastAttemptAt = attemptAt
        let failure: SubscriptionError?
        switch outcome {
        case let .unchanged(response, content, hints):
            // A 304 often omits the validators: keep the stored ones then.
            state.etag = response.etag ?? state.etag
            state.lastModified = response.lastModified ?? state.lastModified
            state.httpExpires = response.httpExpires
            if let content {
                state.contentSHA256 = content
            }
            if let hints {
                state.serverMinRefreshPeriod = KMLRefreshHint.sanitised(hints.minRefreshPeriod)
                state.serverExpires = hints.expires
            }
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
                state.serverMinRefreshPeriod = KMLRefreshHint.sanitised(result.networkLinkControl?.minRefreshPeriod)
                state.serverExpires = result.networkLinkControl?.expires
                state.contentSHA256 = result.contentSHA256
            } catch {
                if isGone(live, in: storage) {
                    // Deleted for good while the write ran: nothing to record, nothing to show.
                    return .success(())
                }
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

    /// Whether `entry` was deleted: out of the catalogue, or its folder no longer on disk.
    private func isGone(_ entry: CatalogEntry, in storage: StorageLocations) -> Bool {
        liveEntry(entry.storageFolderName) == nil
            || !FileManager.default.fileExists(atPath: storage.folder(for: entry).path)
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
