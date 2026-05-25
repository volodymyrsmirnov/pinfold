import SwiftUI

extension Color {

    /// Creates a SwiftUI `Color` from a KML color hex string.
    ///
    /// KML encodes colors in `aabbggrr` order (alpha, blue, green, red), which is the
    /// **reverse** of the usual RGBA byte order. For example, `"ff0000ff"` is opaque red
    /// (alpha=0xff, blue=0x00, green=0x00, red=0xff).
    ///
    /// - Parameter kmlHex: An 8-character hexadecimal string in `aabbggrr` format.
    ///   Letters may be upper or lower case. Any other length or non-hex content returns
    ///   `nil`.
    /// - Returns: A `Color` value, or `nil` when the input is malformed.
    init?(kmlHex: String) {
        guard kmlHex.count == 8,
              let value = UInt32(kmlHex, radix: 16) else { return nil }

        // KML byte order: aa bb gg rr (most-significant byte first in the 8-char string)
        let alpha = Double((value >> 24) & 0xFF) / 255.0
        let blue  = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >>  8) & 0xFF) / 255.0
        let red   = Double((value >>  0) & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}
