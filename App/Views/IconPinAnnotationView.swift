import MapKit
import UIKit

/// A placemark pin for a style with an icon: the file's icon, in its own colours, centred
/// on a neutral `PinDiscView`.
///
/// - Favourite: a small yellow star badge on the disc's top-right rim.
/// - Visited: the icon is dimmed.
/// - Selected (`setPinSelected`): a 2 pt ring in the icon's own colour, on top of the
///   coordinator's scale-up.
///
/// The icon arrives pre-sized by `OpticalIcon` into a `2·iconRadius` square (at most
/// `iconMaxSide` across), leaving clear air between it and the disc edge.
final class IconPinAnnotationView: MKAnnotationView {
    static let reuseID = "placemark.icon"
    static let diameter: CGFloat = 34
    /// Every visible icon pixel stays within this radius of the centre — at least 5 pt
    /// clear of the disc edge.
    /// `nonisolated`: read off the main actor by `PlacemarkPinImage` when sizing icons.
    nonisolated static let iconRadius: CGFloat = 12
    /// The visible icon is at most this wide or tall.
    nonisolated static let iconMaxSide: CGFloat = 18
    static let visitedIconAlpha: CGFloat = 0.45
    private static let starSide: CGFloat = 14

    private let disc = PinDiscView()
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

    var discView: PinDiscView {
        disc
    }

    /// Everything the pin shows. `icon` is the un-decorated base image (favourite and
    /// visited are drawn here, not baked into it); `ringColor` colours the selection ring.
    func configure(icon: UIImage, ringColor: UIColor?, isFavorite: Bool, isVisited: Bool) {
        iconView.image = icon
        iconView.alpha = isVisited ? Self.visitedIconAlpha : 1
        starView.isHidden = !isFavorite
        disc.configure(ringColor: ringColor, isEmphasized: isPinSelected)
    }

    func setPinSelected(_ selected: Bool) {
        isPinSelected = selected
        disc.configure(ringColor: disc.ringColor, isEmphasized: selected)
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
