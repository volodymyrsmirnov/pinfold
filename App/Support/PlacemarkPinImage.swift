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

    /// The identity of the *base* (un-decorated) pin image for a placemark: everything
    /// `image(for:...)` actually consumes that varies between placemarks — the resolved
    /// style's icon `href` and `iconColor`. (`dimension` is a fixed constant, so it is not
    /// part of the key.) Placemarks that resolve to the same style — the common case, since
    /// a KML file has few distinct styles — produce the same key, so the base image can be
    /// built once and reused. Favorite/visited decoration is applied per-annotation *after*
    /// the cache lookup and is deliberately NOT part of this key.
    struct CacheKey: Hashable {
        let iconHref: String?
        let iconColor: String?
    }

    /// Derives the base-image cache key for `placemark` under `document`'s styles.
    static func cacheKey(for placemark: KMLPlacemark, document: KMLDocument) -> CacheKey {
        let style = document.resolvedStyle(forStyleUrl: placemark.styleUrl)
        return CacheKey(iconHref: style?.iconHref, iconColor: style?.iconColor)
    }

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
            // SwiftFormat puts the brace of a wrapped multi-line `if` on its own line.
            // swiftlint:disable opening_brace
            if let localURL = resourceCache.localURL(forHref: href, in: resourcesDir),
               let image = UIImage(contentsOfFile: localURL.path)
            {
                // swiftlint:enable opening_brace
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
        // Symmetric padding so the base stays centred in the canvas — the map anchors
        // pins by image centre (centerOffset = .zero), so asymmetric growth would shift
        // favorite pins off their coordinate.
        let pad = isFavorite ? badge / 2 : 0
        let canvas = CGSize(width: base.size.width + 2 * pad, height: base.size.height + 2 * pad)

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
