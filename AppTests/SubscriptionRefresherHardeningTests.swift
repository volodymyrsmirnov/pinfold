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
}
