import Foundation
@testable import Pinfold
import Testing

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

/// Tests for the session-restoration slice of `AppSettings`. The cross-property couplings
/// (different folder clears the per-file slice; disabling the toggle clears everything) are
/// the risky part: in an `@Observable` class property observers DO fire for assignments
/// inside `init`, so without the bootstrap guard, initializing the folder name from disk
/// would wipe the very state being loaded.
@Suite(.serialized) @MainActor struct SettingsResumeTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsResumeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func restoreSessionEnabled_defaultsTrue() {
        #expect(AppSettings(defaults: makeDefaults()).restoreSessionEnabled == true)
    }

    @Test func restoreSessionEnabled_persistsFalse() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).restoreSessionEnabled = false
        #expect(AppSettings(defaults: defaults).restoreSessionEnabled == false)
    }

    @Test func resumeSlice_roundTrips() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeRoutes = Data([1, 2, 3])
        settings.resumeSearchText = "cafe"
        settings.resumeCollapsedFolderIDs = ["0", "0/1"]
        settings.resumeNearestFirst = true
        settings.resumeScrollAnchorRowID = "0/1/p2"

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.resumeEntryFolderName == "folder-a")
        #expect(fresh.resumeRoutes == Data([1, 2, 3]))
        #expect(fresh.resumeSearchText == "cafe")
        #expect(fresh.resumeCollapsedFolderIDs == ["0", "0/1"])
        #expect(fresh.resumeNearestFirst == true)
        #expect(fresh.resumeScrollAnchorRowID == "0/1/p2")
    }

    @Test func differentFolder_clearsPerFileSlice() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeScrollAnchorRowID = "p1"
        settings.resumeSearchText = "x"
        settings.resumeRoutes = Data([9])

        settings.resumeEntryFolderName = "folder-b"
        #expect(settings.resumeScrollAnchorRowID == nil)
        #expect(settings.resumeSearchText == nil)
        #expect(settings.resumeRoutes == nil)
    }

    @Test func nilFolder_clearsPerFileSlice() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeScrollAnchorRowID = "p1"

        settings.resumeEntryFolderName = nil
        #expect(settings.resumeScrollAnchorRowID == nil)
    }

    @Test func sameFolder_preservesPerFileSlice() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeScrollAnchorRowID = "p1"

        settings.resumeEntryFolderName = "folder-a"
        #expect(settings.resumeScrollAnchorRowID == "p1")
    }

    @Test func disablingToggle_clearsEverything() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.resumeEntryFolderName = "folder-a"
        settings.resumeRoutes = Data([1])
        settings.resumeScrollAnchorRowID = "p1"

        settings.restoreSessionEnabled = false
        #expect(settings.resumeEntryFolderName == nil)
        #expect(settings.resumeRoutes == nil)
        #expect(settings.resumeScrollAnchorRowID == nil)
        #expect(AppSettings(defaults: defaults).resumeEntryFolderName == nil)
    }

    /// Regression test for the `@Observable` init gotcha: observers fire inside `init`, so
    /// without the bootstrap guard the init assignment of the folder name would trip the
    /// clear-on-different-folder coupling and delete the anchor being loaded.
    @Test func initWithSavedFolderAndAnchor_preservesAnchor() {
        let defaults = makeDefaults()
        let seed = AppSettings(defaults: defaults)
        seed.resumeEntryFolderName = "folder-a"
        seed.resumeScrollAnchorRowID = "0/p3"

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.resumeScrollAnchorRowID == "0/p3")
        #expect(fresh.resumeEntryFolderName == "folder-a")
    }
}
