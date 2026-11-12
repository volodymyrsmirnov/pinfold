import MapKit
import PinfoldCore

/// Placemarks whose pins are waiting to be added to the map in batches (D6). A plain value
/// type so the queue behaviour is unit-testable without a map.
struct PendingPins {
    /// Pins added per run-loop turn.
    static let batchSize = 500

    private var queue: [KMLPlacemark] = []

    var isEmpty: Bool {
        queue.isEmpty
    }

    var keys: Set<String> {
        Set(queue.map(\.stableKey))
    }

    mutating func append(_ placemarks: [KMLPlacemark]) {
        queue.append(contentsOf: placemarks)
    }

    mutating func remove(key: String) {
        queue.removeAll { $0.stableKey == key }
    }

    /// Removes and returns the next batch (up to `batchSize`).
    mutating func takeBatch() -> [KMLPlacemark] {
        let batch = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(batch.count)
        return batch
    }

    /// Removes and returns the pending placemark with `key`, if queued.
    mutating func take(key: String) -> KMLPlacemark? {
        guard let index = queue.firstIndex(where: { $0.stableKey == key }) else { return nil }
        return queue.remove(at: index)
    }
}

extension PlacemarkMapRepresentable.Coordinator {
    /// Every placemark pin on the map: the primary pins plus the extra MultiGeometry points.
    var allPinAnnotations: [PlacemarkAnnotation] {
        Array(annotationsByKey.values) + extraAnnotationsByKey.values.flatMap(\.self)
    }

    /// The realized pins (primary + extras) of one placemark.
    func pins(forKey key: String) -> [PlacemarkAnnotation] {
        (annotationsByKey[key].map { [$0] } ?? []) + (extraAnnotationsByKey[key] ?? [])
    }

    /// Keys with a pin on the map or queued to get one. The reconciliation baseline, so a
    /// placemark still waiting for its batch is never queued twice.
    var realizedPinKeys: Set<String> {
        Set(annotationsByKey.keys).union(pendingPins.keys)
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

    /// Adds `placemarks`' pins: the first batch now, the rest in batches of
    /// `PendingPins.batchSize` on later run-loop turns so a 50k-point file never blocks
    /// the main thread for one long pass.
    func addPinsInBatches(_ placemarks: [KMLPlacemark], to mapView: MKMapView) {
        pendingPins.append(placemarks)
        drainBatch(on: mapView)
    }

    /// Adds the next batch, then schedules the following one.
    private func drainBatch(on mapView: MKMapView) {
        for placemark in pendingPins.takeBatch() {
            addPins(for: placemark, to: mapView)
        }
        guard !pendingPins.isEmpty, !isDrainingPins else { return }
        isDrainingPins = true
        DispatchQueue.main.async { [weak self, weak mapView] in
            guard let self else { return }
            isDrainingPins = false
            guard let mapView else { return }
            drainBatch(on: mapView)
        }
    }

    /// Realizes `key`'s pin right now if it is still queued (used so a focus deep link
    /// finds its pin on first layout), and returns the realized primary pin.
    func realizedPin(forKey key: String, on mapView: MKMapView) -> PlacemarkAnnotation? {
        if let placemark = pendingPins.take(key: key) {
            addPins(for: placemark, to: mapView)
        }
        return annotationsByKey[key]
    }

    /// Removes a placemark's whole pin group (primary + extras) and unregisters it,
    /// dropping it from the pending queue too.
    func removePins(forKey key: String, from mapView: MKMapView) {
        pendingPins.remove(key: key)
        if let annotation = annotationsByKey.removeValue(forKey: key) {
            mapView.removeAnnotation(annotation)
        }
        if let extras = extraAnnotationsByKey.removeValue(forKey: key) {
            mapView.removeAnnotations(extras)
        }
    }
}
