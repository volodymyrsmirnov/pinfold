import Foundation

extension StorageLocations {
    /// Serialises in-process sidecar read-modify-write cycles (UI edits and the background
    /// snapshot task); `NSFileCoordinator` covers other processes and the iCloud daemon.
    private static let sidecarUpdateLock = NSLock()

    /// Reads the sidecar, applies `mutate`, and writes it back, preserving every field
    /// the caller does not touch. No-op if the sidecar is absent. Use this instead of
    /// reconstructing `EntryMetadata` from an in-memory `CatalogEntry` (which does not
    /// carry the favorite/visited sets and would clobber them).
    ///
    /// The read and the write happen inside **one** coordinated write (`.forMerging`), so a
    /// concurrent update of another field is never overwritten with a stale copy.
    func updateMetadata(forFolderNamed name: String, _ mutate: (inout EntryMetadata) -> Void) throws {
        _ = try updateSidecar(forFolderNamed: name, mutate)
    }

    /// Like `updateMetadata`, but throws `CocoaError(.fileNoSuchFile)` when the sidecar is
    /// absent instead of silently doing nothing. For callers (the network-link snapshot) that
    /// must not proceed on a sidecar that is missing or merely not downloaded yet. Returns the
    /// sidecar as it was before `mutate`.
    @discardableResult
    func updateExistingMetadata(
        forFolderNamed name: String, _ mutate: (inout EntryMetadata) -> Void
    ) throws -> EntryMetadata {
        guard let original = try updateSidecar(forFolderNamed: name, mutate) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return original
    }

    /// The shared coordinated read-modify-write. Returns the sidecar as read, or `nil` when absent.
    private func updateSidecar(
        forFolderNamed name: String, _ mutate: (inout EntryMetadata) -> Void
    ) throws -> EntryMetadata? {
        // Fold any iCloud conflict versions in first (inert locally); it writes by itself.
        guard try readMetadata(forFolderNamed: name) != nil else { return nil }
        let url = metadataFile(forFolderNamed: name)
        Self.sidecarUpdateLock.lock()
        defer { Self.sidecarUpdateLock.unlock() }
        var before: EntryMetadata?
        try Self.coordinate(writingAt: url, options: .forMerging) { target in
            let original = try EntryMetadata.decoded(from: Data(contentsOf: target))
            var meta = original
            mutate(&meta)
            try meta.encoded().write(to: target, options: .atomic)
            before = original
        }
        return before
    }
}
