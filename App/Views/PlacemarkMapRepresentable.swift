import MapKit
import PinfoldCore
import SwiftUI
import UIKit

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
/// - Bridges selection to `selectedKey`: tapping a pin writes its `stableKey`; clearing
///   `selectedKey` deselects on the map. Keying by `stableKey` (not the parse-order
///   `placemark.id`) means selection survives the document being re-parsed while open.
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
    @Binding var selectedKey: String?

    /// UserDefaults key for the persisted basemap style. The style control and its
    /// persistence are owned entirely by this representable / its coordinator.
    static let styleDefaultsKey = "embeddedMapStyle"

    /// Above this many placemarks, clustering is forced on regardless of the user's
    /// `clusterPins` setting: MapKit collapses (drops frames, stops responding) when asked
    /// to lay out tens of thousands of individual, non-colliding annotation views, so an
    /// unclustered map at that scale is unusable. Clustering keeps the view count bounded.
    static let forcedClusteringThreshold = 2000

    /// The clustering actually applied: the user's `clusterPins` setting, OR forced on when
    /// the placemark count exceeds `forcedClusteringThreshold`. Single source of truth read
    /// by `makeUIView`, the `viewFor` delegate (live, via `parent`), and reconciliation adds.
    var effectiveClustering: Bool {
        clusterPins || placemarks.count > Self.forcedClusteringThreshold
    }

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

        // Single creation path (shared with updateUIView's reconciliation): build one
        // annotation per pin-bearing placemark and register it in the coordinator's index.
        // `shouldShowPin` suppresses pins for pure line/polygon placemarks (the overlay is
        // their representation); track and point placemarks keep their pin.
        for placemark in placemarks where Self.shouldShowPin(placemark) {
            guard let annotation = makeAnnotation(for: placemark, coordinator: context.coordinator)
            else { continue }
            mapView.addAnnotation(annotation)
            context.coordinator.annotationsByKey[annotation.stableKey] = annotation
        }
        context.coordinator.lastPlacemarkKeys = Set(context.coordinator.annotationsByKey.keys)
        context.coordinator.lastDesiredKeys = Set(placemarks.map(\.stableKey))
        context.coordinator.lastFavoriteKeys = favoriteKeys
        context.coordinator.lastVisitedKeys = visitedKeys

        // Build + add geometry overlays (lines/polygons/tracks) and register them in the
        // sibling `overlaysByKey` index, keyed (like annotations) by placemark stableKey.
        let overlays = OverlayBuilder.overlays(for: placemarks, document: document)
        for styled in overlays {
            mapView.addOverlay(styled.overlay)
            context.coordinator.overlaysByKey[styled.stableKey, default: []].append(styled)
        }

        let coordinates = placemarks.compactMap(\.coordinate)
        mapView.onFirstLayout = { [weak mapView] in
            guard let mapView else { return }
            Self.fit(coordinates: coordinates, overlays: overlays, in: mapView, animated: false)
        }

        addControls(to: mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Standard idiom: refresh the coordinator's parent so delegate callbacks
        // (viewFor's clusterPins, didSelect/didDeselect's selection binding) read the
        // live struct rather than the makeCoordinator-time snapshot.
        let coordinator = context.coordinator
        coordinator.parent = self

        mapView.showsUserLocation = showsUserLocation

        // Reconcile placemark set: add new pins, drop removed ones. Only recompute when the
        // desired key-set actually changed (selection/favorite toggles re-enter updateUIView
        // too) — and re-fit only when the set changed, never on a bare re-render.
        // Reconcile by the full placemark key-set (not just pin-bearing placemarks): an
        // overlay-only placemark has no annotation but still owns overlays, so the diff must
        // see it. Pin suppression is then applied per-placemark when realizing annotations.
        // Guard on the FULL desired key-set (`lastDesiredKeys`), not `lastPlacemarkKeys`:
        // the latter only holds *pin-bearing* keys, so an overlay-only placemark would make
        // `desiredKeys != lastPlacemarkKeys` perpetually true and re-reconcile/re-fit on
        // every bare re-render (e.g. a selection toggle). `lastPlacemarkKeys` /
        // `overlaysByKey.keys` remain the realized-content sets the two diffs reconcile from.
        let desiredKeys = Set(placemarks.map(\.stableKey))
        if desiredKeys != coordinator.lastDesiredKeys {
            let diff = Self.annotationDiff(
                currentKeys: coordinator.lastPlacemarkKeys, desired: placemarks
            )
            for key in diff.toRemove {
                if let annotation = coordinator.annotationsByKey.removeValue(forKey: key) {
                    mapView.removeAnnotation(annotation)
                }
            }
            for placemark in diff.toAdd where Self.shouldShowPin(placemark) {
                guard let annotation = makeAnnotation(for: placemark, coordinator: coordinator)
                else { continue }
                mapView.addAnnotation(annotation)
                coordinator.annotationsByKey[annotation.stableKey] = annotation
            }
            coordinator.lastPlacemarkKeys = Set(coordinator.annotationsByKey.keys)

            // Mirror the diff onto overlays. Overlays are rebuilt from the desired set and
            // reconciled by the same stableKey identity, so a multi-geometry placemark's
            // overlays are added/removed together.
            let overlayDiff = Self.overlayDiff(
                currentKeys: Set(coordinator.overlaysByKey.keys), desired: placemarks
            )
            for key in overlayDiff.toRemove {
                if let styledList = coordinator.overlaysByKey.removeValue(forKey: key) {
                    mapView.removeOverlays(styledList.map(\.overlay))
                }
            }
            let addedOverlays = OverlayBuilder.overlays(for: overlayDiff.toAdd, document: document)
            for styled in addedOverlays {
                mapView.addOverlay(styled.overlay)
                coordinator.overlaysByKey[styled.stableKey, default: []].append(styled)
            }
            coordinator.lastDesiredKeys = desiredKeys

            // Re-fit to the new pin + overlay set (mirrors the first-layout fit).
            let allOverlays = coordinator.overlaysByKey.values.flatMap(\.self)
            Self.fit(
                coordinates: placemarks.compactMap(\.coordinate),
                overlays: allOverlays, in: mapView, animated: true
            )
        }

        // Reconcile SwiftUI -> map selection: if SwiftUI cleared it, deselect on the map
        // (which reverts the highlight via didDeselect).
        if selectedKey == nil {
            for annotation in mapView.selectedAnnotations where annotation is PlacemarkAnnotation {
                mapView.deselectAnnotation(annotation, animated: true)
            }
        }

        // Re-decorate pins only when the sets actually changed — selection flips
        // selectedKey and triggers updateUIView too, so without this guard every tap
        // would re-composite UIGraphicsImageRenderer images for all N annotations.
        // Walk the coordinator's own index (not mapView.annotations) so we touch exactly
        // the placemark pins. `view(for:)` is nil for offscreen annotations — annotation.image
        // still lands, so viewFor(_:) picks up the correct image on next reuse.
        let decorationChanged = coordinator.lastFavoriteKeys != favoriteKeys
            || coordinator.lastVisitedKeys != visitedKeys
        if decorationChanged {
            coordinator.lastFavoriteKeys = favoriteKeys
            coordinator.lastVisitedKeys = visitedKeys
            for annotation in coordinator.annotationsByKey.values {
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

    // MARK: - Annotation reconciliation

    //
    // The pure diff/pin-rule helpers (`annotationDiff`, `overlayDiff`, `shouldShowPin`) live
    // in `PlacemarkMapSupport.swift` as a `nonisolated` extension on this type.

    /// Builds a `PlacemarkAnnotation` for `placemark` (returns `nil` if it has no
    /// coordinate). Single creation path shared by `makeUIView` and `updateUIView`'s
    /// reconciliation. The base image is resolved through `coordinator.pinImageCache`,
    /// keyed by style identity, so the disk I/O + scaling happens once per distinct style
    /// (O(styles)), not per placemark; decoration stays per-annotation.
    func makeAnnotation(for placemark: KMLPlacemark, coordinator: Coordinator) -> PlacemarkAnnotation? {
        guard let coordinate = placemark.coordinate else { return nil }
        let key = PlacemarkPinImage.cacheKey(for: placemark, document: document)
        let base: UIImage
        if let cached = coordinator.pinImageCache[key] {
            base = cached
        } else {
            base = PlacemarkPinImage.image(
                for: placemark, document: document, entry: entry,
                resourceCache: resourceCache, storage: storage
            )
            coordinator.pinImageCache[key] = base
        }
        let image = PlacemarkPinImage.decorated(
            base,
            isFavorite: favoriteKeys.contains(placemark.stableKey),
            isVisited: visitedKeys.contains(placemark.stableKey)
        )
        return PlacemarkAnnotation(
            stableKey: placemark.stableKey,
            coordinate: CLLocationCoordinate2D(
                latitude: coordinate.latitude, longitude: coordinate.longitude
            ),
            title: placemark.name,
            baseImage: base,
            image: image
        )
    }

    // MARK: - Fit to pins

    /// Fits the map to the union of all pin coordinates and overlay bounding rects.
    ///
    /// Overlay rects are folded in via `MKMapRect.union` on each overlay's
    /// `boundingMapRect`. Antimeridian handling for *overlays* stays naive (a line that
    /// straddles the 180° seam can over-expand the fit) — `MapRectBuilder`'s wrapped-rect
    /// logic applies only to the point set; overlay coordinates are typically dense enough
    /// that a seam-crossing fit is an acceptable edge case here.
    static func fit(
        coordinates: [Coordinate],
        overlays: [StyledOverlay] = [],
        in mapView: MKMapView,
        animated: Bool
    ) {
        var rect = MapRectBuilder.boundingRect(for: coordinates) ?? .null
        for styled in overlays {
            rect = rect.union(styled.overlay.boundingMapRect)
        }
        guard !rect.isNull else { return }
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

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// The current representable. Refreshed at the top of every `updateUIView`
        /// (`context.coordinator.parent = self`) so delegate callbacks read live values
        /// (e.g. `clusterPins`, selection binding) rather than the makeCoordinator-time
        /// snapshot.
        var parent: PlacemarkMapRepresentable
        weak var mapView: MKMapView?
        weak var styleButton: UIButton?
        var currentStyle: EmbeddedMapStyle?
        var lastFavoriteKeys: Set<String> = []
        var lastVisitedKeys: Set<String> = []
        /// The set of placemark `stableKey`s currently realized as annotations on the map.
        /// Compared against the desired set each `updateUIView` to skip reconciliation when
        /// nothing changed.
        var lastPlacemarkKeys: Set<String> = []
        /// Live index of the placemark annotations on the map, keyed by `stableKey`. Lets
        /// favorite/visited re-decoration touch exactly the annotations it owns instead of
        /// walking every `mapView.annotations` (which also includes the user-location dot
        /// and the geometry overlays' renderers).
        ///
        /// ## Registry invariant (WP-G)
        /// This index — together with `overlaysByKey` — is the **sole mutator** of the
        /// placemark annotations and overlays on the `MKMapView`: nothing else may
        /// `addAnnotation`/`removeAnnotation`/`addOverlay`/`removeOverlay` for placemark
        /// content. Reconciliation is purely by **identity** — the `stableKey` set, not
        /// content. A same-key *content* change is never observed live: the document is
        /// re-parsed from disk on open, which re-derives every hash-based `stableKey`
        /// ("h:…") from the placemark's own name/coordinate, so a content change yields a
        /// *new* key (an add+remove), not an in-place mutation. Only an author-supplied
        /// id-keyed placemark ("id:…") could in theory keep its key while its content
        /// changes — and that cannot happen within a single parse, where each id appears
        /// once. The diff therefore never needs to compare content under a stable key.
        var annotationsByKey: [String: PlacemarkAnnotation] = [:]
        /// Live index of the geometry overlays on the map, keyed by the owning placemark's
        /// `stableKey`. A multi-geometry placemark maps to several `StyledOverlay`s under one
        /// key (added/removed as a group). Mirrors `annotationsByKey`; see that property's
        /// **Registry invariant** doc — the same sole-mutator / identity-reconciliation rules
        /// apply here.
        var overlaysByKey: [String: [StyledOverlay]] = [:]
        /// The full set of placemark `stableKey`s desired on the last reconcile (pins +
        /// overlay-only placemarks). The reconciliation guard compares against this — not
        /// `lastPlacemarkKeys` (pins only) — so an overlay-only placemark doesn't trigger a
        /// reconcile/re-fit on every bare re-render.
        var lastDesiredKeys: Set<String> = []
        /// Base (un-decorated) pin images keyed by style identity. A KML file has FEW
        /// distinct styles, so this turns the O(placemarks) disk-read + scale work in
        /// `makeAnnotation` into O(styles): the first placemark of each style builds its
        /// base image (one `UIImage(contentsOfFile:)` + resize, or one SF-Symbol render),
        /// and every later placemark of that style reuses it. Decoration stays per-annotation.
        var pinImageCache: [PlacemarkPinImage.CacheKey: UIImage] = [:]

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
            // Cluster only when enabled (or forced on above the threshold). With clustering
            // off, `.none` collision keeps every overlapping pin visible; with it on,
            // `.circle` clusters less aggressively than the default rectangle.
            let clustering = parent.effectiveClustering
            view.clusteringIdentifier = clustering
                ? PlacemarkMapRepresentable.clusteringIdentifier
                : nil
            view.collisionMode = clustering ? .circle : .none
            view.canShowCallout = false
            // Center-anchor: the SF Symbol fallback and typical KML point icons are
            // centered on their coordinate (no hotSpot parsing).
            view.centerOffset = .zero
            // Reset any highlight left over from view reuse.
            view.transform = .identity
            view.zPriority = .defaultUnselected
            return view
        }

        // MARK: Overlay rendering

        /// Renders a geometry overlay from the style baked into its `StyledPolyline`/
        /// `StyledPolygon` subclass — read by overlay identity, so no side table is needed.
        /// Any non-styled overlay falls back to a plain renderer.
        func mapView(_: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? StyledPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = polygon.stroke
                renderer.fillColor = polygon.fill
                renderer.lineWidth = polygon.lineWidth
                return renderer
            }
            if let polyline = overlay as? StyledPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.stroke
                renderer.lineWidth = polyline.lineWidth
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: Selection

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let cluster = annotation as? MKClusterAnnotation {
                // Zoom to the cluster's members. Reuse Self.fit so the single-/coincident-
                // member case (zero-size rect → fixed ~1 km span) matches the first-layout
                // fit exactly.
                let coordinates = cluster.memberAnnotations.map { member in
                    Coordinate(
                        longitude: member.coordinate.longitude, latitude: member.coordinate.latitude
                    )
                }
                PlacemarkMapRepresentable.fit(coordinates: coordinates, in: mapView, animated: true)
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            if let placemark = annotation as? PlacemarkAnnotation {
                parent.selectedKey = placemark.stableKey
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
                    self.parent.selectedKey = nil
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
