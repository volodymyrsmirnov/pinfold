import PinfoldCore
import SwiftUI

// MARK: - PlacemarkMapView

/// Map screen for a single KML file. Plots the supplied (already filtered) point
/// placemarks, shows the user's location when authorized, and presents a bottom
/// preview card on selection that opens `PlacemarkDetailView`.
///
/// `placemarks` is pre-filtered by the caller (`KMLDetailView`) to those with a
/// coordinate, honoring any active search query.
struct PlacemarkMapView: View {

    let placemarks: [KMLPlacemark]
    let document: KMLDocument
    let entry: CatalogEntry

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage
    @Environment(AppSettings.self) private var settings
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?

    @State private var selectedPlacemarkID: String?
    @State private var placemarkToOpenID: String?
    @State private var locationAuth = LocationAuthorization()

    private var selectedPlacemark: KMLPlacemark? {
        placemarks.first { $0.id == selectedPlacemarkID }
    }

    var body: some View {
        // Only the map ignores the safe area (so it fills behind the translucent nav
        // bar); the preview card stays a normal ZStack child and remains above the
        // home indicator.
        ZStack(alignment: .bottom) {
            PlacemarkMapRepresentable(
                placemarks: placemarks,
                document: document,
                entry: entry,
                resourceCache: resourceCache,
                storage: storage,
                showsUserLocation: locationAuth.isAuthorized,
                clusterPins: settings.clusterMapPins,
                favoriteKeys: annotations?.favoriteKeys ?? [],
                visitedKeys: annotations?.visitedKeys ?? [],
                selectedID: $selectedPlacemarkID
            )
            .ignoresSafeArea()

            if let placemark = selectedPlacemark {
                PlacemarkPreviewCard(placemark: placemark, document: document, entry: entry) {
                    placemarkToOpenID = placemark.id
                }
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedPlacemarkID)
        // Let the map show through the navigation bar; the glass back button floats over
        // it. No title — a label with no scrim would be unreadable over varied map tiles
        // (matches Apple Maps' full-screen presentation).
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $placemarkToOpenID) { id in
            if let placemark = placemarks.first(where: { $0.id == id }) {
                PlacemarkDetailView(placemark: placemark, document: document, entry: entry)
            }
        }
        .task {
            locationAuth.request()
        }
    }
}

// MARK: - PlacemarkPreviewCard

/// A compact tappable card shown over the map for the selected placemark. Reuses
/// `StyleIcon` and the photo-thumbnail pattern from `PlacemarkRow`. Tapping it invokes
/// `onOpen` (which pushes the detail screen).
private struct PlacemarkPreviewCard: View {

    let placemark: KMLPlacemark
    let document: KMLDocument
    let entry: CatalogEntry
    let onOpen: () -> Void

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                StyleIcon(placemark: placemark, document: document, entry: entry, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if annotations?.isFavorite(placemark) == true {
                            Image(systemName: "star.fill")
                                .font(.footnote)
                                .foregroundStyle(.yellow)
                        }
                        Text(placemark.name ?? "Untitled")
                            .font(.headline)
                            .strikethrough(annotations?.isVisited(placemark) == true)
                            .foregroundStyle(annotations?.isVisited(placemark) == true ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    if let html = placemark.descriptionHTML, !html.isEmpty {
                        let preview = AttributedHTML.plainText(html)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !preview.isEmpty {
                            Text(preview)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                thumbnail
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(radius: 8, y: 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let firstLink = placemark.photoLinks.first {
            let resourcesDir = storage.resourcesDirectory(for: entry)
            if let localURL = resourceCache.localURL(forHref: firstLink, in: resourcesDir) {
                AsyncImage(url: localURL) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(width: 44, height: 44)
            }
        }
    }
}
