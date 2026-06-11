import Foundation
import PinfoldCore

/// Formats a `Coordinate` for display and copy-to-clipboard with a stable,
/// locale-independent representation: `"<lat>, <lon>"` with a `.` decimal separator,
/// a `", "` separator between latitude and longitude, and 6 fractional digits.
///
/// The output is deliberately **not** localized: coordinates are technical values that
/// users copy into other apps, paste into URLs, or share verbatim. A locale that uses a
/// `,` decimal separator (e.g. de_DE) would otherwise turn `37.421998, -122.084000` into
/// `37,421998, -122,084000`, which is ambiguous and unparseable. We pin the formatting to
/// `en_US_POSIX` via `String(format:locale:)` so the result is identical on every device
/// regardless of the user's region settings.
enum CoordinateFormatter {
    /// Number of fractional digits used for both latitude and longitude. Six digits is
    /// roughly 0.1 m of precision — plenty for any placemark, and the de-facto convention
    /// for sharing decimal coordinates.
    static let fractionDigits = 6

    /// Renders `"<latitude>, <longitude>"`, e.g. `"37.421998, -122.084000"`.
    static func string(for coordinate: Coordinate) -> String {
        string(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Renders `"<latitude>, <longitude>"` from raw degrees. Pinned to `en_US_POSIX` so
    /// the decimal separator is always `.` regardless of the device locale.
    static func string(latitude: Double, longitude: Double) -> String {
        String(
            format: "%.\(fractionDigits)f, %.\(fractionDigits)f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude
        )
    }
}
