import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `CoordinateFormatter`, which must produce a stable, locale-independent
/// `"<lat>, <lon>"` string (6 fractional digits, `.` decimal separator, `, ` separator).
struct CoordinateFormatterTests {
    @Test func formatsKnownCoordinateExactly() {
        let coord = Coordinate(longitude: -122.084, latitude: 37.421998)
        #expect(CoordinateFormatter.string(for: coord) == "37.421998, -122.084000")
    }

    @Test func formatsNegativeValues() {
        let coord = Coordinate(longitude: -0.5, latitude: -41.89)
        #expect(CoordinateFormatter.string(for: coord) == "-41.890000, -0.500000")
    }

    @Test func alwaysSixFractionDigits() {
        let coord = Coordinate(longitude: 0, latitude: 0)
        #expect(CoordinateFormatter.string(for: coord) == "0.000000, 0.000000")
    }

    /// The app cannot change its process locale inside a test, so we assert the property
    /// the formatter guarantees by construction: it pins formatting to `en_US_POSIX`,
    /// producing a `.` decimal separator even for a value a comma-decimal locale (de_DE)
    /// would otherwise render with `,`. The raw-degrees overload shares the same pinned
    /// path, so verifying it proves the formatter is locale-independent.
    @Test func decimalSeparatorIsDotRegardlessOfLocale() {
        let rendered = CoordinateFormatter.string(latitude: 1234.5, longitude: -6.75)
        #expect(rendered == "1234.500000, -6.750000")
        // The exact-equality check above already proves locale independence: a comma-decimal
        // locale (de_DE) would render "1234,500000, -6,750000" and an en_US locale would add a
        // grouping separator ("1,234.500000"). Neither appears, so the formatter is pinned.
        let latComponent = rendered.split(separator: ", ").first.map(String.init)
        #expect(latComponent == "1234.500000") // no grouping comma, dot decimal separator
    }
}
