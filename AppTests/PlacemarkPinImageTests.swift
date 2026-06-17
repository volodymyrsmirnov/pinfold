@testable import Pinfold
import Testing
import UIKit

/// Tests for `PlacemarkPinImage`. The cached-icon path needs on-disk files and is
/// verified manually on the simulator; here we only assert the symbol fallback
/// produces a usable, non-empty image.
struct PlacemarkPinImageTests {
    @Test func fallbackImage_isNonEmpty() {
        let image = PlacemarkPinImage.fallbackImage(tint: .systemRed)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test func decoratedReturnsImageForEveryStateCombo() {
        let base = PlacemarkPinImage.fallbackImage(tint: .systemBlue)
        for favorite in [false, true] {
            for visited in [false, true] {
                let decorated = PlacemarkPinImage.decorated(base, isFavorite: favorite, isVisited: visited)
                #expect(decorated.size.width > 0)
                #expect(decorated.size.height > 0)
                if favorite {
                    #expect(decorated.size.width > base.size.width)
                    #expect(decorated.size.height > base.size.height)
                }
            }
        }
    }

    @Test func decoratedWithNoFlagsReturnsBaseUnchanged() {
        let base = PlacemarkPinImage.fallbackImage(tint: .systemBlue)
        let decorated = PlacemarkPinImage.decorated(base, isFavorite: false, isVisited: false)
        #expect(decorated === base)
    }

    /// The "Seen" decoration must actually make the pin translucent — not merely return a
    /// non-empty image (which the combo test above already covered while the fade silently
    /// regressed). Drawing a fully-opaque base through `decorated(isVisited: true)` must
    /// yield a center pixel whose alpha is reduced to ~0.45.
    @Test func decoratedVisitedFadesThePin() {
        let base = solidOpaqueImage(.red, side: 12)
        #expect(abs(centerAlpha(of: base) - 1.0) < 0.05) // sanity: base is opaque

        let visited = PlacemarkPinImage.decorated(base, isFavorite: false, isVisited: true)
        let alpha = centerAlpha(of: visited)
        #expect(alpha > 0.3)
        #expect(alpha < 0.6) // ~0.45, clearly below the opaque base

        // Favorite-only (not visited) must stay fully opaque — the fade is the visited flag's.
        let favorite = PlacemarkPinImage.decorated(base, isFavorite: true, isVisited: false)
        #expect(centerAlpha(of: favorite) > 0.9)
    }

    // MARK: - Pixel helpers

    /// A `side`×`side` fully-opaque image filled with `color`.
    private func solidOpaqueImage(_ color: UIColor, side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The alpha (0…1) of `image`'s center pixel, sampled into a 1×1 RGBA context.
    private func centerAlpha(of image: UIImage) -> CGFloat {
        guard let cg = image.cgImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        // Position the source so its center maps onto the single sampled pixel.
        context?.draw(
            cg,
            in: CGRect(x: -CGFloat(cg.width) / 2 + 0.5, y: -CGFloat(cg.height) / 2 + 0.5,
                       width: CGFloat(cg.width), height: CGFloat(cg.height))
        )
        return CGFloat(pixel[3]) / 255.0
    }
}
