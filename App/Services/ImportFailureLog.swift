import Foundation
import Observation

// MARK: - ImportFailure

/// A single import failure, suitable for display in a list.
struct ImportFailure: Identifiable {
    let id = UUID()
    /// The name of the file that failed to import.
    let filename: String
    /// A user-facing description of why it failed (already localized).
    let reason: String
    /// When the failure was recorded.
    let date: Date
}

// MARK: - ImportFailureLog

/// A bounded, newest-first record of import failures across every arrival path
/// (file-type association, share-extension inbox, Documents inbox).
///
/// Files arrive three ways and all converge on `ImportService`; failures used to be silent.
/// This log is the single sink the UI observes, so a parse error or an I/O error during
/// import surfaces to the user instead of vanishing. Injected as an environment object next
/// to `MigrationAlertState`; `HomeView` observes it and presents the recent failures.
@MainActor @Observable
final class ImportFailureLog {
    /// Maximum number of failures retained. Bounded because this list is shown verbatim in
    /// the UI — older failures are evicted so the surface never grows without limit.
    static let cap = 20

    /// Recorded failures, newest first.
    private(set) var failures: [ImportFailure] = []

    /// Records a failure, keeping only the most recent `cap` entries (newest first).
    func record(filename: String, reason: String) {
        failures.insert(ImportFailure(filename: filename, reason: reason, date: .now), at: 0)
        if failures.count > Self.cap {
            failures.removeLast(failures.count - Self.cap)
        }
    }

    /// Clears all recorded failures (the user dismissed the surfaced list).
    func clear() {
        failures.removeAll()
    }
}
