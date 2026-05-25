import PinfoldCore
import SwiftUI

// MARK: - StyleIcon

/// Renders a placemark's KML style icon inside a fixed-size rounded tile.
///
/// Resolution order:
/// 1. If the placemark's resolved style has an icon `href` whose image is cached on disk,
///    that image is shown **untinted** (KML icons such as the Google "paddle" markers bake
///    their color into the image, so tinting would be wrong).
/// 2. Otherwise, falls back to a generic `mappin` SF Symbol tinted by the style's
///    `iconColor` (or `.accentColor`), matching the app's prior behavior.
///
/// `iconScale` is intentionally ignored: the tile is a fixed size for consistent layout.
struct StyleIcon: View {
    // MARK: - Properties

    let placemark: KMLPlacemark
    let document: KMLDocument
    let entry: CatalogEntry
    /// Edge length of the square tile in points.
    var size: CGFloat = 36

    // MARK: - Environment

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage

    // MARK: - Body

    var body: some View {
        let style = document.resolvedStyle(forStyleUrl: placemark.styleUrl)
        let tint = Color(kmlHex: style?.iconColor ?? "") ?? .accentColor

        ZStack {
            RoundedRectangle(cornerRadius: size / 6, style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: size, height: size)

            iconContent(href: style?.iconHref, tint: tint)
        }
    }

    // MARK: - Icon content

    @ViewBuilder
    private func iconContent(href: String?, tint: Color) -> some View {
        if let localURL = cachedIconURL(href: href) {
            AsyncImage(url: localURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.72, height: size * 0.72)
                default:
                    fallbackPin(tint: tint)
                }
            }
        } else {
            fallbackPin(tint: tint)
        }
    }

    /// Resolves an icon href to a cached on-disk URL, or nil when absent/uncached.
    private func cachedIconURL(href: String?) -> URL? {
        guard let href, !href.isEmpty else { return nil }
        let resourcesDir = storage.resourcesDirectory(for: entry)
        return resourceCache.localURL(forHref: href, in: resourcesDir)
    }

    private func fallbackPin(tint: Color) -> some View {
        Image(systemName: "mappin")
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(tint)
    }
}
