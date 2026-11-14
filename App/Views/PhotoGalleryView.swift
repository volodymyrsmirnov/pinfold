import ImageIO
import PinfoldCore
import SwiftUI
import UIKit

// MARK: - PhotoGalleryView

/// A horizontal scrolling gallery of photo thumbnails for a placemark.
///
/// For each href in `photoLinks`, the view resolves the local cached file via
/// `ResourceCache`. Resolved images are shown as tappable thumbnails. Unresolved
/// (missing or not yet downloaded) links show a placeholder tile.
///
/// Tapping a resolved thumbnail opens `PhotoViewer` in a sheet on that photo: swipe sideways
/// between the place's photos, pinch or double-tap to zoom, drag down to close.
struct PhotoGalleryView: View {
    // MARK: - Properties

    let photoLinks: [String]
    let entry: CatalogEntry

    // MARK: - State

    @State private var viewer: PhotoViewer.Item?

    // MARK: - Environment

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage

    // MARK: - Body

    var body: some View {
        let urls = localURLs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(photoLinks.enumerated()), id: \.offset) { index, _ in
                    let url = urls[index]
                    thumbnailTile(url: url)
                        .onTapGesture {
                            open(at: index, in: urls)
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Photo \(index + 1) of \(photoLinks.count)")
                        .accessibilityAddTraits(url == nil ? [] : .isButton)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 120)
        .sheet(item: $viewer) { item in
            PhotoViewer(item: item)
        }
    }

    /// The cached file for each link, in link order (`nil` where it isn't on disk yet).
    private var localURLs: [URL?] {
        let resourcesDir = storage.resourcesDirectory(for: entry)
        return photoLinks.map { resourceCache.localURL(forHref: $0, in: resourcesDir) }
    }

    /// Opens the viewer on the tapped photo, paging through only the photos that are on disk.
    /// The start page is counted from the tapped position (not looked up by URL), so a link
    /// that repeats opens on the copy that was tapped.
    private func open(at index: Int, in urls: [URL?]) {
        guard urls[index] != nil else { return }
        let available = urls.compactMap(\.self)
        let startIndex = urls[..<index].count { $0 != nil }
        viewer = PhotoViewer.Item(urls: available, startIndex: startIndex)
    }

    // MARK: - Thumbnail tile

    @ViewBuilder
    private func thumbnailTile(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                default:
                    placeholderTile
                }
            }
            .frame(width: 100, height: 100)
        } else {
            placeholderTile
        }
    }

    private var placeholderTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 100, height: 100)
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PhotoViewer

/// A sheet showing a place's photos one at a time: swipe left and right between them, pinch or
/// double-tap to zoom, and drag the sheet down (or tap Close) to dismiss.
///
/// Built from a paging `TabView` and a zooming `UIScrollView` per photo rather than Quick Look:
/// cached photos are stored under hashed file names (which Quick Look would show as titles), and
/// a photo downloaded from a URL without an extension is cached as `.img`, which it can't open.
struct PhotoViewer: View {
    /// What the sheet opens on: the photos to page through and the one to start on.
    struct Item: Identifiable {
        let id = UUID()
        let urls: [URL]
        let startIndex: Int
    }

    let item: Item

    @State private var selection: Int
    /// Decoded photos for the current page and its neighbours, by page index.
    @State private var images: [Int: UIImage] = [:]
    /// Pages whose file couldn't be decoded, so they aren't retried on every swipe.
    @State private var failures: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    init(item: Item) {
        self.item = item
        _selection = State(initialValue: item.startIndex)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(item.urls.indices, id: \.self) { index in
                    ZoomablePhoto(
                        image: images[index],
                        failed: failures.contains(index),
                        isCurrent: index == selection
                    )
                    .accessibilityLabel("Photo \(index + 1) of \(item.urls.count)")
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: item.urls.count > 1 ? .always : .never))
            .background { pagingShortcuts }
            .task(id: selection) { await loadImages(around: selection) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.black)
        .presentationDragIndicator(.visible)
        .presentationSizing(.page)
    }

    /// Left and right arrows page on a hardware keyboard (iPad, Mac), where swiping is awkward.
    /// Invisible buttons, so the shortcuts work without adding visible controls.
    @ViewBuilder
    private var pagingShortcuts: some View {
        if item.urls.count > 1 {
            Group {
                Button("Previous Photo") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Photo") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// Keeps the photos for `centre` and the pages either side decoded, and drops the rest.
    ///
    /// The neighbours are decoded before they are swiped to, so a page slides in already showing
    /// its photo instead of flashing the loading state; holding at most three bitmaps keeps
    /// paging through a long gallery from piling them all up in memory. The current page loads
    /// first. A decode that finishes after the user has paged on is still kept if its page is
    /// next to the new one.
    private func loadImages(around centre: Int) async {
        let window = (centre - 1 ... centre + 1).filter(item.urls.indices.contains)
        images = images.filter { window.contains($0.key) }
        for index in [centre, centre + 1, centre - 1] where window.contains(index) {
            guard images[index] == nil, !failures.contains(index) else { continue }
            let loaded = await loadDisplayImage(item.urls[index])
            if abs(index - selection) <= 1 {
                if let loaded {
                    images[index] = loaded
                } else {
                    failures.insert(index)
                }
            }
            if Task.isCancelled {
                return
            }
        }
    }

    private func step(_ delta: Int) {
        let target = selection + delta
        guard item.urls.indices.contains(target) else { return }
        withAnimation { selection = target }
    }

    /// "2 of 5" when there is more than one photo; nothing otherwise.
    private var title: String {
        item.urls.count > 1 ? String(localized: "\(selection + 1) of \(item.urls.count)") : ""
    }
}

// MARK: - ZoomablePhoto

/// One page of the viewer: the photo in a zooming scroll view once `PhotoViewer` has decoded it,
/// a spinner until then, or a message if it can't be read. Zoom resets when the page is swiped
/// away (`isCurrent` turns false).
private struct ZoomablePhoto: View {
    let image: UIImage?
    let failed: Bool
    let isCurrent: Bool

    var body: some View {
        if let image {
            ZoomableImageView(image: image, isCurrent: isCurrent)
        } else if failed {
            ContentUnavailableView(
                "Image Unavailable",
                systemImage: "photo.slash",
                description: Text("This photo could not be loaded.")
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The longest side, in pixels, a photo is decoded at: sharp at full zoom on the largest
/// screens, without holding a full-size bitmap (a 48 MP photo would be ~190 MB).
private let maxDisplayPixelSize = 3072

/// Decodes `url` for display off the main actor, downsampled to `maxDisplayPixelSize` with
/// ImageIO (which never decodes the full-size image) and with its orientation applied. A
/// `nonisolated` free function so the detached closure is compiled outside any view (see the note
/// at the top of `DocumentLoad.swift`).
private func loadDisplayImage(_ url: URL) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDisplayPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }.value
}

// MARK: - ZoomableImageView

/// Wraps `ZoomingImageScrollView` for SwiftUI.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let isCurrent: Bool

    func makeUIView(context _: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        view.display(image)
        return view
    }

    func updateUIView(_ view: ZoomingImageScrollView, context _: Context) {
        if view.image !== image {
            view.display(image)
        }
        if !isCurrent {
            view.resetZoom()
        }
    }
}

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
