import MapKit
import PinfoldCore
import SwiftUI
import UIKit

// MARK: - EmbeddedMapStyle

/// The basemap style for the in-app map, surfaced as a picker on the map screen.
enum EmbeddedMapStyle: String, CaseIterable, Identifiable {
    /// Standard vector ("geo") map.
    case standard
    /// Satellite imagery only.
    case satellite
    /// Satellite imagery with roads and labels.
    case hybrid

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .standard: "Map"
        case .satellite: "Satellite"
        case .hybrid: "Hybrid"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .satellite: "globe.americas"
        case .hybrid: "globe.americas.fill"
        }
    }

    /// The MapKit configuration realizing this style.
    var configuration: MKMapConfiguration {
        switch self {
        case .standard: MKStandardMapConfiguration()
        case .satellite: MKImageryMapConfiguration()
        case .hybrid: MKHybridMapConfiguration()
        }
    }
}

// MARK: - PlacemarkAnnotation

/// An `MKAnnotation` for a single KML point placemark, carrying its parse-session id
/// (for selection lookup) and its pre-rendered pin image.
final class PlacemarkAnnotation: NSObject, MKAnnotation {
    let placemarkID: String
    let stableKey: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    /// The un-decorated base image (loaded from disk or SF Symbol). Stored so
    /// `updateUIView` can re-composite favorite/visited badges cheaply without re-reading disk.
    let baseImage: UIImage
    /// The currently decorated pin image. Updated in `updateUIView` when favorite/visited
    /// state changes; the `viewFor` delegate reads this to set `view.image`.
    var image: UIImage

    init(
        placemarkID: String,
        stableKey: String,
        coordinate: CLLocationCoordinate2D,
        title: String?,
        baseImage: UIImage,
        image: UIImage
    ) {
        self.placemarkID = placemarkID
        self.stableKey = stableKey
        self.coordinate = coordinate
        self.title = title
        self.baseImage = baseImage
        self.image = image
    }
}

// MARK: - FittingMapView

/// `MKMapView` subclass that fires `onFirstLayout` exactly once, the first time it
/// receives a non-zero size. Fitting all pins here (rather than in
/// `updateUIView`'s render-timing-dependent path) guarantees the initial region is
/// computed against the real map bounds, so the map opens centered on the pins and
/// never "jumps" to a deferred fit on a later re-render.
final class FittingMapView: MKMapView {
    var onFirstLayout: (() -> Void)?
    private var didLayoutOnce = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didLayoutOnce, bounds.width > 0, bounds.height > 0 else { return }
        didLayoutOnce = true
        onFirstLayout?()
    }
}

// MARK: - PlacemarkMapRepresentable

/// Wraps `MKMapView` directly (SwiftUI's `Map` is more limited) to render many pins
/// with full control over annotation views.
///
/// - Builds one `PlacemarkAnnotation` per placemark (with its `PlacemarkPinImage`).
/// - Fits all pins on the map's first layout (`MapRectBuilder` + `setVisibleMapRect`),
///   single pin → a fixed ~1 km span.
/// - Shows the user-location dot when `showsUserLocation` is `true`.
/// - Adds native controls: a basemap-style menu and an `MKUserTrackingButton`.
/// - Clustering follows `clusterPins`: when on, nearby pins group into numbered
///   clusters (tapping a cluster zooms to its members); when off, every pin renders
///   individually even when overlapping.
/// - Highlights the selected pin (scaled up, raised to front).
/// - Bridges selection to `selectedID`: tapping a pin writes its id; clearing
///   `selectedID` deselects on the map.
struct PlacemarkMapRepresentable: UIViewRepresentable {
    let placemarks: [KMLPlacemark]
    let document: KMLDocument
    let entry: CatalogEntry
    let resourceCache: ResourceCache
    let storage: StorageLocations
    let showsUserLocation: Bool
    let clusterPins: Bool
    let favoriteKeys: Set<String>
    let visitedKeys: Set<String>
    @Binding var selectedID: String?

    /// UserDefaults key for the persisted basemap style. The style control and its
    /// persistence are owned entirely by this representable / its coordinator.
    static let styleDefaultsKey = "embeddedMapStyle"

    private static let clusteringIdentifier = "kml.placemark"
    private static let placemarkReuseID = "placemark"
    private static let clusterReuseID = "cluster"
    private static let edgePadding = UIEdgeInsets(top: 80, left: 60, bottom: 140, right: 60)
    private static let selectedScale: CGFloat = 1.5

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = FittingMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        let initialStyle = EmbeddedMapStyle(
            rawValue: UserDefaults.standard.string(forKey: Self.styleDefaultsKey) ?? ""
        ) ?? .standard
        mapView.preferredConfiguration = initialStyle.configuration
        context.coordinator.mapView = mapView
        context.coordinator.currentStyle = initialStyle

