import Foundation
@testable import Pinfold
import Testing

/// `SubscriptionRefresher` decisions that must not trust a stale catalogue (third final review):
/// a reload overtaken by a newer one returns without publishing, so after Stop Updating or a
/// trash the catalogue can still show the old entry. Also a `304` to a request without
/// validators, and a list deleted right after its content write. Shares the fixtures of
/// `SubscriptionRefresherTests`.
extension SubscriptionRefresherTests {
    /// Keeps every catalogue reload from publishing (a newer one always overtakes it) until
    /// cancelled.
    func overtakeReloads(_ catalog: Catalog) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                catalog.scanGeneration &+= 1
                await Task.yield()
            }
        }
    }

    /// Stop Updating whose own reload is overtaken: the catalogue still shows the subscription.
    func stopWithStaleCatalogue(_ refresher: SubscriptionRefresher, _ env: Environment, _ entry: CatalogEntry)
        async throws
    {
        let overtaker = overtakeReloads(env.catalog)
        try await refresher.stopUpdating(entry)
        overtaker.cancel()
        await overtaker.value
        // The scenario held: the stop is on disk but not in the catalogue.
        #expect(try env.storage.readMetadata(forFolderNamed: entry.storageFolderName)?.subscription == nil)
        #expect(try env.entry(entry.storageFolderName).subscription != nil)
    }

    func stateFileExists(_ env: Environment, _ entry: CatalogEntry) -> Bool {
        let stateFile = env.resources(entry).appendingPathComponent(SubscriptionStateStore.filename)
        return FileManager.default.fileExists(atPath: stateFile.path)
    }

    // MARK: - Stop Updating with a stale catalogue (H1)

    @Test func stopUpdatingWhileHashing_staleCatalogue_neverFetches() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let before = try env.original(entry)
        let gate = FetchGate()
        env.stub.respond(with: .data(kml(["Alpha"])))
        let refresher = env.makeRefresher(hasher: gatedHasher(gate))

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        try await stopWithStaleCatalogue(refresher, env, entry)
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(env.stub.calls == 0)
        #expect(try env.original(entry) == before)
        #expect(try env.storage.readMetadata(forFolderNamed: folder)?.subscription == nil)
        #expect(!stateFileExists(env, entry))
    }

    @Test func stopUpdatingWhileFetching_staleCatalogue_discardsTheResult() async throws {
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
        try await stopWithStaleCatalogue(refresher, env, entry)
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(try env.original(entry) == before)
        #expect(try env.storage.readMetadata(forFolderNamed: folder)?.subscription == nil)
        #expect(!stateFileExists(env, entry))
        #expect(refresher.phase(for: entry) == .idle)
    }

    /// A refresh that starts after Stop Updating, while the catalogue still shows the
    /// subscription, sends no request.
    @Test func refreshAfterStopUpdating_staleCatalogue_neverFetches() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        env.stub.respond(with: .data(kml(["Alpha"])))
        let refresher = env.makeRefresher()

        try await stopWithStaleCatalogue(refresher, env, entry)
        let result = try await refresher.refreshNow(env.entry(folder))

        #expect(failure(of: result) == nil)
        #expect(env.stub.calls == 0)
        #expect(!stateFileExists(env, entry))
    }

    /// Once the catalogue shows the stop, a later subscribe of the same list in another way (a
    /// synced device) refreshes again: the stop marker does not outlive its purpose.
    @Test func stoppedList_resubscribedOnDisk_refreshesAgainOnceShown() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let subscription = try #require(entry.subscription)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        try await refresher.stopUpdating(entry)
        #expect(try env.entry(folder).subscription == nil)
        try env.storage.updateExistingMetadata(forFolderNamed: folder) { $0.subscription = subscription }
        await env.catalog.reload()
        _ = try await refresher.refreshNow(env.entry(folder))

        #expect(env.stub.calls == 1)
    }

    // MARK: - Trash with a stale catalogue (H1)

    @Test func trashedWhileFetching_staleCatalogue_discardsTheResult() async throws {
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
        // Trashed on disk; the catalogue has not published it.
        try env.storage.updateExistingMetadata(forFolderNamed: folder) { $0.trashedAt = Self.now }
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(try env.original(entry) == before)
        #expect(!stateFileExists(env, entry))
        #expect(try env.storage.readMetadata(forFolderNamed: folder)?.subscription != nil)
    }

    // MARK: - A 304 without validators (H4)

    /// No validators were sent (no stored state describes the original), so a `304` verifies
    /// nothing: it is an error, as on the subscribe path.
    @Test func refresh_304WithoutValidators_isAnError() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(env.stub.lastEtag == nil)
        #expect(failure(of: result) == .http(304))
        let state = SubscriptionStateStore.read(in: env.resources(entry))
        #expect(state.lastSuccessAt == nil)
        #expect(state.lastError != nil)
    }

    /// Matching content but no stored validators: no conditional header goes out, so an
    /// unrequested `304` verifies nothing and is a failure, not a check (K2).
    @Test func refresh_304WithMatchingContentButNoValidators_isAnError() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let state = SubscriptionState(
            lastAttemptAt: Date(timeIntervalSince1970: 1000), contentSHA256: entry.contentSHA256
        )
        SubscriptionStateStore.write(state, in: env.resources(entry))
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(env.stub.lastEtag == nil)
        #expect(failure(of: result) == .http(304))
        #expect(SubscriptionStateStore.read(in: env.resources(entry)).lastSuccessAt == nil)
    }

    // MARK: - Deleted right after the content write (H5)

    @Test func refresh_listDeletedAfterTheContentWrite_doesNotRecreateResources() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let new = kml(["Alpha", "Beta"])
        let newSHA = ImportService.sha256Hex(new)
        env.stub.respond(with: .data(new))
        let refresher = env.makeRefresher()
        let resources = env.resources(entry)
        let folderURL = env.storage.folder(for: entry)
        // Deletes the list for good as soon as the refresh's derived data is written, before the
        // refresh records its state.
        let deleter = Task { @MainActor in
            while !Task.isCancelled {
                if PlacemarkIndex.sourceStamp(in: resources) == newSHA {
                    try? FileManager.default.removeItem(at: folderURL)
                    try? FileManager.default.removeItem(at: resources)
                    return
                }
                await Task.yield()
            }
        }

        let result = await refresher.refreshNow(entry)
        deleter.cancel()
        await deleter.value

        #expect(failure(of: result) == nil)
        #expect(!FileManager.default.fileExists(atPath: folderURL.path))
        #expect(!FileManager.default.fileExists(atPath: resources.path))
    }
}
