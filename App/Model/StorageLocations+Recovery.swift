import Foundation

/// The few fields recoverable from a sidecar whose full decode failed (a newer schema, or a
/// damaged file whose JSON is still intact). Used only to keep an entry's identity, name and
/// trash state while the file is otherwise untouchable (B12).
struct TolerantSidecar: Equatable {
    var id: UUID?
    var displayName: String?
    var trashedAt: Date?
}

extension StorageLocations {
    /// Best-effort read of `id`, `displayName` and `trashedAt` from `metadata.json` in the
    /// named folder. `nil` when the file is not a JSON object at all. Never writes.
    ///
    /// Dates follow `EntryMetadata`'s default Codable strategy: a number of seconds since the
    /// reference date.
    func tolerantSidecar(forFolderNamed name: String) -> TolerantSidecar? {
        guard let data = try? coordinatedRead(at: metadataFile(forFolderNamed: name)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let name = (object["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TolerantSidecar(
            id: (object["id"] as? String).flatMap(UUID.init(uuidString:)),
            displayName: name,
            trashedAt: (object["trashedAt"] as? NSNumber)
                .map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        )
    }

    /// In an iCloud root, whether a missing sidecar most likely exists remotely: the probe sees
    /// a placeholder or a not-current item, or the folder is UUID-named (app-created folders get
    /// their sidecar written before the original, so a UUID folder with no sidecar means it has
    /// not synced down). Non-UUID folders (dropped in through the Files app) are not covered.
    func sidecarProbablyExistsRemotely(at url: URL, folderNamed name: String) -> Bool {
        if probe.placeholderExists(for: url) {
            return true
        }
        if let status = probe.downloadStatus(of: url), status == .notDownloaded {
            return true
        }
        return UUID(uuidString: name) != nil
    }
}
