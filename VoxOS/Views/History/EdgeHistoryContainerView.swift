import SwiftUI

/// Hosts the two states of the left-edge history affordance: a slim notch handle,
/// and the compact history card it expands into when clicked.
struct EdgeHistoryContainerView: View {
    @ObservedObject var presentation: EdgeHistoryPresentation
    let onNotchTap: () -> Void
    let onSelectTranscription: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if presentation.isExpanded {
                EdgeHistorySidebarView(
                    onSelectTranscription: onSelectTranscription,
                    isPinned: $presentation.isPinned
                )
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                EdgeHistoryNotchHandle(onTap: onNotchTap)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The slim, vertically-centred handle that peeks out of the left edge on hover.
private struct EdgeHistoryNotchHandle: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.black.opacity(isHovering ? 0.92 : 0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovering ? 0.22 : 0.10), lineWidth: 0.5)
            )
            .frame(width: isHovering ? 7 : 5)
            .frame(maxHeight: .infinity)
            .padding(.vertical, isHovering ? 0 : 12)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
            .onTapGesture(perform: onTap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Show transcription history")
            .accessibilityAddTraits(.isButton)
    }
}
