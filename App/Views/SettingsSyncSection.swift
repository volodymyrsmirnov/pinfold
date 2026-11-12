import SwiftUI

/// The iCloud sync section of Settings. The toggle only flips `settings.syncEnabled`;
/// `RootView` observes that and switches the active storage root live.
struct SettingsSyncSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Sync with iCloud", isOn: $settings.syncEnabled)
        } header: {
            Text("iCloud")
        } footer: {
            Text("Keeps your imported files on every device signed in to the same iCloud "
                + "account. Off by default; turn it on to start syncing. Your existing files "
                + "move into iCloud when you turn it on.")
        }
    }
}
