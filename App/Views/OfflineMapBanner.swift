import SwiftUI

/// A small notice shown over the map while offline: tiles may be missing, pins and routes
/// still work.
struct OfflineMapBanner: View {
    var body: some View {
        Label {
            Text("Offline: map tiles may not load without a connection. Pins and routes still work.")
                .font(.footnote)
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}
