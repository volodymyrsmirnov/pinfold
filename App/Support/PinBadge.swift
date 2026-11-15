import UIKit

/// Draws a KML icon on the map inside a round badge so it reads on any basemap.
///
/// - **Solid badge** — for a single-colour icon (a Google My Maps glyph): a disc filled with
///   the icon's colour (or the KML `iconColor` tint), a white ring, and the icon redrawn as a
///   silhouette in white, or near-black when the fill is light.
/// - **Plate badge** — for a multi-colour icon (a flag, a photo, a pushpin with a star) or a
///   blank one: the original icon, untouched, on a white disc with a hairline outline.
///
/// Both share the size and drop shadow of the teardrop fallback pin and are centre-anchored.
/// Work is synchronous CoreGraphics; the result is cached per style by `PlacemarkPinImage`.
enum PinBadge {
    /// Disc diameter, in points.
    static let diameter: CGFloat = 28
    /// Padding around the disc so the shadow isn't clipped.
    static let margin: CGFloat = 3

    private static let ringWidth: CGFloat = 2
    private static let glyphSide: CGFloat = 16
    private static let plateIconSide: CGFloat = 18
    /// Side of the bitmap an icon is sampled at when classifying it.
    private static let sampleSide = 16
    /// Fewer opaque sample pixels than this is a blank icon.
    private static let minimumOpaquePixels = 4
    /// Share of opaque pixels that must sit near the mean colour for a single-colour icon.
    private static let singleColorShare = 0.9
    /// Euclidean RGB distance (0…1 per channel) that counts as "near the mean colour".
    private static let colorTolerance = 0.2
    /// Fill relative luminance above which the glyph turns dark (yellow #F5C400 is ≈ 0.59,
    /// orange #E8740C ≈ 0.30).
    private static let lightFillLuminance: CGFloat = 0.45

    // MARK: Entry point

    /// The badge for `icon`. `kmlTint` is the style's `iconColor`; `fallback` fills a solid
    /// badge whose icon is near-white and untinted (the accent colour, as the teardrop uses).
    static func badge(for icon: UIImage, kmlTint: UIColor?, fallback: UIColor) -> UIImage {
        guard let iconColor = dominantColor(of: icon) else { return plateBadge(icon: icon) }
        let fill = fillColor(kmlTint: kmlTint, iconColor: iconColor, fallback: fallback)
        return solidBadge(icon: icon, fill: fill)
    }

    // MARK: Classification and colours

    /// The icon's colour if nearly all its opaque pixels share one colour; `nil` when it is
    /// multi-coloured or (nearly) blank.
    static func dominantColor(of icon: UIImage) -> UIColor? {
        let pixels = opaqueSamples(of: icon)
        guard pixels.count >= minimumOpaquePixels else { return nil }
        let count = Double(pixels.count)
        let mean = pixels.reduce(SIMD3<Double>()) { $0 + $1 } / count
        let near = pixels.count { pixel in
            let delta = pixel - mean
            return (delta * delta).sum().squareRoot() <= colorTolerance
        }
        guard Double(near) / count >= singleColorShare else { return nil }
        return UIColor(red: mean.x, green: mean.y, blue: mean.z, alpha: 1)
    }

    /// The solid badge's fill: a meaningful KML tint wins; otherwise the icon's own colour,
    /// unless that is near-white (a white glyph on a white disc would vanish).
    static func fillColor(kmlTint: UIColor?, iconColor: UIColor, fallback: UIColor) -> UIColor {
        if let kmlTint, isMeaningfulTint(kmlTint) {
            return kmlTint.withAlphaComponent(1)
        }
        let rgba = iconColor.rgbaComponents
        return min(rgba.red, rgba.green, rgba.blue) > 0.85 ? fallback : iconColor
    }

    /// White on most fills; near-black on light ones (yellow) so the glyph keeps contrast.
    static func glyphColor(onFill fill: UIColor) -> UIColor {
        relativeLuminance(of: fill) > lightFillLuminance ? UIColor(white: 0.1, alpha: 1) : .white
    }

    /// KML's default `iconColor` is opaque white ("no tint"); a fully transparent one tints
    /// nothing visible either.
    private static func isMeaningfulTint(_ tint: UIColor) -> Bool {
        let rgba = tint.rgbaComponents
        if rgba.alpha < 0.05 {
            return false
        }
        return !(rgba.red > 0.95 && rgba.green > 0.95 && rgba.blue > 0.95)
    }

