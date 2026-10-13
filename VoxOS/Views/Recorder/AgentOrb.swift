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

    /// Space above the messages, under the band's top row.
    static let panelTopInset: CGFloat = 8
    /// Gap between the messages and the composer.
    static let panelSpacing: CGFloat = 14
    /// Space under the composer. The shoulders only pull in the band's sides; its bottom edge is
    /// the frame's own (NotchShape draws it at rect.maxY), so the bottom takes the 12 pt that makes
    /// the composer concentric with the bottom corner, not the side inset.
    static var panelBottomInset: CGFloat { NotchDesign.expanded.bottom - radius }

    static let panelMinHeight: CGFloat = 150
    static let panelMaxHeight: CGFloat = 300
    /// Top padding, the gap above the composer, the composer, and the bottom inset. Derived from
    /// the same constants AssistantPanelLayout pads with, so the two cannot drift apart.
    static var panelChrome: CGFloat { panelTopInset + panelSpacing + minHeight + panelBottomInset }

    static func panelHeight(forContent contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight + panelChrome, panelMinHeight), panelMaxHeight)
    }
}

/// The composer's capsule: its padding, one-line height, fill and border. The content is clipped
/// to the capsule so the orb's glow stays inside the border instead of spilling across it.
struct AgentComposerChrome: ViewModifier {
    /// The composer is held to one line even without the orb, which is what panelChrome counts.
    /// Tests pass nil to measure the composer's own height without that clamp.
    var minHeight: CGFloat? = AgentComposer.minHeight

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, AgentComposer.verticalPadding)
            .frame(minHeight: minHeight)
            .clipShape(AgentComposer.shape)
            .background(AgentComposer.shape.fill(AppTheme.Notch.field))
            .overlay(
                AgentComposer.shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.22), AppTheme.Notch.fieldBorder], startPoint: .top,
                        endPoint: .bottom), lineWidth: 1))
    }
}

/// The reply panel's layout: messages above the composer, inset from the band's frame. Kept
/// apart from AssistantPanelView so its measurements can be laid out and checked on their own.
struct AssistantPanelLayout<Messages: View, Composer: View>: View {
    let messages: Messages
    let composer: Composer

    init(@ViewBuilder messages: () -> Messages, @ViewBuilder composer: () -> Composer) {
        self.messages = messages()
        self.composer = composer()
    }

    var body: some View {
        VStack(spacing: AgentComposer.panelSpacing) {
            messages
            composer
        }
        // Measured from the band's frame, which is wider than its body by the shoulders: see
        // AgentComposer.panelInset. The bottom has no shoulder: see AgentComposer.panelBottomInset.
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.top, AgentComposer.panelTopInset)
        .padding(.bottom, AgentComposer.panelBottomInset)
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
