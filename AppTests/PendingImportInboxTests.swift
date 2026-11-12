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
        let coordinator: ImportCoordinator
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

        let coordinator = ImportCoordinator(failureLog: failureLog)
        let inbox = PendingImportInbox(
            inboxURL: inboxURL,
            coordinator: coordinator,
            catalog: catalog,
            cache: cache
        )
        return Environment(
            inbox: inbox,
            coordinator: coordinator,
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

    /// Scans the inbox (enqueueing on the coordinator) and waits for the queue to settle.
    /// Returns the number of files the scan enqueued.
    @discardableResult
    private func drainAndSettle(_ env: Environment) async -> Int {
        let enqueued = env.inbox.drain()
        await env.coordinator.drainForTesting()
        return enqueued
    }

    // MARK: - Tests

    @Test func drain_singleFile_importsOneEntryAndRemovesFile() async throws {
        let env = try makeEnvironment()
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)

        let count = await drainAndSettle(env)

        #expect(count == 1, "drain() should enqueue 1 file")
        #expect(env.catalog.active.count == 1, "Exactly one active entry must exist after import")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty after a successful drain")
    }

    @Test func drain_ignoresPartialShareCopies() async throws {
        let env = try makeEnvironment()
        try Data("<kml".utf8).write(to: env.inboxURL.appendingPathComponent(".abc.partial"))
        try Data("<kml".utf8).write(to: env.inboxURL.appendingPathComponent("visible.partial"))

        let count = await drainAndSettle(env)

        #expect(count == 0)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.count == 2, "half-written copies are neither imported nor deleted")
    }

    @Test func drain_duplicateContent_skipsSecondImportSilently() async throws {
        let env = try makeEnvironment()

        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)
        await drainAndSettle(env)
        #expect(env.catalog.active.count == 1, "First drain must import exactly 1 file")

        // Same bytes again under a different name.
        try copyFixture(named: "Rome.kml", as: "Rome-copy.kml", into: env.inboxURL)
        await drainAndSettle(env)

        #expect(env.catalog.active.count == 1, "Only one entry must exist after dedup")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty after the second drain")
    }

    @Test func drain_nonExistentInbox_returnsZeroWithoutThrowing() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nonExistentInbox = tempBase.appendingPathComponent("DoesNotExist", isDirectory: true)
        let storage = StorageLocations(root: tempBase.appendingPathComponent("storage", isDirectory: true))
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)

        let inbox = PendingImportInbox(
            inboxURL: nonExistentInbox,
            coordinator: ImportCoordinator(),
            catalog: catalog,
            cache: cache
        )
        let count = inbox.drain()
        #expect(count == 0, "Draining a non-existent inbox must return 0")
    }

    @Test func drain_emptyInbox_returnsZero() async throws {
        let env = try makeEnvironment()
        let count = await drainAndSettle(env)
        #expect(count == 0, "Draining an empty inbox must return 0")
    }

    @Test func drain_malformedFileAlongsideValid_importsValidAndRemovesBoth() async throws {
        let env = try makeEnvironment()

        try Data("garbage not kml".utf8).write(to: env.inboxURL.appendingPathComponent("bad.kml"))
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)

        await drainAndSettle(env)

        #expect(env.catalog.active.count == 1, "Only the valid file should be imported; malformed skipped")
        #expect(env.catalog.active.count == 1, "Exactly one active entry after mixed drain")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty: both files (valid + malformed) removed")
    }

    @Test func drain_parseFailure_recordsFailureAndRemovesFile() async throws {
        let env = try makeEnvironment()
        // Garbage bytes that cannot be parsed as KML or KMZ.
        try Data("garbage not kml".utf8).write(to: env.inboxURL.appendingPathComponent("bad.kml"))

        await drainAndSettle(env)

        #expect(env.catalog.active.isEmpty, "A parse failure imports nothing")
        // Parse failure is permanent → file removed so it is not retried forever.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "A permanently-failing (parse) file must be removed")
        // Failure recorded with the filename and a reason.
        #expect(env.failureLog.failures.count == 1, "The parse failure must be recorded")
        #expect(env.failureLog.failures.first?.filename == "bad.kml")
        #expect(env.failureLog.failures.first?.reason.isEmpty == false, "A reason must be recorded")
        #expect(env.failureLog.failures.first?.reason.contains("NSXMLParserErrorDomain") == false)
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

        await drainAndSettle(env)

        #expect(env.catalog.active.isEmpty, "An I/O failure imports nothing")
        // I/O failure is transient → file KEPT so a later drain can retry it.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining == ["Rome.kml"], "A transiently-failing file must be kept for retry")
        #expect(env.failureLog.failures.count == 1, "The I/O failure must be recorded")
        #expect(env.failureLog.failures.first?.filename == "Rome.kml")
    }

    @Test func drain_concurrentCallsImportOnce() async throws {
        let env = try makeEnvironment()
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: env.inboxURL)

        // Two scans back to back, before the first file is imported. Without the queue's
        // queued-path guard both would enqueue the same file, so it would import twice.
        let first = env.inbox.drain()
        let second = env.inbox.drain()
        await env.coordinator.drainForTesting()
        #expect(first == 1)
        #expect(second == 0, "a file already queued must not be enqueued again")

        let folders = try FileManager.default.contentsOfDirectory(atPath: env.storageRoot.path)
            .filter { !$0.hasPrefix(".") }
        #expect(folders.count == 1, "Concurrent drains of one file must produce exactly one entry folder")
    }

    @Test func drain_twoIdenticalFilesInOneBatch_importsOnlyOne() async throws {
        let env = try makeEnvironment()
        // Same bytes under two names, both present for a single drain. The catalogue is not
        // reloaded until the end of the drain, so dedup must happen within the batch.
        try copyFixture(named: "Rome.kml", as: "Rome-a.kml", into: env.inboxURL)
        try copyFixture(named: "Rome.kml", as: "Rome-b.kml", into: env.inboxURL)

        await drainAndSettle(env)

        #expect(env.catalog.entries.count == 1, "Two identical files in one batch must import only once")
        #expect(env.catalog.active.count == 1, "Only one entry must exist after same-batch dedup")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: env.inboxURL.path)
        #expect(remaining.isEmpty, "Both inbox files must be removed")
    }

    @Test func sharedFileWithoutDocumentName_usesCleanFilenameAsTitle() async throws {
        let env = try makeEnvironment()
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
          <Placemark><Point><coordinates>1,2,0</coordinates></Point></Placemark>
        </Document></kml>
        """
        let name = "0F8FAD5B-D9CB-469F-A165-70867728950E-Weekend Walk.kml"
        try Data(kml.utf8).write(to: env.inboxURL.appendingPathComponent(name))

        await drainAndSettle(env)

        #expect(env.catalog.active.first?.displayName == "Weekend Walk")
        #expect(env.catalog.active.first?.sourceFilename == "Weekend Walk.kml")
    }
}