    /// WCAG relative luminance of an sRGB colour.
    private static func relativeLuminance(of color: UIColor) -> CGFloat {
        let rgba = color.rgbaComponents
        func linear(_ channel: CGFloat) -> CGFloat {
            let value = min(max(channel, 0), 1)
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgba.red) + 0.7152 * linear(rgba.green) + 0.0722 * linear(rgba.blue)
    }

    /// The un-premultiplied RGB of every pixel with alpha ≥ 50 % when `icon` is drawn
    /// aspect-fit into a `sampleSide`-square bitmap.
    private static func opaqueSamples(of icon: UIImage) -> [SIMD3<Double>] {
        guard let cgImage = cgImage(of: icon) else { return [] }
        let side = sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let rect = aspectFit(
                CGSize(width: cgImage.width, height: cgImage.height),
                in: CGRect(x: 0, y: 0, width: side, height: side)
            )
            context.draw(cgImage, in: rect)
            return true
        }
        guard drawn else { return [] }
        var samples: [SIMD3<Double>] = []
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] >= 128 {
            let alpha = Double(bytes[offset + 3])
            samples.append(SIMD3(
                Double(bytes[offset]) / alpha,
                Double(bytes[offset + 1]) / alpha,
                Double(bytes[offset + 2]) / alpha
            ))
        }
        return samples
    }

    private static func cgImage(of icon: UIImage) -> CGImage? {
        if let cgImage = icon.cgImage {
            return cgImage
        }
        guard icon.size.width > 0, icon.size.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: icon.size).image { _ in icon.draw(at: .zero) }.cgImage
    }

    // MARK: Drawing

    private static func solidBadge(icon: UIImage, fill: UIColor) -> UIImage {
        render { context, disc in
            fill.setFill()
            drawShadowed(context) { UIBezierPath(ovalIn: disc).fill() }

            let ring = UIBezierPath(ovalIn: disc.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
            ring.lineWidth = ringWidth
            UIColor.white.setStroke()
            ring.stroke()

            // Silhouette: draw the icon, then paint the glyph colour only where it is opaque.
            // The transparency layer keeps `.sourceIn` from wiping the disc beneath.
            let glyphRect = aspectFit(icon.size, in: centeredSquare(side: glyphSide, in: disc))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            icon.draw(in: glyphRect)
            glyphColor(onFill: fill).setFill()
            UIRectFillUsingBlendMode(glyphRect, .sourceIn)
            context.endTransparencyLayer()
        }
    }

    private static func plateBadge(icon: UIImage) -> UIImage {
        render { context, disc in
            UIColor.white.setFill()
            drawShadowed(context) { UIBezierPath(ovalIn: disc).fill() }

            let outline = UIBezierPath(ovalIn: disc.insetBy(dx: 0.25, dy: 0.25))
            outline.lineWidth = 0.5
            UIColor(white: 0, alpha: 0.2).setStroke()
            outline.stroke()

            icon.draw(in: aspectFit(icon.size, in: centeredSquare(side: plateIconSide, in: disc)))
        }
    }

    /// Renders a `diameter + 2·margin` square image, handing the drawing closure the disc rect.
    private static func render(_ draw: (CGContext, CGRect) -> Void) -> UIImage {
        let side = diameter + 2 * margin
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            draw(context.cgContext, CGRect(x: margin, y: margin, width: diameter, height: diameter))
        }
    }

    /// The teardrop pin's soft drop shadow, applied to whatever `draw` paints.
    private static func drawShadowed(_ context: CGContext, _ draw: () -> Void) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 1),
            blur: 2,
            color: UIColor.black.withAlphaComponent(0.35).cgColor
        )
        draw()
        context.restoreGState()
    }

    private static func centeredSquare(side: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// The largest rect with `size`'s aspect ratio that fits centred in `bounds`.
    private static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

// MARK: - RGBAComponents

/// A colour's sRGB channels, 0…1.
struct RGBAComponents {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

extension UIColor {
    var rgbaComponents: RGBAComponents {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBAComponents(red: red, green: green, blue: blue, alpha: alpha)
    }
}
