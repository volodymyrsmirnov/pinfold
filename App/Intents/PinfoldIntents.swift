import AppIntents
import Foundation

// MARK: - CatalogEntryEntity

/// An App Intents shadow model for a catalogue entry — the unit the user picks in Shortcuts /
/// Siri to open a file. Mirrors `CatalogEntry` (its `id` is the entry's `storageFolderName`,
/// the same string used as the Spotlight entry id and the deep-link key) rather than conforming
/// `CatalogEntry` itself (a value type that shouldn't carry intent machinery).
struct CatalogEntryEntity: AppEntity {
    static let defaultQuery = EntryQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "File"

    /// The entry's on-disk folder name (a UUID string), used for both display resolution and
    /// deep-link routing.
    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(entry: CatalogEntry) {
        self.init(id: entry.storageFolderName, displayName: entry.displayName)
    }
}

// MARK: - EntryQuery

/// Resolves `CatalogEntryEntity` values against the live `Catalog` (reached via
/// `AppDependencies.shared`). Supports both id-based resolution (re-hydrating a previously
/// chosen entry) and free-text search (the Shortcuts/Siri picker). Trashed entries are
/// excluded — you can't open something that's in the Trash.
struct EntryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CatalogEntryEntity] {
        guard let catalog = AppDependencies.shared.catalog else { return [] }
        let wanted = Set(identifiers)
        // Omit (don't throw for) missing ids — a stale id just resolves to nothing.
        return catalog.active
            .filter { wanted.contains($0.storageFolderName) }
            .map(CatalogEntryEntity.init(entry:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [CatalogEntryEntity] {
        guard let catalog = AppDependencies.shared.catalog else { return [] }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty
            ? catalog.active
            : catalog.active.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
        return matches.map(CatalogEntryEntity.init(entry:))
    }

    @MainActor
    func suggestedEntities() async throws -> [CatalogEntryEntity] {
        guard let catalog = AppDependencies.shared.catalog else { return [] }
        return catalog.active.map(CatalogEntryEntity.init(entry:))
    }
}

// MARK: - OpenEntryIntent

/// Opens a catalogue file in Pinfold. Foreground intent (`openAppWhenRun`) that routes through
/// the deep-link `NavigationRouter`: it sets the chosen folder name on the router, which
/// `RootView` observes and turns into a sidebar selection. No-op (gracefully) if the app's
/// dependencies aren't wired yet.
struct OpenEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open File"
    static let description = IntentDescription("Opens a file from your Pinfold catalogue.")

    /// Bring the app to the foreground — the catalogue UI is where the file actually opens.
    static let openAppWhenRun = true

    @Parameter(title: "File")
    var entry: CatalogEntryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$entry)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDependencies.shared.router?.openEntry(folderName: entry.id)
        return .result()
    }
}

// MARK: - PinfoldShortcuts

/// Registers the "Open … in Pinfold" phrase so the open-file action is available in Siri and
/// the Shortcuts app with no user setup.
struct PinfoldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenEntryIntent(),
            phrases: [
                "Open \(\.$entry) in \(.applicationName)",
                "Open \(.applicationName)",
            ],
            shortTitle: "Open File",
            systemImageName: "map"
        )
    }
}
