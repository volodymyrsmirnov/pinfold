import SwiftUI

/// A list row representing a single imported KML/KMZ file in the catalogue.
///
/// Shows a map SF Symbol in a rounded tile, the file's `displayName` as the primary
/// label, and a secondary line with the point count and formatted import date.
struct FileRow: View {
    let entry: CatalogEntry
    /// The online-list status, or `nil` for a normal list (and for trashed rows).
    var online: OnlineStatus?

    /// What an online list's row shows: its glyph and the second line's tail.
    enum OnlineStatus: Equatable {
        case idle(lastSuccess: Date?)
        case refreshing
        case failed
    }

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

                secondaryLineView

                if entry.isReadOnly {
                    Label(readOnlyBadge, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                if !entry.tags.isEmpty {
                    Label(entry.tags.joined(separator: ", "), systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            if let online {
                Spacer(minLength: 0)
                onlineGlyph(online)
            }
        }
        .padding(.vertical, 2)
    }

    /// Only an idle online list shows a relative time ("Updated 20s ago"); that row is
    /// re-evaluated each minute so it keeps ticking, every other row is a plain view.
    @ViewBuilder
    private var secondaryLineView: some View {
        if case .idle = online {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                secondaryText(now: context.date)
            }
        } else {
            secondaryText(now: .now)
        }
    }

    private func secondaryText(now: Date) -> some View {
        Text(Self.secondaryLine(entry: entry, online: online, now: now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func onlineGlyph(_ status: OnlineStatus) -> some View {
        switch status {
        case .idle:
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .accessibilityLabel("Online list")
        case .refreshing:
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .accessibilityLabel("Updating")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .accessibilityLabel("Couldn't update")
        }
    }

    // MARK: - Private helpers

    /// The online glyph's square, shared by the globe, warning and spinner so they match.
    private static let glyphSize: CGFloat = 20

    private var readOnlyBadge: String {
        entry.sidecarState == .notDownloaded ? "Downloading from iCloud" : "Saved data unreadable"
    }

    /// `N points · ⟨tail⟩`: the import date for a normal list; for an online list the last
    /// successful update (falling back to the import date before the first check), "Updating…"
    /// while a refresh runs, or "Couldn't update" after a failure. Pure, so it is tested directly.
    static func secondaryLine(entry: CatalogEntry, online: OnlineStatus?, now: Date) -> String {
        // Explicit singular/plural branch rather than `^[…](inflect: true)`: the automatic
        // grammar-agreement markup is only guaranteed to render once verified on every
        // destination (final review flagged it showing literally on the Mac "Designed for
        // iPad" build), and the project ships no string catalog. Same pattern as the
        // import-failure banner.
        let points = entry.pointCount == 1
            ? String(localized: "1 point")
            : String(localized: "\(entry.pointCount) points")
        switch online {
        case nil:
            let dateStr = entry.importDate.formatted(date: .abbreviated, time: .omitted)
            return "\(points) · \(dateStr)"
        case let .idle(lastSuccess):
            let when = relative(lastSuccess ?? entry.importDate, to: now)
            return "\(points) · " + String(localized: "Updated \(when)")
        case .refreshing:
            return "\(points) · " + String(localized: "Updating\u{2026}")
        case .failed:
            return "\(points) · " + String(localized: "Couldn't update")
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static func relative(_ date: Date, to now: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
