import MapKit
import SwiftUI

// MARK: - FavoritesMapView

/// Every starred point placemark across all files on one SwiftUI `Map`, tinted per file from a
/// fixed palette. Selecting a marker shows a card that opens the place through the caller's
/// route (`onOpen`). No clustering. Shows `OfflineMapBanner` while offline.
struct FavoritesMapView: View {
    let pins: [FavoritePin]
    let fileNames: [String: String]
    let onOpen: (FavoritePin) -> Void

    @State private var selectedID: String?
    @State private var network = NetworkStatus()

    private var selectedPin: FavoritePin? {
        pins.first { $0.id == selectedID }
    }

    var body: some View {
        Map(initialPosition: .automatic, selection: $selectedID) {
            ForEach(pins) { pin in
                Marker(
                    pin.name.isEmpty ? "Unnamed place" : pin.name,
                    systemImage: "star.fill",
                    coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
                )
                .tint(FavoritePinPalette.color(at: pin.tintIndex))
                .tag(pin.id)
            }
        }
        .overlay(alignment: .top) {
            if !network.isOnline {
                OfflineMapBanner().padding(.top, 8)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let pin = selectedPin {
                FavoritePinCard(pin: pin, fileName: fileNames[pin.folderName]) { onOpen(pin) }
                    .padding()
            }
        }
        .animation(.snappy, value: selectedID)
    }
}

// MARK: - FavoritePinPalette

/// The fixed tint palette; `FavoritePins.tintIndex` picks a slot per file.
enum FavoritePinPalette {
    static let colors: [Color] = [.red, .blue, .green, .orange, .purple, .teal, .pink, .indigo]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

// MARK: - FavoritePinCard

/// The tappable card for the selected favourite: name, file name, chevron.
private struct FavoritePinCard: View {
    let pin: FavoritePin
    let fileName: String?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Circle()
                    .fill(FavoritePinPalette.color(at: pin.tintIndex))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.name.isEmpty ? String(localized: "Unnamed place") : pin.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let fileName {
                        Text(fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
