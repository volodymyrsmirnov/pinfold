import MapKit
@testable import Pinfold
import Testing

struct OverlayHitTesterTests {
    private func pts(_ pairs: [(Double, Double)]) -> [MKMapPoint] {
        pairs.map { MKMapPoint(x: $0.0, y: $0.1) }
    }

    private func line(_ key: String, _ pairs: [(Double, Double)]) -> OverlayHitTester.Candidate {
        .init(key: key, shape: .line(pts(pairs)))
    }

    private var square: OverlayHitTester.Candidate {
        .init(key: "poly", shape: .polygon(
            outer: pts([(0, 0), (100, 0), (100, 100), (0, 100)]),
            holes: [pts([(40, 40), (60, 40), (60, 60), (40, 60)])]
        ))
    }

    @Test func tapNearLineSelectsIt() {
        let candidates = [line("a", [(0, 0), (100, 0)])]
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 50, y: 4), in: candidates, tolerance: 5) == "a")
    }

    @Test func tapFarFromLineSelectsNothing() {
        let candidates = [line("a", [(0, 0), (100, 0)])]
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 50, y: 20), in: candidates, tolerance: 5) == nil)
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 150, y: 0), in: candidates, tolerance: 5) == nil)
    }

    @Test func tapInsidePolygonSelectsIt() {
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 10, y: 10), in: [square], tolerance: 2) == "poly")
    }

    @Test func tapInsideHoleSelectsNothing() {
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 50, y: 50), in: [square], tolerance: 2) == nil)
    }

    @Test func nearestOfTwoOverlappingLinesWins() {
        let candidates = [
            line("far", [(0, 0), (100, 0)]),
            line("near", [(0, 3), (100, 3)]),
        ]
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 50, y: 2), in: candidates, tolerance: 5) == "near")
    }

    @Test func lineBeatsPolygonItLiesOn() {
        let candidates = [square, line("track", [(0, 20), (100, 20)])]
        #expect(OverlayHitTester.hit(at: MKMapPoint(x: 30, y: 21), in: candidates, tolerance: 3) == "track")
    }

    @Test func toleranceScalesWithZoom() {
        #expect(OverlayHitTester.tolerance(screenPoints: 22, visibleMapWidth: 1000, boundsWidth: 400) == 55)
        #expect(OverlayHitTester.tolerance(screenPoints: 22, visibleMapWidth: 1000, boundsWidth: 0) == 0)
    }
}
