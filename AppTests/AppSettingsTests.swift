import Testing
import Foundation
@testable import Pinfold

/// Tests for `Settings` — the UserDefaults-backed app preferences that replaced the
/// SwiftData `AppSettings` model. The defining requirement is that a value written by one
/// instance is visible to a freshly-created instance on the same store (this is what fixes
/// the "toggle shows old state / only applies on app install" bug).
@Suite(.serialized) @MainActor struct SettingsTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func syncEnabled_defaultsFalse() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.syncEnabled == false)
    }

    @Test func syncEnabled_persistsAcrossInstances() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).syncEnabled = true
        // A fresh instance (simulating reopening Settings or relaunch) sees the new value.
        #expect(AppSettings(defaults: defaults).syncEnabled == true)
    }

    @Test func enabledMapAppIDs_roundTrips() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.enabledMapAppIDs.isEmpty)

        settings.enabledMapAppIDs = ["apple", "google"]
        #expect(AppSettings(defaults: defaults).enabledMapAppIDs == ["apple", "google"])
    }

    @Test func defaultMapAppID_nilByDefault_setAndClear() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.defaultMapAppID == nil)

        settings.defaultMapAppID = "apple"
        #expect(AppSettings(defaults: defaults).defaultMapAppID == "apple")

        settings.defaultMapAppID = nil
        #expect(AppSettings(defaults: defaults).defaultMapAppID == nil)
    }

    @Test func clusterMapPins_defaultsFalse_persists() {
        let defaults = makeDefaults()
        #expect(AppSettings(defaults: defaults).clusterMapPins == false)

        AppSettings(defaults: defaults).clusterMapPins = true
        #expect(AppSettings(defaults: defaults).clusterMapPins == true)
    }
}