        let annotations = placemarks.compactMap { placemark -> PlacemarkAnnotation? in
            guard let coordinate = placemark.coordinate else { return nil }
            let base = PlacemarkPinImage.image(
                for: placemark, document: document, entry: entry,
                resourceCache: resourceCache, storage: storage
            )
            let image = PlacemarkPinImage.decorated(
                base,
                isFavorite: favoriteKeys.contains(placemark.stableKey),
                isVisited: visitedKeys.contains(placemark.stableKey)
            )
            return PlacemarkAnnotation(
                placemarkID: placemark.id,
                stableKey: placemark.stableKey,
                coordinate: CLLocationCoordinate2D(
                    latitude: coordinate.latitude, longitude: coordinate.longitude
                ),
                title: placemark.name,
                baseImage: base,
                image: image
            )
        }
        mapView.addAnnotations(annotations)

        let coordinates = placemarks.compactMap(\.coordinate)
        mapView.onFirstLayout = { [weak mapView] in
            guard let mapView else { return }
            Self.fit(coordinates: coordinates, in: mapView, animated: false)
        }

        addControls(to: mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.showsUserLocation = showsUserLocation

        // Reconcile SwiftUI -> map selection: if SwiftUI cleared it, deselect on the map
        // (which reverts the highlight via didDeselect).
        if selectedID == nil {
            for annotation in mapView.selectedAnnotations where annotation is PlacemarkAnnotation {
                mapView.deselectAnnotation(annotation, animated: true)
            }
        }

        // Re-decorate pins only when the sets actually changed — selection flips
        // selectedID and triggers updateUIView too, so without this guard every tap
        // would re-composite UIGraphicsImageRenderer images for all N annotations.
        // `view(for:)` is nil for offscreen annotations — annotation.image still lands,
        // so viewFor(_:) picks up the correct image on next reuse.
        if context.coordinator.lastFavoriteKeys != favoriteKeys
            || context.coordinator.lastVisitedKeys != visitedKeys {
            context.coordinator.lastFavoriteKeys = favoriteKeys
            context.coordinator.lastVisitedKeys = visitedKeys
            for annotation in mapView.annotations.compactMap({ $0 as? PlacemarkAnnotation }) {
                let fresh = PlacemarkPinImage.decorated(
                    annotation.baseImage,
                    isFavorite: favoriteKeys.contains(annotation.stableKey),
                    isVisited: visitedKeys.contains(annotation.stableKey)
                )
                annotation.image = fresh
                mapView.view(for: annotation)?.image = fresh
            }
        }
    }

    // MARK: - Fit to pins

