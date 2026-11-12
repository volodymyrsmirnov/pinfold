import MapKit
import UIKit

// MARK: - Tap selection and highlight for lines and polygons (D2)

extension PlacemarkMapRepresentable.Coordinator {
    /// How far (in screen points) from a line or polygon edge a tap still counts.
    static let overlayTapTolerance: CGFloat = 22
    /// The selected overlay's stroke is drawn this many times thicker.
    static let highlightWidthFactor: CGFloat = 2

    /// Installs the overlay tap recogniser. It never blocks MapKit's own gestures, but it waits
    /// for every double-tap recogniser (MapKit's double-tap zoom plus our own placeholder, which
    /// guarantees at least one) to fail, so a double-tap zoom never also changes the selection.
    func installOverlayTapRecognizer(on mapView: MKMapView) {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleOverlayTap(_:)))
        recognizer.delegate = self
        let placeholder = UITapGestureRecognizer()
        placeholder.numberOfTapsRequired = 2
        placeholder.delegate = self
        mapView.addGestureRecognizer(placeholder)
        mapView.addGestureRecognizer(recognizer)
        Self.requireDoubleTapsToFail(for: recognizer, in: mapView)
    }

    /// Makes `singleTap` wait for every double-tap recogniser found on `view` and its subviews.
    static func requireDoubleTapsToFail(for singleTap: UITapGestureRecognizer, in view: UIView) {
        for candidate in view.gestureRecognizers ?? [] {
            if let tap = candidate as? UITapGestureRecognizer, tap !== singleTap, tap.numberOfTapsRequired == 2 {
                singleTap.require(toFail: tap)
            }
        }
        for subview in view.subviews {
            requireDoubleTapsToFail(for: singleTap, in: subview)
        }
    }

    @objc func handleOverlayTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let mapView else { return }
        let location = recognizer.location(in: mapView)
        let tolerance = OverlayHitTester.tolerance(
            screenPoints: Self.overlayTapTolerance,
            visibleMapWidth: mapView.visibleMapRect.size.width,
            boundsWidth: mapView.bounds.width
        )
        let point = MKMapPoint(mapView.convert(location, toCoordinateFrom: mapView))
        let candidates = hitCandidates(near: point, tolerance: tolerance)
        if let key = OverlayHitTester.hit(at: point, in: candidates, tolerance: tolerance) {
            for annotation in mapView.selectedAnnotations {
                mapView.deselectAnnotation(annotation, animated: false)
            }
            parent.selectedKey = key
            applyOverlayHighlight(forKey: key)
        } else if parent.selectedKey != nil {
            // A tap on bare map clears the selection (MapKit already deselects any pin).
            parent.selectedKey = nil
            applyOverlayHighlight(forKey: nil)
        }
    }

    /// Hit candidates for overlays whose bounds could contain `point`; the bounding-rect
    /// prefilter keeps a tap cheap even with thousands of overlays on the map.
    private func hitCandidates(near point: MKMapPoint, tolerance: Double) -> [OverlayHitTester.Candidate] {
        let probe = MKMapRect(x: point.x - tolerance, y: point.y - tolerance,
                              width: tolerance * 2, height: tolerance * 2)
        var result: [OverlayHitTester.Candidate] = []
        for (key, styledList) in overlaysByKey {
            for styled in styledList where styled.overlay.boundingMapRect.intersects(probe) {
                if let polyline = styled.overlay as? MKPolyline {
                    result.append(.init(key: key, shape: .line(polyline.mapPoints)))
                } else if let polygon = styled.overlay as? MKPolygon {
                    let holes = (polygon.interiorPolygons ?? []).map(\.mapPoints)
                    result.append(.init(key: key, shape: .polygon(outer: polygon.mapPoints, holes: holes)))
                }
            }
        }
        return result
    }

    /// Highlights the overlays of `key` (thicker stroke) and un-highlights the previous
    /// ones. `nil` clears. Idempotent; called after taps and from every `updateUIView`.
    func applyOverlayHighlight(forKey key: String?) {
        let overlayKey = key.flatMap { overlaysByKey[$0] == nil ? nil : $0 }
        guard overlayKey != highlightedOverlayKey else { return }
        let previous = highlightedOverlayKey
        highlightedOverlayKey = overlayKey
        for changed in [previous, overlayKey].compactMap(\.self) {
            for styled in overlaysByKey[changed] ?? [] {
                guard let renderer = mapView?.renderer(for: styled.overlay) as? MKOverlayPathRenderer
                else { continue }
                renderer.lineWidth = styled.lineWidth * (changed == overlayKey ? Self.highlightWidthFactor : 1)
                renderer.setNeedsDisplay()
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PlacemarkMapRepresentable.Coordinator: UIGestureRecognizerDelegate {
    /// Defers to annotation taps: a touch that lands on a pin (or cluster) view belongs to
    /// MapKit's selection, not to the overlay hit-test.
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is MKAnnotationView {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private extension MKMultiPoint {
    /// The vertices as a Swift array.
    var mapPoints: [MKMapPoint] {
        Array(UnsafeBufferPointer(start: points(), count: pointCount))
    }
}
