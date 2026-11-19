import UIKit

/// A scroll view that fits its image to the bounds, centres it, and zooms from 1× to 4× with a
/// pinch or a double tap.
///
/// At 1× only the pan gesture is switched off, so a vertical drag goes to the sheet (dismiss) and
/// a horizontal one to the pager, while the pinch gesture stays live to start a zoom. (Turning off
/// `isScrollEnabled` instead would forward every touch up the responder chain, pinch included.)
/// Zoomed in, it pans; if the sheet takes over a drag at the top edge, the offset is put back
/// inside the content when the drag ends, so the photo never stays parked off-centre.
final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    /// The bounds size the image was last fitted to; a change refits at 1×.
    private var fittedBounds: CGSize = .zero

    var image: UIImage? {
        imageView.image
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        bouncesZoom = true
        decelerationRate = .fast
        panGestureRecognizer.isEnabled = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `image` at 1×, fitted to the current bounds.
    func display(_ image: UIImage) {
        imageView.image = image
        fittedBounds = .zero
        setNeedsLayout()
    }

    /// Returns to 1× (used when the page is swiped away).
    func resetZoom() {
        if zoomScale != minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if fittedBounds != bounds.size {
            fittedBounds = bounds.size
            zoomScale = 1
            let fitted = Self.fittedSize(of: image.size, in: bounds.size)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        centreContent()
    }

    /// `size` scaled down (or up) to fit inside `bounds` with its aspect ratio kept.
    static func fittedSize(of size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Insets that keep the image centred while it is smaller than the bounds.
    private func centreContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let scale = min(maximumZoomScale, 2.5)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let target = CGRect(
            x: point.x - size.width / 2, y: point.y - size.height / 2,
            width: size.width, height: size.height
        )
        zoom(to: target, animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in _: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_: UIScrollView) {
        centreContent()
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale
    }

    func scrollViewDidEndZooming(_: UIScrollView, with _: UIView?, atScale scale: CGFloat) {
        panGestureRecognizer.isEnabled = scale > minimumZoomScale
        settleIntoContent()
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleIntoContent()
        }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        settleIntoContent()
    }

    /// Moves the offset back inside the content (plus the centring insets) if something — the
    /// sheet's dismiss drag, typically — left it outside.
    private func settleIntoContent() {
        let minX = -contentInset.left
        let minY = -contentInset.top
        let maxX = max(minX, contentSize.width + contentInset.right - bounds.width)
        let maxY = max(minY, contentSize.height + contentInset.bottom - bounds.height)
        let settled = CGPoint(
            x: min(max(contentOffset.x, minX), maxX),
            y: min(max(contentOffset.y, minY), maxY)
        )
        if settled != contentOffset {
            setContentOffset(settled, animated: true)
        }
    }
}
