import PinfoldCore
import SwiftUI
import UIKit

// MARK: - PinAnchor

/// How a pin image is anchored to its placemark coordinate.
///
/// - `center`: the image's centre sits on the coordinate. Used for custom KML icons,
///   which (like the Google "paddle"/dot markers) are designed to be centred and whose
///   `hotSpot` we don't parse.
/// - `bottomTip`: the image's bottom-centre point sits on the coordinate. Used for the
///   built-in teardrop pin, which *points* at its location the way 📍 does.
enum PinAnchor {
    case center
    case bottomTip

    /// The `MKAnnotationView.centerOffset` that realises this anchor for an image of the
    /// given height. `center` needs no shift; `bottomTip` shifts the view up by half the
    /// image height so the bottom edge (where the teardrop's tip is drawn) lands on the
    /// coordinate. Height is read live because favorite decoration grows the image upward.
    func centerOffset(forImageOfHeight height: CGFloat) -> CGPoint {
        switch self {
        case .center: .zero
        case .bottomTip: CGPoint(x: 0, y: -height / 2)
        }
    }
}

// MARK: - PlacemarkPinImage

/// Builds the `UIImage` used as an `MKAnnotationView`'s image for a placemark, together
/// with the `PinAnchor` describing how it sits on its coordinate.
///
/// Resolution order (mirrors `StyleIcon`):
/// 1. If the placemark's resolved style has an icon `href` cached on disk, that image is
///    loaded directly via `UIImage(contentsOfFile:)`, scaled down to fit, and anchored by
///    its centre.
/// 2. Otherwise, a teardrop "balloon" pin tinted by the style's `iconColor` (or accent
///    color) is drawn, anchored by its bottom tip. A white outline, white inner dot, and
///    soft drop shadow keep it legible on any basemap — including a dark-colored pin on a
///    dark map, where the outline and dot still read.
///
/// All work is synchronous file/CoreGraphics I/O — call it on the main actor when
/// building annotations (placemark counts are typically small).
enum PlacemarkPinImage {
    /// Target max edge length of a *custom* (href-backed) pin image, in points, and the
    /// teardrop head diameter. Kept fairly small so pins collide (and therefore cluster)
    /// less aggressively — MapKit has no cluster-radius API, so annotation-view size is the
    /// main lever.
    static let dimension: CGFloat = 24

    /// Teardrop geometry, in points. `pinHeight` is the distance from the head's top to the
    /// tip; `margin` pads the top and sides so the outline + shadow aren't clipped. There is
    /// deliberately **no bottom margin**: the tip is drawn on the image's bottom edge so
    /// `PinAnchor.bottomTip` can place it on the coordinate via `centerOffset = -height/2`.
    private static let pinHeight: CGFloat = 32
    private static let margin: CGFloat = 3

    /// The identity of the *base* (un-decorated) pin image for a placemark: everything
    /// `image(for:...)` actually consumes that varies between placemarks — the resolved
    /// style's icon `href` and `iconColor`. (`dimension` is a fixed constant, so it is not
    /// part of the key.) Placemarks that resolve to the same style — the common case, since
    /// a KML file has few distinct styles — produce the same key, so the base image (and its
    /// anchor) can be built once and reused. Favorite/visited decoration is applied
    /// per-annotation *after* the cache lookup and is deliberately NOT part of this key.
    struct CacheKey: Hashable {
        let iconHref: String?
        let iconColor: String?
    }

    /// Derives the base-image cache key for `placemark` under `document`'s styles.
    static func cacheKey(for placemark: KMLPlacemark, document: KMLDocument) -> CacheKey {
        let style = document.resolvedStyle(forStyleUrl: placemark.styleUrl)
        return CacheKey(iconHref: style?.iconHref, iconColor: style?.iconColor)
    }

    /// Builds the base pin image and its anchor for `placemark`. A cached href-backed icon
    /// is centre-anchored; the teardrop fallback is tip-anchored.
    static func image(
        for placemark: KMLPlacemark,
        document: KMLDocument,
        entry: CatalogEntry,
        resourceCache: ResourceCache,
        storage: StorageLocations
    ) -> (image: UIImage, anchor: PinAnchor) {
        let style = document.resolvedStyle(forStyleUrl: placemark.styleUrl)

        if let href = style?.iconHref, !href.isEmpty {
            let resourcesDir = storage.resourcesDirectory(for: entry)
            // SwiftFormat puts the brace of a wrapped multi-line `if` on its own line.
            // swiftlint:disable opening_brace
            if let localURL = resourceCache.localURL(forHref: href, in: resourcesDir),
               let image = UIImage(contentsOfFile: localURL.path)
            {
                // swiftlint:enable opening_brace
                return (resized(image, maxDimension: dimension), .center)
            }
        }

        let tint = UIColor(Color(kmlHex: style?.iconColor ?? "") ?? .accentColor)
        return (fallbackImage(tint: tint), .bottomTip)
    }

