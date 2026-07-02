import CoreGraphics
import Foundation

/// Live geometry of the placemark list's realized rows, for scroll-anchor capture/restore.
///
/// Deliberately a plain (non-`@Observable`) class held in `@State`: rows write their frames
/// on every scroll frame via `onGeometryChange`, and those writes must NOT invalidate the
/// view tree. NOT the iOS 18 scroll-instrumentation APIs (`scrollPosition` /
/// `onScrollVisibilityChange`): those do not support `List` (UICollectionView-backed;
/// `ScrollView` only) and silently never fire — verified in a previous implementation
/// attempt that recorded nothing under real scrolling.
///
/// Rows remove themselves in `onDisappear` as `List` derealizes them, so `frames` only
/// holds (approximately) the realized rows — stale frames of far-offscreen rows cannot
/// masquerade as the anchor. All frames are in the GLOBAL coordinate space, compared
/// against the list's own global frame.
final class RowFrameBox {
    /// Row id (`PlacemarkOutline.Row.id`, a positional tree path) → last-known global frame.
    var frames: [String: CGRect] = [:]
    /// The `List`'s own global frame.
    var listFrame: CGRect?
    /// Where a successful scroll restore actually landed the anchor row's top, relative to
    /// the list's top (the list's content-top inset, e.g. under the large title). Recorded
    /// by the restore path and used to calibrate `anchorRowID()`'s reference line so
    /// save→restore round-trips don't creep by one row per cycle.
    var restoredTopOffset: CGFloat?

    /// The id of the row to anchor scroll restoration on: the realized row whose top is
    /// nearest the reference line (list top + calibration), excluding rows scrolled fully
    /// above it. `nil` when geometry hasn't been observed yet.
    func anchorRowID() -> String? {
        guard let listFrame else { return nil }
        let referenceY = listFrame.minY + (restoredTopOffset ?? 0)
        return frames
            .filter { $0.value.maxY > referenceY + 1 }
            .min { abs($0.value.minY - referenceY) < abs($1.value.minY - referenceY) }?
            .key
    }

    /// Clears everything (a different document's rows are unrelated geometry).
    func reset() {
        frames.removeAll()
        listFrame = nil
        restoredTopOffset = nil
    }
}
