import MapKit
import PinfoldCore
import SwiftUI
import UIKit

// MARK: - PlacemarkMapRepresentable

/// Wraps `MKMapView` directly (SwiftUI's `Map` is more limited) to render many pins
/// with full control over annotation views.
///
/// - Builds one `PlacemarkAnnotation` per placemark (with its `PlacemarkPinImage`).
/// - Fits all pins on first layout; single pin → a fixed ~1 km span.
/// - Shows the user-location dot with heading when `showsUserLocation` is `true`.
/// - Clustering follows `clusterPins`: when on, nearby pins group into numbered
///   clusters (tapping a cluster zooms to its members); when off, every pin renders
///   individually even when overlapping.
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
    /// When non-nil and it matches a realized pin, the map opens zoomed to and with that
    /// pin selected (its preview card shown) instead of fitting all pins — the "Show on
    /// Embedded Map" deep link from the POI page. `nil` → fit all pins (the default).
    var initialFocusKey: String?
    @Binding var selectedKey: String?

    /// UserDefaults key for the persisted basemap style. The style control and its
    /// persistence are owned entirely by this representable / its coordinator.
    static let styleDefaultsKey = "embeddedMapStyle"

    /// Per-file remembered camera. Stateless wrapper over UserDefaults, so constructing it
    /// per representable value is free.
    let cameraStore = MapCameraStore()

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

    static let clusteringIdentifier = "kml.placemark"
    static let placemarkReuseID = "placemark"
    static let clusterReuseID = "cluster"
    static let edgePadding = UIEdgeInsets(top: 80, left: 60, bottom: 140, right: 60)
    static let selectedScale: CGFloat = 1.5

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = FittingMapView()
        mapView.delegate = context.coordinator
        Self.configureUserLocation(on: mapView, showsUserLocation: showsUserLocation, animated: false)
        let initialStyle = EmbeddedMapStyle(
            rawValue: UserDefaults.standard.string(forKey: Self.styleDefaultsKey) ?? ""
        ) ?? .standard
        mapView.preferredConfiguration = initialStyle.configuration
        context.coordinator.mapView = mapView
        context.coordinator.currentStyle = initialStyle
        context.coordinator.lastShowsUserLocation = showsUserLocation

        // Single creation path (shared with updateUIView's reconciliation): build one
        // annotation per pin-bearing placemark and register it in the coordinator's index.
        // `shouldShowPin` suppresses pins for pure line/polygon placemarks (the overlay is
        // their representation); track and point placemarks keep their pin.
        context.coordinator.addPinsInBatches(placemarks.filter(Self.shouldShowPin), to: mapView)
        context.coordinator.lastPlacemarkKeys = context.coordinator.realizedPinKeys
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

        let coordinates = Self.fitCoordinates(for: placemarks)
        let focusKey = initialFocusKey
        let savedCamera = cameraStore.camera(forFolderName: entry.storageFolderName)
        let userLocationVisible = showsUserLocation
        mapView.onFirstLayout = { [weak mapView, weak coordinator = context.coordinator] in
            guard let mapView, let coordinator else { return }
            coordinator.suppressCameraSave = true
            // Initial-focus deep link ("Show on Embedded Map"): if the carried key resolves
            // to a realized pin, zoom to it and select it (surfacing its preview card).
            // Otherwise a remembered per-file state wins over the fit-all default.
            if let focusKey, let annotation = coordinator.realizedPin(forKey: focusKey, on: mapView) {
                Self.focus(on: annotation, in: mapView)
            } else if let savedCamera {
                if savedCamera.isTracking, userLocationVisible {
                    // The user left this file's map following them — resume following
                    // (plain follow where heading hardware is absent, e.g. the Mac
                    // runtime). MapKit recenters once a fix arrives; no programmatic
                    // framing needed. `suppressCameraSave` stays armed, deliberately
                    // dropping the first tracking-recenter settle's save — the store
                    // already holds this exact state.
                    mapView.setUserTrackingMode(
                        CLLocationManager.headingAvailable() ? .followWithHeading : .follow,
                        animated: false
                    )
                } else {
                    Self.apply(savedCamera, to: mapView)
                }
            } else {
                Self.fit(coordinates: coordinates, overlays: overlays, in: mapView, animated: false)
            }
            coordinator.didInitialFrame = true
        }

        addControls(to: mapView, coordinator: context.coordinator)
        context.coordinator.installOverlayTapRecognizer(on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Standard idiom: refresh the coordinator's parent so delegate callbacks
        // (viewFor's clusterPins, didSelect/didDeselect's selection binding) read the
        // live struct rather than the makeCoordinator-time snapshot.
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.lastShowsUserLocation != showsUserLocation {
            Self.configureUserLocation(on: mapView, showsUserLocation: showsUserLocation, animated: true)
            coordinator.lastShowsUserLocation = showsUserLocation
        }

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
                coordinator.removePins(forKey: key, from: mapView)
            }
            coordinator.addPinsInBatches(diff.toAdd.filter(Self.shouldShowPin), to: mapView)
            coordinator.lastPlacemarkKeys = coordinator.realizedPinKeys

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

            // Re-fit to the new pin + overlay set (mirrors the first-layout fit). It is
            // programmatic: its settle callback must not overwrite the remembered camera.
            coordinator.suppressCameraSave = true
            let allOverlays = coordinator.overlaysByKey.values.flatMap(\.self)
            Self.fit(
                coordinates: Self.fitCoordinates(for: placemarks),
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
        coordinator.applyOverlayHighlight(forKey: selectedKey)
        let changedKeys = Self.decorationDiff(
            oldFavorites: coordinator.lastFavoriteKeys, newFavorites: favoriteKeys,
            oldVisited: coordinator.lastVisitedKeys, newVisited: visitedKeys
        )
        coordinator.lastFavoriteKeys = favoriteKeys
        coordinator.lastVisitedKeys = visitedKeys
        for key in changedKeys {
            for annotation in coordinator.pins(forKey: key) {
                redecorate(annotation, on: mapView, coordinator: coordinator)
            }
        }
    }

    /// Re-decorates one pin from the decoration cache. The fresh image and its
    /// `centerOffset` move together: a tip-anchored pin's height changes when its favorite
    /// badge is added/removed, so the offset is re-derived to keep the tip on the
    /// coordinate. Offscreen views are nil here; `viewFor` recomputes both from the
    /// (now-fresh) `annotation.image` on reuse.
    private func redecorate(_ annotation: PlacemarkAnnotation, on mapView: MKMapView, coordinator: Coordinator) {
        let fresh = coordinator.decorationCache.image(
            for: annotation.baseImage,
            isFavorite: favoriteKeys.contains(annotation.stableKey),
            isVisited: visitedKeys.contains(annotation.stableKey),
            anchor: annotation.anchor
        )
        annotation.image = fresh
        if let view = mapView.view(for: annotation) {
            view.image = fresh
            view.centerOffset = annotation.anchor.centerOffset(forImageOfHeight: fresh.size.height)
        }
    }

    // MARK: - Annotation reconciliation

    //
    // The pure diff/pin-rule helpers (`annotationDiff`, `overlayDiff`, `shouldShowPin`) live
    // in `PlacemarkMapSupport.swift` as a `nonisolated` extension on this type.

    /// Builds the `PlacemarkAnnotation` for `placemark`'s representative point, plus one per
    /// extra MultiGeometry point (all sharing the placemark's `stableKey`). Returns `nil`
    /// if the placemark has no coordinate. Single creation path shared by `makeUIView` and
    /// `updateUIView`'s reconciliation. The base image is resolved through
    /// `coordinator.pinImageCache`, keyed by style identity, so the disk I/O + scaling
    /// happens once per distinct style (O(styles)), not per placemark; decoration stays
    /// per-annotation.
    func makeAnnotations(
        for placemark: KMLPlacemark, coordinator: Coordinator
    ) -> (primary: PlacemarkAnnotation, extras: [PlacemarkAnnotation])? {
        guard let coordinate = placemark.coordinate else { return nil }
        let key = PlacemarkPinImage.cacheKey(for: placemark, document: document)
        let base: (image: UIImage, anchor: PinAnchor)
        if let cached = coordinator.pinImageCache[key] {
            base = cached
        } else {
            base = PlacemarkPinImage.image(
                for: placemark, document: document, entry: entry,
                resourceCache: resourceCache, storage: storage
            )
            coordinator.pinImageCache[key] = base
        }
        let image = coordinator.decorationCache.image(
            for: base.image,
            isFavorite: favoriteKeys.contains(placemark.stableKey),
            isVisited: visitedKeys.contains(placemark.stableKey),
            anchor: base.anchor
        )
        func annotation(at coordinate: Coordinate) -> PlacemarkAnnotation {
            PlacemarkAnnotation(
                stableKey: placemark.stableKey,
                coordinate: CLLocationCoordinate2D(
                    latitude: coordinate.latitude, longitude: coordinate.longitude
                ),
                title: placemark.name,
                baseImage: base.image,
                image: image,
                anchor: base.anchor
            )
        }
        return (annotation(at: coordinate), Self.extraPoints(of: placemark).map(annotation(at:)))
    }
}
