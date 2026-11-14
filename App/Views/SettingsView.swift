import SwiftUI

// MARK: - SettingsView

/// App settings screen for map-app and sync preferences.
///
/// Reads and writes `AppSettings` (UserDefaults-backed) directly; every mutation persists
/// immediately, so reopening Settings always shows the current state. The iCloud toggle
/// only flips `settings.syncEnabled` — `RootView` observes that and switches the active
/// storage root live (no relaunch required).
struct SettingsView: View {
    // MARK: - Environment

    @Environment(MapAppService.self) private var mapService
    @Environment(AppSettings.self) private var settings
    @Environment(MigrationAlertState.self) private var migrationAlert

    // MARK: - Body

    var body: some View {
        Form {
            defaultMapAppSection
            mapAppsSection
            mapViewSection
            sessionSection
            SettingsDownloadsSection()
            SettingsStorageSection()
            SettingsSyncSection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        // Surface a partial iCloud migration: entries whose folders couldn't be moved stay
        // in the previous location rather than silently disappearing from the catalogue.
        .alert(
            Text("Some Items Didn't Move", comment: "Title of the partial-migration alert"),
            isPresented: Binding(
                get: { migrationAlert.message != nil },
                set: {
                    if !$0 {
                        migrationAlert.message = nil
                    }
                }
            ),
            presenting: migrationAlert.message
        ) { _ in
            Button("OK", role: .cancel) { migrationAlert.message = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Embedded map section

    @ViewBuilder
    private var mapViewSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Cluster Nearby Pins", isOn: $settings.clusterMapPins)
        } header: {
            Text("Embedded Map")
        } footer: {
            Text("Groups nearby pins into numbered clusters when zoomed out. "
                + "Turn off to always show every pin individually.")
        }
    }

    // MARK: - Session section

    @ViewBuilder
    private var sessionSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Restore Session on Launch", isOn: $settings.restoreSessionEnabled)
        } header: {
            Text("Session")
        } footer: {
            Text("Reopens the file, screen, and position you were viewing when the app restarts.")
        }
    }

    // MARK: - Default map app section

    @ViewBuilder
    private var defaultMapAppSection: some View {
        let enabled = mapService.availableApps(enabledIDs: settings.enabledMapAppIDs)

        Section {
            Picker("Default App", selection: Binding<String?>(
                get: { settings.defaultMapAppID },
                set: { settings.defaultMapAppID = $0 }
            )) {
                Text("None \u{2014} always ask").tag(String?.none)
                ForEach(enabled) { app in
                    Text(app.displayName).tag(Optional(app.id))
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Default Map App")
        } footer: {
            Text("When set, tapping \"Open in Maps\" immediately launches the chosen app. " +
                "Long-press the button to always see the picker.")
        }
    }

    // MARK: - Map apps section

    @ViewBuilder
    private var mapAppsSection: some View {
        let installed = mapService.installedApps()
        Section {
            ForEach(installed) { app in
                Toggle(app.displayName, isOn: enabledBinding(for: app))
                    // At least one app must stay on: an empty list means "all apps" to
                    // `MapAppService`, so switching off the last one would re-enable them all.
                    .disabled(isOnlyEnabledApp(app, among: installed))
            }
        } header: {
            Text("Map Apps")
        } footer: {
            Text("Apps you don't have installed are hidden automatically.")
        }
    }

    // MARK: - Helpers

    /// Whether `app` is the only installed app still switched on.
    private func isOnlyEnabledApp(_ app: MapApp, among installed: [MapApp]) -> Bool {
        let ids = settings.enabledMapAppIDs
        let enabled = ids.isEmpty ? installed : installed.filter { ids.contains($0.id) }
        return enabled.count == 1 && enabled.first?.id == app.id
    }

    /// Returns a `Binding<Bool>` for the given app's membership in `enabledMapAppIDs`.
    private func enabledBinding(for app: MapApp) -> Binding<Bool> {
        Binding<Bool>(
            get: {
                // When the enabled list is empty, every app is treated as enabled
                // (per MapAppService.availableApps contract) so show the toggle ON.
                settings.enabledMapAppIDs.isEmpty || settings.enabledMapAppIDs.contains(app.id)
            },
            set: { isEnabled in
                var ids = settings.enabledMapAppIDs

                // If the list is empty, seed it with all installed IDs first.
                if ids.isEmpty {
                    ids = mapService.installedApps().map(\.id)
                }

                if isEnabled {
                    if !ids.contains(app.id) {
                        ids.append(app.id)
                    }
                } else {
                    // Never store an empty list: it would read back as "every app enabled".
                    guard ids.contains(where: { $0 != app.id }) else { return }
                    ids.removeAll { $0 == app.id }
                    // If the user disabled the default app, clear the default.
                    if settings.defaultMapAppID == app.id {
                        settings.defaultMapAppID = nil
                    }
                }

                settings.enabledMapAppIDs = ids
            }
        )
    }
}
