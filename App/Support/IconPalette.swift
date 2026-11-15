import UIKit

/// Decides whether a KML icon is "single-colour" — and so can be redrawn as a silhouette on a
/// solid `PinBadge` — and which colour it is.
///
/// Real map icons are rarely one flat colour: Google My Maps glyphs carry a black outline,
/// classic Google icons add gradients and black detail, and downsampling blends the two. So
/// pixels are judged by **hue**, not by RGB distance:
/// - near-black pixels are outline/detail and don't count against the icon;
/// - white/grey pixels are neutral;
/// - coloured pixels must share one hue.
///
/// Thresholds were tuned on the Rome fixture's classic icons and synthetic My Maps glyphs.
enum IconPalette {
    struct Classification {
        /// The icon's colour: the coloured pixels' (brighter) mean, `.white` for a white/grey
        /// icon, `.black` for a dark one.
        let color: UIColor
        /// Whether near-black pixels should be knocked out of the silhouette (outline and
        /// detail). False for a dark icon, whose dark pixels *are* the glyph.
        let knocksOutDark: Bool
    }

    /// Minimum HSV saturation and value for a pixel to count as coloured.
    private static let chromaticSaturation = 0.25
    private static let chromaticValue = 0.25
    /// Minimum value for a non-coloured pixel to count as white/grey rather than near-black.
    private static let lightValue = 0.4
    /// Below this share of opaque pixels being coloured or light, the icon is a dark glyph.
    private static let darkIconShare = 0.25
    /// Share of non-dark pixels that must be coloured for the icon to be judged by its hue.
    private static let chromaticShare = 0.3
    /// Share of coloured pixels within `hueTolerance` of the mean hue for one hue.
    private static let singleHueShare = 0.85
    private static let hueTolerance = 25.0 / 360
    /// The icon colour averages coloured pixels at least this bright relative to the
    /// brightest, so anti-aliased blends with the outline don't muddy it.
    private static let brightShare = 0.75

    /// Classifies `bitmap`; `nil` for a multi-coloured or (nearly) blank icon.
    static func classify(_ bitmap: IconBitmap) -> Classification? {
        let opaque = bitmap.pixels.filter { $0.w >= 0.5 }
        guard opaque.count >= 4 else { return nil }

        var chromatic: [HSV] = []
        var lightCount = 0
        for pixel in opaque {
            let color = HSV(SIMD3(pixel.x, pixel.y, pixel.z))
            if color.saturation >= chromaticSaturation, color.value >= chromaticValue {
                chromatic.append(color)
            } else if color.value >= lightValue {
                lightCount += 1
            }
        }

        let nonDark = chromatic.count + lightCount
        if Double(nonDark) < darkIconShare * Double(opaque.count) {
            return Classification(color: .black, knocksOutDark: false)
        }
        guard !chromatic.isEmpty, Double(chromatic.count) >= chromaticShare * Double(nonDark) else {
            return Classification(color: .white, knocksOutDark: true)
        }

        let meanHue = circularMean(chromatic.map(\.hue))
        let onHue = chromatic.count { hueDistance($0.hue, meanHue) <= hueTolerance }
        guard Double(onHue) >= singleHueShare * Double(chromatic.count) else { return nil }

        let brightest = chromatic.map(\.value).max() ?? 1
        let bright = chromatic.filter { $0.value >= brightShare * brightest }.map(\.rgb)
        let mean = bright.reduce(SIMD3<Double>()) { $0 + $1 } / Double(max(bright.count, 1))
        return Classification(color: UIColor(red: mean.x, green: mean.y, blue: mean.z, alpha: 1), knocksOutDark: true)
    }

    /// How much of a pixel belongs to the silhouette when dark detail is knocked out: 0 for
    /// near-black (value ≤ 0.15), 1 from value 0.4 up, linear between so edges stay smooth.
    static func glyphWeight(of pixel: SIMD4<Double>) -> Double {
        let value = max(pixel.x, pixel.y, pixel.z)
        return min(max((value - 0.15) / 0.25, 0), 1)
    }

    private static func circularMean(_ hues: [Double]) -> Double {
        let x = hues.reduce(0) { $0 + cos(2 * .pi * $1) }
        let y = hues.reduce(0) { $0 + sin(2 * .pi * $1) }
        let mean = atan2(y, x) / (2 * .pi)
        return mean < 0 ? mean + 1 : mean
    }

    private static func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    /// A pixel's RGB with its hue (0…1), saturation and value.
    private struct HSV {
        let rgb: SIMD3<Double>
        let hue: Double
        let saturation: Double
        let value: Double

        init(_ rgb: SIMD3<Double>) {
            self.rgb = rgb
            let maximum = rgb.max(), delta = maximum - rgb.min()
            value = maximum
            saturation = maximum > 0 ? delta / maximum : 0
            guard delta > 0 else {
                hue = 0
                return
            }
            let sector: Double = if maximum == rgb.x {
                (rgb.y - rgb.z) / delta
            } else if maximum == rgb.y {
                (rgb.z - rgb.x) / delta + 2
            } else {
                (rgb.x - rgb.y) / delta + 4
            }
            let turn = sector / 6
            hue = turn < 0 ? turn + 1 : turn
        }
    }
}
