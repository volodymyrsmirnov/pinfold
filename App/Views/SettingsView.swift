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
        @Bindable var settings = settings
        Form {
            defaultMapAppSection
            mapAppsSection
            mapViewSection
            sessionSection
            iCloudSection(settings: $settings)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        // Surface a partial iCloud migration: entries whose folders couldn't be moved stay
        // in the previous location rather than silently disappearing from the catalogue.
        .alert(
            Text("Some Items Didn't Move", comment: "Title of the partial-migration alert"),
            isPresented: Binding(
                get: { migrationAlert.message != nil },
                set: { if !$0 { migrationAlert.message = nil } }
            ),
            presenting: migrationAlert.message
        ) { _ in
            Button("OK", role: .cancel) { migrationAlert.message = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - iCloud section

    private func iCloudSection(settings: Bindable<AppSettings>) -> some View {
        Section {
            Toggle("Sync with iCloud", isOn: settings.syncEnabled)
        } header: {
            Text("iCloud")
        } footer: {
            Text("Keeps your imported files on every device signed in to the same iCloud "
                + "account. Off by default; turn it on to start syncing. Your existing files "
                + "move into iCloud when you turn it on.")
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
            }
        } header: {
            Text("Map Apps")
        } footer: {
            Text("Apps you don't have installed are hidden automatically.")
        }
    }

    // MARK: - Helpers

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
