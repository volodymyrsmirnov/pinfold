import PinfoldCore

/// Douglas-Peucker polyline simplification, used to keep long GPS tracks cheap to render.
///
/// Distances are measured in raw degrees (planar lon/lat): this is a visual thinning, not
/// a geodesy calculation, and at the zoom levels where a 2,000-vertex line still looks
/// identical to its source the distortion is irrelevant.
enum PolylineSimplifier {
    /// The vertex budget per overlay (the plan's call).
    static let maxVertices = 2000

    /// Returns `coordinates` reduced to at most `maxVertices` points, raising the effective
    /// tolerance as far as needed. Endpoints are always kept; lines already within the cap
    /// are returned untouched.
    ///
    /// Implementation: one Douglas-Peucker pass records, for every interior point, the
    /// distance at which the algorithm would first split on it (its "importance"). Keeping
    /// the `maxVertices - 2` most important interior points is the result of raising the
    /// tolerance until the cap is met, without re-running the pass.
    static func capped(_ coordinates: [Coordinate], maxVertices: Int = maxVertices) -> [Coordinate] {
        let cap = max(maxVertices, 2)
        guard coordinates.count > cap else { return coordinates }
        let importance = importances(of: coordinates)
        let last = coordinates.count - 1
        let keep = importance.indices
            .filter { $0 != 0 && $0 != last }
            .sorted { importance[$0] > importance[$1] }
            .prefix(cap - 2)
        let kept = Set(keep).union([0, last])
        return kept.sorted().map { coordinates[$0] }
    }

    /// Classic Douglas-Peucker at a fixed `tolerance` (degrees). Endpoints always survive;
    /// fewer than three points are returned as-is.
    static func simplify(_ coordinates: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }
        let importance = importances(of: coordinates)
        let last = coordinates.count - 1
        return coordinates.indices
            .filter { $0 == 0 || $0 == last || importance[$0] > tolerance }
            .map { coordinates[$0] }
    }

    /// For each point, the perpendicular distance at which Douglas-Peucker splits on it
    /// (0 for points never chosen as a split, and for the endpoints). Iterative so a
    /// 100k-point track cannot overflow the stack.
    private static func importances(of coordinates: [Coordinate]) -> [Double] {
        var result = [Double](repeating: 0, count: coordinates.count)
        var stack = [(0, coordinates.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first > 1 else { continue }
            var maxDistance = -1.0
            var maxIndex = first
            for index in (first + 1) ..< last {
                let distance = perpendicularDistance(
                    coordinates[index], from: coordinates[first], to: coordinates[last]
                )
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = index
                }
            }
            result[maxIndex] = maxDistance
            stack.append((first, maxIndex))
            stack.append((maxIndex, last))
        }
        return result
    }

    private static func perpendicularDistance(
        _ point: Coordinate, from start: Coordinate, to end: Coordinate
    ) -> Double {
        let dx = end.longitude - start.longitude
        let dy = end.latitude - start.latitude
        let px = point.longitude - start.longitude
        let py = point.latitude - start.latitude
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
        return abs(px * dy - py * dx) / lengthSquared.squareRoot()
    }
}
