import SwiftUI

/// A list row representing a single imported file in the catalogue.
///
/// Leading: a rounded tile whose glyph says where the list comes from — a document for a file
/// imported from the device, a globe for an online list that refreshes from its URL. Then the
/// file's `displayName` and a secondary line with the point count and the import date (or, for
/// an online list, when it last updated). Trailing: a spinner while an online list refreshes,
/// and a chevron when tapping the row pushes the file (`showsDisclosure`).
struct FileRow: View {
    let entry: CatalogEntry
    /// The online-list status, or `nil` for a normal list (and for trashed rows).
    var online: OnlineStatus?
    /// Whether to draw the trailing chevron: on when the row navigates to a new screen
    /// (a collapsed split view), off in select mode, in Trash, and beside an open detail column.
    var showsDisclosure = false
    /// Whether the row is the selected one beside an open file (iPad, Mac). Its tile then turns
    /// solid accent with a white glyph, which reads on both selection highlights: the accent one
    /// (list focused), where the tinted tile's blue glyph would vanish, and the grey one.
    var isHighlighted = false

    /// What an online list's row shows: its glyph and the second line's tail.
    enum OnlineStatus: Equatable {
        case idle(lastSuccess: Date?)
        case refreshing
        case failed
    }

    var body: some View {
        HStack(spacing: 12) {
            sourceTile

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
            }
            Spacer(minLength: 0)
            if online == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating")
            }
            if showsDisclosure {
                RowDisclosureIndicator()
            }
        }
        .padding(.vertical, 2)
    }

    /// The leading tile: a document for an imported file, a globe for an online list.
    private var sourceTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? Color.accentColor : Color.accentColor.opacity(0.15))
                .frame(width: 44, height: 44)
            Image(systemName: entry.isOnline ? "globe" : "doc")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
        }
        .accessibilityElement()
        .accessibilityLabel(entry.isOnline ? "Online list" : "File")
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

    /// A failed update is called out in orange so it reads at a glance without a glyph.
    private func secondaryText(now: Date) -> some View {
        Text(Self.secondaryLine(entry: entry, online: online, now: now))
            .font(.caption)
            .foregroundStyle(online == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }

    // MARK: - Private helpers

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

// MARK: - RowDisclosureIndicator

/// The trailing chevron of a row that pushes a new screen, drawn like a `NavigationLink`'s.
/// `List(selection:)` rows navigate through the split view and so get no chevron of their own.
struct RowDisclosureIndicator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - Catalogue list style

extension View {
    /// The style of the catalogue's lists (Files, Trash, select mode, search results): inset
    /// cards when rows push a new screen (iPhone, narrow windows), and a plain list beside an
    /// open file (iPad, Mac), where the selected row is a full-width highlight as in Mail's
    /// message list rather than a card whose first row picks up the card's rounded corners.
    func catalogueListStyle() -> some View {
        modifier(CatalogueListStyle())
    }
}

private struct CatalogueListStyle: ViewModifier {
    @Environment(\.showsRowDisclosure) private var showsRowDisclosure

    func body(content: Content) -> some View {
        if showsRowDisclosure {
            content.listStyle(.insetGrouped)
        } else {
            content.listStyle(.plain)
        }
    }
}
