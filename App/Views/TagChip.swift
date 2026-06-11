import SwiftUI

// MARK: - TagChip

/// A single pill-shaped filter chip in the catalogue's tag bar. Selected chips fill with the
/// accent colour; unselected ones use a subtle fill. Kept in its own small `View` so the chip's
/// styling doesn't bloat `HomeView`'s body (which is sensitive to SwiftUI type-check cost).
struct TagChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
