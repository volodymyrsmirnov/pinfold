@testable import Pinfold
import Testing
import UIKit

/// Tests for `PlacemarkPinImage`. The cached-icon path needs on-disk files and is
/// verified manually on the simulator; here we only assert the symbol fallback
/// produces a usable, non-empty image.
struct PlacemarkPinImageTests {

    @Test func fallbackImage_isNonEmpty() {
        let image = PlacemarkPinImage.fallbackImage(tint: .systemRed)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
