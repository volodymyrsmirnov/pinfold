import SwiftUI

/// The Downloads section of Settings: whether remote icons and photos named by a file are
/// downloaded on import.
struct SettingsDownloadsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Download Images", selection: $settings.remoteImagePolicy) {
                Text("Always").tag(RemoteImagePolicy.always)
                Text("Ask").tag(RemoteImagePolicy.ask)
                Text("Never").tag(RemoteImagePolicy.never)
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text(
                "Some files link to icons and photos on the web. Downloading them reveals this "
                    + "device's IP address to the hosts the file names. With Ask, images download "
                    + "only after you allow it for that file; with Never, nothing is downloaded."
            )
        }
    }
}
