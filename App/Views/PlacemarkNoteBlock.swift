import PinfoldCore
import SwiftUI

/// The "My Notes" block on the placemark page: shows the saved note (or an add button) and
/// presents `NoteEditorSheet`. Saving reloads the catalogue so cross-file search sees it.
struct PlacemarkNoteBlock: View {
    let placemark: KMLPlacemark
    let annotations: PlacemarkAnnotations
    let catalog: Catalog?

    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My Notes")
                .font(.subheadline.bold())
            if let note = annotations.note(for: placemark) {
                Text(note.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(hasNote ? "Edit Note" : "Add Note", systemImage: "square.and.pencil") {
                editing = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .sheet(isPresented: $editing) {
            NoteEditorSheet(
                title: "My Notes",
                initialText: annotations.note(for: placemark)?.text ?? "",
                onSave: save
            )
        }
    }

    private var hasNote: Bool {
        annotations.note(for: placemark) != nil
    }

    private func save(_ text: String) {
        annotations.setNote(text, for: placemark)
        guard let catalog else { return }
        Task { await catalog.reload() }
    }
}
