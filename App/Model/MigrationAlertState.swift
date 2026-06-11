import Foundation

/// Holds a user-facing message describing entries that could not be moved during a storage
/// root migration (the iCloud sync toggle), so the Settings flow can surface it as an alert.
///
/// A partial migration must never be silent: the moved entries live in the new root, but any
/// folder that failed to move stays in the previous location and would otherwise vanish from
/// the catalogue without explanation. `RootView.applyStorage` populates `message` when a
/// migration reports failures; `SettingsView` observes it and presents the alert.
@MainActor @Observable
final class MigrationAlertState {
    /// Non-nil while a migration-failure alert should be shown. Cleared when dismissed.
    var message: String?

    /// Builds and stores a localized message naming the entries that failed to migrate.
    ///
    /// - Parameter failedNames: human-readable names of the failed entries (display names when
    ///   cheaply available, else raw folder names).
    func report(failedNames: [String]) {
        guard !failedNames.isEmpty else { return }
        let names = failedNames.joined(separator: ", ")
        message = String(
            localized: "These items couldn't be moved and remain in their previous location: \(names).",
            comment: "Alert body after a partial iCloud storage migration; the placeholder is a comma-separated list of entry names."
        )
    }
}
