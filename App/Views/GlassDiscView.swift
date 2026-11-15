import UIKit

/// The round (or capsule) Liquid Glass backing shared by map pins and cluster bubbles, so
/// both always look alike.
///
/// - Live glass (`UIGlassEffect`, interactive) or, when `isFlat`, a pre-drawn translucent
///   disc that costs no blur — the fallback for crowded maps.
/// - An optional faint tint, stronger when `isEmphasized` (a selected pin).
/// - A hairline edge (light on dark maps, dark on light ones), or a 2 pt ring in the tint
///   colour when emphasized, plus a soft drop shadow, so the disc stays separate on any
///   basemap.
///
/// Corners are always fully rounded (`height / 2`), so a square frame gives a circle and a
/// wider one a capsule.
final class GlassDiscView: UIView {
    static let restingTintAlpha: CGFloat = 0.3
    static let emphasizedTintAlpha: CGFloat = 0.6
    static let restingEdgeWidth: CGFloat = 0.75
    static let emphasizedEdgeWidth: CGFloat = 2

    private let glass = UIVisualEffectView(effect: nil)
    private let flatDisc = UIView()
    private let flatTint = UIView()
    private let edge = UIView()
    private let foreground = UIView()

    private(set) var tint: UIColor?
    private(set) var isFlat = false
    private(set) var isEmphasized = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        glass.cornerConfiguration = .capsule()
        for part in [flatDisc, flatTint, edge, foreground] {
            part.clipsToBounds = true
            part.isUserInteractionEnabled = false
        }
        addSubview(flatDisc)
        flatDisc.addSubview(flatTint)
        addSubview(glass)
        addSubview(foreground)
        addSubview(edge)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Where content (a cluster's count) goes: above both the live glass and the flat
    /// disc, so it shows whichever backing is active.
    var contentView: UIView {
        foreground
    }

    var isShowingLiveGlass: Bool {
        !glass.isHidden
    }

    var edgeWidth: CGFloat {
        edge.layer.borderWidth
    }

    func configure(tint: UIColor?, isFlat: Bool, isEmphasized: Bool) {
        self.tint = tint
        self.isFlat = isFlat
        self.isEmphasized = isEmphasized
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        for part in [glass, flatDisc, flatTint, edge, foreground] {
            part.frame = bounds
        }
        for part in [flatDisc, flatTint, edge, foreground] {
            part.layer.cornerRadius = radius
        }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }

    private func refresh() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let tintAlpha = isEmphasized ? Self.emphasizedTintAlpha : Self.restingTintAlpha

        glass.isHidden = isFlat
        flatDisc.isHidden = !isFlat
        if isFlat {
            glass.effect = nil
            flatDisc.backgroundColor = isDark ? UIColor(white: 0.12, alpha: 0.78) : UIColor(white: 1, alpha: 0.85)
            flatTint.backgroundColor = tint?.withAlphaComponent(tintAlpha)
        } else {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = tint?.withAlphaComponent(tintAlpha)
            effect.isInteractive = true
            glass.effect = effect
        }

        if isEmphasized {
            edge.layer.borderWidth = Self.emphasizedEdgeWidth
            edge.layer.borderColor = (tint ?? tintColor).withAlphaComponent(1).cgColor
        } else {
            edge.layer.borderWidth = Self.restingEdgeWidth
            edge.layer.borderColor = (isDark ? UIColor(white: 1, alpha: 0.35) : UIColor(white: 0, alpha: 0.15)).cgColor
        }
    }
}
