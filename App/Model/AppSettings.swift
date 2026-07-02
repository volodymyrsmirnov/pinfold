import Foundation
import Observation

/// App preferences, backed by `UserDefaults`.
///
/// Replaces the SwiftData `AppSettings` model. Values are stored in observable properties
/// (so SwiftUI views update) and mirrored to `UserDefaults` on every change (so the value
/// survives across `Settings` instances and app launches). Reading through `UserDefaults`
/// is what fixes the old "toggle shows stale state / only applies on app install" bug,
/// where the preference lived in an un-synchronising key-value store.
///
/// The sync preference is intentionally **per-device** (local `UserDefaults`): each device
/// decides whether to participate in iCloud sync. The session-restoration slice is likewise
/// per-device — it is UI state and must never sync.
@MainActor @Observable final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Guards cross-property `didSet` side effects during `init`. In an `@Observable`
    /// class, property observers DO fire for assignments inside `init` (the macro rewrites
    /// stored properties into computed accessors), so without this flag the init assignment
    /// of `resumeEntryFolderName` would trip the clear-on-different-folder coupling and
    /// delete the saved per-file slice before it is ever read. Cleared LAST in `init`.
    @ObservationIgnored private var isBootstrapping = true

    private enum Key {
        static let enabledMapAppIDs = "settings.enabledMapAppIDs"
        static let defaultMapAppID = "settings.defaultMapAppID"
        static let clusterMapPins = "settings.clusterMapPins"
        static let syncEnabled = "settings.syncEnabled"
        static let entrySort = "settings.entrySort"
        static let restoreSessionEnabled = "settings.restoreSessionEnabled"
        static let resumeEntryFolderName = "settings.resumeEntryFolderName"
        static let resumeRoutes = "settings.resumeRoutes"
        static let resumeSearchText = "settings.resumeSearchText"
        static let resumeCollapsedFolderIDs = "settings.resumeCollapsedFolderIDs"
        static let resumeNearestFirst = "settings.resumeNearestFirst"
        static let resumeScrollAnchorRowID = "settings.resumeScrollAnchorRowID"
    }

    /// Identifiers of the map apps the user has explicitly enabled. Empty means "all
    /// installed apps are enabled" (see `MapAppService.availableApps`).
    var enabledMapAppIDs: [String] {
        didSet { defaults.set(enabledMapAppIDs, forKey: Key.enabledMapAppIDs) }
    }

    /// Identifier of the default map app, or `nil` to always show the picker sheet.
    var defaultMapAppID: String? {
        didSet { defaults.set(defaultMapAppID, forKey: Key.defaultMapAppID) }
    }

    /// Whether the in-app map clusters nearby pins.
    var clusterMapPins: Bool {
        didSet { defaults.set(clusterMapPins, forKey: Key.clusterMapPins) }
    }

    /// Whether this device participates in iCloud Drive sync. Off by default (opt-in).
    var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) }
    }

    /// How the catalogue's active list is ordered (presentation-level; see `EntrySort`).
    /// Stored as the case's raw-value string; defaults to `.dateDesc` (newest first).
    var entrySort: EntrySort {
        didSet { defaults.set(entrySort.rawValue, forKey: Key.entrySort) }
    }

    // MARK: - Session restoration

    /// Whether the app reopens the file/screen/position from the previous session on
    /// launch. ON by default (`bool(forKey:)` defaults to false, so read via `object`).
    /// Turning it off clears all saved session state.
    var restoreSessionEnabled: Bool {
        didSet {
            defaults.set(restoreSessionEnabled, forKey: Key.restoreSessionEnabled)
            guard !isBootstrapping, !restoreSessionEnabled else { return }
            resumeEntryFolderName = nil // cascades: clears the per-file slice too
        }
    }

    /// The `storageFolderName` of the entry selected when the app last deactivated, or
    /// `nil` when nothing was selected. Writing a DIFFERENT value (including nil) clears
    /// the per-file slice below — a scroll anchor, search query, or route stack is
    /// meaningless in another file; re-writing the same value preserves it.
    var resumeEntryFolderName: String? {
        didSet {
            defaults.set(resumeEntryFolderName, forKey: Key.resumeEntryFolderName)
            guard !isBootstrapping, resumeEntryFolderName != oldValue else { return }
            resumeRoutes = nil
            resumeSearchText = nil
            resumeCollapsedFolderIDs = nil
            resumeNearestFirst = false
            resumeScrollAnchorRowID = nil
        }
    }

    /// The JSON-encoded `[EntryRoute]` (versioned envelope; see `EntryRoute.encodeForResume`).
    var resumeRoutes: Data? {
        didSet { defaults.set(resumeRoutes, forKey: Key.resumeRoutes) }
    }

    /// The placemark list's search text at deactivation. `nil` = nothing saved.
    var resumeSearchText: String? {
        didSet { defaults.set(resumeSearchText, forKey: Key.resumeSearchText) }
    }

    /// Collapsed folder ids (positional tree paths) at deactivation. `nil` = nothing saved.
    var resumeCollapsedFolderIDs: [String]? {
        didSet { defaults.set(resumeCollapsedFolderIDs, forKey: Key.resumeCollapsedFolderIDs) }
    }

    /// Whether the nearest-first sort was active at deactivation.
    var resumeNearestFirst: Bool {
        didSet { defaults.set(resumeNearestFirst, forKey: Key.resumeNearestFirst) }
    }

    /// The topmost visible outline row id at deactivation (the scroll anchor).
    var resumeScrollAnchorRowID: String? {
        didSet { defaults.set(resumeScrollAnchorRowID, forKey: Key.resumeScrollAnchorRowID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // NOTE: in an @Observable class these assignments DO fire didSet (macro-rewritten
        // computed properties) — `isBootstrapping` suppresses the cross-property couplings
        // until every stored value has been loaded.
        enabledMapAppIDs = defaults.stringArray(forKey: Key.enabledMapAppIDs) ?? []
        defaultMapAppID = defaults.string(forKey: Key.defaultMapAppID)
        clusterMapPins = defaults.bool(forKey: Key.clusterMapPins)
        syncEnabled = defaults.bool(forKey: Key.syncEnabled)
        entrySort = defaults.string(forKey: Key.entrySort)
            .flatMap(EntrySort.init(rawValue:)) ?? .dateDesc
        restoreSessionEnabled = defaults.object(forKey: Key.restoreSessionEnabled) as? Bool ?? true
        resumeEntryFolderName = defaults.string(forKey: Key.resumeEntryFolderName)
        resumeRoutes = defaults.data(forKey: Key.resumeRoutes)
        resumeSearchText = defaults.string(forKey: Key.resumeSearchText)
        resumeCollapsedFolderIDs = defaults.stringArray(forKey: Key.resumeCollapsedFolderIDs)
        resumeNearestFirst = defaults.bool(forKey: Key.resumeNearestFirst)
        resumeScrollAnchorRowID = defaults.string(forKey: Key.resumeScrollAnchorRowID)
        isBootstrapping = false
    }
}
