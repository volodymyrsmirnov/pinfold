import Foundation

/// Serialises storage applications (launch, iCloud toggle, re-resolve) so two never run
/// interleaved: each operation starts only after every earlier one has finished, in the order
/// `run` was called. Without this a re-resolve awaiting its resolution could repoint the
/// catalogue while a toggle migration was reading the "from" root.
@MainActor final class StorageApplyQueue {
    private var tail: Task<Void, Never>?

    /// Runs `operation` after all previously queued operations complete, and returns once it
    /// has finished. Callers must re-check any state they depend on *inside* `operation`.
    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }
}
