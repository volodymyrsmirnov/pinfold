@testable import Pinfold
import UIKit

/// Synthetic icons and colour helpers shared by the icon and glass-pin tests.
enum IconFixtures {
    static let orange = UIColor(red: 232 / 255, green: 116 / 255, blue: 12 / 255, alpha: 1)

    /// A `side`×`side` canvas with a filled circle of `diameter` in `color` at `origin`.
    static func circle(
        _ color: UIColor,
        canvas side: CGFloat = 24,
        diameter: CGFloat = 20,
        origin: CGPoint = CGPoint(x: 2, y: 2)
    ) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))).fill()
        }
    }

    /// A canvas completely filled with `color` — an edge-to-edge glyph.
    static func filled(_ color: UIColor, size: CGSize = CGSize(width: 24, height: 24)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Left half red, right half blue.
    static func twoColor() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 24))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 12, y: 0, width: 12, height: 24))
        }
    }

    static func blank() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }
    }

    /// A 32×32 disc in `color` with a 3 px black outline — the My Maps glyph look.
    static func outlined(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { _ in
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 32, height: 32)).fill()
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 26, height: 26)).fill()
        }
    }

    /// Colour sweeping across the hue circle — a photo-like, multi-hue icon.
    static func hueSweep() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            for column in 0 ..< 32 {
                UIColor(hue: CGFloat(column) / 32, saturation: 0.9, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: column, y: 0, width: 1, height: 32))
            }
        }
    }

    static func isClose(_ lhs: UIColor, _ rhs: UIColor, tolerance: CGFloat = 0.06) -> Bool {
        let left = lhs.rgbaComponents, right = rhs.rgbaComponents
        return abs(left.red - right.red) <= tolerance && abs(left.green - right.green) <= tolerance
            && abs(left.blue - right.blue) <= tolerance && abs(left.alpha - right.alpha) <= tolerance
    }

    /// The bounding box of `image`'s visible pixels, in points.
    static func visibleBox(of image: UIImage) -> CGRect? {
        guard let bitmap = IconBitmap(image) else { return nil }
        let scale = image.size.width / CGFloat(bitmap.width)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for (index, pixel) in bitmap.pixels.enumerated() where pixel.w > 0.1 {
            let x = index % bitmap.width, y = index / bitmap.width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        guard maxX >= minX else { return nil }
        return CGRect(
            x: CGFloat(minX) * scale, y: CGFloat(minY) * scale,
            width: CGFloat(maxX - minX + 1) * scale, height: CGFloat(maxY - minY + 1) * scale
        )
    }

    /// The farthest visible pixel corner from the image centre, in points.
    static func reach(of image: UIImage) -> CGFloat {
        guard let bitmap = IconBitmap(image) else { return 0 }
        let scale = image.size.width / CGFloat(bitmap.width)
        let centerX = Double(bitmap.width) / 2, centerY = Double(bitmap.height) / 2
        var farthest = 0.0
        for (index, pixel) in bitmap.pixels.enumerated() where pixel.w > 0.1 {
            let x = Double(index % bitmap.width), y = Double(index / bitmap.width)
            let dx = max(abs(x - centerX), abs(x + 1 - centerX))
            let dy = max(abs(y - centerY), abs(y + 1 - centerY))
            farthest = max(farthest, (dx * dx + dy * dy).squareRoot())
        }
        return CGFloat(farthest) * scale
    }
}
