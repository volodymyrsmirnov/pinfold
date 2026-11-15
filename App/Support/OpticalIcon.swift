import UIKit

/// Sizes a KML icon by what is actually drawn in it, for a round glass pin.
///
/// Icon files differ in how much transparent padding surrounds the shape: a Google My Maps
/// glyph fills its image edge to edge, a pushpin leaves room around it. Scaling whole images
/// to one box therefore makes some icons look bigger than others and lets edge-to-edge ones
/// poke past a round disc. Instead the visible shape is centred and scaled as large as two
/// limits allow: its farthest visible pixel at most `radius` from the centre (so it can't
/// reach past the safe circle) and its visible box at most `maxSide` across (so a compact
/// round icon doesn't swell to fill the whole circle). Every icon reads at a similar size
/// with air around it.
enum OpticalIcon {
    /// Pixels at or below this alpha count as transparent padding.
    private static let visibleAlpha = 0.1

    /// `image` redrawn into a `2·radius` square, its visible shape centred and scaled to fit
    /// both a circle of `radius` and a `maxSide` square. Returns `image` unchanged when it has
    /// nothing visible.
    static func render(_ image: UIImage, radius: CGFloat, maxSide: CGFloat = .greatestFiniteMagnitude) -> UIImage {
        guard radius > 0, maxSide > 0, let bitmap = IconBitmap(image), let shape = VisibleShape(bitmap) else {
            return image
        }
        let scale = min(Double(radius) / shape.reach, Double(maxSide) / shape.longestSide)
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

    /// The visible pixels' bounding-box centre, the box's longest side, and the pixels'
    /// farthest reach from the centre, in bitmap pixels (a pixel spans `[x, x+1)`, so its far
    /// corner is what counts).
    private struct VisibleShape {
        let center: (x: Double, y: Double)
        let longestSide: Double
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
            longestSide = Double(max(maxX - minX + 1, maxY - minY + 1))
            reach = visible.reduce(0.0) { farthest, pixel in
                let dx = max(abs(Double(pixel.x) - centerX), abs(Double(pixel.x + 1) - centerX))
                let dy = max(abs(Double(pixel.y) - centerY), abs(Double(pixel.y + 1) - centerY))
                return max(farthest, (dx * dx + dy * dy).squareRoot())
            }
        }
    }
}
