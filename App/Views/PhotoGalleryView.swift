import SwiftUI
import PinfoldCore

// MARK: - PhotoItem

/// A lightweight wrapper around a local file `URL` for use as an `Identifiable`
/// `fullScreenCover` binding item. Avoids a `@retroactive Identifiable` extension
/// on `URL`.
private struct PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - PhotoGalleryView

/// A horizontal scrolling gallery of photo thumbnails for a placemark.
///
/// For each href in `photoLinks`, the view resolves the local cached file via
/// `ResourceCache`. Resolved images are shown as tappable thumbnails. Unresolved
/// (missing or not yet downloaded) links show a placeholder tile.
///
/// Tapping a resolved thumbnail presents the full-size image as a full-screen cover.
struct PhotoGalleryView: View {

    // MARK: - Properties

    let photoLinks: [String]
    let entry: CatalogEntry

    // MARK: - State

    @State private var selectedItem: PhotoItem?

    // MARK: - Environment

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage

    // MARK: - Body

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photoLinks, id: \.self) { href in
                    let resourcesDir = storage.resourcesDirectory(for: entry)
                    let localURL = resourceCache.localURL(forHref: href, in: resourcesDir)
                    thumbnailTile(url: localURL)
                        .onTapGesture {
                            if let url = localURL {
                                selectedItem = PhotoItem(url: url)
                            }
                        }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 120)
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenPhotoView(url: item.url)
        }
    }

    // MARK: - Thumbnail tile

    @ViewBuilder
    private func thumbnailTile(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
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

// MARK: - FullScreenPhotoView

/// Full-screen cover that shows a single cached image with a dismiss button.
private struct FullScreenPhotoView: View {

    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    case .failure:
                        ContentUnavailableView(
                            "Image Unavailable",
                            systemImage: "photo.slash",
                            description: Text("This photo could not be loaded.")
                        )
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color.black)
            }
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .white.opacity(0.3))
                    }
                }
            }
        }
        .background(Color.black)
    }
}
