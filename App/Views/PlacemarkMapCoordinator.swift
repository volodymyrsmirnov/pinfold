import MapKit
import PinfoldCore
import SwiftUI
import UIKit

extension PlacemarkMapRepresentable {
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
        var lastShowsUserLocation = false
        /// Set once the first-layout framing (focus / saved camera / fit-all) has been
        /// applied; region changes before that are layout noise and must not be saved.
        var didInitialFrame = false
        /// The last tracking mode MapKit reported. Lets `didChange` distinguish the user's
        /// engage tap (.none → .follow, which gets the heading upgrade) from MapKit's own
        /// gesture demotion (.followWithHeading → .follow when the user rotates the map),
        /// which must be respected, not fought.
        var lastReportedTrackingMode: MKUserTrackingMode = .none
        /// One-shot suppression for the region-settle callback of a programmatic framing
        /// (initial framing, reconcile re-fit) so it doesn't overwrite the saved camera.
        /// The fit-all BUTTON deliberately does not set it: its settle callback saving the
        /// fit-all framing is what makes the button a natural "reset".
        var suppressCameraSave = false
        /// Pins waiting to be added in batches (D6); see `addPinsInBatches`.
        var pendingPins = PendingPins()
        var isDrainingPins = false
        /// Memoized decorated pin images keyed by style + favourite + visited (D6).
        let decorationCache = PinDecorationCache()
        /// The `stableKey` whose overlays are currently drawn highlighted (D2).
        var highlightedOverlayKey: String?
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
        /// The extra pins of multi-point placemarks (the 2nd+ `<Point>` of a MultiGeometry),
        /// keyed by the owning placemark's `stableKey` — the same key as the primary pin in
        /// `annotationsByKey`. Same **Registry invariant**: this is the sole mutator of
        /// those annotations; they are added, removed and re-decorated as a group with the
        /// placemark, and selecting any of them selects the placemark.
        var extraAnnotationsByKey: [String: [PlacemarkAnnotation]] = [:]
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
        /// The cached value carries the pin's `PinAnchor` alongside its base image.
        var pinImageCache: [PlacemarkPinImage.CacheKey: (image: UIImage, anchor: PinAnchor)] = [:]

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

        /// Fits all pins + overlays (the pre-camera-persistence default framing). Wired to
        /// the control column's fit-all button. Deliberately does NOT suppress the settle
        /// save: the resulting framing is persisted, making this the "reset" for the
        /// remembered camera.
        ///
        /// A deliberate "show everything": disengage tracking first (follow mode would
        /// immediately recenter the fit onto the user). The didChange save records the
        /// disengage at the old camera; the fit's own unsuppressed settle then records
        /// the fit framing — so tracking-off-at-fit is what gets remembered.
        func fitAllPins() {
            guard let mapView else { return }
            mapView.setUserTrackingMode(.none, animated: false)
            let overlays = overlaysByKey.values.flatMap(\.self)
            PlacemarkMapRepresentable.fit(
                coordinates: PlacemarkMapRepresentable.fitCoordinates(for: parent.placemarks),
                overlays: overlays, in: mapView, animated: true
            )
        }

        // MARK: Camera persistence

        /// Fires once per settled gesture or animation — the per-file camera save point.
        /// User-tracking pans settle through here too and are saved deliberately: "where
        /// the map was following me" IS where the user was.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated _: Bool) {
            if suppressCameraSave {
                suppressCameraSave = false
                return
            }
            guard didInitialFrame else { return }
            parent.cameraStore.setCamera(
                PlacemarkMapRepresentable.cameraState(of: mapView),
                forFolderName: parent.entry.storageFolderName
            )
        }

        /// Tracking-mode changes: preserve the heading coupling for the USER's engage tap
        /// only (the MKUserTrackingButton's `.none → .follow`; upgrade it to
        /// `.followWithHeading` — tracking is never auto-engaged anywhere else), and
        /// persist the on/off state per file so reopening the map resumes it.
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            let previous = lastReportedTrackingMode
            lastReportedTrackingMode = mode
            // Heading coupling: upgrade ONLY the user's engage tap (.none → .follow). A
            // .followWithHeading → .follow transition is MapKit releasing the heading lock
            // for a manual rotate — fighting it would recreate the "map overrides the
            // user's camera" bug this feature fixed. Heading-incapable hardware (the Mac
            // "Designed for iPad" runtime has no magnetometer) never upgrades: a rejected
            // .followWithHeading could clamp back to .follow and ping-pong this handler.
            if mode == .follow, previous == .none, CLLocationManager.headingAvailable() {
                mapView.setUserTrackingMode(.followWithHeading, animated: animated)
                return // the upgrade re-fires this callback; save from that pass
            }
            guard didInitialFrame else { return }
            parent.cameraStore.setCamera(
                PlacemarkMapRepresentable.cameraState(of: mapView),
                forFolderName: parent.entry.storageFolderName
            )
        }

        // MARK: Annotation views

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }

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
            // Anchor per the pin's PinAnchor: the teardrop fallback is tip-anchored (points
            // at its coordinate); custom KML icons stay centre-anchored (no hotSpot parsing).
            view.centerOffset = placemark.anchor.centerOffset(forImageOfHeight: placemark.image.size.height)
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
                renderer.lineWidth = polygon.lineWidth * highlightFactor(for: polygon.stableKey)
                return renderer
            }
            if let polyline = overlay as? StyledPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.stroke
                renderer.lineWidth = polyline.lineWidth * highlightFactor(for: polyline.stableKey)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func highlightFactor(for key: String) -> CGFloat {
            key == highlightedOverlayKey ? Self.highlightWidthFactor : 1
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
            guard let pin = annotation as? PlacemarkAnnotation else { return }
            let key = pin.stableKey
            setHighlighted(false, for: annotation, in: mapView)
            // Defer: on a pin-to-pin tap, MapKit fires didDeselect(old) before
            // didSelect(new); checking now would momentarily clear and flicker the card.
            // After the runloop turn, selectedAnnotations reflects the new selection.
            DispatchQueue.main.async {
                // Only clear what this pin owned: a tap on a line/polygon sets
                // `selectedKey` to the overlay's key while it deselects the pin.
                if mapView.selectedAnnotations.isEmpty, self.parent.selectedKey == key {
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
