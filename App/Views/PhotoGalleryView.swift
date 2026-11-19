import ImageIO
import PinfoldCore
import SwiftUI
import UIKit

// MARK: - PhotoGalleryView

/// A horizontal scrolling gallery of photo thumbnails for a placemark.
///
/// For each href in `photoLinks`, the view resolves the local cached file via
/// `ResourceCache`. Resolved images are shown as tappable thumbnails. Unresolved
/// (missing or not yet downloaded) links show a placeholder tile: a spinner while the photo
/// downloads, a "couldn't load" badge after a failed attempt.
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
        let statuses = imageStatuses
        let urls = statuses.map { status -> URL? in
            if case let .cached(url) = status {
                url
            } else {
                nil
            }
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(photoLinks.enumerated()), id: \.offset) { index, _ in
                    let url = urls[index]
                    thumbnailTile(status: statuses[index])
                        .onTapGesture {
                            open(at: index, in: urls)
                        }
                        .accessibilityElement()
                        .accessibilityLabel("Photo \(index + 1) of \(photoLinks.count)")
                        .accessibilityValue(Self.accessibilityStatus(statuses[index]))
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

    /// The tile's status for VoiceOver: its label is the position, so the placeholder's own
    /// label isn't read.
    private static func accessibilityStatus(_ status: RemoteImageStatus) -> Text {
        switch status {
        case .loading: Text("Downloading")
        case .failed: Text("Couldn't Download")
        case .idle, .cached: Text(verbatim: "")
        }
    }

    /// Where each link's photo stands, in link order.
    private var imageStatuses: [RemoteImageStatus] {
        let resourcesDir = storage.resourcesDirectory(for: entry)
        return photoLinks.map { resourceCache.observedImageStatus(forHref: $0, in: resourcesDir) }
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
    private func thumbnailTile(status: RemoteImageStatus) -> some View {
        if case let .cached(url) = status {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                default:
                    placeholderTile(.idle)
                }
            }
            .frame(width: 100, height: 100)
        } else {
            placeholderTile(status)
        }
    }

    private func placeholderTile(_ status: RemoteImageStatus) -> some View {
        RemoteImagePlaceholder(status: status, size: 100, cornerRadius: 8, symbolSize: 28)
    }
}

// MARK: - PhotoViewer

/// A sheet showing a place's photos one at a time: swipe left and right between them, pinch or
/// double-tap to zoom, and drag the sheet down (or tap Close) to dismiss.
///
/// Built from a paging `ScrollView` and a zooming `UIScrollView` per photo rather than Quick Look:
/// cached photos are stored under hashed file names (which Quick Look would show as titles), and
/// a photo downloaded from a URL without an extension is cached as `.img`, which it can't open.
///
/// Not a page-style `TabView`: the neighbours are decoded as a swipe settles, and a page whose
/// content changed mid-swipe (spinner to photo) left the `TabView` stopped between pages, half of
/// one photo beside half of the next. Here every page is exactly the container's size
/// (`containerRelativeFrame`), so a page's content can't move the pager.
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
            pager
                .overlay(alignment: .bottom) { pageDots }
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

    /// One page per photo, swiped sideways a whole page at a time.
    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(item.urls.indices, id: \.self) { index in
                    ZoomablePhoto(
                        image: images[index],
                        failed: failures.contains(index),
                        isCurrent: index == selection
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .accessibilityLabel("Photo \(index + 1) of \(item.urls.count)")
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: pageBinding)
    }

    /// The scrolled-to page, as `selection`.
    private var pageBinding: Binding<Int?> {
        Binding(
            get: { selection },
            set: { page in
                if let page {
                    selection = page
                }
            }
        )
    }

    /// The page indicator the system pager drew: a `UIPageControl`, which shrinks and scrolls
    /// its dots for a long gallery and can be tapped, scrubbed and adjusted with VoiceOver.
    @ViewBuilder
    private var pageDots: some View {
        if item.urls.count > 1 {
            PageControl(numberOfPages: item.urls.count, currentPage: selection) { page in
                withAnimation { selection = page }
            }
            // The full width, so UIPageControl fits (and scrolls) the dots of a long gallery itself.
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .padding(.bottom, 12)
        }
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

// MARK: - PageControl

/// `UIPageControl` for SwiftUI: shows `currentPage` and reports the page the person picks.
private struct PageControl: UIViewRepresentable {
    let numberOfPages: Int
    let currentPage: Int
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.onSelect = onSelect
        control.numberOfPages = numberOfPages
        if control.currentPage != currentPage {
            control.currentPage = currentPage
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }

        @objc func changed(_ control: UIPageControl) {
            onSelect(control.currentPage)
        }
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
