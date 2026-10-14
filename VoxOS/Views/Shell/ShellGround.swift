import SwiftUI

/// The window ground: the desktop blurred through a dark veil, with one soft violet glow behind
/// the content. Set once in the shell; pages never add their own glows. In light mode the veil
/// lifts and the glow drops to a faint wash so text keeps its contrast.
struct ShellGround: View {
    @Environment(\.colorScheme) private var scheme

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height)
            ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                Self.veil(isDark: isDark)
                RadialGradient(
                    colors: [AppTheme.Accent.brand.opacity(isDark ? 0.30 : 0.10), .clear],
                    center: UnitPoint(x: 0.62, y: 0.12),
                    startRadius: 0,
                    endRadius: reach * 0.70
                )
                RadialGradient(
                    colors: [AppTheme.Accent.brand.opacity(isDark ? 0.14 : 0.05), .clear],
                    center: UnitPoint(x: 0.05, y: 1.0),
                    startRadius: 0,
                    endRadius: reach * 0.45
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Deep violet-black in dark mode so the window reads dark over any wallpaper.
    static func veil(isDark: Bool) -> Color {
        isDark ? Color(red: 0.05, green: 0.04, blue: 0.09).opacity(0.72) : Color.white.opacity(0.35)
    }
}
