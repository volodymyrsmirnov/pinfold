import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

struct PolylineSimplifierTests {
    private func wiggle(_ count: Int) -> [Coordinate] {
        (0 ..< count).map {
            Coordinate(longitude: Double($0) * 0.001, latitude: sin(Double($0) * 0.37) * 0.01)
        }
    }

    @Test func keepsEndpoints() {
        let line = wiggle(5000)
        let result = PolylineSimplifier.capped(line)
        #expect(result.first == line.first)
        #expect(result.last == line.last)
        let tight = PolylineSimplifier.simplify(line, tolerance: 0.5)
        #expect(tight.first == line.first)
        #expect(tight.last == line.last)
    }

    @Test func shortLinesAreUntouched() {
        let line = wiggle(1500)
        #expect(PolylineSimplifier.capped(line) == line)
        #expect(PolylineSimplifier.capped(wiggle(2000)).count == 2000)
    }

    @Test func longTrackIsReducedToTheCap() {
        let result = PolylineSimplifier.capped(wiggle(60000))
        #expect(result.count == PolylineSimplifier.maxVertices)
        let small = PolylineSimplifier.capped(wiggle(500), maxVertices: 50)
        #expect(small.count == 50)
    }

    @Test func straightLineCollapsesToTwoPoints() {
        let line = (0 ..< 100).map { Coordinate(longitude: Double($0), latitude: Double($0)) }
        let result = PolylineSimplifier.simplify(line, tolerance: 0.0001)
        #expect(result == [line[0], line[99]])
    }

    @Test func keptPointsStayInOriginalOrder() {
        let result = PolylineSimplifier.capped(wiggle(3000))
        let xs = result.map(\.longitude)
        #expect(xs == xs.sorted())
    }

    @Test func identicalPointsSimplifyQuickly() {
        let line = [Coordinate](repeating: Coordinate(longitude: 10, latitude: 20), count: 100_000)
        let start = ContinuousClock.now
        let result = PolylineSimplifier.capped(line)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(result.count == PolylineSimplifier.maxVertices)
        #expect(result.first == line.first && result.last == line.last)
    }

    @Test func collinearPointsSimplifyQuickly() {
        let line = (0 ..< 100_000).map { Coordinate(longitude: Double($0) * 0.0001, latitude: 5) }
        let start = ContinuousClock.now
        let result = PolylineSimplifier.capped(line)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(result.count == PolylineSimplifier.maxVertices)
        #expect(result.first == line.first && result.last == line.last)
    }
}
