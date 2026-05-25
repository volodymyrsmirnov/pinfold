import Testing
import SwiftUI
import UIKit
@testable import Pinfold

/// Tests for `Color(kmlHex:)` — KML `aabbggrr` color parsing.
///
/// KML byte order: alpha, blue, green, red (most-significant byte first in the 8-char string).
/// For example, `"ff0000ff"` = alpha=0xff, blue=0x00, green=0x00, red=0xff → opaque red.
@Suite struct KMLColorTests {

    // MARK: - Non-nil happy path

    @Test func validHex_isNonNil() {
        // A typical KML color: semi-transparent orange-ish (ff d1 88 02)
        #expect(Color(kmlHex: "ffd18802") != nil)
    }

    @Test func opaqueRed_isNonNil() {
        // "ff0000ff": a=ff b=00 g=00 r=ff → opaque red
        #expect(Color(kmlHex: "ff0000ff") != nil)
    }

    @Test func fullyTransparent_isNonNil() {
        // "00000000": a=00, b=00, g=00, r=00 → fully transparent black
        #expect(Color(kmlHex: "00000000") != nil)
    }

    @Test func upperCaseHex_isNonNil() {
        #expect(Color(kmlHex: "FFFFFFFF") != nil)
    }

    // MARK: - Channel order verification

    /// Verifies that `"ff0000ff"` (KML aabbggrr) decodes as opaque red.
    ///
    /// KML byte order: a=0xff, b=0x00, g=0x00, r=0xff → red=1, green=0, blue=0, alpha=1.
    /// We bridge via `UIColor` to read back the RGBA components, since `Color` itself
    /// does not expose components in a cross-platform way.
    @Test @MainActor func opaqueRed_hasCorrectChannels() throws {
        let color = try #require(Color(kmlHex: "ff0000ff"))
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r > 0.99, "red channel should be ~1.0")
        #expect(g < 0.01, "green channel should be ~0.0")
        #expect(b < 0.01, "blue channel should be ~0.0")
        #expect(a > 0.99, "alpha channel should be ~1.0 (opaque)")
    }

    /// Verifies that `"ff00ff00"` (a=ff, b=00, g=ff, r=00) decodes as opaque green.
    @Test @MainActor func opaqueGreen_hasCorrectChannels() throws {
        let color = try #require(Color(kmlHex: "ff00ff00"))
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r < 0.01, "red channel should be ~0.0")
        #expect(g > 0.99, "green channel should be ~1.0")
        #expect(b < 0.01, "blue channel should be ~0.0")
        #expect(a > 0.99, "alpha channel should be ~1.0 (opaque)")
    }

    /// Verifies that `"ffff0000"` (a=ff, b=ff, g=00, r=00) decodes as opaque blue.
    @Test @MainActor func opaqueBlue_hasCorrectChannels() throws {
        let color = try #require(Color(kmlHex: "ffff0000"))
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r < 0.01, "red channel should be ~0.0")
        #expect(g < 0.01, "green channel should be ~0.0")
        #expect(b > 0.99, "blue channel should be ~1.0")
        #expect(a > 0.99, "alpha channel should be ~1.0 (opaque)")
    }

    // MARK: - Malformed input returns nil

    @Test func wrongLength_short_returnsNil() {
        #expect(Color(kmlHex: "ff00ff") == nil, "7-char string must return nil")
    }

    @Test func wrongLength_long_returnsNil() {
        #expect(Color(kmlHex: "ff0000ff00") == nil, "10-char string must return nil")
    }

    @Test func emptyString_returnsNil() {
        #expect(Color(kmlHex: "") == nil)
    }

    @Test func nonHexCharacters_returnsNil() {
        #expect(Color(kmlHex: "gghhiijj") == nil, "non-hex digits must return nil")
    }

    @Test func whitespaceInString_returnsNil() {
        #expect(Color(kmlHex: "ff00ff ") == nil, "trailing space makes it 9 chars")
    }

    @Test func hashPrefixed_returnsNil() {
        // Some callers might pass "#rrggbbaa"; ensure nil (KML does not use '#').
        #expect(Color(kmlHex: "#ff0000ff") == nil, "9-char hash-prefixed must return nil")
    }
}
