import SwiftUI
import PinfoldCore

// MARK: - MapPickerSheet

/// A bottom sheet that lists available map apps and lets the user pick one to
/// open a placemark coordinate.
///
/// Displays `mapService.availableApps(enabledIDs: settings.enabledMapAppIDs)` plus
/// a "Copy Coordinates" row. Tapping a map app row opens it and dismisses the sheet.
///
/// Present with `.sheet(isPresented:) { MapPickerSheet(coordinate:name:) }`.
struct MapPickerSheet: View {

    // MARK: - Properties

    /// The coordinate to open in a map app.
    let coordinate: Coordinate
    /// The display name of the placemark (used as the pin label).
    let name: String

    // MARK: - Environment

    @Environment(MapAppService.self) private var mapService
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var coordinatesCopied = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                mapAppsSection
                utilitiesSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Open in\u{2026}")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.thinMaterial)
    }

    // MARK: - Map apps section

    private var mapAppsSection: some View {
        let apps = mapService.availableApps(enabledIDs: settings.enabledMapAppIDs)
        return Section {
            if apps.isEmpty {
                Text("No map apps enabled.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    Button {
                        mapService.open(
                            app,
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            name: name
                        )
                        dismiss()
                    } label: {
                        Label(app.displayName, systemImage: "map")
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - Utilities section

    private var utilitiesSection: some View {
        let coordString = coordinateString
        return Section {
            Button {
                UIPasteboard.general.string = coordString
                coordinatesCopied = true
            } label: {
                Label(
                    coordinatesCopied ? "Copied!" : "Copy Coordinates",
                    systemImage: coordinatesCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .foregroundStyle(.primary)
            .onChange(of: coordinatesCopied) { _, newValue in
                if newValue {
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        coordinatesCopied = false
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var coordinateString: String {
        "\(coordinate.latitude), \(coordinate.longitude)"
    }
}
