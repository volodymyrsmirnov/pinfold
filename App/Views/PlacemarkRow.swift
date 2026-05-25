import PinfoldCore
import SwiftUI

// MARK: - PlacemarkRow

/// A compact list row that represents a single `KMLPlacemark`.
///
/// Layout:
/// - Leading: a `StyleIcon` tile showing the placemark's resolved style icon (cached
///   image when available, otherwise a tinted "mappin" fallback).
/// - Center: the placemark name and a one-line description preview (plain text).
/// - Trailing: a photo thumbnail if at least one cached image is available.
///
/// `AttributedHTML.plainText` is used for the preview — it is safe to call in a list
/// body because it performs only regex-based tag stripping (never HTML parsing).
struct PlacemarkRow: View {
    // MARK: - Properties

    let placemark: KMLPlacemark
    let document: KMLDocument
    let entry: CatalogEntry

    // MARK: - Environment

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage
    @Environment(PlacemarkAnnotations.self) private var annotations: PlacemarkAnnotations?

    // MARK: - Annotation state

    private var isFavorite: Bool { annotations?.isFavorite(placemark) ?? false }
    private var isVisited: Bool { annotations?.isVisited(placemark) ?? false }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            StyleIcon(placemark: placemark, document: document, entry: entry, size: 36)
            labelStack
            Spacer(minLength: 0)
            thumbnailView
        }
        .padding(.vertical, 2)
    }

    // MARK: - Label stack

    private var labelStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
                Text(placemark.name ?? "Untitled")
                    .font(.body)
                    .strikethrough(isVisited)
                    .foregroundStyle(isVisited ? .secondary : .primary)
                    .lineLimit(1)
            }
            if let html = placemark.descriptionHTML, !html.isEmpty {
                let preview = AttributedHTML.plainText(html).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Photo thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let firstLink = placemark.photoLinks.first {
            let resourcesDir = storage.resourcesDirectory(for: entry)
            if let localURL = resourceCache.localURL(forHref: firstLink, in: resourcesDir) {
                AsyncImage(url: localURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    default:
                        photoPlaceholder
                    }
                }
                .frame(width: 44, height: 44)
            } else {
                photoPlaceholder
            }
        }
    }

    private var photoPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 44, height: 44)
            Image(systemName: "photo")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }
}
