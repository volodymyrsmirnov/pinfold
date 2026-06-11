import MapKit
import PinfoldCore

// MARK: - MapRectBuilder

/// Computes a bounding `MKMapRect` over a set of coordinates, used to fit all of a
/// file's pins on screen.
///
/// Returns `nil` for empty input. A single coordinate yields a zero-size rect at that
/// point (the caller substitutes a fixed span for the single-pin case).
///
/// ## Antimeridian handling
///
/// A naive `MKMapRect.union` over coordinates that straddle the antimeridian (the 180°/
/// −180° seam) produces a rect that spans almost the entire globe the *long* way around:
/// two pins at lon 179.5 and −179.5 are only 1° apart across the seam, yet their map
/// points sit at opposite edges of the world, so the union is ~358° wide. The fit then
/// zooms all the way out instead of framing the tight cluster.
///
/// To fix this we compute **two** candidate rects and return whichever is narrower:
/// 1. The naive rect (correct for normal, non-wrapping spans).
/// 2. A *wrapped* rect: shift every longitude < 0 by +360° so the coordinates become
///    contiguous in a continuous 0…360 longitude space, build the rect there, then
///    translate it back into MapKit map-point space by offsetting its `x` origin.
///
/// The wrapped rect's `x` (and `maxX`) can legally extend **beyond** `MKMapRect.world.maxX`.
/// MapKit treats the map plane as horizontally wrapping, so `MKMapRect.contains` and
/// `MKMapView.setVisibleMapRect` both handle a rect that crosses the right edge of the world
/// — the rendered region simply wraps across the seam. We never normalise the `x` back into
/// `[0, world.maxX)` because doing so would re-introduce the very split we are avoiding.
///
/// For any non-wrapping set the wrapped rect is wider than (or equal to) the naive rect, so
/// the naive rect wins and the common case is numerically unchanged.
enum MapRectBuilder {
    static func boundingRect(for coordinates: [Coordinate]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }

        let naive = naiveRect(for: coordinates)
        guard let wrapped = wrappedRect(for: coordinates) else { return naive }

        // Return whichever frames the pins more tightly horizontally. The wrapped candidate
        // is only meaningfully narrower when the set actually straddles the seam; for every
        // other set it is the naive rect translated by ±360°, so its width matches the naive
        // one to within floating-point rounding. We therefore require it to be narrower by a
        // real margin (a small fraction of a world width) before preferring it — otherwise a
        // sub-ulp difference would hand back a shifted rect for an ordinary non-wrapping set,
        // and `contains`/`setVisibleMapRect` would frame the wrong region. For non-wrapping
        // sets the naive rect (and its exact legacy values) win unchanged.
        let tighteningMargin = MKMapRect.world.size.width * 1e-9
        return wrapped.size.width < naive.size.width - tighteningMargin ? wrapped : naive
    }

    /// The classic union of zero-size point rects in MapKit's map-point space.
    private static func naiveRect(for coordinates: [Coordinate]) -> MKMapRect {
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        return rect
    }

    /// Builds the rect in a continuous 0…360 longitude space (negative longitudes shifted by
    /// +360°), then translates it back into map-point space by offsetting `x`. The resulting
    /// rect may legally have `maxX` beyond `MKMapRect.world.maxX` (see the type doc comment).
    ///
    /// Returns `nil` only for empty input (guarded by the caller); a single coordinate yields
    /// a zero-size rect identical to the naive one, so the caller's narrower-wins comparison
    /// keeps the legacy single-pin behaviour.
    private static func wrappedRect(for coordinates: [Coordinate]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }

        // One full world width in map points: shifting a longitude by +360° corresponds to
        // adding exactly this much to its map-point x.
        let worldWidth = MKMapRect.world.size.width

        var rect = MKMapRect.null
        for coordinate in coordinates {
            let basePoint = MKMapPoint(
                CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            // Shift western-hemisphere points one world to the right so the cluster is
            // contiguous (e.g. lon −179.5 lands just past lon 179.5 rather than at the far
            // left edge). Eastern points stay put.
            let shiftedX = coordinate.longitude < 0 ? basePoint.x + worldWidth : basePoint.x
            let point = MKMapPoint(x: shiftedX, y: basePoint.y)
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        return rect
    }
}
