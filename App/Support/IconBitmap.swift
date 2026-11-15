import UIKit

/// An icon rasterised into an RGBA buffer (at most `maxSide` pixels on its long edge) for
/// per-pixel work: `PinBadge` classifies icons from it and builds their glyph masks.
struct IconBitmap {
    /// Long-edge cap. KML icons are typically 32–64 px; larger ones are scaled down.
    static let maxSide = 64

    let width: Int
    let height: Int
    /// Un-premultiplied RGBA, 0…1, row-major from the top-left.
    let pixels: [SIMD4<Double>]

    init?(_ icon: UIImage) {
        guard let cgImage = Self.cgImage(of: icon), cgImage.width > 0, cgImage.height > 0 else { return nil }
        let scale = min(1, Double(Self.maxSide) / Double(max(cgImage.width, cgImage.height)))
        let width = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let height = max(1, Int((Double(cgImage.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = Self.context(data: buffer.baseAddress, width: width, height: height) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        pixels = stride(from: 0, to: bytes.count, by: 4).map { offset in
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha > 0 else { return .zero }
            return SIMD4(
                min(Double(bytes[offset]) / 255 / alpha, 1),
                min(Double(bytes[offset + 1]) / 255 / alpha, 1),
                min(Double(bytes[offset + 2]) / 255 / alpha, 1),
                alpha
            )
        }
    }

    /// A same-size image painted in `color`, each pixel's alpha being the icon's alpha times
    /// `weight(pixel)` (0…1) — a silhouette, optionally with parts knocked out.
    func glyph(color: UIColor, weight: (SIMD4<Double>) -> Double) -> CGImage? {
        let rgba = color.rgbaComponents
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, pixel) in pixels.enumerated() {
            let alpha = pixel.w * min(max(weight(pixel), 0), 1)
            let offset = index * 4
            bytes[offset] = UInt8((Double(rgba.red) * alpha * 255).rounded())
            bytes[offset + 1] = UInt8((Double(rgba.green) * alpha * 255).rounded())
            bytes[offset + 2] = UInt8((Double(rgba.blue) * alpha * 255).rounded())
            bytes[offset + 3] = UInt8((alpha * 255).rounded())
        }
        return bytes.withUnsafeMutableBytes { buffer in
            Self.context(data: buffer.baseAddress, width: width, height: height)?.makeImage()
        }
    }

    private static func context(data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func cgImage(of icon: UIImage) -> CGImage? {
        if let cgImage = icon.cgImage {
            return cgImage
        }
        guard icon.size.width > 0, icon.size.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: icon.size).image { _ in icon.draw(at: .zero) }.cgImage
    }
}
