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
/// decides whether to participate in iCloud sync.
@MainActor @Observable final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let enabledMapAppIDs = "settings.enabledMapAppIDs"
        static let defaultMapAppID = "settings.defaultMapAppID"
        static let clusterMapPins = "settings.clusterMapPins"
        static let syncEnabled = "settings.syncEnabled"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Initial assignments do not trigger `didSet`, so this only reads.
        enabledMapAppIDs = defaults.stringArray(forKey: Key.enabledMapAppIDs) ?? []
        defaultMapAppID = defaults.string(forKey: Key.defaultMapAppID)
        clusterMapPins = defaults.bool(forKey: Key.clusterMapPins)
        syncEnabled = defaults.bool(forKey: Key.syncEnabled)
    }
}
