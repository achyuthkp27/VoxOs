import AppKit
import SwiftUI

/// Shown once per launch over the main window: a white beam of voice enters the app icon and
/// leaves as the mode spectrum, then the app fades in. Purely visual: launch work never waits on
/// it, and a click dismisses it early.
struct LaunchSplash: View {
    /// Once per process, so reopening the window later does not replay it.
    @MainActor private static var hasPlayed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var isPresented: Bool
    @State private var beamProgress: CGFloat = 0
    @State private var bandProgress: CGFloat = 0
    @State private var opacity: Double = 1

    init() {
        _isPresented = State(initialValue: !Self.hasPlayed && !ProcessIdentity.isTestHost)
    }

    var body: some View {
        if isPresented {
            GeometryReader { proxy in
                splash(in: proxy.size)
            }
            .ignoresSafeArea()
            .opacity(opacity)
            .contentShape(Rectangle())
            .onTapGesture {
                Self.hasPlayed = true
                isPresented = false
            }
            .task { await play() }
            .accessibilityHidden(true)
        }
    }

    private func splash(in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let glyphSize: CGFloat = 76
        let entry = CGPoint(x: center.x - glyphSize * 0.32, y: center.y)
        let exit = CGPoint(x: center.x + glyphSize * 0.32, y: center.y)
        let bands = AppTheme.Spectrum.bands
        let fan = size.height * 0.34

        return ZStack {
            AppTheme.Surface.window
            ShellGround.veil(isDark: scheme == .dark)
            RadialGradient(
                colors: [AppTheme.Accent.brand.opacity(scheme == .dark ? 0.28 : 0.10), .clear],
                center: .center,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.5
            )

            BeamSegment(from: CGPoint(x: 0, y: center.y + size.height * 0.10), to: entry)
                .trim(from: 0, to: beamProgress)
                .stroke(beamColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))

            ForEach(bands.indices, id: \.self) { index in
                let spread = bands.count > 1 ? CGFloat(index) / CGFloat(bands.count - 1) - 0.5 : 0
                BeamSegment(from: exit, to: CGPoint(x: size.width, y: center.y + spread * fan))
                    .trim(from: 0, to: bandProgress)
                    .stroke(bands[index], style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
                .position(center)
        }
    }

    private var beamColor: Color {
        scheme == .dark ? AppTheme.Spectrum.beam : AppTheme.Text.primary
    }

    private func play() async {
        Self.hasPlayed = true
        if reduceMotion {
            beamProgress = 1
            bandProgress = 1
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            try? await Task.sleep(for: .milliseconds(300))
        } else {
            withAnimation(.easeIn(duration: 0.35)) { beamProgress = 1 }
            try? await Task.sleep(for: .milliseconds(330))
            withAnimation(.easeOut(duration: 0.45)) { bandProgress = 1 }
            try? await Task.sleep(for: .milliseconds(580))
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            try? await Task.sleep(for: .milliseconds(300))
        }
        isPresented = false
    }
}

/// One straight ray, so `trim` can draw it in from its start.
private struct BeamSegment: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}
