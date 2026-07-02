import Foundation
import Observation

// MARK: - AppDependencies

/// A tiny process-wide handle that lets in-process App Intents reach the app's live services.
///
/// App Intents are instantiated by the system, not by SwiftUI, so they can't read the
/// environment. For a foreground intent (`openAppWhenRun = true`) the app process is already
/// running, so the intent can resolve entities against the same `Catalog` the UI holds — it
/// just needs a way to find it. `RootView` publishes its `Catalog` and `NavigationRouter` here
/// at bootstrap; the intent reads them back.
///
/// `@MainActor` because both stored references are main-actor types and intents that touch them
/// run their resolution on the main actor.
@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    /// The live catalogue, set by `RootView` once it exists. `nil` before bootstrap (an intent
    /// fired before the UI is up resolves nothing — acceptable; the user just retries).
    var catalog: Catalog?

    /// The deep-link router `RootView` observes. Setting `pendingEntryFolderName` here drives the
    /// split view to open that entry. `nil` before bootstrap.
    var router: NavigationRouter?

    private init() {}
}

// MARK: - NavigationRouter

/// A one-shot deep-link sink for routing into the catalogue from outside the view tree (App
/// Intents, and any future programmatic navigation) — and the owner of the detail column's
/// navigation path.
///
/// `RootView` observes `pendingEntryFolderName` via `.onChange`: when an intent sets it, the
/// root resolves the folder name to an active entry and selects it (reusing the existing
/// selection plumbing). Consume-once: `RootView` clears it back to `nil` after handling, so the
/// same folder name set twice still re-fires the `.onChange`.
///
/// `path` backs `RootView`'s detail `NavigationStack(path:)`. It lives here — not as view
/// `@State` — so any view inside the open file (list rows aside, which use
/// `NavigationLink(value:)`) can push by appending a route, and so session restore can set
/// the whole stack in one assignment. Routes are per-document: `RootView` clears the path
/// whenever the selected entry changes.
@MainActor @Observable
final class NavigationRouter {
    /// The folder name of an entry an external trigger wants opened, or `nil` when idle.
    var pendingEntryFolderName: String?

    /// The detail column's navigation stack, as durable route values.
    var path: [EntryRoute] = []

    /// Requests that the entry with `folderName` be opened. Observed by `RootView`.
    func openEntry(folderName: String) {
        pendingEntryFolderName = folderName
    }
}
