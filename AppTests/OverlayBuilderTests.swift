import MapKit
@testable import Pinfold
import PinfoldCore
import Testing
import UIKit

/// Tests for `OverlayBuilder.overlays(for:document:)` — the pure builder that turns
/// line/polygon/track geometry placemarks into styled `MKOverlay`s.
///
/// `MKShape` initializers (MKPolyline/MKPolygon) are documented as thread-safe, but the
/// suite is marked `@MainActor` to avoid any friction with MapKit object construction
/// and to read back resolved `UIColor` components deterministically.
@MainActor
struct OverlayBuilderTests {
    // MARK: - Helpers

    /// A placemark carrying the given geometries. `coordinate` is the representative
    /// first vertex so it matches how the parser keeps point-less geometry placemarks.
    private func placemark(
        id: String,
        styleUrl: String? = nil,
        hasPoint: Bool = false,
        geometries: [KMLGeometry],
        coordinate: Coordinate? = Coordinate(longitude: 0, latitude: 0)
    ) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: id, descriptionHTML: nil, styleUrl: styleUrl,
            coordinate: coordinate, hasPoint: hasPoint, geometries: geometries,
            extendedData: [], photoLinks: [], sourceID: id
        )
    }

    /// A document with a single line/poly style keyed by `id` (no leading '#').
    private func document(style: KMLStyle?) -> KMLDocument {
        var styles: [String: KMLStyle] = [:]
        if let style { styles[style.id] = style }
        let root = KMLContainer(id: "root", name: nil, children: [], placemarks: [])
        return KMLDocument(
            name: nil, descriptionHTML: nil, root: root, styles: styles, styleMaps: [:]
        )
    }

    private func line(_ pts: [(Double, Double)]) -> [Coordinate] {
        pts.map { Coordinate(longitude: $0.0, latitude: $0.1) }
    }

    /// RGBA components read back from a resolved `UIColor`.
    private struct RGBA {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
    }

    private func components(_ color: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: r, g: g, b: b, a: a)
    }

    // MARK: - LineString

    @Test func lineString_yieldsStyledPolyline() throws {
        // "ff0000ff" KML aabbggrr = opaque red; width 5.
        let style = KMLStyle(
            id: "s", iconHref: nil, iconColor: nil, iconScale: nil,
            lineColor: "ff0000ff", lineWidth: 5
        )
        let pm = placemark(
            id: "L", styleUrl: "#s",
            geometries: [.lineString(line([(0, 0), (1, 1), (2, 2)]))]
        )
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: style))

        #expect(overlays.count == 1)
        let styled = try #require(overlays.first)
        let polyline = try #require(styled.overlay as? MKPolyline)
        #expect(polyline.pointCount == 3)
        #expect(styled.lineWidth == 5)
        #expect(styled.fill == nil)
        #expect(styled.stableKey == "id:L")

        let c = components(styled.stroke)
        #expect(c.r > 0.99)
        #expect(c.g < 0.01)
        #expect(c.b < 0.01)
        #expect(c.a > 0.99)
    }

    // MARK: - Polygon with inner ring

    @Test func polygon_withInnerRing_yieldsPolygonWithOneInterior() throws {
        let style = KMLStyle(
            id: "s", iconHref: nil, iconColor: nil, iconScale: nil,
            lineColor: "ff00ff00", polyColor: "8000ff00", polyFill: true
        )
        let outer = line([(0, 0), (0, 4), (4, 4), (4, 0)])
        let inner = line([(1, 1), (1, 2), (2, 2), (2, 1)])
        let pm = placemark(
            id: "P", styleUrl: "#s",
            geometries: [.polygon(outer: outer, inners: [inner])]
        )
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: style))

        #expect(overlays.count == 1)
        let styled = try #require(overlays.first)
        let polygon = try #require(styled.overlay as? MKPolygon)
        #expect(polygon.interiorPolygons?.count == 1)
        // Fill present (polyFill true), alpha from the poly color hex (0x80 ≈ 0.5).
        let fill = try #require(styled.fill)
        let f = components(fill)
        #expect(f.a > 0.45 && f.a < 0.55)
    }

    // MARK: - Track

    @Test func track_yieldsPolyline() {
        let pm = placemark(id: "T", geometries: [.track(line([(0, 0), (1, 0)]))])
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: nil))
        #expect(overlays.count == 1)
        #expect(overlays.first?.overlay is MKPolyline)
    }

    // MARK: - Point-only placemark

    @Test func pointOnly_yieldsNoOverlays() {
        let pm = placemark(
            id: "Pt", hasPoint: true, geometries: [],
            coordinate: Coordinate(longitude: 3, latitude: 4)
        )
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: nil))
        #expect(overlays.isEmpty)
    }

    // MARK: - Unstyled line → default stroke + width 3

    @Test func unstyledLine_usesDefaultStrokeAndWidth() throws {
        let pm = placemark(id: "U", geometries: [.lineString(line([(0, 0), (1, 1)]))])
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: nil))

        let styled = try #require(overlays.first)
        #expect(styled.lineWidth == 3)
        // Default stroke is the system-blue equivalent.
        let c = components(styled.stroke)
        let blue = components(.systemBlue)
        #expect(abs(c.r - blue.r) < 0.01)
        #expect(abs(c.g - blue.g) < 0.01)
        #expect(abs(c.b - blue.b) < 0.01)
    }

    // MARK: - polyFill false → no fill

    @Test func polyFillFalse_yieldsNilFill() throws {
        let style = KMLStyle(
            id: "s", iconHref: nil, iconColor: nil, iconScale: nil,
            lineColor: "ff0000ff", polyColor: "ff0000ff", polyFill: false
        )
        let pm = placemark(
            id: "PF", styleUrl: "#s",
            geometries: [.polygon(outer: line([(0, 0), (0, 1), (1, 1)]), inners: [])]
        )
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: style))
        let styled = try #require(overlays.first)
        #expect(styled.overlay is MKPolygon)
        #expect(styled.fill == nil)
    }

    // MARK: - Multi-geometry → N overlays sharing stableKey

    @Test func multiGeometry_yieldsOverlayPerGeometrySharingKey() {
        let pm = placemark(
            id: "M",
            geometries: [
                .lineString(line([(0, 0), (1, 1)])),
                .polygon(outer: line([(0, 0), (0, 1), (1, 1)]), inners: []),
                .track(line([(2, 2), (3, 3)])),
            ]
        )
        let overlays = OverlayBuilder.overlays(for: [pm], document: document(style: nil))
        #expect(overlays.count == 3)
        #expect(overlays.allSatisfy { $0.stableKey == "id:M" })
        #expect(overlays.contains { $0.overlay is MKPolyline && !($0.overlay is MKPolygon) })
        #expect(overlays.contains { $0.overlay is MKPolygon })
    }
}
