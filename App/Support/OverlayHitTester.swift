import MapKit

/// Pure map-point hit-testing for tapping lines and polygons. No `MKMapView`, no state.
///
/// All geometry is in `MKMapPoint` space (planar, so plain 2D maths is right). A screen-
/// point tolerance becomes a map-point tolerance through the map's current scale, see
/// `tolerance(screenPoints:visibleMapWidth:boundsWidth:)`.
///
/// Precedence: the nearest line within tolerance wins; otherwise the smallest polygon whose
/// interior (minus its holes) contains the tap; otherwise the polygon whose border is
/// nearest within tolerance.
enum OverlayHitTester {
    enum Shape {
        case line([MKMapPoint])
        case polygon(outer: [MKMapPoint], holes: [[MKMapPoint]])
    }

    struct Candidate {
        let key: String
        let shape: Shape
    }

    /// Converts a tolerance in screen points to map points at the current zoom.
    static func tolerance(screenPoints: CGFloat, visibleMapWidth: Double, boundsWidth: CGFloat) -> Double {
        guard boundsWidth > 0 else { return 0 }
        return Double(screenPoints) * visibleMapWidth / Double(boundsWidth)
    }

    /// The `stableKey` of the overlay hit by a tap at `point`, or `nil` if none.
    static func hit(at point: MKMapPoint, in candidates: [Candidate], tolerance: Double) -> String? {
        var bestLine: (key: String, distance: Double)?
        var bestInterior: (key: String, area: Double)?
        var bestBorder: (key: String, distance: Double)?

        for candidate in candidates {
            switch candidate.shape {
            case let .line(points):
                let distance = distanceToPath(point, points, closed: false)
                if distance <= tolerance, distance < (bestLine?.distance ?? .infinity) {
                    bestLine = (candidate.key, distance)
                }
            case let .polygon(outer, holes):
                if contains(point, outer: outer, holes: holes) {
                    let area = boundsArea(outer)
                    if area < (bestInterior?.area ?? .infinity) {
                        bestInterior = (candidate.key, area)
                    }
                } else {
                    let rings = [outer] + holes
                    let distance = rings.map { distanceToPath(point, $0, closed: true) }.min() ?? .infinity
                    if distance <= tolerance, distance < (bestBorder?.distance ?? .infinity) {
                        bestBorder = (candidate.key, distance)
                    }
                }
            }
        }
        return bestLine?.key ?? bestInterior?.key ?? bestBorder?.key
    }

    /// Even-odd point-in-polygon: inside `outer` and outside every hole.
    static func contains(_ point: MKMapPoint, outer: [MKMapPoint], holes: [[MKMapPoint]]) -> Bool {
        guard ringContains(point, outer) else { return false }
        return !holes.contains { ringContains(point, $0) }
    }

    // MARK: - Maths

    private static func ringContains(_ point: MKMapPoint, _ ring: [MKMapPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossX = (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x
                if point.x < crossX {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    private static func distanceToPath(_ point: MKMapPoint, _ path: [MKMapPoint], closed: Bool) -> Double {
        guard let first = path.first else { return .infinity }
        guard path.count > 1 else { return distance(point, first) }
        var best = Double.infinity
        for index in 0 ..< path.count - 1 {
            best = min(best, distanceToSegment(point, path[index], path[index + 1]))
        }
        if closed, let last = path.last {
            best = min(best, distanceToSegment(point, last, first))
        }
        return best
    }

    private static func distanceToSegment(_ point: MKMapPoint, _ start: MKMapPoint, _ end: MKMapPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, start) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return distance(point, MKMapPoint(x: start.x + t * dx, y: start.y + t * dy))
    }

    private static func distance(_ lhs: MKMapPoint, _ rhs: MKMapPoint) -> Double {
        ((lhs.x - rhs.x) * (lhs.x - rhs.x) + (lhs.y - rhs.y) * (lhs.y - rhs.y)).squareRoot()
    }

    private static func boundsArea(_ ring: [MKMapPoint]) -> Double {
        guard let first = ring.first else { return 0 }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in ring {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return (maxX - minX) * (maxY - minY)
    }
}
