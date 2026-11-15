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
        guard let cgImage = Self.source(for: icon), cgImage.width > 0, cgImage.height > 0 else { return nil }
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

    /// The pixels to analyse, in display orientation. An upright image's raw pixels are used
    /// as they are (the init scales them down); anything else (an EXIF-rotated JPEG) is
    /// redrawn upright **directly at the capped size** and 1× scale — redrawing a large photo
    /// at full size first could need gigabytes.
    static func source(for icon: UIImage) -> CGImage? {
        if icon.imageOrientation == .up, let cgImage = icon.cgImage {
            return cgImage
        }
        let pixelSize = CGSize(width: icon.size.width * icon.scale, height: icon.size.height * icon.scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let fit = min(1, CGFloat(maxSide) / max(pixelSize.width, pixelSize.height))
        let size = CGSize(
            width: max(1, (pixelSize.width * fit).rounded()),
            height: max(1, (pixelSize.height * fit).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            icon.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
