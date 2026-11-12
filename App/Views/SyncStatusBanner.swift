import SwiftUI

/// A one-line notice at the top of the catalogue while iCloud sync is on but unreachable.
/// Renders nothing in any other state.
struct SyncStatusBanner: View {
    @Environment(SyncStatus.self) private var syncStatus: SyncStatus?

    var body: some View {
        if syncStatus?.isUnavailable == true {
            Label(
                "iCloud is unavailable. Showing files stored on this device; "
                    + "new imports move to iCloud when it is back.",
                systemImage: "icloud.slash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}
