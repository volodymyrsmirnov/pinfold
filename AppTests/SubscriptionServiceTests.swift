import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// `SubscriptionURL` and `SubscriptionService`: turning a pasted URL or a network link into an
/// online list. Every test injects a stub fetcher; nothing touches the network.
@Suite(.serialized) @MainActor
struct SubscriptionServiceTests {
    // MARK: - Fixtures

    private nonisolated static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let feedURL = URL(string: "https://example.test/feed.kml")!

    private func kml(_ names: [String], documentName: String = "Feed") -> Data {
        let placemarks = names.enumerated().map { index, name in
            "<Placemark><name>\(name)</name><Point><coordinates>\(index + 1),2,0</coordinates></Point></Placemark>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>\(documentName)</name>\(placemarks)</Document></kml>
        """.utf8)
    }

    private func linkFile(_ hrefs: [String]) -> Data {
        let links = hrefs.enumerated().map { index, href in
            "<NetworkLink><name>L\(index)</name><Link><href>\(href)</href></Link></NetworkLink>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Links</name>\(links)</Document></kml>
        """.utf8)
    }

    private let geoJSON = Data("""
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Quake"},
    "geometry":{"type":"Point","coordinates":[10,20]}}]}
    """.utf8)

    @MainActor private struct Environment {
        let storage: StorageLocations
        let cache: ResourceCache
        let catalog: Catalog
        let coordinator: ImportCoordinator
        let refresher: SubscriptionRefresher
        let stub: SubscribeFetchStub

        var service: SubscriptionService {
            let stub = stub
            return SubscriptionService(
                catalog: catalog, coordinator: coordinator, cache: cache, refresher: refresher,
                fetcher: { url, _, _ in try stub.fetch(url) }
            )
        }

        func sidecar(_ folder: String) throws -> EntryMetadata {
            try #require(try storage.readMetadata(forFolderNamed: folder))
        }

        func entry(_ id: UUID) throws -> CatalogEntry {
            try #require(catalog.entries.first { $0.id == id })
        }
    }

