import MapKit
@testable import Pinfold
import Testing
import UIKit

/// Tests for the glass map pin, cluster bubble and their shared disc.
@MainActor
struct GlassPinViewsTests {
    private let icon = IconFixtures.circle(.red)

    @Test func pin_showsFavoriteAndVisitedState() {
        let pin = GlassPinAnnotationView(annotation: nil, reuseIdentifier: nil)
        pin.configure(icon: icon, tint: .red, isFavorite: true, isVisited: true, isFlat: false)
        #expect(pin.isShowingFavoriteBadge)
        #expect(abs(pin.iconAlpha - GlassPinAnnotationView.visitedIconAlpha) < 0.001)
        #expect(pin.icon === icon)

        pin.configure(icon: icon, tint: .red, isFavorite: false, isVisited: false, isFlat: false)
        #expect(!pin.isShowingFavoriteBadge)
        #expect(pin.iconAlpha == 1)
    }

    @Test func pin_selectionEmphasisesTheDiscAndResetsOnReuse() {
        let pin = GlassPinAnnotationView(annotation: nil, reuseIdentifier: nil)
        pin.configure(icon: icon, tint: .red, isFavorite: false, isVisited: false, isFlat: false)
        #expect(pin.discView.edgeWidth == GlassDiscView.restingEdgeWidth)

        pin.setPinSelected(true)
        #expect(pin.discView.isEmphasized)
        #expect(pin.discView.edgeWidth == GlassDiscView.emphasizedEdgeWidth)
        #expect(pin.discView.tint == .red)

        pin.prepareForReuse()
        #expect(!pin.isPinSelected)
        #expect(pin.discView.edgeWidth == GlassDiscView.restingEdgeWidth)
    }

    /// Selection survives a reconfigure (a favourite toggled while the pin is selected).
    @Test func pin_reconfigureKeepsSelection() {
        let pin = GlassPinAnnotationView(annotation: nil, reuseIdentifier: nil)
        pin.setPinSelected(true)
        pin.configure(icon: icon, tint: nil, isFavorite: true, isVisited: false, isFlat: false)
        #expect(pin.discView.isEmphasized)
    }

    @Test func disc_flatFallbackDropsLiveGlass() {
        let disc = GlassDiscView()
        disc.configure(tint: nil, isFlat: false, isEmphasized: false)
        #expect(disc.isShowingLiveGlass)
        disc.configure(tint: nil, isFlat: true, isEmphasized: false)
        #expect(!disc.isShowingLiveGlass)
    }

    @Test func cluster_isACircleUntilTheCountNeedsRoom() {
        let cluster = GlassClusterAnnotationView(annotation: nil, reuseIdentifier: nil)
        cluster.configure(count: 12, tint: nil, isFlat: false)
        #expect(cluster.countText == "12")
        #expect(cluster.frame.size == CGSize(width: GlassClusterAnnotationView.height, height: GlassClusterAnnotationView.height))

        cluster.configure(count: 12345, tint: nil, isFlat: true)
        #expect(cluster.frame.width > GlassClusterAnnotationView.height)
        #expect(cluster.frame.height == GlassClusterAnnotationView.height)
        #expect(!cluster.discView.isShowingLiveGlass)
    }

    /// The count stays visible on both the live glass and the flat fallback disc.
    @Test func cluster_countIsVisibleInBothModes() {
        let cluster = GlassClusterAnnotationView(annotation: nil, reuseIdentifier: nil)
        for isFlat in [false, true] {
            cluster.configure(count: 7, tint: nil, isFlat: isFlat)
            #expect(cluster.isCountVisible, "count hidden when isFlat = \(isFlat)")
        }
    }

    /// Reconfiguring a cluster already on the map (a tint refresh) keeps it where MapKit
    /// placed it, even when its width changes.
    @Test func cluster_reconfigureKeepsItsPosition() {
        let cluster = GlassClusterAnnotationView(annotation: nil, reuseIdentifier: nil)
        cluster.configure(count: 7, tint: nil, isFlat: false)
        cluster.center = CGPoint(x: 120, y: 240)
        cluster.configure(count: 12345, tint: .red, isFlat: false)
        #expect(cluster.center == CGPoint(x: 120, y: 240))
        #expect(cluster.bounds.width > GlassClusterAnnotationView.height)
    }

    @Test func cluster_majorityTint() {
        let red = UIColor.red, blue = UIColor.blue
        #expect(GlassClusterAnnotationView.majorityTint(of: [red, red, blue]) == red)
        #expect(GlassClusterAnnotationView.majorityTint(of: [red, blue]) == nil)
        // Untinted members count against a majority.
        #expect(GlassClusterAnnotationView.majorityTint(of: [red, nil, nil]) == nil)
        #expect(GlassClusterAnnotationView.majorityTint(of: []) == nil)
        // Near-identical shades from different icon files share a hue.
        let blue1 = UIColor(red: 0.10, green: 0.45, blue: 0.85, alpha: 1)
        let blue2 = UIColor(red: 0.12, green: 0.50, blue: 0.88, alpha: 1)
        #expect(GlassClusterAnnotationView.majorityTint(of: [blue1, blue2, nil]) == blue1)
    }
}
