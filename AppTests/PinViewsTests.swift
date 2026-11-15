import MapKit
@testable import Pinfold
import Testing
import UIKit

/// Tests for the icon map pin, the cluster bubble and their shared disc.
@MainActor
struct PinViewsTests {
    private let icon = IconFixtures.circle(.red)

    @Test func pin_showsFavoriteAndVisitedState() {
        let pin = IconPinAnnotationView(annotation: nil, reuseIdentifier: nil)
        pin.configure(icon: icon, ringColor: .red, isFavorite: true, isVisited: true)
        #expect(pin.isShowingFavoriteBadge)
        #expect(abs(pin.iconAlpha - IconPinAnnotationView.visitedIconAlpha) < 0.001)
        #expect(pin.icon === icon)

        pin.configure(icon: icon, ringColor: .red, isFavorite: false, isVisited: false)
        #expect(!pin.isShowingFavoriteBadge)
        #expect(pin.iconAlpha == 1)
    }

    /// The icon keeps at least 5 pt of air to the disc edge.
    @Test func pin_leavesAirAroundTheIcon() {
        #expect(IconPinAnnotationView.diameter / 2 - IconPinAnnotationView.iconRadius >= 5)
        #expect(IconPinAnnotationView.iconMaxSide <= 2 * IconPinAnnotationView.iconRadius)
    }

    @Test func pin_selectionShowsTheRingAndResetsOnReuse() {
        let pin = IconPinAnnotationView(annotation: nil, reuseIdentifier: nil)
        pin.configure(icon: icon, ringColor: .red, isFavorite: false, isVisited: false)
        #expect(pin.discView.edgeWidth == PinDiscView.restingEdgeWidth)

        pin.setPinSelected(true)
        #expect(pin.discView.isEmphasized)
        #expect(pin.discView.edgeWidth == PinDiscView.emphasizedEdgeWidth)
        #expect(pin.discView.ringColor == .red)

        pin.prepareForReuse()
        #expect(!pin.isPinSelected)
        #expect(pin.discView.edgeWidth == PinDiscView.restingEdgeWidth)
    }

    /// Selection survives a reconfigure (a favourite toggled while the pin is selected).
    @Test func pin_reconfigureKeepsSelection() {
        let pin = IconPinAnnotationView(annotation: nil, reuseIdentifier: nil)
        pin.setPinSelected(true)
        pin.configure(icon: icon, ringColor: nil, isFavorite: true, isVisited: false)
        #expect(pin.discView.isEmphasized)
    }

    /// The disc is a neutral, near-opaque fill in both appearances — never tinted with the
    /// icon's colour, which blended icons into their backing.
    @Test func disc_isNeutralAndNearOpaqueInBothAppearances() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            window.overrideUserInterfaceStyle = style
            let disc = PinDiscView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
            window.addSubview(disc)
            disc.configure(ringColor: .red, isEmphasized: false)
            let fill = try #require(disc.fillColor).rgbaComponents
            #expect(fill.alpha >= 0.9, "fill too translucent in \(style)")
            #expect(abs(fill.red - fill.green) < 0.01 && abs(fill.green - fill.blue) < 0.01, "fill tinted in \(style)")
            #expect(style == .dark ? fill.red < 0.3 : fill.red > 0.9)
        }
    }

    @Test func cluster_isACircleUntilTheCountNeedsRoom() {
        let cluster = ClusterBubbleAnnotationView(annotation: nil, reuseIdentifier: nil)
        cluster.configure(count: 12)
        #expect(cluster.countText == "12")
        #expect(cluster.isCountVisible)
        let side = ClusterBubbleAnnotationView.height
        #expect(cluster.frame.size == CGSize(width: side, height: side))

        cluster.configure(count: 12345)
        #expect(cluster.frame.width > side)
        #expect(cluster.frame.height == side)
    }

    /// Reconfiguring a cluster already on the map keeps it where MapKit placed it.
    @Test func cluster_reconfigureKeepsItsPosition() {
        let cluster = ClusterBubbleAnnotationView(annotation: nil, reuseIdentifier: nil)
        cluster.configure(count: 7)
        cluster.center = CGPoint(x: 120, y: 240)
        cluster.configure(count: 12345)
        #expect(cluster.center == CGPoint(x: 120, y: 240))
    }
}