    /// A teardrop "balloon" pin filled with `tint`, with a white outline, white inner dot,
    /// and soft drop shadow. The tip is at the image's bottom-centre; anchored later via
    /// `PinAnchor.bottomTip`.
    static func fallbackImage(tint: UIColor) -> UIImage {
        let size = CGSize(width: dimension + 2 * margin, height: pinHeight + margin)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            let radius = dimension / 2
            let center = CGPoint(x: size.width / 2, y: margin + radius)
            let tip = CGPoint(x: size.width / 2, y: margin + pinHeight) // bottom edge

            let path = balloonPath(center: center, radius: radius, tip: tip)

            // Fill with a soft drop shadow for separation on light/colored basemaps.
            cg.saveGState()
            cg.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 2,
                color: UIColor.black.withAlphaComponent(0.35).cgColor
            )
            tint.setFill()
            path.fill()
            cg.restoreGState()

            // White outline — keeps even a dark-colored pin visible on a dark basemap.
            UIColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()

            // White inner dot — the classic pin "hole", and a second legibility cue.
            let dot = UIBezierPath(
                arcCenter: center, radius: radius * 0.36,
                startAngle: 0, endAngle: .pi * 2, clockwise: true
            )
            UIColor.white.setFill()
            dot.fill()
        }
    }

    /// A single closed teardrop path: the major arc of the head circle (the top, away from
    /// the tip) joined to the two tangent lines that meet at `tip`. Building it as one path
    /// (rather than a circle + triangle union) lets the white outline trace a clean,
    /// seamless edge.
    private static func balloonPath(center: CGPoint, radius: CGFloat, tip: CGPoint) -> UIBezierPath {
        let distance = tip.y - center.y
        // Half-angle between the center→tip axis and a radius to a tangent point.
        let phi = acos(min(radius / distance, 1))
        // Tangent points, found by rotating the (downward) center→tip axis by ±phi.
        let rightTangent = CGPoint(x: center.x + radius * sin(phi), y: center.y + radius * cos(phi))
        let leftTangent = CGPoint(x: center.x - radius * sin(phi), y: center.y + radius * cos(phi))
        let startAngle = atan2(rightTangent.y - center.y, rightTangent.x - center.x)
        let endAngle = atan2(leftTangent.y - center.y, leftTangent.x - center.x)

        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: rightTangent)
        // clockwise:false sweeps decreasing angle from the right tangent up over the top to
        // the left tangent (the major arc), avoiding the tail side.
        path.addArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.close()
        return path
    }

    /// Returns `base` with a small star badge composited at the top-right when favorite,
    /// and at reduced opacity when visited. Returns `base` unchanged when neither applies.
    ///
    /// Padding respects `anchor` so the anchor point stays put as the image grows:
    /// - `.center` grows symmetrically (the centre is unchanged).
    /// - `.bottomTip` grows upward and sideways only — never at the bottom — so the tip
    ///   stays on the image's bottom-centre edge. `centerOffset` is recomputed from the
    ///   decorated height by the caller, so the extra top padding doesn't break the anchor.
    static func decorated(
        _ base: UIImage,
        isFavorite: Bool,
        isVisited: Bool,
        anchor: PinAnchor = .center
    ) -> UIImage {
        guard isFavorite || isVisited else { return base }

        let badge = dimension * 0.55
        let pad = isFavorite ? badge / 2 : 0
        // bottomTip: pad top + both sides (keep tip centred-x), but not the bottom.
        // center: pad symmetrically all round.
        let bottomPad: CGFloat = anchor == .bottomTip ? 0 : pad
        let canvas = CGSize(
            width: base.size.width + 2 * pad,
            height: base.size.height + pad + bottomPad
        )

        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            base.draw(in: CGRect(x: pad, y: pad, width: base.size.width, height: base.size.height),
                      blendMode: .normal, alpha: isVisited ? 0.45 : 1.0)
            if isFavorite {
                let starConfig = UIImage.SymbolConfiguration(pointSize: badge, weight: .bold)
                let star = UIImage(systemName: "star.fill", withConfiguration: starConfig)?
                    .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
                let starRect = CGRect(x: canvas.width - badge - pad / 2, y: pad / 2, width: badge, height: badge)
                star?.draw(in: starRect)
            }
        }
    }

    /// Scales `image` down so its longest edge is at most `maxDimension` (never upscales).
    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
