@testable import Pinfold
import Testing
import UIKit

/// Tests for `IconPalette`: how an icon's colour family (and so its glass tint) is read.
struct IconPaletteTests {
    private func kind(_ image: UIImage) -> IconPalette.Kind? {
        IconBitmap(image).flatMap(IconPalette.kind(of:))
    }

    @Test func singleColorIcon_isItsHue() throws {
        guard case let .hue(color) = try #require(kind(IconFixtures.circle(IconFixtures.orange))) else {
            Issue.record("expected a hue")
            return
        }
        #expect(IconFixtures.isClose(color, IconFixtures.orange))
    }

    /// A My Maps glyph: one colour with a black outline still reads as that colour.
    @Test func outlinedGlyph_isItsHue() throws {
        guard case let .hue(color) = try #require(kind(IconFixtures.outlined(IconFixtures.orange))) else {
            Issue.record("expected a hue")
            return
        }
        #expect(IconFixtures.isClose(color, IconFixtures.orange, tolerance: 0.08))
    }

    @Test func greyIcon_isLight() {
        #expect(kind(IconFixtures.outlined(UIColor(white: 0.8, alpha: 1))) == .light)
    }

    @Test func blackIcon_isDark() {
        #expect(kind(IconFixtures.circle(.black)) == .dark)
    }

    @Test func multiHueAndBlankIcons_haveNoKind() {
        #expect(kind(IconFixtures.twoColor()) == nil)
        #expect(kind(IconFixtures.hueSweep()) == nil)
        #expect(kind(IconFixtures.blank()) == nil)
    }

    @Test func glassTint_onlyForHuedIcons() throws {
        let tint = try #require(IconPalette.glassTint(for: IconFixtures.circle(IconFixtures.orange)))
        #expect(IconFixtures.isClose(tint, IconFixtures.orange))
        #expect(IconPalette.glassTint(for: IconFixtures.circle(.white)) == nil)
        #expect(IconPalette.glassTint(for: IconFixtures.circle(.black)) == nil)
        #expect(IconPalette.glassTint(for: IconFixtures.twoColor()) == nil)
        #expect(IconPalette.glassTint(for: IconFixtures.blank()) == nil)
    }
}
