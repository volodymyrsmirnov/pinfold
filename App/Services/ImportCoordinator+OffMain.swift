import Foundation

// MARK: - Off-main work (free functions)

/// Reads `url`'s bytes and prepares the import, both off the main actor in one detached hop.
/// A `nonisolated` free function (not a method on the `@MainActor` coordinator) so the
/// `Task.detached` closure is compiled here, not inside the coordinator's SIL — see the
/// `ClosureLifetimeFixup` note in FavoritesView.swift. The caller owns the security-scoped
/// access bracket, which spans the `await` on this function.
///
/// Cancelling the calling task cancels the detached read-and-parse, which then throws
/// `CancellationError`.
func readAndPrepareFile(_ url: URL, filename: String) async throws -> ImportResult {
    let task = Task.detached(priority: .userInitiated) {
        let data = try Data(contentsOf: url)
        return try ImportService.prepare(data: data, sourceFilename: filename)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Prepares in-memory bytes off the main actor (the test-seam source). Cancellable like
/// `readAndPrepareFile`.
func prepareBytes(_ data: Data, filename: String) async throws -> ImportResult {
    let task = Task.detached(priority: .userInitiated) {
        try ImportService.prepare(data: data, sourceFilename: filename)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
