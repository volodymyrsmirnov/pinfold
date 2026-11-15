import MapKit
import UIKit

/// A cluster bubble matching the icon pins: the member count on the same neutral
/// `PinDiscView` — a circle for 1–2 digit counts, growing into a capsule for longer ones.
final class ClusterBubbleAnnotationView: MKAnnotationView {
    static let reuseID = "cluster.bubble"
    static let height: CGFloat = 36
    /// Horizontal padding around the count when it outgrows the circle.
    private static let horizontalPadding: CGFloat = 8

    private let disc = PinDiscView()
    private let countLabel = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clipsToBounds = false
        addSubview(disc)
        let base = UIFont.systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 15) } ?? base
        countLabel.textColor = .label
        countLabel.textAlignment = .center
        disc.contentView.addSubview(countLabel)
        // MapKit draws clusters above pins; keep that ordering explicit.
        displayPriority = .defaultHigh
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var countText: String? {
        countLabel.text
    }

    var discView: PinDiscView {
        disc
    }

    /// Whether the count label and every view above it, up to this one, is shown.
    var isCountVisible: Bool {
        var view: UIView? = countLabel
        while let current = view, current !== self {
            if current.isHidden || current.alpha == 0 {
                return false
            }
            view = current.superview
        }
        return view === self
    }

    func configure(count: Int) {
        countLabel.text = "\(count)"
        let width = Self.width(forCountText: countLabel.text ?? "", font: countLabel.font)
        // Resize around the current centre: MapKit positions the view, and a bubble already
        // on screen must not jump.
        bounds.size = CGSize(width: width, height: Self.height)
        disc.frame = bounds
        countLabel.frame = disc.bounds
        centerOffset = .zero
    }

    /// The bubble width: a circle until the count needs more room, then a capsule.
    static func width(forCountText text: String, font: UIFont) -> CGFloat {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return max(height, textWidth + 2 * horizontalPadding)
    }
}
