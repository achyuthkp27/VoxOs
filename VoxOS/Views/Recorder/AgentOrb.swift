import SwiftUI

/// The composer's measurements: a 19 pt pill one line tall, so it is concentric with the
/// expanded band's 31 pt bottom corner when inset by 12 pt.
enum AgentComposer {
    static let radius: CGFloat = 19
    static let minHeight: CGFloat = 38
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// Height of the reply panel for a given height of its messages: enough for the composer and
    /// one short answer at least, never more than the band should hang down.
    static let panelMinHeight: CGFloat = 150
    static let panelMaxHeight: CGFloat = 300
    /// Top padding, the gap above the composer, the composer, and the bottom inset.
    static let panelChrome: CGFloat = 8 + 14 + minHeight + 12

    static func panelHeight(forContent contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight + panelChrome, panelMinHeight), panelMaxHeight)
    }
}

/// The measured height of the reply panel's messages, reported up so the band can fit them.
struct AssistantContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The Agent's presence in the panel: an 18 pt orb in the Agent's violet that breathes while it
/// is thinking and rests when it is listening for the next request.
struct AgentOrb: View {
    let isActive: Bool
    static let size: CGFloat = 18
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Recorder.agentAccent.opacity(0.35))
                .frame(width: Self.size * 1.7, height: Self.size * 1.7)
                .blur(radius: 6)
                .opacity(isActive ? 1 : 0.5)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95), AppTheme.Recorder.agentAccent,
                            AppTheme.Recorder.agentAccent.opacity(0.7),
                        ],
                        center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: Self.size * 0.6)
                )
                .frame(width: Self.size, height: Self.size)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .scaleEffect(isActive && breathe && !reduceMotion ? 1.12 : 1)
        .animation(
            isActive && !reduceMotion
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.25),
            value: breathe
        )
        .onAppear { breathe = true }
        .onChange(of: isActive) { _, active in breathe = active || breathe }
        .frame(width: Self.size * 1.7, height: Self.size * 1.7)
        .accessibilityHidden(true)
    }
}
