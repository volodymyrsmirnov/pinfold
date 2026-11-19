import SwiftUI

/// The tile shown where a remote photo isn't on disk yet: a spinner while it downloads, a
/// "couldn't load" badge after a failed attempt, and a plain photo glyph otherwise.
struct RemoteImagePlaceholder: View {
    let status: RemoteImageStatus
    var size: CGFloat
    var cornerRadius: CGFloat
    var symbolSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            switch status {
            case .loading:
                ProgressView()
                    .controlSize(size < 60 ? .small : .regular)
            case .failed:
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.secondary)
            case .idle, .cached:
                Image(systemName: "photo")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        switch status {
        case .loading: Text("Downloading Photo")
        case .failed: Text("Couldn't Download Photo")
        case .idle, .cached: Text("Photo")
        }
    }
}
