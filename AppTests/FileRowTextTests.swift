import Foundation
@testable import Pinfold
import Testing

/// The catalogue row's second line (`FileRow.secondaryLine`), including the online-list variants.
@MainActor struct FileRowTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(points: Int = 3, importDate: Date) -> CatalogEntry {
        CatalogEntry(
            id: UUID(), displayName: "Trail", sourceFilename: "trail.kml",
            importDate: importDate, pointCount: points, contentSHA256: "x",
            storageFolderName: "trail"
        )
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    @Test func secondaryLine_idle_showsUpdated() {
        let checked = now.addingTimeInterval(-7200)
        let line = FileRow.secondaryLine(
            entry: entry(importDate: now.addingTimeInterval(-86400 * 30)),
            online: .idle(lastSuccess: checked), now: now
        )
        #expect(line == "3 points · Updated \(relative(checked))")
    }

    @Test func secondaryLine_neverChecked_showsImportDate() {
        let imported = now.addingTimeInterval(-86400 * 3)
        let line = FileRow.secondaryLine(
            entry: entry(importDate: imported), online: .idle(lastSuccess: nil), now: now
        )
        #expect(line == "3 points · Updated \(relative(imported))")
    }

    @Test func secondaryLine_failed_showsCouldntUpdate() {
        let line = FileRow.secondaryLine(
            entry: entry(points: 1, importDate: now), online: .failed, now: now
        )
        #expect(line == "1 point · Couldn't update")
    }

    @Test func secondaryLine_refreshing_showsUpdating() {
        let line = FileRow.secondaryLine(entry: entry(importDate: now), online: .refreshing, now: now)
        #expect(line == "3 points · Updating\u{2026}")
    }

    @Test func secondaryLine_offlineList_unchanged() {
        let imported = now.addingTimeInterval(-86400 * 3)
        let line = FileRow.secondaryLine(entry: entry(importDate: imported), online: nil, now: now)
        #expect(line == "3 points · \(imported.formatted(date: .abbreviated, time: .omitted))")
    }
}
