import Foundation
@testable import Pinfold
import Testing

/// `SubscriptionRefresher`: fetches due online lists through a stub fetcher, writes changed
/// content, records per-device state and arms the in-session timer. Nothing touches the network.
@Suite(.serialized) @MainActor
struct SubscriptionRefresherTests {
    // MARK: - Fixtures

    nonisolated static let now = Date(timeIntervalSince1970: 2_000_000_000)

    func kml(_ names: [String], extra: String = "") -> Data {
        let placemarks = names.enumerated().map { index, name in
            "<Placemark><name>\(name)</name><Point><coordinates>\(index + 1),2,0</coordinates></Point></Placemark>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">\(extra)<Document><name>Feed</name>\(placemarks)</Document></kml>
        """.utf8)
    }

    @MainActor struct Environment {
        let storage: StorageLocations
        let cache: ResourceCache
        let catalog: Catalog
        let stub: FetchStub

        func entry(_ folder: String) throws -> CatalogEntry {
            try #require(catalog.entries.first { $0.storageFolderName == folder })
        }

        func resources(_ entry: CatalogEntry) -> URL {
            storage.resourcesDirectory(for: entry)
        }

        func original(_ entry: CatalogEntry) throws -> Data {
            try Data(contentsOf: storage.originalFile(for: entry))
        }

        func makeRefresher(network: NetworkStatus? = nil) -> SubscriptionRefresher {
            let stub = stub
            return SubscriptionRefresher(
                catalog: catalog, cache: cache, network: network,
                fetcher: { url, etag, lastModified in try await stub.fetch(url, etag: etag, lastModified: lastModified) },
                clock: { SubscriptionRefresherTests.now }
            )
        }
    }

    func makeEnvironment() -> Environment {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base.appendingPathComponent("synced", isDirectory: true),
                                       cacheRoot: base.appendingPathComponent("cache", isDirectory: true))
        let cache = ResourceCache(downloader: { _ in Data() }, policy: { .never })
        return Environment(storage: storage, cache: cache, catalog: Catalog(storage: storage, cache: cache),
                           stub: FetchStub())
    }

    /// Commits a subscribed list for `url` and returns its folder name.
    @discardableResult
    func addOnlineList(_ env: Environment, url: String = "https://example.test/feed.kml",
                       names: [String] = ["Old"], state: SubscriptionState? = nil) async throws -> String
    {
        var prepared = try ImportService.prepare(data: kml(names), sourceFilename: "feed.kml")
        prepared.subscription = try Subscription(url: #require(URL(string: url)), origin: .url,
                                                 subscribedAt: Date(timeIntervalSince1970: 1000))
        let entry = try ImportService.commit(prepared, storage: env.storage, cache: env.cache)
        if let state {
            SubscriptionStateStore.write(state, in: env.storage.resourcesDirectory(for: entry))
        }
        await env.catalog.reload()
        return entry.storageFolderName
    }

    /// A state that makes a list not due for about an hour.
    var checkedAMinuteAgo: SubscriptionState {
        SubscriptionState(lastAttemptAt: Self.now.addingTimeInterval(-60),
                          lastSuccessAt: Self.now.addingTimeInterval(-60))
    }

    func started(_ refresher: SubscriptionRefresher) async {
        refresher.start()
        await refresher.activationTask?.value
    }

    // MARK: - Start

    @Test func nothingFetchedBeforeStart() async throws {
        let env = makeEnvironment()
        try await addOnlineList(env)
        let refresher = env.makeRefresher()

        refresher.sceneDidBecomeActive()
        await refresher.activationTask?.value
        await refresher.refreshDue()
        refresher.rearm()

        #expect(env.stub.calls == 0)
        #expect(refresher.nextFireDate == nil)
    }

    @Test func refreshDue_onlyDueEntries() async throws {
        let env = makeEnvironment()
        try await addOnlineList(env, url: "https://example.test/recent.kml", state: checkedAMinuteAgo)
        try await addOnlineList(env, url: "https://example.test/never.kml")
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        await started(refresher)

        #expect(env.stub.urls == ["https://example.test/never.kml"])
    }

    // MARK: - Outcomes

    @Test func refresh_304_updatesStateOnly() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        // The validators describe the original on disk, so they are sent.
        let old = SubscriptionState(lastAttemptAt: Self.now.addingTimeInterval(-7200), etag: "\"v1\"",
                                    lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
                                    contentSHA256: entry.contentSHA256)
        SubscriptionStateStore.write(old, in: env.resources(entry))
        let before = try env.original(entry)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect((try? result.get()) != nil)
        let state = SubscriptionStateStore.read(in: env.resources(entry))
        #expect(state.lastSuccessAt == Self.now)
        #expect(state.lastAttemptAt == Self.now)
        #expect(state.etag == "\"v1\"")
        #expect(state.lastModified == "Wed, 21 Oct 2026 07:28:00 GMT")
        #expect(state.lastError == nil)
        #expect(try env.original(entry) == before)
        #expect(env.stub.lastEtag == "\"v1\"")
        #expect(refresher.lastSuccess(for: entry) == Self.now)
        #expect(refresher.phase(for: entry) == .idle)
    }

    @Test func refresh_sameSHA_noWrite() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let originalURL = env.storage.originalFile(for: entry)
        let sentinel = env.resources(entry).appendingPathComponent("stale-icon.png")
        try Data("old".utf8).write(to: sentinel)
        let modifiedBefore = try modificationDate(originalURL)
        let resourcesBefore = try resourceListing(env.resources(entry))
        try env.stub.respond(with: .data(env.original(entry)))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect((try? result.get()) != nil)
        #expect(try modificationDate(originalURL) == modifiedBefore)
        #expect(try resourceListing(env.resources(entry)) == resourcesBefore)
        #expect(SubscriptionStateStore.read(in: env.resources(entry)).lastSuccessAt == Self.now)
    }

    @Test func refresh_changed_replacesAndKeepsAnnotations() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let note = PlacemarkNote(text: "Bring water", modifiedAt: Date(timeIntervalSince1970: 2000), placemarkName: "Old")
        try env.storage.updateExistingMetadata(forFolderNamed: folder) { metadata in
            metadata.displayName = "My Trail Feed"
            metadata.notes = ["key-1": note]
            metadata.favoriteKeys = ["key-1"]
            metadata.tags = ["hiking"]
        }
        await env.catalog.reload()
        let entry = try env.entry(folder)
        let new = kml(["Alpha", "Beta"],
                      extra: "<NetworkLinkControl><minRefreshPeriod>600</minRefreshPeriod></NetworkLinkControl>")
        env.stub.respond(with: .data(new), etag: "\"v2\"")
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect((try? result.get()) != nil)
        let after = try #require(try env.storage.readMetadata(forFolderNamed: folder))
        #expect(after.displayName == "My Trail Feed")
        #expect(after.notes == ["key-1": note])
        #expect(after.favoriteKeys == ["key-1"])
        #expect(after.tags == ["hiking"])
        #expect(after.subscription != nil)
        #expect(after.pointCount == 2)
        let reloaded = try env.entry(folder)
        #expect(reloaded.pointCount == 2)
        #expect(reloaded.displayName == "My Trail Feed")
        #expect(try env.original(reloaded) == new)
        let state = SubscriptionStateStore.read(in: env.resources(reloaded))
        #expect(state.etag == "\"v2\"")
        #expect(state.serverMinRefreshPeriod == 600)
        #expect(state.lastError == nil)
        let names = PlacemarkIndexStore.shared.snapshot(for: env.resources(reloaded))?.entries.map(\.name)
        #expect(names?.sorted() == ["Alpha", "Beta"])
    }

    @Test func refresh_htmlBody_keepsContentAndRecordsError() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let before = try env.original(entry)
        let html = "<!DOCTYPE html><html><head><title>Sign in</title></head><body><p>Wi-Fi login</p></body></html>"
        env.stub.respond(with: .data(Data(html.utf8)))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == .notSupported)
        let message = "The server didn't return a KML, KMZ, GPX or GeoJSON file."
        #expect(SubscriptionError.notSupported.errorDescription == message)
        #expect(refresher.phase(for: entry) == .failed(message))
        #expect(try env.original(entry) == before)
        #expect(try env.entry(folder).contentSHA256 == entry.contentSHA256)
        let state = SubscriptionStateStore.read(in: env.resources(entry))
        #expect(state.lastError == message)
        #expect(state.lastAttemptAt == Self.now)
    }

    @Test func refresh_linkOnly_isError() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let before = try env.original(entry)
        let linkOnly = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Links</name>
        <NetworkLink><name>Next</name><Link><href>https://example.test/next.kml</href></Link></NetworkLink>
        </Document></kml>
        """.utf8)
        env.stub.respond(with: .data(linkOnly))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == .linkOnly)
        #expect(SubscriptionError.linkOnly.errorDescription == "The server returned a file that only links to other files.")
        #expect(try env.original(entry) == before)
        #expect(env.stub.calls == 1)
    }

    @Test func refresh_http500_recordsError() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        env.stub.fail(with: DownloadError.httpStatus(500))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == .http(500))
        let state = SubscriptionStateStore.read(in: env.resources(entry))
        #expect(state.lastError != nil)
        #expect(state.lastSuccessAt == nil)
        guard case .failed = refresher.phase(for: entry) else {
            Issue.record("expected a failed phase")
            return
        }
    }

    @Test func refresh_trashedEntry_skipped() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        try await env.catalog.moveToTrash(env.entry(folder))
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        await started(refresher)

        #expect(env.stub.calls == 0)
    }

    @Test func refresh_stopUpdatingMidFlight_doesNotRestoreSubscription() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let before = try env.original(entry)
        let gate = FetchGate()
        env.stub.gate = gate
        env.stub.respond(with: .data(kml(["Alpha", "Beta"])))
        let refresher = env.makeRefresher()

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        try await refresher.stopUpdating(entry)
        await gate.open()
        _ = await inFlight.value

        let after = try #require(try env.storage.readMetadata(forFolderNamed: folder))
        #expect(after.subscription == nil)
        #expect(try env.original(env.entry(folder)) == before)
        #expect(try env.entry(folder).subscription == nil)
        let stateFile = env.resources(entry).appendingPathComponent(SubscriptionStateStore.filename)
        #expect(!FileManager.default.fileExists(atPath: stateFile.path))
    }

    @Test func refresh_readOnlyMidFlight_discardsSilently() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let before = try env.original(entry)
        let gate = FetchGate()
        env.stub.gate = gate
        env.stub.respond(with: .data(kml(["Alpha", "Beta"])))
        let refresher = env.makeRefresher()

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        // The sidecar becomes unreadable (e.g. a newer schema synced in): the entry is read-only.
        try Data("{".utf8).write(to: env.storage.metadataFile(for: entry))
        await env.catalog.reload()
        #expect(try env.entry(folder).isReadOnly)
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(refresher.phase(for: entry) == .idle)
        #expect(try env.original(entry) == before)
        let stateFile = env.resources(entry).appendingPathComponent(SubscriptionStateStore.filename)
        #expect(!FileManager.default.fileExists(atPath: stateFile.path))
    }

    @Test func refreshNow_readOnly_returnsErrorWithoutFetchingOrFailing() async throws {
        let env = makeEnvironment()
        let refresher = env.makeRefresher()
        let placeholder = try CatalogEntry(
            id: UUID(), displayName: "Synced", sourceFilename: "feed.kml", importDate: .now, pointCount: 0,
            contentSHA256: "", storageFolderName: UUID().uuidString, trashedAt: nil,
            subscription: Subscription(url: #require(URL(string: "https://example.test/feed.kml")),
                                       origin: .url, subscribedAt: .now),
            sidecarState: .notDownloaded
        )

        let result = await refresher.refreshNow(placeholder)

        #expect(failure(of: result) == .readOnly)
        #expect(env.stub.calls == 0)
        #expect(refresher.phase(for: placeholder) == .idle)
    }

    // MARK: - In flight

    @Test func refreshDue_twiceConcurrently_fetchesOnce() async throws {
        let env = makeEnvironment()
        try await addOnlineList(env)
        // Opens by itself on a second fetch, so a missing in-flight check fails instead of hanging.
        let gate = FetchGate(autoOpenAt: 2)
        env.stub.gate = gate
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        refresher.start() // the launch check fetches the never-checked list and is held at the gate
        let launch = refresher.activationTask
        await gate.waitForArrivals(1)
        refresher.sceneDidBecomeActive() // the app comes back to the foreground meanwhile
        await refresher.activationTask?.value
        await refresher.refreshDue()
        await gate.open()
        await launch?.value

        #expect(env.stub.calls == 1)
    }

    @Test func refreshNow_ignoresDueButNotInFlight() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env, state: checkedAMinuteAgo)
        let entry = try env.entry(folder)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        _ = await refresher.refreshNow(entry)
        #expect(env.stub.calls == 1)

        let gate = FetchGate(autoOpenAt: 3)
        env.stub.gate = gate
        let first = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        let second = Task { await refresher.refreshNow(entry) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(refresher.phase(for: entry) == .refreshing)
        await gate.open()
        _ = await first.value
        _ = await second.value

        #expect(env.stub.calls == 2)
    }

    @Test func refreshDue_atMostThreeFetchesAtOnce() async throws {
        let env = makeEnvironment()
        for index in 0 ..< 5 {
            try await addOnlineList(env, url: "https://example.test/\(index).kml")
        }
        let gate = FetchGate()
        env.stub.gate = gate
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        refresher.start()
        await gate.waitForArrivals(3)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(await gate.arrivals == 3)
        await gate.open()
        await refresher.activationTask?.value

        #expect(env.stub.calls == 5)
        #expect(env.stub.maxConcurrent == 3)
    }

    // MARK: - Timer

    @Test func timer_armsForEarliestDue_andCancelsOnResign() async throws {
        let env = makeEnvironment()
        // Due in 50 minutes and in 10 minutes.
        try await addOnlineList(env, url: "https://example.test/a.kml", state: SubscriptionState(
            lastAttemptAt: Self.now.addingTimeInterval(-600), lastSuccessAt: Self.now.addingTimeInterval(-600)
        ))
        try await addOnlineList(env, url: "https://example.test/b.kml", state: SubscriptionState(
            lastAttemptAt: Self.now.addingTimeInterval(-3000), lastSuccessAt: Self.now.addingTimeInterval(-3000)
        ))
        let refresher = env.makeRefresher()

        await started(refresher)

        #expect(env.stub.calls == 0)
        #expect(refresher.nextFireDate == Self.now.addingTimeInterval(600))
        #expect(refresher.isTimerArmed)

        refresher.sceneDidResignActive()
        #expect(!refresher.isTimerArmed)
        #expect(refresher.nextFireDate == nil)

        refresher.sceneDidBecomeActive()
        await refresher.activationTask?.value
        #expect(refresher.isTimerArmed)
    }

    @Test func staleActivation_afterResign_armsNothingAndFetchesNothing() async throws {
        let env = makeEnvironment()
        try await addOnlineList(env, url: "https://example.test/recent.kml", state: checkedAMinuteAgo)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()
        await started(refresher)
        #expect(refresher.isTimerArmed)
        refresher.sceneDidResignActive() // the app goes to the background
        try await addOnlineList(env, url: "https://example.test/due.kml") // a due list syncs in

        let token = refresher.activationToken // `.active` arrives; RootView reads the token
        refresher.sceneDidResignActive() // a quick swipe before the deferred activation runs
        refresher.sceneDidBecomeActive(token: token)
        await refresher.activationTask?.value

        #expect(env.stub.calls == 0)
        #expect(!refresher.isTimerArmed)
        #expect(refresher.nextFireDate == nil)

        // A current token activates as usual.
        refresher.sceneDidBecomeActive(token: refresher.activationToken)
        await refresher.activationTask?.value
        #expect(env.stub.urls == ["https://example.test/due.kml"])
        #expect(refresher.isTimerArmed)
    }

    @Test func timer_neverSoonerThanFloor() async throws {
        let env = makeEnvironment()
        // Failed 4 minutes ago: due again in 1 minute, but the timer waits for the floor.
        try await addOnlineList(env, state: SubscriptionState(
            lastAttemptAt: Self.now.addingTimeInterval(-240), lastError: "offline"
        ))
        let refresher = env.makeRefresher()

        await started(refresher)

        #expect(env.stub.calls == 0)
        #expect(refresher.nextFireDate == Self.now.addingTimeInterval(SubscriptionSchedule.floor))
    }

    @Test func offline_skipsAndRearmsOnline() async throws {
        let env = makeEnvironment()
        try await addOnlineList(env)
        env.stub.respond(with: .notModified)
        let network = NetworkStatus(isOnline: false)
        let refresher = env.makeRefresher(network: network)

        await started(refresher)
        #expect(env.stub.calls == 0)
        #expect(!refresher.isTimerArmed)

        network.update(isOnline: true)
        try await waitUntil { env.stub.calls == 1 && refresher.isTimerArmed }

        #expect(env.stub.calls == 1)
        #expect(refresher.isTimerArmed)
    }

    // MARK: - Stop Updating

    @Test func stopUpdating_clearsSubscriptionAndState() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env, state: checkedAMinuteAgo)
        let entry = try env.entry(folder)
        let refresher = env.makeRefresher()
        await started(refresher)
        #expect(refresher.isTimerArmed)

        try await refresher.stopUpdating(entry)

        #expect(try env.storage.readMetadata(forFolderNamed: folder)?.subscription == nil)
        #expect(try env.entry(folder).subscription == nil)
        #expect(SubscriptionStateStore.read(in: env.resources(entry)) == SubscriptionState())
        #expect(!refresher.isTimerArmed)
    }

    // MARK: - Helpers

    func failure(of result: Result<Void, SubscriptionError>) -> SubscriptionError? {
        if case let .failure(error) = result {
            error
        } else {
            nil
        }
    }

    func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Every file in `dir` but the refresh state, with its modification date.
    func resourceListing(_ dir: URL) throws -> [String: Date] {
        var listing: [String: Date] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            where name != SubscriptionStateStore.filename
        {
            listing[name] = try modificationDate(dir.appendingPathComponent(name))
        }
        return listing
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Stub fetcher

/// Records every fetch and answers with a canned response, optionally holding at a gate.
final class FetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var response: Result<ConditionalResponse, Error> = .failure(DownloadError.httpStatus(404))
    private var recorded: [String] = []
    private var etags: [String?] = []
    private var running = 0
    private var peak = 0
    private var gateStorage: FetchGate?

    var gate: FetchGate? {
        get { lock.withLock { gateStorage } }
        set { lock.withLock { gateStorage = newValue } }
    }

    var calls: Int {
        lock.withLock { recorded.count }
    }

    var urls: [String] {
        lock.withLock { recorded }
    }

    var lastEtag: String? {
        lock.withLock { etags.last ?? nil }
    }

    var maxConcurrent: Int {
        lock.withLock { peak }
    }

    func respond(with body: ConditionalResponse.Body, etag: String? = nil) {
        lock.withLock {
            response = .success(ConditionalResponse(body: body, etag: etag, lastModified: nil, httpExpires: nil))
        }
    }

    func fail(with error: Error) {
        lock.withLock { response = .failure(error) }
    }

    func fetch(_ url: URL, etag: String?, lastModified _: String?) async throws -> ConditionalResponse {
        let gate = lock.withLock {
            recorded.append(url.absoluteString)
            etags.append(etag)
            running += 1
            peak = max(peak, running)
            return gateStorage
        }
        await gate?.arrive()
        let response = lock.withLock {
            running -= 1
            return self.response
        }
        return try response.get()
    }
}

/// Holds fetches until opened. With `autoOpenAt`, it opens once that many fetches have arrived.
actor FetchGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private let autoOpenAt: Int?
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(autoOpenAt: Int? = nil) {
        self.autoOpenAt = autoOpenAt
    }

    func arrive() async {
        arrivals += 1
        let ready = watchers.filter { $0.count <= arrivals }
        watchers.removeAll { $0.count <= arrivals }
        ready.forEach { $0.continuation.resume() }
        if let autoOpenAt, arrivals >= autoOpenAt {
            open()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }
}
