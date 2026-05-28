import PinfoldCore
import SwiftUI

// MARK: - PlacemarkDetailView

/// Detail screen for a single `KMLPlacemark`.
///
/// Displays (in order):
/// 1. Photo gallery (if any photo links exist).
/// 2. Plain-text description (HTML tags stripped, entities decoded, line breaks kept).
/// 3. Coordinates.
/// 4. Extended data as chip rows.
/// 5. "Open in Maps" primary action button.
///
/// Toolbar menu provides secondary actions: Copy Coordinates, Share, Copy Name.
struct PlacemarkDetailView: View {
    // MARK: - Properties

    let placemark: KMLPlacemark
    let document: KMLDocument
    let entry: CatalogEntry

    // MARK: - Environment

    @Environment(MapAppService.self) private var mapService
    @Environment(AppSettings.self) private var settings
    @Environment(\.resourceCache) private var resourceCache
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?

    // MARK: - State

    /// Whether to show the map picker sheet.
    @State private var showMapPicker = false
    /// Whether to force-show the picker (long-press on Open in Maps).
    @State private var forcePicker = false

    // MARK: - Computed

    /// The description as readable, multi-line plain text (tags stripped, entities decoded,
    /// line breaks preserved). KML descriptions are untrusted, so they are never sent
    /// through `NSAttributedString`'s HTML importer.
    private var descriptionText: String? {
        guard let html = placemark.descriptionHTML, !html.isEmpty else { return nil }
        let text = AttributedHTML.readableText(html)
        return text.isEmpty ? nil : text
    }

    private var coordinateString: String? {
        guard let coord = placemark.coordinate else { return nil }
        return "\(coord.latitude), \(coord.longitude)"
    }

    private var hasCoordinate: Bool {
        placemark.coordinate != nil
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !placemark.photoLinks.isEmpty {
                    PhotoGalleryView(photoLinks: placemark.photoLinks, entry: entry)
                        .padding(.bottom, 8)
                }
                contentStack
            }
        }
        .navigationTitle(placemark.name ?? "Untitled")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .sheet(isPresented: $showMapPicker) {
            if let coord = placemark.coordinate {
                MapPickerSheet(
                    coordinate: coord,
                    name: placemark.name ?? ""
                )
            }
        }
    }

    // MARK: - Content stack

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Style icon + favorite star header
            HStack(alignment: .center, spacing: 8) {
                StyleIcon(placemark: placemark, document: document, entry: entry, size: 48)
                if annotations?.isFavorite(placemark) == true {
                    Image(systemName: "star.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                }
                Text(placemark.name ?? "Untitled")
                    .font(.title3.bold())
                    .strikethrough(annotations?.isVisited(placemark) == true)
                    .foregroundStyle(annotations?.isVisited(placemark) == true ? .secondary : .primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(annotations?.accessibilityDescription(for: placemark) ?? (placemark.name ?? "Untitled"))
            .padding(.horizontal)

            // Description
            if let descriptionText {
                Text(descriptionText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            // Coordinates
            if let coordStr = coordinateString {
                coordinatesRow(coordStr)
            }

            // Extended data chips
            if !placemark.extendedData.isEmpty {
                extendedDataSection
            }

            // Open in Maps button
            openInMapsButton
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .padding(.top, 8)
    }

    // MARK: - Coordinates row

    private func coordinatesRow(_ coordStr: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "location")
                .foregroundStyle(.secondary)
                .font(.footnote)
            Text(coordStr)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Extended data section

    private var extendedDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.subheadline.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(placemark.extendedData, id: \.name) { item in
                        extendedDataChip(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func extendedDataChip(_ item: KMLDataItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(item.value)
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    // MARK: - Open in Maps button

    private var openInMapsButton: some View {
        Button {
            guard hasCoordinate else { return }
            openInMaps()
        } label: {
            Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!hasCoordinate)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard hasCoordinate else { return }
                showMapPicker = true
            }
        )
    }

    // MARK: - Toolbar menu

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let annotations {
                    Button {
                        annotations.toggleFavorite(placemark)
                    } label: {
                        let on = annotations.isFavorite(placemark)
                        Label(on ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: on ? "star.slash" : "star")
                    }
                    Button {
                        annotations.toggleVisited(placemark)
                    } label: {
                        let on = annotations.isVisited(placemark)
                        Label(on ? "Mark as Unseen" : "Mark as Seen",
                              systemImage: on ? "eye.slash" : "eye")
                    }
                    Divider()
                }
                if let coordStr = coordinateString {
                    Button {
                        UIPasteboard.general.string = coordStr
                    } label: {
                        Label("Copy Coordinates", systemImage: "doc.on.doc")
                    }

                    if let coord = placemark.coordinate {
                        let q = (placemark.name ?? "")
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        let mapsURL = "https://maps.apple.com/?ll=\(coord.latitude),\(coord.longitude)&q=\(q)"
                        if let url = URL(string: mapsURL) {
                            ShareLink(item: url, subject: Text(placemark.name ?? "Placemark")) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                Button {
                    UIPasteboard.general.string = placemark.name ?? ""
                } label: {
                    Label("Copy Name", systemImage: "character.cursor.ibeam")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Open in Maps logic

    /// Opens the placemark in the user's default map app if one is set, installed and
    /// enabled; otherwise presents the picker sheet. Long-pressing the button bypasses
    /// this and always shows the picker (handled at the gesture site).
    private func openInMaps() {
        guard let coord = placemark.coordinate else { return }

        if let defaultApp = mapService.resolveDefault(
            id: settings.defaultMapAppID,
            enabledIDs: settings.enabledMapAppIDs
        ) {
            mapService.open(
                defaultApp,
                latitude: coord.latitude,
                longitude: coord.longitude,
                name: placemark.name ?? ""
            )
        } else {
            showMapPicker = true
        }
    }
}
