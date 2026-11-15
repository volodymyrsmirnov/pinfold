import MapKit
import UIKit

/// A placemark pin for a style with an icon: the file's icon, colours untouched, on a
/// `GlassDiscView` tinted with the icon's hue.
///
/// - Favourite: a small yellow star badge on the disc's top-right rim.
/// - Visited: the icon is dimmed.
/// - Selected (`setPinSelected`): stronger tint and a ring, on top of the coordinator's
///   scale-up.
///
/// The icon arrives pre-sized by `OpticalIcon` into a `2·iconRadius` square, so it always
/// sits clear of the disc edge and the selection ring.
final class GlassPinAnnotationView: MKAnnotationView {
    static let reuseID = "placemark.glass"
    static let diameter: CGFloat = 32
    /// Radius of the safe circle every icon is sized to: 3.5 pt clear of the disc edge, so
    /// the 2 pt selection ring never touches the icon.
    static let iconRadius: CGFloat = 12.5
    static let visitedIconAlpha: CGFloat = 0.45
    private static let starSide: CGFloat = 14

    private let disc = GlassDiscView()
    private let iconView = UIImageView()
    private let starView = UIView()

    private(set) var isPinSelected = false

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let side = Self.diameter
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        clipsToBounds = false
        disc.frame = bounds
        addSubview(disc)

        iconView.contentMode = .scaleAspectFit
        let inset = side / 2 - Self.iconRadius
        iconView.frame = bounds.insetBy(dx: inset, dy: inset)
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        buildStar()
        addSubview(starView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var icon: UIImage? {
        iconView.image
    }

    var iconAlpha: CGFloat {
        iconView.alpha
    }

    var isShowingFavoriteBadge: Bool {
        !starView.isHidden
    }

    var discView: GlassDiscView {
        disc
    }

    /// Everything the pin shows. `icon` is the un-decorated base image (favourite and
    /// visited are drawn here, not baked into it).
    func configure(icon: UIImage, tint: UIColor?, isFavorite: Bool, isVisited: Bool, isFlat: Bool) {
        iconView.image = icon
        iconView.alpha = isVisited ? Self.visitedIconAlpha : 1
        starView.isHidden = !isFavorite
        disc.configure(tint: tint, isFlat: isFlat, isEmphasized: isPinSelected)
    }

    func setPinSelected(_ selected: Bool) {
        isPinSelected = selected
        disc.configure(tint: disc.tint, isFlat: disc.isFlat, isEmphasized: selected)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPinSelected(false)
    }

    /// A yellow disc with a dark star, centred on the main disc's rim at 45°.
    private func buildStar() {
        let side = Self.starSide
        let radius = Self.diameter / 2
        let center = CGPoint(x: radius + radius * cos(.pi / 4), y: radius - radius * sin(.pi / 4))
        starView.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        starView.backgroundColor = .systemYellow
        starView.layer.cornerRadius = side / 2
        starView.layer.borderWidth = 1.5
        starView.layer.borderColor = UIColor.white.cgColor
        starView.isUserInteractionEnabled = false
        starView.isHidden = true
        let star = UIImageView(image: UIImage(
            systemName: "star.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        ))
        star.tintColor = UIColor(white: 0.15, alpha: 1)
        star.contentMode = .center
        star.frame = starView.bounds
        starView.addSubview(star)
    }
}
