import Foundation
@testable import Pinfold
import Testing

/// Tests for `StorageResolver`: which root to run on, and the recovery decision when iCloud
/// comes back. Temp roots only; no iCloud is touched. The live container is a device item.
struct StorageResolverTests {
    private struct FakeUbiquity: UbiquityProviding {
        var documents: URL?
        var token: Data?

        func documentsURL() -> URL? {
            documents
        }

        func identityToken() -> Data? {
            token
        }
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func resolver(documents: URL?, local: URL) -> StorageResolver {
        StorageResolver(
            ubiquity: FakeUbiquity(documents: documents, token: Data("me".utf8)),
            local: StorageLocations(root: local),
            makeSynced: { StorageLocations(root: $0, cacheRoot: $0.appendingPathComponent("cache")) }
        )
    }

    private func seed(_ root: URL, folder: String) throws {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kml".utf8).write(to: dir.appendingPathComponent("f.kml"))
    }

    @Test func syncOff_isLocal() {
        let local = tempRoot()
        let result = resolver(documents: tempRoot(), local: local).resolve(syncEnabled: false)
        #expect(result.status == .off)
        #expect(result.storage.root == local)
    }

    @Test func syncOnWithContainer_isICloud() {
        let docs = tempRoot()
        let result = resolver(documents: docs, local: tempRoot()).resolve(syncEnabled: true)
        #expect(result.status == .active)
        #expect(result.storage.root == docs)
        #expect(result.identityToken == Data("me".utf8))
    }

    @Test func syncOnWithoutContainer_isUnavailableOnLocalRoot() {
        let local = tempRoot()
        let result = resolver(documents: nil, local: local).resolve(syncEnabled: true)
        #expect(result.status == .unavailable)
        #expect(result.storage.root == local)
        #expect(!result.isUbiquitous)
    }

    @Test func recoveryDecision() {
        #expect(StorageResolver.shouldRecover(previous: .unavailable, resolved: .active))
        #expect(StorageResolver.shouldRecover(previous: nil, resolved: .active))
        #expect(!StorageResolver.shouldRecover(previous: .active, resolved: .active))
        #expect(!StorageResolver.shouldRecover(previous: .off, resolved: .active))
        #expect(!StorageResolver.shouldRecover(previous: .unavailable, resolved: .unavailable))
        #expect(!StorageResolver.shouldRecover(previous: .unavailable, resolved: .off))
    }

    @Test func recovery_migratesStrandedEntriesThenSwitches() throws {
        let local = tempRoot()
        let docs = tempRoot()
        try seed(local, folder: "A")
        try seed(local, folder: "B")
        let resolver = resolver(documents: docs, local: local)
        #expect(StorageResolver.hasStrandedEntries(in: resolver.local))

        let resolution = resolver.resolve(syncEnabled: true)
        let report = try StorageResolver.recoverStranded(
            from: resolver.local, to: resolution.storage, toUbiquitous: false
        )

        #expect(Set(report.moved) == ["A", "B"])
        #expect(report.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("A/f.kml").path))
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("A").path))
        #expect(!StorageResolver.hasStrandedEntries(in: resolver.local))
        #expect(resolution.status == .active)
    }

    @Test func recovery_withNothingStranded_justSwitches() throws {
        let local = tempRoot()
        let docs = tempRoot()
        try seed(docs, folder: "Remote")
        let resolver = resolver(documents: docs, local: local)
        #expect(!StorageResolver.hasStrandedEntries(in: resolver.local))

        let report = try StorageResolver.recoverStranded(
            from: resolver.local, to: resolver.resolve(syncEnabled: true).storage, toUbiquitous: false
        )
        #expect(report.moved.isEmpty && report.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("Remote/f.kml").path))
    }
}
