import SwiftUI

/// A list row representing a single imported KML/KMZ file in the catalogue.
///
/// Shows a map SF Symbol in a rounded tile, the file's `displayName` as the primary
/// label, and a secondary line with the point count and formatted import date.
struct FileRow: View {
    let entry: CatalogEntry

    var body: some View {
        HStack(spacing: 12) {
            // Rounded tile icon
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "map")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !entry.tags.isEmpty {
                    Label(entry.tags.joined(separator: ", "), systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Private helpers

    private var secondaryLine: String {
        let dateStr = entry.importDate.formatted(date: .abbreviated, time: .omitted)
        // Explicit singular/plural branch rather than `^[…](inflect: true)`: the automatic
        // grammar-agreement markup is only guaranteed to render once verified on every
        // destination (final review flagged it showing literally on the Mac "Designed for
        // iPad" build), and the project ships no string catalog. Same pattern as the
        // import-failure banner.
        let points = entry.pointCount == 1
            ? String(localized: "1 point")
            : String(localized: "\(entry.pointCount) points")
        return "\(points) · \(dateStr)"
    }
}
