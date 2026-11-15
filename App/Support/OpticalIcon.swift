import UIKit

/// Sizes a KML icon by what is actually drawn in it, for a round glass pin.
///
/// Icon files differ in how much transparent padding surrounds the shape: a Google My Maps
/// glyph fills its image edge to edge, a pushpin leaves room around it. Scaling whole images
/// to one box therefore makes some icons look bigger than others and lets edge-to-edge ones
/// poke past a round disc. Instead the visible shape is centred and scaled so its farthest
/// visible pixel lies exactly `radius` from the centre: every icon reads at the same size
/// and none can reach past the safe circle.
enum OpticalIcon {
    /// Pixels at or below this alpha count as transparent padding.
    private static let visibleAlpha = 0.1

    /// `image` redrawn into a `2·radius` square, its visible shape centred and scaled to fit a
    /// circle of `radius`. Returns `image` unchanged when it has nothing visible.
    static func render(_ image: UIImage, radius: CGFloat) -> UIImage {
        guard radius > 0, let bitmap = IconBitmap(image), let shape = VisibleShape(bitmap) else { return image }
        let scale = Double(radius) / shape.reach
        let drawSize = CGSize(width: Double(bitmap.width) * scale, height: Double(bitmap.height) * scale)
        let origin = CGPoint(
            x: Double(radius) - shape.center.x * scale,
            y: Double(radius) - shape.center.y * scale
        )
        let side = radius * 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    /// The visible pixels' bounding-box centre and their farthest reach from it, in bitmap
    /// pixels (a pixel spans `[x, x+1)`, so its far corner is what counts).
    private struct VisibleShape {
        let center: (x: Double, y: Double)
        let reach: Double

        init?(_ bitmap: IconBitmap) {
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            var visible: [(x: Int, y: Int)] = []
            for (index, pixel) in bitmap.pixels.enumerated() where pixel.w > OpticalIcon.visibleAlpha {
                let x = index % bitmap.width, y = index / bitmap.width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                visible.append((x, y))
            }
            guard !visible.isEmpty else { return nil }
            let centerX = Double(minX + maxX + 1) / 2, centerY = Double(minY + maxY + 1) / 2
            center = (centerX, centerY)
            reach = visible.reduce(0.0) { farthest, pixel in
                let dx = max(abs(Double(pixel.x) - centerX), abs(Double(pixel.x + 1) - centerX))
                let dy = max(abs(Double(pixel.y) - centerY), abs(Double(pixel.y + 1) - centerY))
                return max(farthest, (dx * dx + dy * dy).squareRoot())
            }
        }
    }
}
