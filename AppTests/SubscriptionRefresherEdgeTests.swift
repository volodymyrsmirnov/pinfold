import Foundation
@testable import Pinfold
import Testing

/// `SubscriptionRefresher` edge cases from the second final review: eligibility re-checked after
/// hashing the original, a stored attempt time in the future, a list deleted during a fetch that
/// writes nothing, and an unreadable original. Shares the fixtures of `SubscriptionRefresherTests`.
extension SubscriptionRefresherTests {
    /// Hashes the original like the live hasher, after waiting at `gate`.
    func gatedHasher(_ gate: FetchGate) -> SubscriptionRefresher.OriginalHasher {
        { url in
            await gate.arrive()
            return (try? Data(contentsOf: url)).map(ImportService.sha256Hex)
        }
    }

    // MARK: - Eligibility after hashing (G1)

    @Test func dueCheck_sceneResignsWhileHashing_neverFetches() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let gate = FetchGate()
        env.stub.respond(with: .notModified)
        let refresher = env.makeRefresher(hasher: gatedHasher(gate))

        refresher.start()
        await gate.waitForArrivals(1)
        refresher.sceneDidResignActive()
        await gate.open()
        await refresher.activationTask?.value

        #expect(env.stub.calls == 0)
        #expect(SubscriptionStateStore.read(in: env.resources(entry)).lastAttemptAt == nil)
        #expect(refresher.phase(for: entry) == .idle)
    }

    @Test func refreshNow_stopUpdatingWhileHashing_neverFetches() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let gate = FetchGate()
        env.stub.respond(with: .data(kml(["Alpha"])))
        let refresher = env.makeRefresher(hasher: gatedHasher(gate))

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        try await refresher.stopUpdating(entry)
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(env.stub.calls == 0)
        #expect(try env.storage.readMetadata(forFolderNamed: folder)?.subscription == nil)
    }

    // MARK: - A stored attempt in the future (G4)

    /// The clock was set back after the last check: Refresh Now must still apply what it fetched.
    @Test func refreshNow_storedAttemptInTheFuture_appliesTheOutcome() async throws {
        let env = makeEnvironment()
        let future = SubscriptionState(lastAttemptAt: Self.now.addingTimeInterval(86400),
                                       lastSuccessAt: Self.now.addingTimeInterval(86400))
        let folder = try await addOnlineList(env, state: future)
        let entry = try env.entry(folder)
        let new = kml(["Alpha", "Beta"])
        env.stub.respond(with: .data(new))
        let refresher = env.makeRefresher()

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == nil)
        #expect(try env.original(env.entry(folder)) == new)
        #expect(SubscriptionStateStore.read(in: env.resources(entry)).lastAttemptAt == Self.now)
    }

    // MARK: - Deleted during a fetch that writes no content (G6)

    private func deleteDuringFetch(respond: (FetchStub) -> Void) async throws -> (Environment, CatalogEntry) {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let gate = FetchGate()
        env.stub.gate = gate
        respond(env.stub)
        let refresher = env.makeRefresher()

        let inFlight = Task { await refresher.refreshNow(entry) }
        await gate.waitForArrivals(1)
        // Deleted permanently; the catalogue has not reloaded yet.
        try FileManager.default.removeItem(at: env.storage.folder(for: entry))
        try FileManager.default.removeItem(at: env.resources(entry))
        await gate.open()
        let result = await inFlight.value

        #expect(failure(of: result) == nil)
        #expect(refresher.phase(for: entry) == .idle)
        return (env, entry)
    }

    @Test func refresh_listDeletedDuringA304_doesNotRecreateResources() async throws {
        let (env, entry) = try await deleteDuringFetch { $0.respond(with: .notModified) }
        #expect(!FileManager.default.fileExists(atPath: env.resources(entry).path))
    }

    @Test func refresh_listDeletedDuringAFailedFetch_doesNotRecreateResources() async throws {
        let (env, entry) = try await deleteDuringFetch { $0.fail(with: DownloadError.httpStatus(500)) }
        #expect(!FileManager.default.fileExists(atPath: env.resources(entry).path))
    }

    // MARK: - Unreadable original (G7)

    /// The original can't be read (an iCloud placeholder): bytes matching the sidecar's hash are
    /// unchanged content, so nothing is rewritten and `resources/` is not rebuilt.
    @Test func refresh_unreadableOriginal_sameBytesAsSidecar_noRewrite() async throws {
        let env = makeEnvironment()
        let folder = try await addOnlineList(env)
        let entry = try env.entry(folder)
        let originalURL = env.storage.originalFile(for: entry)
        let modifiedBefore = try modificationDate(originalURL)
        let resourcesBefore = try resourceListing(env.resources(entry))
        try env.stub.respond(with: .data(env.original(entry)))
        let refresher = env.makeRefresher(hasher: { _ in nil })

        let result = await refresher.refreshNow(entry)

        #expect(failure(of: result) == nil)
        #expect(try modificationDate(originalURL) == modifiedBefore)
        #expect(try resourceListing(env.resources(entry)) == resourcesBefore)
        #expect(SubscriptionStateStore.read(in: env.resources(entry)).lastSuccessAt == Self.now)
    }
}

/// A settable clock for refreshers whose time must move during a test.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
