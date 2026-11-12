import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// `NetworkLinkSnapshotService`: the one-time, user-confirmed download for network-link files.
/// Every test injects a stub downloader; nothing touches the network.
@Suite(.serialized) @MainActor
struct NetworkLinkSnapshotTests {
    // MARK: - Fixtures

    private nonisolated static func linkFile(_ hrefs: [String]) -> Data {
        let links = hrefs.enumerated().map { index, href in
            "<NetworkLink><name>L\(index)</name><Link><href>\(href)</href></Link></NetworkLink>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Links</name>\(links)</Document></kml>
        """.utf8)
    }

    private nonisolated static func placemarkFile(_ name: String, lon: Double = 1) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>\(name)</name>
        <Placemark><name>\(name)</name><Point><coordinates>\(lon),2,0</coordinates></Point></Placemark>
        </Document></kml>
        """.utf8)
    }

    private struct Environment {
        let storage: StorageLocations
        let cache: ResourceCache
        let catalog: Catalog
        let entry: CatalogEntry
    }

    private func makeEnvironment(hrefs: [String]) async throws -> Environment {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base.appendingPathComponent("synced", isDirectory: true),
                                       cacheRoot: base.appendingPathComponent("cache", isDirectory: true))
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)
        let prepared = try ImportService.prepare(data: Self.linkFile(hrefs), sourceFilename: "links.kml")
        try ImportService.commit(prepared, storage: storage, cache: cache)
        await catalog.reload()
        let first = try #require(catalog.entries.first)
        return Environment(storage: storage, cache: cache, catalog: catalog, entry: first)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            urls.append(url)
        }

        var all: [URL] {
            lock.lock(); defer { lock.unlock() }
            return urls
        }
    }

    private func service(
        calls: Calls = Calls(), maxBytes: Int = NetworkLinkSnapshotService.defaultMaxBytes,
        respond: @escaping @Sendable (URL) throws -> Data
    ) -> NetworkLinkSnapshotService {
        NetworkLinkSnapshotService(maxBytes: maxBytes) { url in
            calls.record(url)
            return try respond(url)
        }
    }

    private let link = KMLNetworkLink(name: "Data", href: "https://example.test/data.kml")

    // MARK: - Single link

    @Test func singleLink_replacesOriginalAndUpdatesSidecar() async throws {
        let env = try await makeEnvironment(hrefs: [link.href])
        let stale = env.storage.resourcesDirectory(for: env.entry).appendingPathComponent("stale.txt")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale)
        let downloaded = Self.placemarkFile("Fresh")

        let updated = try await service { _ in downloaded }
            .replaceOriginal(of: env.entry, with: link, storage: env.storage, catalog: env.catalog)

        #expect(try Data(contentsOf: env.storage.originalFile(for: updated)) == downloaded)
        let sidecar = try #require(try env.storage.readMetadata(forFolderNamed: env.entry.storageFolderName))
        #expect(sidecar.pointCount == 1)
        #expect(sidecar.contentSHA256 == ImportService.sha256Hex(downloaded))
        #expect(sidecar.sourceFilename == updated.sourceFilename)
        #expect(sidecar.displayName == env.entry.displayName)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(env.catalog.entries.first?.pointCount == 1)
    }

    @Test func httpLinkIsUpgradedToHttps() async throws {
        let env = try await makeEnvironment(hrefs: ["http://example.test/data.kml"])
        let calls = Calls()
        let insecure = KMLNetworkLink(name: nil, href: "http://example.test/data.kml")
        _ = try await service(calls: calls) { _ in Self.placemarkFile("A") }
            .replaceOriginal(of: env.entry, with: insecure, storage: env.storage, catalog: env.catalog)
        #expect(calls.all.map(\.absoluteString) == ["https://example.test/data.kml"])
    }

    @Test func downloadThatIsNotKML_leavesEntryUntouched() async throws {
        let env = try await makeEnvironment(hrefs: [link.href])
        let before = try Data(contentsOf: env.storage.originalFile(for: env.entry))
        let sidecarBefore = try env.storage.readMetadata(forFolderNamed: env.entry.storageFolderName)

        await #expect(throws: NetworkLinkSnapshotService.SnapshotError.notKML) {
            try await service { _ in Data("<html><body>nope</body></html>".utf8) }
                .replaceOriginal(of: env.entry, with: link, storage: env.storage, catalog: env.catalog)
        }
        #expect(try Data(contentsOf: env.storage.originalFile(for: env.entry)) == before)
        #expect(try env.storage.readMetadata(forFolderNamed: env.entry.storageFolderName) == sidecarBefore)
    }

    @Test func http404_surfacesReadableError() async throws {
        let env = try await makeEnvironment(hrefs: [link.href])
        do {
            _ = try await service { _ in throw DownloadError.httpStatus(404) }
                .replaceOriginal(of: env.entry, with: link, storage: env.storage, catalog: env.catalog)
            Issue.record("expected a failure")
        } catch {
            #expect(error == .http(404))
            #expect(error.localizedDescription.contains("404"))
        }
    }

    @Test func oversizeDownloadIsRejected() async throws {
        let env = try await makeEnvironment(hrefs: [link.href])
        let before = try Data(contentsOf: env.storage.originalFile(for: env.entry))
        // The downloader reports it, and a downloader that ignores the cap is caught too.
        await #expect(throws: NetworkLinkSnapshotService.SnapshotError.tooLarge) {
            try await service { _ in throw DownloadError.tooLarge }
                .replaceOriginal(of: env.entry, with: link, storage: env.storage, catalog: env.catalog)
        }
        await #expect(throws: NetworkLinkSnapshotService.SnapshotError.tooLarge) {
            try await service(maxBytes: 10) { _ in Self.placemarkFile("Big") }
                .replaceOriginal(of: env.entry, with: link, storage: env.storage, catalog: env.catalog)
        }
        #expect(try Data(contentsOf: env.storage.originalFile(for: env.entry)) == before)
    }

    @Test func readOnlyEntryIsNotReplaced() async throws {
        let env = try await makeEnvironment(hrefs: [link.href])
        var readOnly = env.entry
        readOnly.sidecarState = .unreadable
        let calls = Calls()
        await #expect(throws: NetworkLinkSnapshotService.SnapshotError.readOnly) {
            try await service(calls: calls) { _ in Self.placemarkFile("A") }
                .replaceOriginal(of: readOnly, with: link, storage: env.storage, catalog: Catalog(storage: env.storage))
        }
        #expect(calls.all.isEmpty)
    }

    // MARK: - Several links

    @Test func multipleLinks_enqueueSeparateImports() async throws {
        let hrefs = ["https://one.test/a.kml", "https://two.test/b.kml"]
        let env = try await makeEnvironment(hrefs: hrefs)
        let linkFileBefore = try Data(contentsOf: env.storage.originalFile(for: env.entry))
        let links = hrefs.map { KMLNetworkLink(name: nil, href: $0) }
        let coordinator = ImportCoordinator()

        let outcome = await service { url in Self.placemarkFile(url.host() ?? "x", lon: url.host() == "one.test" ? 1 : 5) }
            .enqueueSnapshots(for: links, coordinator: coordinator, catalog: env.catalog, cache: env.cache)
        await coordinator.drainForTesting()

        #expect(outcome.enqueued == 2)
        #expect(outcome.failures.isEmpty)
        #expect(env.catalog.entries.count == 3)
        #expect(try Data(contentsOf: env.storage.originalFile(for: env.entry)) == linkFileBefore)
    }

    // MARK: - Consent

    @Test func nothingIsFetchedWithoutConfirmation() throws {
        let calls = Calls()
        _ = service(calls: calls) { _ in Data() }
        let parsed = try KMLReader.read(data: Self.linkFile(["http://one.test/a.kml", "ftp://x.test/y", "file:///etc/passwd"]))

        let offer = try #require(NetworkLinkOffer(document: parsed.document))
        #expect(offer.links.count == 1)
        #expect(offer.hosts == ["one.test"])
        #expect(offer.isSingle)
        #expect(calls.all.isEmpty)

        let withPlacemarks = try KMLReader.read(data: Self.placemarkFile("A"))
        #expect(NetworkLinkOffer(document: withPlacemarks.document) == nil)
    }
}
