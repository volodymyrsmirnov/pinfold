import Foundation
import Observation

/// Bridges menu-bar / keyboard `Commands` to the views that own the corresponding UI.
///
/// `Commands` live on the `WindowGroup` scene, outside the view hierarchy that owns
/// transient UI state (the file importer lives in `HomeView`). This `@Observable` object is
/// injected into the environment — mirroring `MigrationAlertState` — so a command can flip a
/// flag that the owning view observes via `.onChange` and turns into the real action.
///
/// `importRequested` is a monotonically-increasing counter rather than a `Bool`: a counter
/// triggers `.onChange` on every invocation, so pressing ⌘I again after dismissing the picker
/// re-presents it. A `Bool` toggled true-then-reset would need careful resetting to fire twice.
///
/// This environment-object approach assumes effectively single-active-importer semantics: in a
/// multi-window iPad setup every window observes the same counter. If true multi-window command
/// routing is ever needed, `FocusedValues` (routing to the key window) is the upgrade path.
@MainActor @Observable
final class AppCommands {
    /// Bumped each time the user invokes the "Import…" command. `HomeView` observes changes
    /// and presents its `fileImporter` — the same flow as its toolbar "+" button.
    private(set) var importRequested = 0

    /// Invoked by the "Import…" menu command / ⌘I shortcut.
    func requestImport() {
        importRequested += 1
    }
}
