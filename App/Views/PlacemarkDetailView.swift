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
/// 5. "My Notes" block.
/// 6. "Open in Maps" primary action button.
///
/// Toolbar menu: the shared `PlacemarkActions` (share, favourite, seen, copy coordinates, copy
/// name) — the same set the place's row offers on a long press — with Show on Map after Share.
struct PlacemarkDetailView: View {
    // MARK: - Properties

    let placemark: KMLPlacemark
    let document: KMLDocument
    let entry: CatalogEntry

    // MARK: - Environment

    @Environment(MapAppService.self) private var environmentMapService: MapAppService?
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?
    @Environment(\.resourceCache) private var resourceCache
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?
    @Environment(Catalog.self) private var catalog: Catalog?
    @Environment(NavigationRouter.self) private var router: NavigationRouter?

    // MARK: - State

    /// Whether to show the map picker sheet.
    @State private var showMapPicker = false
    /// Fallbacks for macOS "Designed for iPad" navigation/sheet hosts that can drop typed
    /// environment values from pushed destinations. Normal app flows still use the injected
    /// environment instances.
    @State private var fallbackMapService = MapAppService()
    @State private var fallbackSettings = AppSettings()

    /// The router that owns the detail column's path: the environment value when propagation
    /// delivers it, else the shared instance published to `AppDependencies` at bootstrap.
    /// This view is a pushed destination — the one hosting arrangement where the Mac
    /// "Designed for iPad" runtime has historically dropped stack-root environment values
    /// (see the fallbacks above) — and a dropped router would silently dead-button
    /// "Show on Map". The fallback makes the push deterministic; both refer to the same
    /// live instance.
    private var activeRouter: NavigationRouter? {
        router ?? AppDependencies.shared.router
    }

    private var coordinateString: String? {
        guard let coord = placemark.coordinate else { return nil }
        return CoordinateFormatter.string(for: coord)
    }

    private var hasCoordinate: Bool {
        placemark.coordinate != nil
    }

    private var mapService: MapAppService {
        environmentMapService ?? fallbackMapService
    }

    private var settings: AppSettings {
        environmentSettings ?? fallbackSettings
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
        // Favourite / Open in Maps menu commands act on the place open in THIS window.
        .focusedSceneValue(\.placeCommands, placeCommands)
        .sheet(isPresented: $showMapPicker) {
            if let coord = placemark.coordinate {
                MapPickerSheet(
                    coordinate: coord,
                    name: placemark.name ?? ""
                )
                .environment(mapService)
                .environment(settings)
            }
        }
    }

    /// The menu-bar actions for this place, mirroring its "⋯" menu; each is `nil` (menu item
    /// disabled) when it cannot apply.
    private var placeCommands: PlaceCommands {
        PlaceCommands(
            place: PlaceRef(placemark),
            annotations: annotations,
            openInMaps: hasCoordinate ? { openInMaps() } : nil,
            showOnMap: hasCoordinate ? { activeRouter?.path.append(.map(focusKey: placemark.stableKey)) } : nil
        )
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
            if let html = placemark.descriptionHTML, !html.isEmpty {
                DescriptionView(html: html, entry: entry)
                    .padding(.horizontal)
            }

            // Address and phone
            contactRows

            // Coordinates
            if let coordStr = coordinateString {
                coordinatesRow(coordStr)
            }

            // Extended data chips
            if !placemark.extendedData.isEmpty {
                extendedDataSection
            }

            // Personal note
            if let annotations {
                PlacemarkNoteBlock(placemark: placemark, annotations: annotations, catalog: catalog)
            }

            // Open in Maps button
            openInMapsButton
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .padding(.top, 8)
    }

    // MARK: - Address and phone rows

    private var trimmedAddress: String? {
        let value = placemark.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// A `tel:` URL for the placemark's phone number (digits and `+` only), when it has one.
    private var phoneURL: URL? {
        guard let phone = placemark.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }

    @ViewBuilder
    private var contactRows: some View {
        if let address = trimmedAddress {
            Label(address, systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .textSelection(.enabled)
        }
        if let phoneURL, let phone = placemark.phoneNumber {
            Link(destination: phoneURL) {
                Label(phone, systemImage: "phone")
                    .font(.subheadline)
            }
            .padding(.horizontal)
        }
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
                    ForEach(placemark.extendedData) { item in
                        extendedDataChip(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// One field as a chip: its name above its value. A value that is a single web address
    /// makes the whole chip a link (tinted, with an arrow), so it can be tapped to open.
    @ViewBuilder
    private func extendedDataChip(_ item: KMLDataItem) -> some View {
        if let url = WebLink.url(from: item.value) {
            Link(destination: url) {
                chipContent(item, isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the link")
        } else {
            chipContent(item, isLink: false)
                .textSelection(.enabled)
        }
    }

    private func chipContent(_ item: KMLDataItem, isLink: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName ?? item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(item.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isLink {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isLink ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: 280, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
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
                PlacemarkActions(place: PlaceRef(placemark), annotations: annotations) {
                    if hasCoordinate {
                        Button {
                            activeRouter?.path.append(.map(focusKey: placemark.stableKey))
                        } label: {
                            Label("Show on Map", systemImage: "map")
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
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
