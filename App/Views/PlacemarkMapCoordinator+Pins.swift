import MapKit
import PinfoldCore

extension PlacemarkMapRepresentable.Coordinator {
    /// Every placemark pin on the map: the primary pins plus the extra MultiGeometry points.
    var allPinAnnotations: [PlacemarkAnnotation] {
        Array(annotationsByKey.values) + extraAnnotationsByKey.values.flatMap(\.self)
    }

    /// Realizes a placemark's pin group (primary + extras) and registers it. The sole
    /// creation path for placemark annotations — see the registry invariant on
    /// `annotationsByKey`.
    func addPins(for placemark: KMLPlacemark, to mapView: MKMapView) {
        guard let pins = parent.makeAnnotations(for: placemark, coordinator: self) else { return }
        mapView.addAnnotation(pins.primary)
        annotationsByKey[pins.primary.stableKey] = pins.primary
        if !pins.extras.isEmpty {
            mapView.addAnnotations(pins.extras)
            extraAnnotationsByKey[pins.primary.stableKey] = pins.extras
        }
    }

    /// Removes a placemark's whole pin group (primary + extras) and unregisters it.
    func removePins(forKey key: String, from mapView: MKMapView) {
        if let annotation = annotationsByKey.removeValue(forKey: key) {
            mapView.removeAnnotation(annotation)
        }
        if let extras = extraAnnotationsByKey.removeValue(forKey: key) {
            mapView.removeAnnotations(extras)
        }
    }
}
