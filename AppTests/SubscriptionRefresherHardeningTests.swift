import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// `SubscriptionRefresher` hardening from the final review: absurd hints, validators tied to the
/// bytes on disk, eligibility re-checks after a fetch slot, the bounded pipeline, multi-window
/// state re-reads and quiet failures. Shares the fixtures of `SubscriptionRefresherTests`.
extension SubscriptionRefresherTests {
    // MARK: - Absurd hints (F1)

    @Test func timer_hugeIntervalHint_armsWithoutCrashing() async throws {
        let env = makeEnvironment()
        var prepared = try ImportService.prepare(data: kml(["Old"]), sourceFilename: "feed.kml")
        prepared.subscription = try Subscription(
            url: #require(URL(string: "https://example.test/slow.kml")), origin: .networkLink,
            subscribedAt: Date(timeIntervalSince1970: 1000), refreshMode: .onInterval, refreshInterval: 1e21
        )
        let entry = try ImportService.commit(prepared, storage: env.storage, cache: env.cache)
        SubscriptionStateStore.write(checkedAMinuteAgo, in: env.storage.resourcesDirectory(for: entry))
        await env.catalog.reload()
        let refresher = env.makeRefresher()

        await started(refresher)
        // Let the armed timer task start sleeping: an unclamped delay traps in `Duration.seconds`.
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(env.stub.calls == 0)
        #expect(refresher.isTimerArmed)
        #expect(refresher.nextFireDate == Self.now.addingTimeInterval(KMLRefreshHint.maxSeconds - 60))
        refresher.sceneDidResignActive()
    }

    // MARK: - Validators and the unchanged shortcut follow the bytes on disk (F2)

