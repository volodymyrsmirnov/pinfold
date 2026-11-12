import Foundation

/// The iCloud facts the resolver needs, behind a seam so the decision is testable without a
/// signed-in device.
protocol UbiquityProviding: Sendable {
    /// The container's `Documents` directory, or `nil` when iCloud is unavailable.
    /// Blocking in production: call off the main actor.
    func documentsURL() -> URL?

    /// An opaque, comparable form of the current iCloud identity (`nil` when signed out).
    func identityToken() -> Data?
}

/// The outcome of resolving the storage root for the current sync preference.
struct StorageResolution {
    /// The layout the catalogue should run on.
    let storage: StorageLocations
    /// What the UI should say about it.
    let status: SyncStatus.State
    /// The iCloud identity at resolution time.
    let identityToken: Data?

    /// `true` when `storage.root` is the iCloud container.
    var isUbiquitous: Bool {
        storage.isUbiquitous
    }
}

/// Decides which storage root to run on. Pure apart from the injected `UbiquityProviding`.
///
/// - sync off: the local root, status `.off`.
/// - sync on and a container: the iCloud root, status `.active`.
/// - sync on and no container: the local root, status `.unavailable` (the app keeps working
///   and says so; nothing is blocked).
struct StorageResolver {
    var ubiquity: any UbiquityProviding
    /// The local (non-synced) layout.
    var local: StorageLocations
    /// Builds the synced layout for an iCloud documents folder.
    var makeSynced: @Sendable (URL) -> StorageLocations = { StorageLocations.synced(root: $0) }

    /// Resolves the root for `syncEnabled`. Blocking when sync is on: call off the main actor.
    func resolve(syncEnabled: Bool) -> StorageResolution {
        guard syncEnabled else {
            return StorageResolution(storage: local, status: .off, identityToken: ubiquity.identityToken())
        }
        let token = ubiquity.identityToken()
        guard let documents = ubiquity.documentsURL() else {
            return StorageResolution(storage: local, status: .unavailable, identityToken: token)
        }
        return StorageResolution(storage: makeSynced(documents), status: .active, identityToken: token)
    }

    /// Whether stranded local entries should now move to iCloud: iCloud is the resolved root
    /// and either it was unavailable in this session (`previous == .unavailable`) or this is
    /// the launch resolution (`previous == nil`, which also catches files imported while an
    /// earlier session ran without iCloud). Never on the toggle path, which migrates itself.
    static func shouldRecover(previous: SyncStatus.State?, resolved: SyncStatus.State) -> Bool {
        guard resolved == .active else { return false }
        return previous == nil || previous == .unavailable
    }

    /// Moves every entry folder still in `local.root` into the iCloud root, then returns the
    /// per-folder report. Blocking file work: call off the main actor. Folders that already
    /// exist in iCloud stay put (the iCloud copy wins) and are not reported as failures.
    ///
    /// - Parameter toUbiquitous: `true` in production (`setUbiquitous`); tests pass `false`
    ///   to use the plain move between temp roots.
    @discardableResult
    static func recoverStranded(
        from local: StorageLocations,
        to synced: StorageLocations,
        toUbiquitous: Bool = true
    ) throws -> StorageLocations.MigrationReport {
        try StorageLocations.migrateEntries(
            from: local,
            to: synced,
            fromUbiquitous: false,
            toUbiquitous: toUbiquitous
        )
    }

    /// `true` when `local.root` holds entry folders (so a recovery has something to move).
    static func hasStrandedEntries(in local: StorageLocations) -> Bool {
        guard let names = try? local.entryFolderNames() else { return false }
        return !names.isEmpty
    }
}
