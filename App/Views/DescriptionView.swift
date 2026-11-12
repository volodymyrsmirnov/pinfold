import SwiftUI

/// Renders a KML description (untrusted HTML) as native blocks: paragraphs with bold, italic
/// and tappable allowlisted links, lists, tables and images. No web view is involved.
///
/// Images draw only when their `src` is already in the entry's local resource cache; nothing
/// is ever fetched while rendering.
struct DescriptionView: View {
    let html: String
    let entry: CatalogEntry

    @State private var blocks: [DescriptionBlocks.Block] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                DescriptionBlockView(block: block, entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: html) {
            blocks = await parseOffMain(html)
        }
    }
}

/// Parses off the main actor. A free function so the detached closure lives outside any view.
private nonisolated func parseOffMain(_ html: String) async -> [DescriptionBlocks.Block] {
    await Task.detached(priority: .userInitiated) {
        DescriptionBlocks.parse(html)
    }.value
}

// MARK: - Block rendering

private struct DescriptionBlockView: View {
    let block: DescriptionBlocks.Block
    let entry: CatalogEntry

    var body: some View {
        switch block {
        case let .paragraph(runs):
            Text(runs.attributed())
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .list(ordered, items):
            listView(ordered: ordered, items: items)
        case let .table(rows):
            tableView(rows)
        case let .image(src, alt):
            DescriptionImage(src: src, alt: alt, entry: entry)
        }
    }

    private func listView(ordered: Bool, items: [[DescriptionBlocks.Run]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(index + 1)." : "\u{2022}")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item.attributed())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func tableView(_ rows: [[[DescriptionBlocks.Run]]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(cell.attributed())
                            .font(row.count == 2 && column == 0 ? .subheadline.bold() : .subheadline)
                            .foregroundStyle(row.count == 2 && column == 0 ? .secondary : .primary)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An image that exists in the local resource cache; renders nothing (or the alt text) otherwise.
private struct DescriptionImage: View {
    let src: String
    let alt: String?
    let entry: CatalogEntry

    @Environment(\.resourceCache) private var resourceCache
    @Environment(\.storageLocations) private var storage

    var body: some View {
        if let url = resourceCache.localURL(forHref: src, in: storage.resourcesDirectory(for: entry)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit()
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            .accessibilityLabel(alt ?? "Image")
        } else if let alt {
            Text(alt)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
