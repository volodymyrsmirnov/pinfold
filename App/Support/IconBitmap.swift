import UIKit

/// An icon rasterised into an RGBA buffer (at most `maxSide` pixels on its long edge) for
/// per-pixel work: `IconPalette` classifies icons from it and `OpticalIcon` measures their
/// visible shape.
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

    private static func context(data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func cgImage(of icon: UIImage) -> CGImage? {
        // Only an upright image's raw pixels match how it is drawn; anything else (an EXIF-
        // rotated JPEG) is redrawn so the bitmap is in display orientation.
        if icon.imageOrientation == .up, let cgImage = icon.cgImage {
            return cgImage
        }
        guard icon.size.width > 0, icon.size.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: icon.size).image { _ in icon.draw(at: .zero) }.cgImage
    }
}
