import Foundation
@testable import Pinfold
import Testing

/// `ResourceRevisions`: a manifest change re-renders the views of that entry only, so an image
/// downloaded after a view first rendered (e.g. after Clear Downloaded Images) shows up live.
/// Each test uses its own temporary directory, so the shared instance's counters never collide.
@MainActor
struct ResourceRevisionsTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Waits past the coalescing delay for the scheduled flush to run on the main actor.
    private func settle() async throws {
        try await Task.sleep(for: ResourceRevisions.coalescingDelay * 3)
    }

    @Test func manifestChangeBumpsTheEntrysRevision() async throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        let revisions = ResourceRevisions.shared
        let before = revisions.revision(for: dir)
        let otherBefore = revisions.revision(for: other)

        try ResourceManifestStore.shared.updateManifest(in: dir) { $0["https://example.com/a.png"] = "a.png" }
        try await settle()

        #expect(revisions.revision(for: dir) > before)
        #expect(revisions.revision(for: other) == otherBefore)
    }

    @Test func unchangedManifestDoesNotBump() async throws {
        let dir = try makeTempDir()
        try ResourceManifestStore.shared.updateManifest(in: dir) { $0["k"] = "v" }
        try await settle()
        let settled = ResourceRevisions.shared.revision(for: dir)

        try ResourceManifestStore.shared.updateManifest(in: dir) { $0["k"] = "v" }
        try await settle()

        #expect(ResourceRevisions.shared.revision(for: dir) == settled)
    }

    @Test func clearingDownloadsBumpsTheRevision() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/icon.png"
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("icon.png"))
        try ResourceManifestStore.shared.updateManifest(in: dir) { $0[href] = "icon.png" }
        try await settle()
        let before = ResourceRevisions.shared.revision(for: dir)

        ResourceCache().clearDownloaded(in: dir)
        try await settle()

        #expect(ResourceRevisions.shared.revision(for: dir) > before)
    }

    @Test func burstOfChangesIsCoalesced() async throws {
        let dir = try makeTempDir()
        let before = ResourceRevisions.shared.revision(for: dir)
        for index in 0 ..< 20 {
            try ResourceManifestStore.shared.updateManifest(in: dir) { $0["href-\(index)"] = "file-\(index)" }
        }
        try await settle()

        let bumps = ResourceRevisions.shared.revision(for: dir) - before
        #expect(bumps >= 1)
        #expect(bumps < 20)
    }
}
