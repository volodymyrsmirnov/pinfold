import MapKit
import UIKit

/// A cluster bubble matching the glass pins: the member count on a `GlassDiscView`, a circle
/// for 1–2 digit counts that grows into a capsule for longer ones. Tinted with the members'
/// shared hue when most of them share one (`majorityTint`).
final class GlassClusterAnnotationView: MKAnnotationView {
    static let reuseID = "cluster.glass"
    static let height: CGFloat = 36
    /// Horizontal padding around the count when it outgrows the circle.
    private static let horizontalPadding: CGFloat = 8

    private let disc = GlassDiscView()
    private let countLabel = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clipsToBounds = false
        addSubview(disc)
        let base = UIFont.systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 15) } ?? base
        countLabel.textColor = .label
        countLabel.textAlignment = .center
        countLabel.adjustsFontForContentSizeCategory = false
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

    var discView: GlassDiscView {
        disc
    }

    func configure(count: Int, tint: UIColor?, isFlat: Bool) {
        countLabel.text = "\(count)"
        let width = Self.width(forCountText: countLabel.text ?? "", font: countLabel.font)
        frame = CGRect(x: 0, y: 0, width: width, height: Self.height)
        disc.frame = bounds
        countLabel.frame = disc.bounds
        disc.configure(tint: tint, isFlat: isFlat, isEmphasized: false)
        centerOffset = .zero
    }

    /// The bubble width: a circle until the count needs more room, then a capsule.
    static func width(forCountText text: String, font: UIFont) -> CGFloat {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return max(height, textWidth + 2 * horizontalPadding)
    }

    /// Hue buckets used to decide whether members "share" a tint: 12 buckets of 30°, so
    /// near-identical shades from different icon files (blu-1, blu-2, …) count as one.
    private static let hueBuckets = 12

    /// The tint most members share — by hue bucket — when more than half of them share it;
    /// else `nil`. Members without a tint (white, black, multi-colour or teardrop pins) count
    /// against it. Returns the first member tint in the winning bucket.
    static func majorityTint(of tints: [UIColor?]) -> UIColor? {
        guard !tints.isEmpty else { return nil }
        var counts: [Int: (tint: UIColor, count: Int)] = [:]
        for case let tint? in tints {
            var hue: CGFloat = 0
            tint.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
            let bucket = Int((hue * CGFloat(hueBuckets)).rounded()) % hueBuckets
            counts[bucket, default: (tint, 0)].count += 1
        }
        guard let best = counts.values.max(by: { $0.count < $1.count }),
              best.count * 2 > tints.count else { return nil }
        return best.tint
    }
}