    static func fit(coordinates: [Coordinate], in mapView: MKMapView, animated: Bool) {
        guard let rect = MapRectBuilder.boundingRect(for: coordinates) else { return }
        if rect.size.width == 0, rect.size.height == 0 {
            // Single pin (or all coincident): use a fixed ~1 km span centered on it.
            let region = MKCoordinateRegion(
                center: MKMapPoint(x: rect.origin.x, y: rect.origin.y).coordinate,
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
            mapView.setRegion(region, animated: animated)
        } else {
            mapView.setVisibleMapRect(rect, edgePadding: edgePadding, animated: animated)
        }
    }

    // MARK: - Native controls

    private func addControls(to mapView: MKMapView, coordinator: Coordinator) {
        let tracking = MKUserTrackingButton(mapView: mapView)
        tracking.translatesAutoresizingMaskIntoConstraints = false
        let trackingContainer = Self.glassContainer()
        trackingContainer.contentView.addSubview(tracking)
        NSLayoutConstraint.activate([
            tracking.centerXAnchor.constraint(equalTo: trackingContainer.contentView.centerXAnchor),
            tracking.centerYAnchor.constraint(equalTo: trackingContainer.contentView.centerYAnchor),
            trackingContainer.widthAnchor.constraint(equalToConstant: 44),
            trackingContainer.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Basemap-style button: a menu of Map / Satellite / Hybrid, placed at the top of
        // the control column.
        let styleButton = UIButton(configuration: .plain())
        styleButton.translatesAutoresizingMaskIntoConstraints = false
        styleButton.setImage(
            UIImage(systemName: "map", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)),
            for: .normal
        )
        styleButton.showsMenuAsPrimaryAction = true
        coordinator.styleButton = styleButton
        styleButton.menu = coordinator.makeStyleMenu()
        let styleContainer = Self.glassContainer()
        styleContainer.contentView.addSubview(styleButton)
        NSLayoutConstraint.activate([
            styleButton.centerXAnchor.constraint(equalTo: styleContainer.contentView.centerXAnchor),
            styleButton.centerYAnchor.constraint(equalTo: styleContainer.contentView.centerYAnchor),
            styleContainer.widthAnchor.constraint(equalToConstant: 44),
            styleContainer.heightAnchor.constraint(equalToConstant: 44),
        ])

        let stack = UIStackView(arrangedSubviews: [styleContainer, trackingContainer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -100),
        ])
    }

    private static func glassContainer() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let parent: PlacemarkMapRepresentable
        weak var mapView: MKMapView?
        weak var styleButton: UIButton?
        var currentStyle: EmbeddedMapStyle?
        var lastFavoriteKeys: Set<String> = []
        var lastVisitedKeys: Set<String> = []

        init(_ parent: PlacemarkMapRepresentable) {
            self.parent = parent
        }

        // MARK: Basemap style

        /// Builds the style menu with a checkmark on the current selection.
        func makeStyleMenu() -> UIMenu {
            let actions = EmbeddedMapStyle.allCases.map { style in
                UIAction(
                    title: style.label,
                    image: UIImage(systemName: style.systemImage),
                    state: style == currentStyle ? .on : .off
                ) { [weak self] _ in
                    self?.selectStyle(style)
                }
            }
            return UIMenu(title: "Map Style", children: actions)
        }

        private func selectStyle(_ style: EmbeddedMapStyle) {
            currentStyle = style
            mapView?.preferredConfiguration = style.configuration
            UserDefaults.standard.set(style.rawValue, forKey: PlacemarkMapRepresentable.styleDefaultsKey)
            // Rebuild so the checkmark moves to the new selection.
            styleButton?.menu = makeStyleMenu()
        }

        // MARK: Annotation views

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PlacemarkMapRepresentable.clusterReuseID
                ) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(
                        annotation: annotation,
                        reuseIdentifier: PlacemarkMapRepresentable.clusterReuseID
                    )
                view.annotation = annotation
                view.markerTintColor = .systemBlue
                view.glyphText = "\(cluster.memberAnnotations.count)"
                return view
            }

            guard let placemark = annotation as? PlacemarkAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: PlacemarkMapRepresentable.placemarkReuseID
            ) ?? MKAnnotationView(
                annotation: annotation,
                reuseIdentifier: PlacemarkMapRepresentable.placemarkReuseID
            )
            view.annotation = annotation
            view.image = placemark.image
            // Cluster only when enabled. With clustering off, `.none` collision keeps
            // every overlapping pin visible; with it on, `.circle` clusters less
            // aggressively than the default rectangle.
            view.clusteringIdentifier = parent.clusterPins
                ? PlacemarkMapRepresentable.clusteringIdentifier
                : nil
            view.collisionMode = parent.clusterPins ? .circle : .none
            view.canShowCallout = false
            // Center-anchor: the SF Symbol fallback and typical KML point icons are
            // centered on their coordinate (no hotSpot parsing).
            view.centerOffset = .zero
            // Reset any highlight left over from view reuse.
            view.transform = .identity
            view.zPriority = .defaultUnselected
            return view
        }

        // MARK: Selection

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let cluster = annotation as? MKClusterAnnotation {
                let rect = cluster.memberAnnotations.reduce(MKMapRect.null) { acc, member in
                    let point = MKMapPoint(member.coordinate)
                    return acc.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
                }
                if rect.size.width == 0, rect.size.height == 0 {
                    let region = MKCoordinateRegion(
                        center: MKMapPoint(x: rect.origin.x, y: rect.origin.y).coordinate,
                        latitudinalMeters: 1000,
                        longitudinalMeters: 1000
                    )
                    mapView.setRegion(region, animated: true)
                } else {
                    mapView.setVisibleMapRect(
                        rect, edgePadding: PlacemarkMapRepresentable.edgePadding, animated: true
                    )
                }
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            if let placemark = annotation as? PlacemarkAnnotation {
                parent.selectedID = placemark.placemarkID
                setHighlighted(true, for: annotation, in: mapView)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: MKAnnotation) {
            guard annotation is PlacemarkAnnotation else { return }
            setHighlighted(false, for: annotation, in: mapView)
            // Defer: on a pin-to-pin tap, MapKit fires didDeselect(old) before
            // didSelect(new); checking now would momentarily clear and flicker the card.
            // After the runloop turn, selectedAnnotations reflects the new selection.
            DispatchQueue.main.async {
                if mapView.selectedAnnotations.isEmpty {
                    self.parent.selectedID = nil
                }
            }
        }

        /// Scales the selected pin up and raises it above neighbours; reverts on deselect.
        /// `view(for:)` may be nil if the annotation is offscreen, in which case there is
        /// nothing to highlight.
        private func setHighlighted(_ highlighted: Bool, for annotation: MKAnnotation, in mapView: MKMapView) {
            guard let view = mapView.view(for: annotation) else { return }
            view.zPriority = highlighted ? .max : .defaultUnselected
            UIView.animate(withDuration: 0.2) {
                view.transform = highlighted
                    ? CGAffineTransform(scaleX: PlacemarkMapRepresentable.selectedScale,
                                        y: PlacemarkMapRepresentable.selectedScale)
                    : .identity
            }
        }
    }
}
