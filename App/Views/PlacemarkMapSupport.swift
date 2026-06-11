import MapKit
import PinfoldCore
import UIKit

// MARK: - PlacemarkAnnotation

/// An `MKAnnotation` for a single KML point placemark, carrying its durable `stableKey`
/// (for selection and favorite/visited lookup) and its pre-rendered pin image.
///
/// Identity is keyed entirely by `stableKey` — durable across re-parses — so selection
/// and decoration survive the document being re-parsed while a map is open. The
/// parse-order `placemark.id` is intentionally *not* stored.
final class PlacemarkAnnotation: NSObject, MKAnnotation {
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
        stableKey: String,
        coordinate: CLLocationCoordinate2D,
        title: String?,
        baseImage: UIImage,
        image: UIImage
    ) {
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

// MARK: - Native map controls

extension PlacemarkMapRepresentable {
    /// Adds the native control column (basemap-style menu + user-tracking button) to the
    /// map. Kept here, separate from the representable's data-reconciliation core, so each
    /// file stays focused.
    func addControls(to mapView: MKMapView, coordinator: Coordinator) {
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

    static func glassContainer() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

// MARK: - Reconciliation diffs & pin rule

extension PlacemarkMapRepresentable {
    /// Pure diff between the annotations currently on the map (`currentKeys`, a set of
    /// `stableKey`s) and the `desired` placemarks. Returns the placemarks to add and the
    /// keys to remove.
    ///
    /// Keyed by `stableKey` (durable across re-parses), matching how favorites/visited and
    /// selection identify placemarks. If two desired placemarks share a `stableKey`,
    /// **last wins** deterministically (the later element in `desired` is the one kept),
    /// so exactly one annotation exists per key. The sibling `overlayDiff` (for line/polygon/
    /// track geometry) follows the same shape and identity rules.
    nonisolated static func annotationDiff(
        currentKeys: Set<String>,
        desired: [KMLPlacemark]
    ) -> (toAdd: [KMLPlacemark], toRemove: Set<String>) {
        // Last-wins dedup: build an ordered, deduplicated list keyed by stableKey.
        var byKey: [String: KMLPlacemark] = [:]
        var order: [String] = []
        for placemark in desired {
            let key = placemark.stableKey
            if byKey[key] == nil { order.append(key) }
            byKey[key] = placemark
        }
        let desiredKeys = Set(order)
        let toAdd = order.compactMap { currentKeys.contains($0) ? nil : byKey[$0] }
        let toRemove = currentKeys.subtracting(desiredKeys)
        return (toAdd, toRemove)
    }

    /// Pure diff between the placemark stableKeys that currently own overlays
    /// (`currentKeys`) and the `desired` placemarks, restricted to those that carry
    /// geometry (an empty-geometry placemark owns no overlays, so it never appears in
    /// either side). Shares `annotationDiff`'s last-wins dedup and identity-by-stableKey
    /// rules: a multi-geometry placemark contributes one key, so its overlays are
    /// added/removed as a group.
    nonisolated static func overlayDiff(
        currentKeys: Set<String>,
        desired: [KMLPlacemark]
    ) -> (toAdd: [KMLPlacemark], toRemove: Set<String>) {
        let withGeometry = desired.filter { !$0.geometries.isEmpty }
        return annotationDiff(currentKeys: currentKeys, desired: withGeometry)
    }

    /// Whether a placemark is realized as a pin on the map.
    ///
    /// Pin-suppression rule: a placemark whose representation is *entirely* an overlay —
    /// it has captured geometry, no explicit `<Point>` (`hasPoint == false`), and none of
    /// its geometries is a track — gets **no pin**; the line/polygon overlay stands in for
    /// it. Everything else keeps its representative-point pin:
    /// - explicit point placemarks (`hasPoint == true`),
    /// - placemarks with no geometry at all,
    /// - **track** placemarks (a track's pin marks its start so the route is still findable
    ///   and selectable from the list, alongside its polyline).
    nonisolated static func shouldShowPin(_ placemark: KMLPlacemark) -> Bool {
        guard !placemark.geometries.isEmpty, !placemark.hasPoint else { return true }
        let isPureLineOrPolygon = placemark.geometries.allSatisfy { geometry in
            if case .track = geometry { return false }
            return true
        }
        return !isPureLineOrPolygon
    }
}
