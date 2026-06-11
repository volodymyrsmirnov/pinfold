import CoreLocation
import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `PlacemarkDistance.format` — the pure, locale-aware distance formatter. The
/// formatted-string assertions avoid an exact locale-brittle match: they parse out the numeric
/// magnitude and assert it is plausible, and only require the string to be non-empty, so the
/// test passes under any locale's unit choice (metric vs. imperial) and separator.
struct PlacemarkDistanceTests {
    @Test func format_nilWhenLocationMissing() {
        let coordinate = Coordinate(longitude: 0, latitude: 0)
        #expect(PlacemarkDistance.format(from: nil, to: coordinate) == nil)
    }

    @Test func format_nilWhenCoordinateMissing() {
        let here = CLLocation(latitude: 0, longitude: 0)
        #expect(PlacemarkDistance.format(from: here, to: nil) == nil)
    }

    @Test func format_nilWhenBothMissing() {
        #expect(PlacemarkDistance.format(from: nil, to: nil) == nil)
    }

    @Test func format_zeroDistanceProducesString() {
        let here = CLLocation(latitude: 10, longitude: 20)
        let same = Coordinate(longitude: 20, latitude: 10)
        let formatted = PlacemarkDistance.format(from: here, to: same)
        // Same point: a real, non-empty string (e.g. "0 m" / "0 ft"); we don't assert the unit.
        #expect(formatted?.isEmpty == false)
    }

    @Test func format_equatorOneDegreeIsAboutHundredKilometres() throws {
        // One degree of longitude at the equator ≈ 111 km. We parse the leading numeric
        // magnitude out of the (locale-formatted) string and assert it's in a plausible band
        // for either metric (~111 km) or imperial (~69 mi) output — never an exact match.
        let here = CLLocation(latitude: 0, longitude: 0)
        let oneDegreeEast = Coordinate(longitude: 1, latitude: 0)
        let formatted = try #require(PlacemarkDistance.format(from: here, to: oneDegreeEast))
        #expect(!formatted.isEmpty)

        let magnitude = try #require(leadingNumber(in: formatted))
        // 111 km (metric) or ~69 mi (imperial) — both land comfortably in [50, 200].
        #expect(magnitude > 50 && magnitude < 200)
    }

    /// Extracts the first run of digits (with an optional decimal separator) and parses it as a
    /// Double, tolerating either "." or "," as the decimal mark so the parse is locale-agnostic.
    private func leadingNumber(in string: String) -> Double? {
        var digits = ""
        for character in string {
            if character.isNumber || character == "." || character == "," {
                digits.append(character == "," ? "." : character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}