    private func makeEnvironment() -> Environment {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base.appendingPathComponent("synced", isDirectory: true),
                                       cacheRoot: base.appendingPathComponent("cache", isDirectory: true))
        let cache = ResourceCache(downloader: { _ in Data() }, policy: { .never })
        let catalog = Catalog(storage: storage, cache: cache)
        let stub = SubscribeFetchStub()
        // Never started: it must not fetch anything on its own during these tests.
        let refresher = SubscriptionRefresher(
            catalog: catalog, cache: cache, network: nil,
            fetcher: { url, _, _ in try stub.fetch(url) }, clock: { SubscriptionServiceTests.now }
        )
        return Environment(storage: storage, cache: cache, catalog: catalog, coordinator: ImportCoordinator(),
                           refresher: refresher, stub: stub)
    }

    /// Commits `data` as a list (optionally online) and returns it.
    @discardableResult
    private func addList(
        _ env: Environment, data: Data, filename: String = "list.kml", subscription: Subscription? = nil
    ) async throws -> CatalogEntry {
        var prepared = try ImportService.prepare(data: data, sourceFilename: filename)
        prepared.subscription = subscription
        let entry = try ImportService.commit(prepared, storage: env.storage, cache: env.cache)
        await env.catalog.reload()
        return try env.entry(entry.id)
    }

    // MARK: - SubscriptionURL

    @Test func normalise_trimsAndUpgrades() {
        let pasted = "  HTTP://Example.com/a.kml \n"
        #expect(SubscriptionURL.normalise(pasted)?.absoluteString == "https://Example.com/a.kml")
        #expect(SubscriptionURL.normalise("https://example.com/a.kml")?.absoluteString == "https://example.com/a.kml")
    }

    @Test func normalise_rejectsNonHTTP() {
        #expect(SubscriptionURL.normalise("webcal://x") == nil)
        #expect(SubscriptionURL.normalise("file:///x") == nil)
        #expect(SubscriptionURL.normalise("example.com") == nil)
        #expect(SubscriptionURL.normalise("") == nil)
    }

    // MARK: - subscribe

    @Test func subscribe_sameURL_returnsExisting_noFetch() async throws {
        let env = makeEnvironment()
        let online = try await addList(env, data: kml(["A"]), subscription: Subscription(
            url: feedURL, origin: .url, subscribedAt: Date(timeIntervalSince1970: 1000)
        ))

        let outcome = try await env.service.subscribe(to: feedURL, origin: .url)

        #expect(outcome == .existing(online.id))
        #expect(env.stub.calls == 0)
        #expect(env.catalog.entries.count == 1)
    }

    @Test func subscribe_matchesStaticList_converts_keepsNotes() async throws {
        let env = makeEnvironment()
        let data = kml(["A", "B"])
        let list = try await addList(env, data: data)
        let note = PlacemarkNote(text: "Lovely", modifiedAt: Date(timeIntervalSince1970: 5000))
        try env.storage.updateExistingMetadata(forFolderNamed: list.storageFolderName) {
            $0.notes = ["k1": note]
            $0.tags = ["hikes"]
            $0.displayName = "Renamed"
        }
        await env.catalog.reload()
        env.stub.respond(with: data, etag: "\"v1\"")

        let outcome = try await env.service.subscribe(to: feedURL, origin: .url)

        #expect(outcome == .converted(list.id))
        #expect(env.catalog.entries.count == 1)
        let sidecar = try env.sidecar(list.storageFolderName)
        #expect(sidecar.subscription?.url == feedURL)
        #expect(sidecar.subscription?.origin == .url)
        #expect(sidecar.subscription?.subscribedAt == Self.now)
        #expect(sidecar.notes == ["k1": note])
        #expect(sidecar.tags == ["hikes"])
        #expect(sidecar.displayName == "Renamed")
        #expect(try env.entry(list.id).isOnline)
        let state = SubscriptionStateStore.read(in: env.storage.resourcesDirectory(for: list))
        #expect(state.etag == "\"v1\"")
        #expect(state.lastSuccessAt == Self.now)
        #expect(try env.refresher.lastSuccess(for: env.entry(list.id)) == Self.now)
    }

    @Test func subscribe_new_enqueuesAndCommitsWithSubscription_noDuplicatePrompt() async throws {
        let env = makeEnvironment()
        let data = kml(["A"])
        let trashed = try await addList(env, data: data)
        try env.storage.updateExistingMetadata(forFolderNamed: trashed.storageFolderName) {
            $0.trashedAt = Date(timeIntervalSince1970: 3000)
        }
        await env.catalog.reload()
        env.stub.respond(with: data, etag: "\"v1\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT")

        let outcome = try await env.service.subscribe(to: feedURL, origin: .url)
        await env.coordinator.drainForTesting()

        #expect(outcome == .enqueued)
        #expect(env.coordinator.pendingDuplicate == nil)
        #expect(env.catalog.entries.count == 2)
        let added = try #require(env.catalog.entries.first { $0.id != trashed.id })
        #expect(added.subscription?.url == feedURL)
        #expect(added.subscription?.origin == .url)
        #expect(added.displayName == "Feed")
        #expect(!added.isTrashed)
        #expect(try env.sidecar(added.storageFolderName).subscription == added.subscription)
        let state = SubscriptionStateStore.read(in: env.storage.resourcesDirectory(for: added))
        #expect(state.etag == "\"v1\"")
        #expect(state.lastModified == "Wed, 21 Oct 2026 07:28:00 GMT")
        #expect(state.lastAttemptAt == Self.now)
        #expect(try #require(env.catalog.entries.first { $0.id == trashed.id }).subscription == nil)
    }

    @Test func subscribe_geoJSON_works() async throws {
        let env = makeEnvironment()
        let url = try #require(URL(string: "https://example.test/quakes.geojson"))
        env.stub.respond(with: geoJSON)

        let outcome = try await env.service.subscribe(to: url, origin: .url)
        await env.coordinator.drainForTesting()

        #expect(outcome == .enqueued)
        let added = try #require(env.catalog.entries.first)
        #expect(added.subscription?.url == url)
        #expect(added.sourceFilename == "quakes.geojson")
        #expect(added.pointCount == 1)
        #expect(env.stub.urls == [url.absoluteString])
    }

    @Test func subscribe_fromLink_copiesHints() async throws {
        let env = makeEnvironment()
        let link = KMLNetworkLink(name: "Live", href: feedURL.absoluteString, refreshMode: .onInterval,
                                  refreshInterval: 60)
        env.stub.respond(with: kml(["A"]))

        let outcome = try await env.service.subscribe(to: feedURL, origin: .networkLink, link: link)
        await env.coordinator.drainForTesting()

        #expect(outcome == .enqueued)
        let subscription = try #require(env.catalog.entries.first?.subscription)
        #expect(subscription.origin == .networkLink)
        #expect(subscription.refreshMode == .onInterval)
        #expect(subscription.refreshInterval == 60)
    }

    @Test func subscribe_linkOnlyResponse_throws() async throws {
        let env = makeEnvironment()
        env.stub.respond(with: linkFile(["https://other.test/a.kml"]))

        await #expect(throws: SubscriptionError.linkOnly) {
            try await env.service.subscribe(to: feedURL, origin: .url)
        }
        await env.coordinator.drainForTesting()
        #expect(env.catalog.entries.isEmpty)
        #expect(!env.coordinator.isImporting)
    }

    @Test func subscribe_httpError_throws() async throws {
        let env = makeEnvironment()
        env.stub.fail(with: DownloadError.httpStatus(404))

        await #expect(throws: SubscriptionError.http(404)) {
            try await env.service.subscribe(to: feedURL, origin: .url)
        }
        #expect(env.catalog.entries.isEmpty)
    }

    // MARK: - subscribeInPlace

    @Test func subscribeInPlace_replacesOriginalAndSetsSubscriptionWithHints() async throws {
        let env = makeEnvironment()
        let entry = try await addList(env, data: linkFile(["http://example.test/feed.kml"]), filename: "links.kml")
        let link = KMLNetworkLink(name: "Feed", href: "http://example.test/feed.kml", refreshMode: .onInterval,
                                  refreshInterval: 120)
        let fetched = kml(["A", "B"])
        env.stub.respond(with: fetched, etag: "\"v2\"")

        let outcome = try await env.service.subscribeInPlace(entry, link: link)

        #expect(outcome == .converted(entry.id))
        #expect(env.stub.urls == ["https://example.test/feed.kml"])
        let live = try env.entry(entry.id)
        #expect(try Data(contentsOf: env.storage.originalFile(for: live)) == fetched)
        #expect(live.pointCount == 2)
        #expect(live.contentSHA256 == ImportService.sha256Hex(fetched))
        let subscription = try #require(live.subscription)
        #expect(subscription.url == feedURL)
        #expect(subscription.origin == .networkLink)
        #expect(subscription.refreshMode == .onInterval)
        #expect(subscription.refreshInterval == 120)
        #expect(live.displayName == entry.displayName)
        #expect(env.catalog.entries.count == 1)
        let state = SubscriptionStateStore.read(in: env.storage.resourcesDirectory(for: live))
        #expect(state.etag == "\"v2\"")
    }

    @Test func subscribeInPlace_urlAlreadyFollowed_returnsExisting_leavesEntryUntouched() async throws {
        let env = makeEnvironment()
        let online = try await addList(env, data: kml(["A"]), subscription: Subscription(
            url: feedURL, origin: .url, subscribedAt: Date(timeIntervalSince1970: 1000)
        ))
        let entry = try await addList(env, data: linkFile(["http://example.test/feed.kml"]), filename: "links.kml")
        let originalBefore = try Data(contentsOf: env.storage.originalFile(for: entry))
        let sidecarBefore = try env.sidecar(entry.storageFolderName)
        let link = KMLNetworkLink(name: "Feed", href: "http://example.test/feed.kml")

        let outcome = try await env.service.subscribeInPlace(entry, link: link)

        #expect(outcome == .existing(online.id))
        #expect(env.stub.calls == 0)
        #expect(try Data(contentsOf: env.storage.originalFile(for: entry)) == originalBefore)
        #expect(try env.sidecar(entry.storageFolderName) == sidecarBefore)
        #expect(env.catalog.entries.count == 2)
    }

    @Test func subscribeInPlace_readOnly_throwsWithoutFetching() async throws {
        let env = makeEnvironment()
        var entry = try await addList(env, data: linkFile([feedURL.absoluteString]), filename: "links.kml")
        entry.sidecarState = .unreadable
        let link = KMLNetworkLink(name: nil, href: feedURL.absoluteString)

        await #expect(throws: SubscriptionError.readOnly) {
            try await SubscriptionService(
                catalog: Catalog(storage: env.storage), coordinator: env.coordinator, cache: env.cache,
                refresher: env.refresher, fetcher: { url, _, _ in try env.stub.fetch(url) }
            ).subscribeInPlace(entry, link: link)
        }
        #expect(env.stub.calls == 0)
    }

    // MARK: - Consent

    @Test func nothingIsFetchedWithoutCall() async throws {
        let env = makeEnvironment()
        _ = env.service
        let entry = try await addList(env, data: linkFile([feedURL.absoluteString]), filename: "links.kml")
        let document = try KMLReader.readDocument(data: Data(contentsOf: env.storage.originalFile(for: entry)))

        #expect(NetworkLinkOffer(document: document) != nil)
        #expect(env.stub.calls == 0)
        #expect(env.catalog.entries.count == 1)
    }

    // MARK: - Overlapping subscribes (F7)

    @Test func subscribe_overlappingSameURL_makesOneList() async throws {
        let env = makeEnvironment()
        env.stub.respond(with: kml(["A"]))
        let service = env.service

        let first = Task { try await service.subscribe(to: feedURL, origin: .url) }
        let second = Task { try await service.subscribe(to: feedURL, origin: .url) }
        _ = try await first.value
        _ = try await second.value
        await env.coordinator.drainForTesting()

        #expect(env.catalog.entries.count == 1)
        #expect(env.catalog.entries.first?.subscription?.url == feedURL)
        #expect(env.stub.calls == 1)
    }

    @Test func subscribe_linkCardAndURLAlertOverlapping_makesOneOnlineList() async throws {
        let env = makeEnvironment()
        let links = try await addList(env, data: linkFile([feedURL.absoluteString]), filename: "links.kml")
        let link = KMLNetworkLink(name: "Feed", href: feedURL.absoluteString)
        env.stub.respond(with: kml(["A"]))
        let service = env.service

        let card = Task { try await service.subscribeInPlace(links, link: link) }
        let alert = Task { try await service.subscribe(to: feedURL, origin: .url) }
        _ = try await card.value
        _ = try await alert.value
        await env.coordinator.drainForTesting()

        #expect(env.catalog.entries.count { $0.subscription?.url == feedURL } == 1)
        #expect(env.stub.calls == 1)
    }

    @Test func subscribe_whileTheSameURLIsOnTheImportQueue_doesNotEnqueueAgain() async throws {
        let env = makeEnvironment()
        env.stub.respond(with: kml(["A"]))
        env.coordinator.hold() // e.g. a storage application is running: the item waits queued

        #expect(try await env.service.subscribe(to: feedURL, origin: .url) == .enqueued)
        #expect(try await env.service.subscribe(to: feedURL, origin: .url) == .enqueued)
        env.coordinator.release(catalog: env.catalog, cache: env.cache)
        await env.coordinator.drainForTesting()

        #expect(env.catalog.entries.count == 1)
        #expect(env.stub.calls == 1)
    }
}

// MARK: - Stub fetcher

private final class SubscribeFetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var response: Result<ConditionalResponse, Error> = .failure(DownloadError.httpStatus(404))
    private var recorded: [String] = []

    var calls: Int {
        lock.withLock { recorded.count }
    }

    var urls: [String] {
        lock.withLock { recorded }
    }

    func respond(with data: Data, etag: String? = nil, lastModified: String? = nil) {
        lock.withLock {
            response = .success(ConditionalResponse(body: .data(data), etag: etag, lastModified: lastModified,
                                                    httpExpires: nil))
        }
    }

    func fail(with error: Error) {
        lock.withLock { response = .failure(error) }
    }

    func fetch(_ url: URL) throws -> ConditionalResponse {
        try lock.withLock {
            recorded.append(url.absoluteString)
            return try response.get()
        }
    }
}
