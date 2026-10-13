import SwiftUI

/// The composer's measurements: a 19 pt pill one line tall, so it is concentric with the
/// expanded band's 31 pt bottom corner when inset by 12 pt.
enum AgentComposer {
    static let radius: CGFloat = 19
    /// One line tall: a full capsule at the composer's radius. The orb's box is derived from this
    /// (see AgentOrb.frameSize), so the composer never grows past it and panelChrome stays true.
    static let minHeight: CGFloat = radius * 2
    /// Space above and below the orb and the text inside the composer.
    static let verticalPadding: CGFloat = 4
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// Height of the reply panel for a given height of its messages: enough for the composer and
    /// one short answer at least, never more than the band should hang down.
    /// Inset of the panel's content from the band's frame. The band's scooped shoulders pull its
    /// sides in by the shoulder radius, so the body edge is that far inside the frame; the
    /// composer then sits 12 pt inside the body, concentric with the 31 pt bottom corner.
    static var panelInset: CGFloat { NotchDesign.expanded.shoulder + (NotchDesign.expanded.bottom - radius) }

    static let panelMinHeight: CGFloat = 150
    static let panelMaxHeight: CGFloat = 300
    /// Top padding, the gap above the composer, the composer, and the bottom inset.
    static let panelChrome: CGFloat = 8 + 14 + minHeight + 12

    static func panelHeight(forContent contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight + panelChrome, panelMinHeight), panelMaxHeight)
    }
}

/// The composer's capsule: its padding, one-line height, fill and border. The content is clipped
/// to the capsule so the orb's glow stays inside the border instead of spilling across it.
struct AgentComposerChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, AgentComposer.verticalPadding)
            .frame(minHeight: AgentComposer.minHeight)
            .clipShape(AgentComposer.shape)
            .background(AgentComposer.shape.fill(AppTheme.Notch.field))
            .overlay(
                AgentComposer.shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.22), AppTheme.Notch.fieldBorder], startPoint: .top,
                        endPoint: .bottom), lineWidth: 1))
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
    var color: Color = AppTheme.Recorder.agentAccent
    static let size: CGFloat = 18
    /// The orb's layout box, glow included: exactly the composer's one-line height minus its
    /// vertical padding, so the orb can never make the composer taller than panelChrome assumes.
    static var frameSize: CGFloat { AgentComposer.minHeight - 2 * AgentComposer.verticalPadding }
    /// Mirrors isActive. It is set on appear as well as on change, because an orb that appears
    /// already active would otherwise never see a change to animate.
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: Self.size * 1.7, height: Self.size * 1.7)
                .blur(radius: 6)
                .opacity(isActive ? 1 : 0.5)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95), color,
                            color.opacity(0.7),
                        ],
                        center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: Self.size * 0.6)
                )
                .frame(width: Self.size, height: Self.size)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .scaleEffect(breathe && !reduceMotion ? 1.12 : 1)
        // Keyed to the active state itself: the old flag latched on and never turned off again,
        // so the orb breathed once and then stood still. A new value with a plain ease replaces
        // the repeating animation, which is what stops the breathing when the reply arrives.
        .animation(
            breathe && !reduceMotion
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.25),
            value: breathe
        )
        .onAppear { breathe = isActive }
        .onChange(of: isActive) { _, active in breathe = active }
        .frame(width: Self.frameSize, height: Self.frameSize)
        .accessibilityHidden(true)
    }
}
