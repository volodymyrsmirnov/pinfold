import MapKit
import PinfoldCore
import UIKit

// MARK: - StyledOverlay

/// An `MKOverlay` (an `MKPolyline` or `MKPolygon`) paired with the resolved KML drawing
/// style and the owning placemark's `stableKey`.
///
/// The concrete overlay is always a `StyledPolyline`/`StyledPolygon` subclass that *also*
/// carries this style, so `mapView(_:rendererFor:)` can read it straight off the overlay
/// (by identity) without a side table. `StyledOverlay` is the value the map's
/// `overlaysByKey` registry stores and diffs; the subclass is what is actually added to
/// the `MKMapView`.
struct StyledOverlay {
    let overlay: MKOverlay
    /// Stroke color for the line / polygon border.
    let stroke: UIColor
    /// Fill color for a polygon interior, or `nil` for polylines and unfilled polygons.
    let fill: UIColor?
    let lineWidth: CGFloat
    /// The owning placemark's durable `stableKey`. All overlays of a multi-geometry
    /// placemark share this key, so the registry diff adds/removes them together.
    let stableKey: String
}

// MARK: - Styled overlay subclasses

/// `MKPolyline` that carries its `StyledOverlay` styling so the renderer can read it by
/// overlay identity (no `ObjectIdentifier` side table).
final class StyledPolyline: MKPolyline {
    var stroke: UIColor = OverlayBuilder.defaultStroke
    var lineWidth: CGFloat = OverlayBuilder.defaultLineWidth
}

/// `MKPolygon` that carries its `StyledOverlay` styling (stroke + optional fill).
final class StyledPolygon: MKPolygon {
    var stroke: UIColor = OverlayBuilder.defaultStroke
    var fill: UIColor?
    var lineWidth: CGFloat = OverlayBuilder.defaultLineWidth
}

// MARK: - OverlayBuilder

/// Pure builder turning line/polygon/track geometry placemarks into styled MapKit
/// overlays. No `MKMapView`, no shared state — fully unit-testable.
///
/// Styling rules (resolved per placemark via `document.resolvedStyle(forStyleUrl:)`):
/// - **Stroke**: `LineStyle` color (KML `aabbggrr` hex) via `UIColor(kmlHex:)`. Absent or
///   malformed → `defaultStroke` (system blue). Width from `lineWidth`, default `3`.
/// - **Polygon fill**: `PolyStyle` color at the alpha encoded in its hex (KML carries the
///   fill alpha in the color itself). When `polyFill == false` the interior is not filled
///   (`fill == nil`). A polygon with no `polyColor` gets no fill.
/// - **Tracks** render as polylines.
/// - A **MultiGeometry** placemark yields one `StyledOverlay` per geometry, all sharing the
///   placemark's `stableKey`.
/// - Placemarks with no captured geometry (point-only) contribute no overlays.
enum OverlayBuilder {
    /// Default stroke when a placemark's style has no (valid) `LineStyle` color — the
    /// system-blue equivalent, matching MapKit's own default overlay tint.
    static let defaultStroke: UIColor = .systemBlue
    /// Default stroke width when the style has no `lineWidth`.
    static let defaultLineWidth: CGFloat = 3

    static func overlays(for placemarks: [KMLPlacemark], document: KMLDocument) -> [StyledOverlay] {
        var result: [StyledOverlay] = []
        for placemark in placemarks where !placemark.geometries.isEmpty {
            let style = document.resolvedStyle(forStyleUrl: placemark.styleUrl)
            let stroke = style?.lineColor.flatMap { UIColor(kmlHex: $0) } ?? defaultStroke
            let lineWidth = style?.lineWidth.map { CGFloat($0) } ?? defaultLineWidth

            for geometry in placemark.geometries {
                switch geometry {
                case let .lineString(coords), let .track(coords):
                    let polyline = makePolyline(coords, stroke: stroke, lineWidth: lineWidth)
                    result.append(StyledOverlay(
                        overlay: polyline, stroke: stroke, fill: nil,
                        lineWidth: lineWidth, stableKey: placemark.stableKey
                    ))
                case let .polygon(outer, inners):
                    let fill = polygonFill(style: style)
                    let polygon = makePolygon(
                        outer: outer, inners: inners,
                        stroke: stroke, fill: fill, lineWidth: lineWidth
                    )
                    result.append(StyledOverlay(
                        overlay: polygon, stroke: stroke, fill: fill,
                        lineWidth: lineWidth, stableKey: placemark.stableKey
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    /// The polygon interior fill: the `PolyStyle` color at its own (KML-encoded) alpha, or
    /// `nil` when `polyFill` is explicitly `false` or no valid `polyColor` is present.
    private static func polygonFill(style: KMLStyle?) -> UIColor? {
        guard style?.polyFill != false else { return nil }
        guard let hex = style?.polyColor else { return nil }
        return UIColor(kmlHex: hex)
    }

    private static func makePolyline(
        _ coords: [Coordinate], stroke: UIColor, lineWidth: CGFloat
    ) -> StyledPolyline {
        let points = coords.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let polyline = StyledPolyline(coordinates: points, count: points.count)
        polyline.stroke = stroke
        polyline.lineWidth = lineWidth
        return polyline
    }

    private static func makePolygon(
        outer: [Coordinate], inners: [[Coordinate]],
        stroke: UIColor, fill: UIColor?, lineWidth: CGFloat
    ) -> StyledPolygon {
        let outerPoints = outer.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let interiors: [MKPolygon] = inners.map { ring in
            let pts = ring.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            return MKPolygon(coordinates: pts, count: pts.count)
        }
        let polygon = StyledPolygon(
            coordinates: outerPoints, count: outerPoints.count,
            interiorPolygons: interiors.isEmpty ? nil : interiors
        )
        polygon.stroke = stroke
        polygon.fill = fill
        polygon.lineWidth = lineWidth
        return polygon
    }
}
