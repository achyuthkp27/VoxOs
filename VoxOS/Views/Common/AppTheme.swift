import SwiftUI

/// The app's palette for macOS Tahoe: system-adaptive text and semantic colours over
/// Liquid Glass surfaces. Nothing here is a fixed light or dark value — the glass reads
/// the wallpaper and appearance, and the text follows the system label colours.
enum AppTheme {
    enum Accent {
        static let primary = Color.accentColor
        static let fillSubtle = primary.opacity(0.10)
        static let fill = primary.opacity(0.16)
        static let fillStrong = primary.opacity(0.30)
        static let border = primary.opacity(0.40)
        static let disabled = primary.opacity(0.45)
        static let foreground = primary
        static let strong = primary
        static let shadow = primary.opacity(0.20)
        /// Soft wash behind selected rows.
        static let wash = primary.opacity(0.14)
        static let hover = primary.opacity(0.85)
    }

    /// Surfaces are glass; these tokens are only the tints laid over it.
    enum Surface {
        /// Opaque system ground for popovers, badges and other small floating surfaces. The
        /// main window itself is glass (`glassWindowBackground`) and never reads this.
        static let window = Color(nsColor: .windowBackgroundColor)
        static let card = Color.primary.opacity(0.04)
        static let materialCard = Color.primary.opacity(0.04)
        static let subtle = Color.primary.opacity(0.05)
        static let tinted = Color.accentColor.opacity(0.06)
        static let controlActive = Color.primary.opacity(0.10)
        static let control = Color.primary.opacity(0.06)
        static let sidePanelOverlay = Color.black.opacity(0.18)
        static let clear = Color.clear
    }

    enum Border {
        static let control = Color.primary.opacity(0.12)
        static let card = Color.primary.opacity(0.08)
        static let subtle = Color.primary.opacity(0.06)
        static let tint = Color.accentColor.opacity(0.35)
        static let sidePanelOuter = Color.white.opacity(0.14)
    }

    enum Selection {
        static let fill = Accent.wash
        static let border = Accent.primary.opacity(0.30)
        static let foreground = Accent.primary
    }

    enum Status {
        static let success = Color(nsColor: .systemGreen)
        static let positive = success
        static let info = Accent.primary
        static let infoStrong = Accent.primary
        static let warning = Color(nsColor: .systemOrange)
        static let warningStrong = warning
        static let error = Color(nsColor: .systemRed)
    }

    enum Data {
        static let transcript = Color(nsColor: .systemIndigo)
        static let audio = Color(nsColor: .systemTeal)
        static let enhancement = Color(nsColor: .systemMint)
        static let purple = Color(nsColor: .systemPurple)
        static let yellow = Color(nsColor: .systemYellow)
        static let orange = Color(nsColor: .systemOrange)
    }

    enum Sidebar {
        static let icon = Text.secondary
        static let dashboard = icon
        static let modes = icon
        static let models = icon
        static let audio = icon
        static let dictionary = icon
        static let transcribeAudio = icon
        static let fallback = icon
        static let license = icon
        static let ground = Color.clear
    }

    enum Waveform {
        static let hoverBubble = Color.primary.opacity(0.74)
        static let hoverMarker = Color.primary.opacity(0.68)
        static let playedLower = Accent.primary
        static let playedUpper = Accent.primary.opacity(0.80)
        static let unplayedLower = Color.primary.opacity(0.25)
        static let unplayedUpper = Color.primary.opacity(0.15)
    }

    enum Text {
        static let heading = Color(nsColor: .labelColor)
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Color(nsColor: .secondaryLabelColor)
        static let muted = Color(nsColor: .tertiaryLabelColor)
        static let disabled = Color(nsColor: .disabledControlTextColor)
        static let onAccent = Color.white
    }

    enum NativeText {
        static let primary = NSColor.labelColor
    }

    enum Action {
        static let primaryFill = Accent.primary
        static let primaryForeground = Text.onAccent
        static let secondaryForeground = Text.primary
        static let disabledFill = Surface.controlActive
        static let disabledForeground = Text.disabled
    }

    enum Radius {
        static let control: CGFloat = 14
        static let card: CGFloat = 22
        static let pill: CGFloat = 999
        static let keycap: CGFloat = 10
    }

    enum Shadow {
        static let card = Color.black.opacity(0.10)
        static let cardRadius: CGFloat = 10
        static let cardY: CGFloat = 4
    }

    /// The notch panel: dark glass rather than flat black, so what's behind blurs through.
    /// The notch panel is plain Liquid Glass — no black fill — so it reads as frosted glass
    /// over whatever is behind it and follows the system appearance.
    enum Notch {
        static let tint: Color? = nil
        static let bubble = Color.primary.opacity(0.08)
        static let field = Color.primary.opacity(0.06)
        static let fieldBorder = Color.primary.opacity(0.12)
        static let chip = Color.primary.opacity(0.14)
        static let text = Color.primary
        static let textMuted = Color.secondary
        static let rim = Color.primary.opacity(0.16)
        static let cornerRadius: CGFloat = 30
    }
}

// MARK: - Glass surfaces

extension View {
    /// A content card as a glass slab: Tahoe's replacement for the white card.
    func glassCard(radius: CGFloat = AppTheme.Radius.card, tint: Color? = nil) -> some View {
        self
            .liquidGlass(cornerRadius: radius, tint: tint)
            .shadow(color: AppTheme.Shadow.card, radius: AppTheme.Shadow.cardRadius, y: AppTheme.Shadow.cardY)
    }

    /// Kept for call sites that predate the glass pass.
    func voiceOSCard(radius: CGFloat = AppTheme.Radius.card, fill: Color = .clear) -> some View {
        glassCard(radius: radius)
    }

    func voiceOSPageBackground() -> some View {
        glassWindowBackground()
    }
}

/// Capsule glass button; prominent variant is accent-tinted.
struct VoiceOSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: compact ? 12.5 : 13.5, weight: .medium))
            .foregroundStyle(kind == .primary ? AppTheme.Text.onAccent : AppTheme.Text.primary)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(minHeight: compact ? 28 : 36)
            .liquidGlassCapsule(tint: kind == .primary ? AppTheme.Accent.primary : nil, interactive: true)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == VoiceOSButtonStyle {
    static var voiceOS: VoiceOSButtonStyle { VoiceOSButtonStyle() }
    static var voiceOSPrimary: VoiceOSButtonStyle { VoiceOSButtonStyle(kind: .primary) }
    static var voiceOSCompact: VoiceOSButtonStyle { VoiceOSButtonStyle(compact: true) }
}

/// Keycap rendered as a small glass tile.
struct VoiceOSKeycap: View {
    let symbol: String
    let label: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 2) {
            Text(symbol).font(.app(size: 15, weight: .medium))
            Text(label).font(.app(size: 10.5, weight: .medium))
            if let detail { Text(detail).font(.app(size: 8.5)).foregroundStyle(AppTheme.Text.muted) }
        }
        .foregroundStyle(AppTheme.Text.primary)
        .frame(width: 54, height: 54)
        .liquidGlass(cornerRadius: AppTheme.Radius.keycap)
    }
}
