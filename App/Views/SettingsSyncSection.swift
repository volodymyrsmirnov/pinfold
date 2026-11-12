import SwiftUI

/// The iCloud sync section of Settings. The toggle only flips `settings.syncEnabled`;
/// `RootView` observes that and switches the active storage root live.
struct SettingsSyncSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SyncStatus.self) private var syncStatus: SyncStatus?

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Sync with iCloud", isOn: $settings.syncEnabled)
            if let line = statusLine {
                Label(line.text, systemImage: line.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Keeps your imported files on every device signed in to the same iCloud "
                + "account. Off by default; turn it on to start syncing. Your existing files "
                + "move into iCloud when you turn it on.")
        }
    }

    /// What to say under the toggle; nothing while sync is off.
    private var statusLine: (text: String, symbol: String)? {
        switch syncStatus?.state {
        case .active:
            ("Syncing with iCloud.", "icloud")
        case .unavailable:
            ("iCloud is unavailable. Using files stored on this device until it is back.", "icloud.slash")
        case .off, nil:
            nil
        }
    }
}
