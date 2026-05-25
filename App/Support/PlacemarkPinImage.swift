import PinfoldCore
import SwiftUI
import UIKit

// MARK: - PlacemarkPinImage

/// Builds the `UIImage` used as an `MKAnnotationView`'s image for a placemark.
///
/// Resolution order (mirrors `StyleIcon`):
/// 1. If the placemark's resolved style has an icon `href` cached on disk, that image
///    is loaded directly via `UIImage(contentsOfFile:)` and scaled down to fit.
/// 2. Otherwise, a `mappin.circle.fill` SF Symbol tinted by the style's `iconColor`
///    (or accent color) is used.
///
/// All work is synchronous file/CoreGraphics I/O — call it on the main actor when
/// building annotations (placemark counts are typically small).
enum PlacemarkPinImage {

    /// Target max edge length of a pin image, in points. Kept fairly small so pins
    /// collide (and therefore cluster) less aggressively — MapKit has no cluster-radius
    /// API, so annotation-view size is the main lever.
    static let dimension: CGFloat = 24

    static func image(
        for placemark: KMLPlacemark,
        document: KMLDocument,
        entry: CatalogEntry,
        resourceCache: ResourceCache,
        storage: StorageLocations
    ) -> UIImage {
        let style = document.resolvedStyle(forStyleUrl: placemark.styleUrl)

        if let href = style?.iconHref, !href.isEmpty {
            let resourcesDir = storage.resourcesDirectory(for: entry)
            if let localURL = resourceCache.localURL(forHref: href, in: resourcesDir),
               let image = UIImage(contentsOfFile: localURL.path) {
                return resized(image, maxDimension: dimension)
            }
        }

        let tint = UIColor(Color(kmlHex: style?.iconColor ?? "") ?? .accentColor)
        return fallbackImage(tint: tint)
    }

    /// A `mappin.circle.fill` glyph tinted by `tint`. Anchored later via `centerOffset`.
    static func fallbackImage(tint: UIColor) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: dimension, weight: .medium)
        let symbol = UIImage(systemName: "mappin.circle.fill", withConfiguration: config) ?? UIImage()
        return symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// Returns `base` with a small star badge composited at the top-right when favorite,
    /// and at reduced opacity when visited. Returns `base` unchanged when neither applies.
    static func decorated(_ base: UIImage, isFavorite: Bool, isVisited: Bool) -> UIImage {
        guard isFavorite || isVisited else { return base }

        let badge = dimension * 0.55
        // Extend the canvas up-and-right so the badge isn't clipped.
        let inset = isFavorite ? badge / 2 : 0
        let canvas = CGSize(width: base.size.width + inset, height: base.size.height + inset)

        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            let baseOrigin = CGPoint(x: 0, y: inset)
            base.draw(in: CGRect(origin: baseOrigin, size: base.size),
                      blendMode: .normal, alpha: isVisited ? 0.45 : 1.0)

            if isFavorite {
                let starConfig = UIImage.SymbolConfiguration(pointSize: badge, weight: .bold)
                let star = UIImage(systemName: "star.fill", withConfiguration: starConfig)?
                    .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
                let starRect = CGRect(x: canvas.width - badge, y: 0, width: badge, height: badge)
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
