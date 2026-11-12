import SwiftUI

/// A small sheet for writing or editing one personal note.
///
/// Pure UI: it hands the edited text back through `onSave`, which returns whether the note was
/// really persisted (blank text means "delete the note"). On failure the sheet stays open with
/// the draft and shows an alert; swipe-to-dismiss is blocked while the draft is unsaved.
struct NoteEditorSheet: View {
    let title: String
    let onSave: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saveFailed = false
    private let initialText: String
    @FocusState private var focused: Bool

    init(title: String, initialText: String, onSave: @escaping (String) -> Bool) {
        self.title = title
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                    }
                }
                .onAppear { focused = true }
                .alert("Couldn't Save Note", isPresented: $saveFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Your note was not saved. It is still here; try again, or copy the text first.")
                }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(text != initialText)
    }

    private func save() {
        if onSave(text) {
            dismiss()
        } else {
            saveFailed = true
        }
    }
}
