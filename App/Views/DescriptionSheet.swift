import SwiftUI

/// What a description sheet shows: a folder's or the document's own description.
struct DescriptionSheetContent: Identifiable {
    let id: String
    let title: String
    let html: String
}

/// A sheet presenting one full description through `DescriptionView`.
struct DescriptionSheet: View {
    let content: DescriptionSheetContent
    let entry: CatalogEntry

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DescriptionView(html: content.html, entry: entry)
                    .padding()
            }
            .navigationTitle(content.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
