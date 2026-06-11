import Foundation
@testable import Pinfold
import Testing

/// Tests for `PendingImportInbox` — inbox draining, dedup, empty inbox, and resilience
/// against malformed files.
@Suite(.serialized) @MainActor struct PendingImportInboxTests {
    // MARK: - Helpers

    /// A fully-wired test environment: an inbox plus the temp directories and failure log it
    /// imports into, so tests can inject I/O failures (chmod the root) and assert on failures.
    private struct Environment {
        let inbox: PendingImportInbox
        let catalog: Catalog
        let inboxURL: URL
        let storageRoot: URL
        let failureLog: ImportFailureLog
    }

    /// Creates a fresh `Catalog`, a temp storage root, a temp inbox directory, and a wired
    /// `PendingImportInbox` with a failure log.
    private func makeEnvironment() throws -> Environment {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = tempBase.appendingPathComponent("storage", isDirectory: true)
        let inboxURL = tempBase.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        // Pre-create the storage root so it can be made read-only for I/O-failure injection.
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let storage = StorageLocations(root: storageRoot)
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)
        let failureLog = ImportFailureLog()

        let inbox = PendingImportInbox(
            inboxURL: inboxURL,
            catalog: catalog,
            storage: storage,
            cache: cache,
            failureLog: failureLog
        )
        return Environment(
            inbox: inbox,
            catalog: catalog,
            inboxURL: inboxURL,
            storageRoot: storageRoot,
            failureLog: failureLog
        )
    }

    /// Copies fixture bytes into the inbox directory under the given filename.
    private func copyFixture(
        named fixtureName: String,
        as destName: String,
        into inboxURL: URL
    ) throws {
        let data = try AppFixture.data(fixtureName)
        try data.write(to: inboxURL.appendingPathComponent(destName))
    }

    // MARK: - Tests

    @Test func drain_singleFile_importsOneEntryAndRemovesFile() async throws {
        let env = try makeEnvironment()
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)

        let count = await env.inbox.drain()

        #expect(count == 1, "drain() should return 1 for a single new file")
        #expect(env.catalog.active.count == 1, "Exactly one active entry must exist after import")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty after a successful drain")
    }

    @Test func drain_duplicateContent_skipsSecondImportAndReturnsZero() async throws {
        let env = try makeEnvironment()

        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)
        let firstCount = await env.inbox.drain()
        #expect(firstCount == 1, "First drain must import exactly 1 file")

        // Same bytes again under a different name.
        try copyFixture(named: "Rome.kml", as: "Rome-copy.kml", into: env.inboxURL)
        let secondCount = await env.inbox.drain()

        #expect(secondCount == 0, "Second drain of identical content must return 0 (dedup)")
        #expect(env.catalog.active.count == 1, "Only one entry must exist after dedup")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty after the second drain")
    }

    @Test func drain_nonExistentInbox_returnsZeroWithoutThrowing() async {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nonExistentInbox = tempBase.appendingPathComponent("DoesNotExist", isDirectory: true)
        let storage = StorageLocations(root: tempBase.appendingPathComponent("storage", isDirectory: true))
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)

        let inbox = PendingImportInbox(
            inboxURL: nonExistentInbox,
            catalog: catalog,
            storage: storage,
            cache: cache
        )
        let count = await inbox.drain()
        #expect(count == 0, "Draining a non-existent inbox must return 0")
    }

    @Test func drain_emptyInbox_returnsZero() async throws {
        let env = try makeEnvironment()
        let count = await env.inbox.drain()
        #expect(count == 0, "Draining an empty inbox must return 0")
    }

    @Test func drain_malformedFileAlongsideValid_importsValidAndRemovesBoth() async throws {
        let env = try makeEnvironment()

        try Data("garbage not kml".utf8).write(to: env.inboxURL.appendingPathComponent("bad.kml"))
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)

        let count = await env.inbox.drain()

        #expect(count == 1, "Only the valid file should be imported; malformed skipped")
        #expect(env.catalog.active.count == 1, "Exactly one active entry after mixed drain")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty: both files (valid + malformed) removed")
    }

    @Test func drain_parseFailure_recordsFailureAndRemovesFile() async throws {
        let env = try makeEnvironment()
        // Garbage bytes that cannot be parsed as KML or KMZ.
        try Data("garbage not kml".utf8).write(to: env.inboxURL.appendingPathComponent("bad.kml"))

        let count = await env.inbox.drain()

        #expect(count == 0, "A parse failure imports nothing")
        // Parse failure is permanent → file removed so it is not retried forever.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "A permanently-failing (parse) file must be removed")
        // Failure recorded with the filename and a reason.
        #expect(env.failureLog.failures.count == 1, "The parse failure must be recorded")
        #expect(env.failureLog.failures.first?.filename == "bad.kml")
        #expect(env.failureLog.failures.first?.reason.isEmpty == false, "A reason must be recorded")
    }

    @Test func drain_ioFailure_keepsFileForRetry() async throws {
        let env = try makeEnvironment()
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)

        // Make the storage root read-only so commit (folder creation / file writes) fails with
        // an I/O error — a transient failure that should keep the file for a later retry.
        // (Precedent: WP-D's chmod-based injection in StorageMigrationTests.)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.storageRoot.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: env.storageRoot.path
            )
        }

        let count = await env.inbox.drain()

        #expect(count == 0, "An I/O failure imports nothing")
        // I/O failure is transient → file KEPT so a later drain can retry it.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining == ["Rome.kml"], "A transiently-failing file must be kept for retry")
        #expect(env.failureLog.failures.count == 1, "The I/O failure must be recorded")
        #expect(env.failureLog.failures.first?.filename == "Rome.kml")
    }

    @Test func drain_twoIdenticalFilesInOneBatch_importsOnlyOne() async throws {
        let env = try makeEnvironment()
        // Same bytes under two names, both present for a single drain. The catalogue is not
        // reloaded until the end of the drain, so dedup must happen within the batch.
        try copyFixture(named: "Rome.kml", as: "Rome-a.kml", into: env.inboxURL)
        try copyFixture(named: "Rome.kml", as: "Rome-b.kml", into: env.inboxURL)

        let count = await env.inbox.drain()

        #expect(count == 1, "Two identical files in one batch must import only once")
        #expect(env.catalog.active.count == 1, "Only one entry must exist after same-batch dedup")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Both inbox files must be removed")
    }
}
