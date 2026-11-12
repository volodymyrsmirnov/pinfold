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
            comment: "Partial iCloud migration alert body; placeholder is a list of entry names."
        )
    }

    /// Reports that the whole migration could not run (enumeration or setup error). Nothing was
    /// moved and the catalogue stays on its current root.
    func reportFailure(_ error: Error) {
        // One localized literal; splitting it would split the translation key.
        // swiftlint:disable line_length
        message = String(
            localized: "Your files couldn't be moved, so they stay where they are and the iCloud setting was not changed (\(error.localizedDescription)).",
            comment: "iCloud migration failed entirely; placeholder is the underlying error."
        )
        // swiftlint:enable line_length
    }
}
