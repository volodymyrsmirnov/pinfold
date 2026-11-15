@testable import Pinfold
import Testing
import UIKit

/// Tests for `PinBadge`: icon classification, colour choice and badge drawing.
struct PinBadgeTests {
    private static let orange = UIColor(red: 232 / 255, green: 116 / 255, blue: 12 / 255, alpha: 1)
    private static let yellow = UIColor(red: 245 / 255, green: 196 / 255, blue: 0, alpha: 1)

    // MARK: Fixtures

    /// A 24×24 icon with a single filled circle in `color` on a transparent background.
    private static func circleIcon(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 20, height: 20)).fill()
        }
    }

    /// A 24×24 square, left half red and right half blue.
    private static func twoColorIcon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 24))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 12, y: 0, width: 12, height: 24))
        }
    }

    private static func blankIcon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }
    }

    private static func wideIcon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 10)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
        }
    }

    // MARK: Helpers

    private static func isClose(_ lhs: UIColor, _ rhs: UIColor, tolerance: CGFloat = 0.05) -> Bool {
        let left = lhs.rgbaComponents, right = rhs.rgbaComponents
        return abs(left.red - right.red) <= tolerance && abs(left.green - right.green) <= tolerance
            && abs(left.blue - right.blue) <= tolerance && abs(left.alpha - right.alpha) <= tolerance
    }

    /// The colour of `image` at `point` (in points), un-premultiplied.
    private static func pixel(of image: UIImage, at point: CGPoint) -> UIColor {
        guard let cgImage = image.cgImage else { return .clear }
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            let scale = image.scale
            // Draw the image shifted so the requested pixel lands on the 1×1 context's origin
            // (CoreGraphics' origin is bottom-left).
            let x = -(point.x * scale).rounded(.down)
            let y = -(CGFloat(cgImage.height) - (point.y * scale).rounded(.down) - 1)
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            context.draw(cgImage, in: CGRect(origin: CGPoint(x: x, y: y), size: size))
        }
        let alpha = CGFloat(bytes[3]) / 255
        guard alpha > 0 else { return .clear }
        return UIColor(
            red: CGFloat(bytes[0]) / 255 / alpha,
            green: CGFloat(bytes[1]) / 255 / alpha,
            blue: CGFloat(bytes[2]) / 255 / alpha,
            alpha: alpha
        )
    }

    // MARK: Classification

    @Test func dominantColor_singleColorIcon() throws {
        let color = try #require(PinBadge.dominantColor(of: Self.circleIcon(Self.orange)))
        #expect(Self.isClose(color, Self.orange))
    }

    @Test func dominantColor_twoColorIcon_isNil() {
        #expect(PinBadge.dominantColor(of: Self.twoColorIcon()) == nil)
    }

    @Test func dominantColor_blankIcon_isNil() {
        #expect(PinBadge.dominantColor(of: Self.blankIcon()) == nil)
    }

    // MARK: Colours

    @Test func fillColor_prefersKMLTint() {
        let fill = PinBadge.fillColor(kmlTint: .red, iconColor: Self.orange, fallback: .systemBlue)
        #expect(Self.isClose(fill, .red))
    }

    @Test func fillColor_ignoresWhiteAndTransparentTint() {
        for tint in [UIColor.white, UIColor.red.withAlphaComponent(0)] {
            let fill = PinBadge.fillColor(kmlTint: tint, iconColor: Self.orange, fallback: .systemBlue)
            #expect(Self.isClose(fill, Self.orange))
        }
    }

    @Test func fillColor_nearWhiteIconUsesFallback() {
        let fill = PinBadge.fillColor(kmlTint: nil, iconColor: .white, fallback: .systemBlue)
        #expect(Self.isClose(fill, .systemBlue))
    }

    @Test func glyphColor_darkOnYellow_whiteOnOrange() {
        #expect(!Self.isClose(PinBadge.glyphColor(onFill: Self.yellow), .white))
        #expect(Self.isClose(PinBadge.glyphColor(onFill: Self.orange), .white))
        #expect(Self.isClose(PinBadge.glyphColor(onFill: .black), .white))
    }

    // MARK: Drawing

    @Test func badge_isDiameterSquare() {
        let side = PinBadge.diameter + 2 * PinBadge.margin
        let icons = [Self.circleIcon(Self.orange), Self.twoColorIcon(), Self.blankIcon(), Self.wideIcon()]
        for icon in icons {
            let badge = PinBadge.badge(for: icon, kmlTint: nil, fallback: .systemBlue)
            #expect(badge.size == CGSize(width: side, height: side))
        }
    }

    /// A solid badge's interior is the fill (or the glyph), never a white plate.
    @Test func badge_solidCenterIsFill() {
        let badge = PinBadge.badge(for: Self.circleIcon(Self.orange), kmlTint: nil, fallback: .systemBlue)
        let center = CGPoint(x: badge.size.width / 2, y: badge.size.height / 2)
        // Just inside the ring, outside the 16 pt glyph square: pure fill.
        let nearEdge = Self.pixel(of: badge, at: CGPoint(x: PinBadge.margin + 3.5, y: center.y))
        #expect(Self.isClose(nearEdge, Self.orange, tolerance: 0.08))
        // Centre: the white glyph silhouette.
        #expect(Self.isClose(Self.pixel(of: badge, at: center), .white, tolerance: 0.08))
    }

    @Test func badge_multiColorHasWhitePlate() {
        let badge = PinBadge.badge(for: Self.twoColorIcon(), kmlTint: nil, fallback: .systemBlue)
        let center = CGPoint(x: badge.size.width / 2, y: badge.size.height / 2)
        let nearEdge = Self.pixel(of: badge, at: CGPoint(x: PinBadge.margin + 3.5, y: center.y))
        #expect(Self.isClose(nearEdge, .white, tolerance: 0.08))
    }

    /// A wide icon keeps its aspect ratio: the plate/disc above and below the bar is not the
    /// icon colour.
    @Test func badge_wideIconIsNotStretched() {
        let badge = PinBadge.badge(for: Self.wideIcon(), kmlTint: nil, fallback: .systemBlue)
        let center = CGPoint(x: badge.size.width / 2, y: badge.size.height / 2)
        let aboveBar = Self.pixel(of: badge, at: CGPoint(x: center.x, y: center.y - 6))
        let onBar = Self.pixel(of: badge, at: center)
        #expect(!Self.isClose(aboveBar, onBar))
    }
}
