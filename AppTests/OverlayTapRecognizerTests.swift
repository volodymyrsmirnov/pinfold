@testable import Pinfold
import Testing
import UIKit

/// The overlay single-tap recogniser must wait for double-tap recognisers (MapKit's zoom).
@MainActor struct OverlayTapRecognizerTests {
    private final class RecordingTap: UITapGestureRecognizer {
        var required: [UIGestureRecognizer] = []
        override func require(toFail other: UIGestureRecognizer) {
            required.append(other)
            super.require(toFail: other)
        }
    }

    @Test func singleTapRequiresEveryDoubleTapInTheHierarchyToFail() {
        let root = UIView()
        let child = UIView()
        root.addSubview(child)
        let rootDouble = UITapGestureRecognizer()
        rootDouble.numberOfTapsRequired = 2
        let childDouble = UITapGestureRecognizer()
        childDouble.numberOfTapsRequired = 2
        let otherSingle = UITapGestureRecognizer()
        root.addGestureRecognizer(rootDouble)
        root.addGestureRecognizer(otherSingle)
        child.addGestureRecognizer(childDouble)
        let single = RecordingTap()
        root.addGestureRecognizer(single)

        PlacemarkMapRepresentable.Coordinator.requireDoubleTapsToFail(for: single, in: root)

        #expect(single.required.count == 2)
        #expect(single.required.contains { $0 === rootDouble })
        #expect(single.required.contains { $0 === childDouble })
    }
}
