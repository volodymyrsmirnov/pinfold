@testable import Pinfold
import Testing
import UIKit

/// Tests for `OpticalIcon`: icons are sized by their visible shape, never by their canvas.
struct OpticalIconTests {
    private let radius: CGFloat = 12.5
    /// Rendering and re-sampling blur edges by about a pixel; allow ~1 pt.
    private let slack: CGFloat = 1

    @Test func outputIsTheSafeSquare() {
        let icon = OpticalIcon.render(IconFixtures.circle(.red), radius: radius)
        #expect(icon.size == CGSize(width: 2 * radius, height: 2 * radius))
    }

    /// An edge-to-edge square — the shape that used to poke past the disc — stays inside
    /// the safe circle: its corners reach the radius, no further.
    @Test func edgeToEdgeSquare_staysInsideTheCircle() {
        let icon = OpticalIcon.render(IconFixtures.filled(.red), radius: radius)
        let reach = IconFixtures.reach(of: icon)
        #expect(reach <= radius + slack)
        #expect(reach >= radius - slack)
    }

    /// The same circle with and without transparent padding comes out the same size.
    @Test func paddingDoesNotChangeTheVisibleSize() throws {
        let padded = OpticalIcon.render(
            IconFixtures.circle(.red, canvas: 64, diameter: 20, origin: CGPoint(x: 22, y: 22)),
            radius: radius
        )
        let edgeToEdge = OpticalIcon.render(
            IconFixtures.circle(.red, canvas: 24, diameter: 24, origin: .zero),
            radius: radius
        )
        let paddedBox = try #require(IconFixtures.visibleBox(of: padded))
        let edgeBox = try #require(IconFixtures.visibleBox(of: edgeToEdge))
        #expect(abs(paddedBox.width - edgeBox.width) <= slack)
        #expect(abs(paddedBox.width - 2 * radius) <= 2 * slack)
    }

    /// Off-centre content is moved to the middle.
    @Test func offCentreShape_isCentred() throws {
        let corner = IconFixtures.circle(.red, canvas: 64, diameter: 16, origin: CGPoint(x: 2, y: 2))
        let box = try #require(IconFixtures.visibleBox(of: OpticalIcon.render(corner, radius: radius)))
        #expect(abs(box.midX - radius) <= slack)
        #expect(abs(box.midY - radius) <= slack)
    }

    /// A wide icon keeps its proportions.
    @Test func wideShape_keepsItsAspectRatio() throws {
        let bar = IconFixtures.filled(.red, size: CGSize(width: 40, height: 10))
        let box = try #require(IconFixtures.visibleBox(of: OpticalIcon.render(bar, radius: radius)))
        #expect(abs(box.width / box.height - 4) <= 0.5)
    }

    /// `maxSide` keeps a compact round icon from swelling to the whole safe circle, so the
    /// disc keeps air around it; the radius limit still holds for edge-to-edge squares.
    @Test func maxSide_capsTheVisibleBox() throws {
        let round = OpticalIcon.render(IconFixtures.circle(.red), radius: radius, maxSide: 18)
        let roundBox = try #require(IconFixtures.visibleBox(of: round))
        #expect(abs(roundBox.width - 18) <= slack)

        let square = OpticalIcon.render(IconFixtures.filled(.red), radius: radius, maxSide: 18)
        let squareBox = try #require(IconFixtures.visibleBox(of: square))
        #expect(squareBox.width <= 18 + slack)
        #expect(IconFixtures.reach(of: square) <= radius + slack)
    }

    @Test func blankIcon_isReturnedUnchanged() {
        let blank = IconFixtures.blank()
        #expect(OpticalIcon.render(blank, radius: radius) === blank)
    }
}

/// Tests for `IconBitmap`'s source image.
struct IconBitmapTests {
    /// A rotated image (EXIF orientation) is redrawn upright straight at the analysis size —
    /// never at full size first, which for a large photo would need gigabytes.
    @Test func rotatedImage_isRedrawnUprightAtTheCappedSize() throws {
        let raw = try #require(IconFixtures.filled(.red, size: CGSize(width: 400, height: 300)).cgImage)
        let rotated = UIImage(cgImage: raw, scale: 1, orientation: .right)
        let source = try #require(IconBitmap.source(for: rotated))
        #expect(max(source.width, source.height) <= IconBitmap.maxSide)
        // `.right` turns the 400×300 landscape into a portrait.
        #expect(source.height > source.width)
    }
}
