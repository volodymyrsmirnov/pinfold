import Foundation
import os

/// Finishing an item, failure reporting and path tracking. A pure move out of
/// `ImportCoordinator.swift` (file length); the members are internal only so the extension can
/// reach the coordinator's state.
extension ImportCoordinator {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "import"
    )

    // MARK: - Finishing and failures

    func makeContext(for item: PendingImport) -> ItemContext {
        switch item.source {
        case let .picker(url):
            ItemContext(filename: url.lastPathComponent, interactive: true, ownedURL: nil, pathKey: Self.key(url))
        case let .owned(file):
            ItemContext(
                filename: file.filename, interactive: item.interactive, ownedURL: file.url,
                cleanupFolder: file.cleanupFolder, pathKey: Self.key(file.url)
            )
        case let .prepared(_, name):
            ItemContext(filename: name, interactive: item.interactive, ownedURL: nil, pathKey: nil)
        case let .subscribed(result):
            ItemContext(
                filename: result.sourceFilename, interactive: item.interactive, ownedURL: nil, pathKey: nil,
                subscriptionURL: result.subscription?.url
            )
        }
    }

    /// Marks an item done: optionally deletes its app-owned copy, releases its path, and
    /// advances the progress count.
    func finish(_ context: ItemContext, deleteOwned: Bool) {
        if deleteOwned, let url = context.ownedURL {
            try? FileManager.default.removeItem(at: context.cleanupFolder ?? url)
        }
        if let key = context.pathKey {
            trackedPaths.remove(key)
        }
        if let url = context.subscriptionURL {
            pendingSubscriptionURLs.remove(url)
        }
        completedCount += 1
    }

    /// A read or parse failure. A parse failure is permanent (the bytes are not valid
    /// KML/KMZ), so the owned copy is deleted; a read error is potentially transient, so the
    /// copy is kept for the next drain. A vanished file is simply gone. A cancelled import is
    /// neither: nothing is reported and the app-owned copy is dropped, like a queued item
    /// that `cancel()` drops.
    func reportPrepareFailure(_ error: Error, _ context: ItemContext) {
        if error is CancellationError {
            finish(context, deleteOwned: true)
            return
        }
        if context.interactive {
            importError = error
            // An interactive item is never retried; only a (dropped) app-owned copy exists.
            finish(context, deleteOwned: true)
            return
        }
        let permanent = Self.isParseFailure(error)
        let vanished = (error as? CocoaError)?.code == .fileReadNoSuchFile
        if !vanished {
            Self.logger.error(
                """
                \(permanent ? "Parse" : "Read") failure importing '\(context.filename, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
            // `ImportError` is a `LocalizedError` that never exposes a raw parser error string.
            failureLog?.record(
                filename: context.filename,
                reason: permanent ? error.localizedDescription : Self.retryReason
            )
        }
        finish(context, deleteOwned: permanent || vanished)
    }

    private static func isParseFailure(_ error: Error) -> Bool {
        guard let importError = error as? ImportError else { return false }
        if case .parseFailure = importError {
            return true
        }
        return false
    }

    /// A commit (I/O) failure: potentially transient, so a non-interactive copy is KEPT for a
    /// later drain and the failure is recorded with a friendly reason; an interactive import
    /// raises the error alert.
    func reportCommitFailure(_ error: Error, _ context: ItemContext) {
        if context.interactive {
            importError = error
        } else {
            Self.logger.error(
                """
                Transient failure importing '\(context.filename, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
            failureLog?.record(filename: context.filename, reason: Self.retryReason)
        }
        finish(context, deleteOwned: context.interactive)
    }

    private static let retryReason = String(
        localized: "Couldn't save the file. It will be retried automatically.",
        comment: "Import failure reason: a transient I/O error; the import will be retried."
    )

    // MARK: - Path tracking

    /// Normalised key for a file URL (symlinks such as `/var` vs `/private/var` resolved).
    static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Registers `url`; `false` when it is already queued, in flight or stalled.
    func track(_ url: URL) -> Bool {
        trackedPaths.insert(Self.key(url)).inserted
    }

    func untrack(_ url: URL) {
        trackedPaths.remove(Self.key(url))
    }
}
