import PinfoldCore
import MapKit

// MARK: - MapRectBuilder

/// Computes a bounding `MKMapRect` over a set of coordinates, used to fit all of a
/// file's pins on screen.
///
/// Returns `nil` for empty input. A single coordinate yields a zero-size rect at that
/// point (the caller substitutes a fixed span for the single-pin case). Antimeridian
/// spanning is intentionally **not** specially handled — the naive union is accepted
/// for this offline catalogue viewer.
enum MapRectBuilder {

    static func boundingRect(for coordinates: [Coordinate]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            let pointRect = MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))
            rect = rect.union(pointRect)
        }
        return rect
    }
}
