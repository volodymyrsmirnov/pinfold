import SwiftUI

/// Notes whose placemark no longer exists in the file (for example after the KML was edited
/// and re-imported). Self-contained: it takes the orphaned notes as input and offers a copy
/// action, so the text is never silently lost.
struct OrphanedNotesSection: View {
    let notes: [(key: String, note: PlacemarkNote)]

    var body: some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes, id: \.key) { item in
                    OrphanedNoteRow(note: item.note)
                }
            } header: {
                Text("Notes for removed placemarks")
            } footer: {
                Text("These placemarks are no longer in this file. Your notes are kept.")
            }
        }
    }
}

private struct OrphanedNoteRow: View {
    let note: PlacemarkNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.placemarkName ?? "Unnamed placemark")
                .font(.subheadline.bold())
            Text(note.text)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                UIPasteboard.general.string = note.text
            } label: {
                Label("Copy Note", systemImage: "doc.on.doc")
            }
        }
    }
}
