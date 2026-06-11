import CoreLocation
import Foundation
import PinfoldCore

// MARK: - PlacemarkDistance

/// Pure, locale-aware formatting of the straight-line distance between the user's location
/// and a placemark's coordinate. No CoreLocation manager, no I/O — just geometry + a
/// `Measurement` formatter, so it is trivially unit-testable.
enum PlacemarkDistance {
    /// The formatted distance from `from` to `to`, or `nil` when either is missing.
    ///
    /// Uses `CLLocation.distance(from:)` (great-circle metres) wrapped in a
    /// `Measurement<UnitLength>` and formatted with `.measurement(width: .abbreviated,
    /// usage: .road)`, which picks a sensible unit (m/km or ft/mi) for the current locale.
    static func format(from: CLLocation?, to: Coordinate?) -> String? {
        guard let from, let to else { return nil }
        let destination = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let metres = from.distance(from: destination)
        let measurement = Measurement(value: metres, unit: UnitLength.meters)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
