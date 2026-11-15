import UIKit

/// The round (or capsule) backing shared by map pins and cluster bubbles, so both always
/// look alike.
///
/// A near-solid neutral disc — dark on dark maps, near-white on light ones — with a
/// hairline edge and a soft drop shadow. It is deliberately **not** live Liquid Glass:
/// on device, glass adapts the colours of whatever sits on it (a red glyph came out pink,
/// blue cyan, amber lime) and a translucent tint in the icon's own hue blended the icon
/// into its backing. A plain view keeps every icon in its exact colours with full contrast,
/// and costs no blur pass however many pins are on screen.
///
/// When `isEmphasized` (a selected pin) the hairline becomes a 2 pt ring in `ringColor`.
/// Corners are always fully rounded (`height / 2`): a square frame gives a circle, a wider
/// one a capsule.
final class PinDiscView: UIView {
    static let restingEdgeWidth: CGFloat = 0.75
    static let emphasizedEdgeWidth: CGFloat = 2

    private let fill = UIView()
    private let edge = UIView()
    private let foreground = UIView()

    private(set) var ringColor: UIColor?
    private(set) var isEmphasized = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        for part in [fill, edge, foreground] {
            part.clipsToBounds = true
            part.isUserInteractionEnabled = false
            addSubview(part)
        }
        bringSubviewToFront(edge)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Where content (a cluster's count) goes: above the fill, below the edge.
    var contentView: UIView {
        foreground
    }

    var edgeWidth: CGFloat {
        edge.layer.borderWidth
    }

    /// The disc's fill colour for the current appearance.
    var fillColor: UIColor? {
        fill.backgroundColor
    }

    func configure(ringColor: UIColor?, isEmphasized: Bool) {
        self.ringColor = ringColor
        self.isEmphasized = isEmphasized
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        for part in [fill, edge, foreground] {
            part.frame = bounds
            part.layer.cornerRadius = radius
        }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }

    private func refresh() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        fill.backgroundColor = isDark ? UIColor(white: 0.12, alpha: 0.92) : UIColor(white: 1, alpha: 0.95)
        layer.shadowOpacity = isDark ? 0.45 : 0.25
        layer.shadowRadius = isDark ? 2 : 2.5
        if isEmphasized {
            edge.layer.borderWidth = Self.emphasizedEdgeWidth
            edge.layer.borderColor = (ringColor ?? tintColor).withAlphaComponent(1).cgColor
        } else {
            edge.layer.borderWidth = Self.restingEdgeWidth
            edge.layer.borderColor = (isDark ? UIColor(white: 1, alpha: 0.28) : UIColor(white: 0, alpha: 0.14)).cgColor
        }
    }
}
