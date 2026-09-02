import AppKit
import SwiftUI

/// macOS Tahoe's Liquid Glass, wrapped so every surface in the app asks for it the same way.
/// On macOS 26 this is the real `glassEffect`; on older systems it degrades to a material
/// with the same shape, so the layout never changes between the two.
extension View {

    /// A glass slab in the given shape. `tint` darkens or colours the glass; `interactive`
    /// lets it respond to hover and press like a control.
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive, clear: clear), in: shape)
        } else {
            self.background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(tint ?? .clear))
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
            .clipShape(shape)
        }
    }

    /// Convenience: rounded-rectangle glass.
    func liquidGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive)
    }

    /// Convenience: capsule glass, the shape of every Tahoe control.
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// Tahoe's glass button styles, with a bordered fallback.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// The window ground: the desktop blurred through, with a slow ambient colour field on
    /// top so the glass above has something to refract even over a flat wallpaper.
    func glassWindowBackground() -> some View {
        background(
            ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                AmbientMesh()
            }
            .ignoresSafeArea()
        )
    }
}

/// Six-point mesh in the accent's neighbourhood, drifting gently. Kept low-contrast so text
/// stays legible; it is atmosphere, not a picture.
struct AmbientMesh: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 14
            if #available(macOS 15.0, *) {
                MeshGradient(width: 3, height: 3, points: Self.points(at: t), colors: palette)
                    .opacity(scheme == .dark ? 0.55 : 0.35)
                    .blur(radius: 40)
            } else {
                LinearGradient(colors: [palette[1], palette[3], palette[5]], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.3)
            }
        }
        .allowsHitTesting(false)
    }

    private static func points(at t: Double) -> [SIMD2<Float>] {
        let dx = Float(sin(t)) * 0.12
        let dy = Float(cos(t * 0.8)) * 0.12
        return [
            SIMD2(0, 0), SIMD2(0.5 + dx * 0.5, 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + dy * 0.5), SIMD2(0.5 + dx, 0.5 + dy), SIMD2(1, 0.5 - dy * 0.5),
            SIMD2(0, 1), SIMD2(0.5 - dx * 0.5, 1), SIMD2(1, 1),
        ]
    }

    private var palette: [Color] {
        let dark = scheme == .dark
        let base: Color = dark ? .black : .white
        let accent: Color = Color.accentColor.opacity(0.35)
        let violet = Color(hue: 0.72, saturation: 0.5, brightness: dark ? 0.45 : 0.95).opacity(0.5)
        let teal = Color(hue: 0.52, saturation: 0.55, brightness: dark ? 0.4 : 0.9).opacity(0.5)
        return [base, accent, base, violet, base, teal, base, accent, base]
    }
}

extension View {
    @available(macOS 26.0, *)
    fileprivate static func glass(tint: Color?, interactive: Bool, clear: Bool) -> Glass {
        var glass = clear ? Glass.clear : Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Groups neighbouring glass shapes so they merge and morph together (macOS 26); a plain
/// group elsewhere.
struct LiquidGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}