    @Test func refresh_sidecarAheadOfBytes_repairsOriginal() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env, names: ["New"])
        let entry = try env.entry(folder)
        let current = try env.original(entry)
        // A crash between the sidecar update and the rename: the sidecar names the new bytes,
        // the old bytes are still on disk.
        try kml(["Old"]).write(to: env.storage.originalFile(for: entry))
        env.stub.respond(with: .data(current))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == nil)
        #expect(try env.original(env.entry(folder)) == current)
        let state = SubscriptionStateStore.read(in: env.resources(entry))
        #expect(state.contentSHA256 == entry.contentSHA256)
    }

    @Test func refresh_validatorsSentOnlyForTheBytesOnDisk() async throws {
        let env = makeEnvironment()
        let stale = SubscriptionState(lastAttemptAt: Self.now.addingTimeInterval(-7200), etag: "\"v1\"",
                                      contentSHA256: "not-what-is-on-disk")
        let folder = try await addOnlineList(env, state: stale)
        let entry = try env.entry(folder)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        _ = await refresher.refreshNow(entry)
        #expect(env.stub.calls == 1)
        #expect(env.stub.lastEtag == nil)

        var matching = stale
        matching.contentSHA256 = entry.contentSHA256
        SubscriptionStateStore.write(matching, in: env.resources(entry))
        let fresh = env.makeRefresher()
        _ = await fresh.refreshNow(entry)
        #expect(env.stub.lastEtag == "\"v1\"")
    }

    // MARK: - Server hints on unchanged content (F5)

    @Test func refresh_sameBytes_recordsServerHintsWhenStateLacksThem() async throws {
        let env = makeEnvironment()
        let control = "<NetworkLinkControl><minRefreshPeriod>3600</minRefreshPeriod>"
            + "<expires>2033-05-18T03:33:20Z</expires></NetworkLinkControl>"
        let data = kml(["A"], extra: control)
        var prepared = try ImportService.prepare(data: data, sourceFilename: "feed.kml")
        prepared.subscription = try Subscription(
            url: #require(URL(string: "https://example.test/feed.kml")), origin: .url,
            subscribedAt: Date(timeIntervalSince1970: 1000)
        )
        // A synced device: content and subscription arrived, no local refresh state.
        let committed = try ImportService.commit(prepared, storage: env.storage, cache: env.cache)
        await env.catalog.reload()
        let entry = try env.entry(committed.storageFolderName)
        let originalURL = env.storage.originalFile(for: entry)
        let modifiedBefore = try modificationDate(originalURL)
        let resourcesBefore = try resourceListing(env.resources(entry))
        env.stub.respond(with: .data(data))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == nil)
        let state = SubscriptionStateStore.read(in: env.resources(entry))
        #expect(state.serverMinRefreshPeriod == 3600)
        #expect(state.serverExpires == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(try modificationDate(originalURL) == modifiedBefore)
        #expect(try resourceListing(env.resources(entry)) == resourcesBefore)
    }

    // MARK: - Eligibility after waiting for a fetch slot (F3)

    /// Four due lists: three fetch, the fourth waits for a slot. Returns the folder of the waiting one.
    private func fourDueListsWithThreeInFlight(
        _ env: Environment, _ refresher: SubscriptionRefresher, gate: FetchGate
    ) async throws -> String {
        var folders: [String: String] = [:]
        for index in 0 ..< 4 {
            let url = "https://example.test/\(index).kml"
            folders[url] = try await addOnlineList(env, url: url)
        }
        env.stub.gate = gate
        env.stub.respond(with: .notModified)
        refresher.start()
        await gate.waitForArrivals(3)
        let waiting = try #require(folders.keys.first { !env.stub.urls.contains($0) })
        return try #require(folders[waiting])
    }

    @Test func queuedFetch_stopUpdatingWhileWaiting_neverFetches() async throws {
        let env = makeEnvironment()
        let gate = FetchGate()
        let refresher = env.makeRefresher()
        let waiting = try await fourDueListsWithThreeInFlight(env, refresher, gate: gate)

        try await refresher.stopUpdating(env.entry(waiting))
        await gate.open()
        await refresher.activationTask?.value

        #expect(env.stub.calls == 3)
        #expect(try env.storage.readMetadata(forFolderNamed: waiting)?.subscription == nil)
    }

    @Test func queuedFetch_sceneResignsWhileWaiting_neverFetches() async throws {
        let env = makeEnvironment()
        let gate = FetchGate()
        let refresher = env.makeRefresher()
        _ = try await fourDueListsWithThreeInFlight(env, refresher, gate: gate)

        refresher.sceneDidResignActive()
        await gate.open()
        await refresher.activationTask?.value

        #expect(env.stub.calls == 3)
    }

    // MARK: - Bounded fetch-through-write pipeline (F4)

    @Test func fetchSlot_isHeldUntilTheWriteIsRecorded() async throws {
        let env = makeEnvironment()
        let gate = FetchGate()
        let refresher = env.makeRefresher()
        _ = try await fourDueListsWithThreeInFlight(env, refresher, gate: gate)
        // A storage application starts while the three are downloading: their writes must wait.
        let blocker = QueueBlocker()
        let application = Task { await refresher.storageQueue.run { await blocker.block() } }
        try await waitUntil { blocker.isBlocking }

        await gate.open()
        try await Task.sleep(for: .milliseconds(200))
        // Three responses wait for the queue; the fourth must not be downloaded meanwhile.
        #expect(env.stub.calls == 3)

        blocker.release()
        await application.value
        await refresher.activationTask?.value
        #expect(env.stub.calls == 4)
    }

    // MARK: - Several windows (F9)

    @Test func refreshDue_rereadsStateAnotherWindowWrote() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()
        #expect(refresher.state(for: entry).lastAttemptAt == nil) // cached: never checked
        // Another window's refresher checks the list and records it.
        SubscriptionStateStore.write(checkedAMinuteAgo, in: env.resources(entry))

        await started(refresher)

        #expect(env.stub.calls == 0)
        #expect(refresher.lastSuccess(for: entry) == checkedAMinuteAgo.lastSuccessAt)
        refresher.sceneDidResignActive()
    }

    @Test func record_newerCheckByAnotherWindow_discardsThisOutcome() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let before = try env.original(entry)
        let gate = FetchGate()
        env.stub.gate = gate
        env.stub.respond(with: .data(kml(["Alpha"])))
        let refresher = env.makeRefresher()

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        let other = SubscriptionState(lastAttemptAt: Self.now.addingTimeInterval(1),
                                      lastSuccessAt: Self.now.addingTimeInterval(1))
        SubscriptionStateStore.write(other, in: env.resources(entry))
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(try env.original(env.entry(folder)) == before)
        #expect(SubscriptionStateStore.read(in: env.resources(entry)) == other)
    }

    // MARK: - Deleted mid-write (F10)

    @Test func refresh_listDeletedDuringWrite_failsQuietly() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let gate = FetchGate()
        env.stub.gate = gate
        env.stub.respond(with: .data(kml(["Alpha"])))
        let refresher = env.makeRefresher()

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        // Deleted permanently; the catalogue has not reloaded yet, so the write is attempted.
        try FileManager.default.removeItem(at: env.storage.folder(for: entry))
        try FileManager.default.removeItem(at: env.resources(entry))
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(refresher.phase(for: entry) == .idle)
        #expect(!FileManager.default.fileExists(atPath: env.resources(entry).path))
    }
}

/// Holds a storage-queue operation until released.
@MainActor final class QueueBlocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isBlocking = false

    func block() async {
        isBlocking = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
