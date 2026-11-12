import UIKit

/// Memoizes `PlacemarkPinImage.decorated` per (base image, favourite, visited).
///
/// A file has few distinct styles, so thousands of favourite/visited pins share a handful
/// of decorated images; without this, toggling one favourite re-rendered a
/// `UIGraphicsImageRenderer` image per pin. The base image's identity stands for the
/// style (the coordinator hands out one base image per style), and the cache retains each
/// base so an `ObjectIdentifier` can never be recycled while it is a key.
final class PinDecorationCache {
    private struct Key: Hashable {
        let base: ObjectIdentifier
        let isFavorite: Bool
        let isVisited: Bool
        let anchor: PinAnchor
    }

    private var images: [Key: (base: UIImage, decorated: UIImage)] = [:]

    var count: Int {
        images.count
    }

    func image(
        for base: UIImage, isFavorite: Bool, isVisited: Bool, anchor: PinAnchor
    ) -> UIImage {
        guard isFavorite || isVisited else { return base }
        let key = Key(
            base: ObjectIdentifier(base), isFavorite: isFavorite, isVisited: isVisited, anchor: anchor
        )
        if let hit = images[key] {
            return hit.decorated
        }
        let decorated = PlacemarkPinImage.decorated(
            base, isFavorite: isFavorite, isVisited: isVisited, anchor: anchor
        )
        images[key] = (base, decorated)
        return decorated
    }
}
