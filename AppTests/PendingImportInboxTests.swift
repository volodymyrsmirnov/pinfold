import Foundation
@testable import Pinfold
import Testing

/// Tests for `PendingImportInbox` — inbox draining, dedup, empty inbox, and resilience
/// against malformed files.
@Suite(.serialized) @MainActor struct PendingImportInboxTests {
    // MARK: - Helpers

    /// Creates a fresh `Catalog`, a temp storage root, and a temp inbox directory.
    private func makeEnvironment() throws -> (
        inbox: PendingImportInbox,
        catalog: Catalog,
        inboxURL: URL
    ) {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageRoot = tempBase.appendingPathComponent("storage", isDirectory: true)
        let inboxURL = tempBase.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

        let storage = StorageLocations(root: storageRoot)
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)

        let inbox = PendingImportInbox(
            inboxURL: inboxURL,
            catalog: catalog,
            storage: storage,
            cache: cache
        )
        return (inbox, catalog, inboxURL)
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
        let (inbox, catalog, inboxURL) = try makeEnvironment()
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: inboxURL)

        let count = await inbox.drain()

        #expect(count == 1, "drain() should return 1 for a single new file")
        #expect(catalog.active.count == 1, "Exactly one active entry must exist after import")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty after a successful drain")
    }

    @Test func drain_duplicateContent_skipsSecondImportAndReturnsZero() async throws {
        let (inbox, catalog, inboxURL) = try makeEnvironment()

        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: inboxURL)
        let firstCount = await inbox.drain()
        #expect(firstCount == 1, "First drain must import exactly 1 file")

        // Same bytes again under a different name.
        try copyFixture(named: "Rome.kml", as: "Rome-copy.kml", into: inboxURL)
        let secondCount = await inbox.drain()

        #expect(secondCount == 0, "Second drain of identical content must return 0 (dedup)")
        #expect(catalog.active.count == 1, "Only one entry must exist after dedup")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: inboxURL.path)
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
        let (inbox, _, _) = try makeEnvironment()
        let count = await inbox.drain()
        #expect(count == 0, "Draining an empty inbox must return 0")
    }

    @Test func drain_malformedFileAlongsideValid_importsValidAndRemovesBoth() async throws {
        let (inbox, catalog, inboxURL) = try makeEnvironment()

        try Data("garbage not kml".utf8).write(to: inboxURL.appendingPathComponent("bad.kml"))
        try copyFixture(named: "Rome.kml", as: "Rome.kml", into: inboxURL)

        let count = await inbox.drain()

        #expect(count == 1, "Only the valid file should be imported; malformed skipped")
        #expect(catalog.active.count == 1, "Exactly one active entry after mixed drain")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: inboxURL.path)
        #expect(remaining.isEmpty, "Inbox must be empty: both files (valid + malformed) removed")
    }

    @Test func drain_twoIdenticalFilesInOneBatch_importsOnlyOne() async throws {
        let (inbox, catalog, inboxURL) = try makeEnvironment()
        // Same bytes under two names, both present for a single drain. The catalogue is not
        // reloaded until the end of the drain, so dedup must happen within the batch.
        try copyFixture(named: "Rome.kml", as: "Rome-a.kml", into: inboxURL)
        try copyFixture(named: "Rome.kml", as: "Rome-b.kml", into: inboxURL)

        let count = await inbox.drain()

        #expect(count == 1, "Two identical files in one batch must import only once")
        #expect(catalog.active.count == 1, "Only one entry must exist after same-batch dedup")

        let remaining = try FileManager.default.contentsOfDirectory(atPath: inboxURL.path)
        #expect(remaining.isEmpty, "Both inbox files must be removed")
    }
}
