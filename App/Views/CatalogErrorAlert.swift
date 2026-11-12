import SwiftUI

/// Presents `Catalog.actionError` as an alert and clears it on dismissal.
///
/// Self-contained: apply it once near the root with `.catalogErrorAlert(catalog)`.
struct CatalogErrorAlert: ViewModifier {
    @Bindable var catalog: Catalog

    func body(content: Content) -> some View {
        content.alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { catalog.actionError != nil },
                set: {
                    if !$0 {
                        catalog.actionError = nil
                    }
                }
            ),
            presenting: catalog.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}

extension View {
    /// Shows catalogue mutation failures (`Catalog.actionError`) as an alert.
    func catalogErrorAlert(_ catalog: Catalog) -> some View {
        modifier(CatalogErrorAlert(catalog: catalog))
    }
}
