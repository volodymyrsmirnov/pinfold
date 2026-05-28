@testable import PinfoldCore
import Testing

struct CoordinateTests {
    @Test func parsesSimpleTuple() {
        let c = Coordinate(parsingFirstTuple: "12.4829,41.8833,0")
        #expect(c?.longitude == 12.4829)
        #expect(c?.latitude == 41.8833)
        #expect(c?.altitude == 0)
    }

    @Test func parsesWithSurroundingWhitespaceAndNewlines() {
        let c = Coordinate(parsingFirstTuple: "\n            -21.9265,64.142,0\n          ")
        #expect(c?.longitude == -21.9265)
        #expect(c?.latitude == 64.142)
    }

    @Test func takesFirstOfMultipleTuples() {
        let c = Coordinate(parsingFirstTuple: " -112.0814,36.1067,0 -112.0870,36.0905,0 ")
        #expect(c?.longitude == -112.0814)
        #expect(c?.latitude == 36.1067)
    }

    @Test func altitudeOptionalWhenMissing() {
        let c = Coordinate(parsingFirstTuple: "12.5,41.9")
        #expect(c?.altitude == nil)
        #expect(c?.longitude == 12.5)
    }

    @Test func returnsNilForGarbage() {
        #expect(Coordinate(parsingFirstTuple: "   ") == nil)
        #expect(Coordinate(parsingFirstTuple: "abc") == nil)
    }

    @Test func rejectsNonFiniteValues() {
        // `Double("nan")` → NaN, `Double("1e999")` → +Infinity. Both must be rejected so
        // they never reach MapKit as invalid map points.
        #expect(Coordinate(parsingFirstTuple: "nan,41.9") == nil)
        #expect(Coordinate(parsingFirstTuple: "12.5,inf") == nil)
        #expect(Coordinate(parsingFirstTuple: "1e999,41.9") == nil)
    }

    @Test func keepsFiniteOutOfRangeValues() {
        // Out-of-range but finite coordinates are intentionally preserved, not clamped or
        // dropped — dropping would make a renderable placemark silently vanish.
        let c = Coordinate(parsingFirstTuple: "200.0,95.0")
        #expect(c?.longitude == 200.0)
        #expect(c?.latitude == 95.0)
    }

    @Test func dropsNonFiniteAltitudeButKeepsTuple() {
        let c = Coordinate(parsingFirstTuple: "12.5,41.9,1e999")
        #expect(c?.longitude == 12.5)
        #expect(c?.latitude == 41.9)
        #expect(c?.altitude == nil)
    }
}
