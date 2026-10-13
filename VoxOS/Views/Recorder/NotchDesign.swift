import SwiftUI

/// The notch's measurements, material and motion in one place.
///
/// These follow the proportions of a premium dictation notch: a flat black band that grows out of
/// the physical notch with scooped shoulders, three silhouettes (resting, listening, expanded)
/// whose corners grow with the surface, and one soft glass material instead of a hard black pill.
/// Everything here is drawn in SwiftUI; no artwork or code is borrowed.
enum NotchDesign {

    // MARK: Silhouettes

    /// Shoulder (the scoop where the band meets the screen edge) and bottom corner radius per state.
    /// Corners grow with the surface so a bigger panel never looks like a small pill scaled up.
    struct Radii: Equatable {
        let shoulder: CGFloat
        let bottom: CGFloat
    }

    static let resting = Radii(shoulder: 10, bottom: 11)
    static let listening = Radii(shoulder: 14, bottom: 17)
    /// The expanded bottom corner is concentric with the 19 pt composer pill inside a 12 pt inset
    /// (19 + 12), which is what makes the inner field and the outer edge look like one shape.
    static let expanded = Radii(shoulder: 18, bottom: 31)

    // MARK: Sizes

    /// Total width of the expanded panel. Its content is inset by AgentComposer.panelInset per side.
    static let expandedWidth: CGFloat = 480
    /// Gap between the straight side of the band and the first piece of content.
    static let contentInset: CGFloat = 12

    /// Height of the band's top row on a display without a notch: the status bar's thickness.
    /// The view and the panel both read it here, so the band and its window always agree.
    @MainActor static var fallbackNotchHeight: CGFloat { NSStatusBar.system.thickness }

    // MARK: Window

    /// The notch panel's window is sized once for the largest band it can hold, plus room for the
    /// band's shadow, so the band is never clipped while it grows. No state widens the band by more
    /// than half the expanded width on either side of the notch.
    static var windowSideExpansion: CGFloat { expandedWidth / 2 }
    /// Room beside the widest band for its shadow.
    static var windowSideMargin: CGFloat { activeShadow.radius }

    /// The tallest band is the notch row plus the reply panel at its cap; below it, its shadow.
    static func windowHeight(notchHeight: CGFloat) -> CGFloat {
        notchHeight + AgentComposer.panelMaxHeight + activeShadow.radius * 2 + activeShadow.y
    }

    // MARK: Material

    /// Liquid Glass is the default. Solid black is the quiet alternative.
    enum Material: String, CaseIterable, Identifiable {
        case liquidGlass
        case solidBlack

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .liquidGlass: return String(localized: "Liquid Glass")
            case .solidBlack: return String(localized: "Solid Black")
            }
        }

        static func resolve(_ raw: String?) -> Material { raw.flatMap(Material.init(rawValue:)) ?? .liquidGlass }
    }

    /// How far down the band stays solid black before the glass takes over. The top has to read
    /// as part of the physical notch, so the glass only shows below it.
    static let glassDarkStop: CGFloat = 0.48
    /// Behind the glass, so the band stays readable even over a bright wallpaper.
    static let glassUnderlay = Color.black.opacity(0.6)

    /// Almost opaque, with the faintest blue so it reads as black glass rather than a flat fill.
    static let solid = Color(red: 0, green: 0, blue: 2 / 255, opacity: 0.98)
    static let glassTint = Color(red: 0, green: 0, blue: 5 / 255, opacity: 0.18)
    /// A one-point cool edge that lifts the active surface off a dark wallpaper.
    static let rim = Color(red: 235 / 255, green: 245 / 255, blue: 1, opacity: 0.22)
    static let rimWidth: CGFloat = 0.9

    struct Shadow {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }
    static let restingShadow = Shadow(opacity: 0.25, radius: 3, y: 2)
    static let activeShadow = Shadow(opacity: 0.30, radius: 10, y: 8)

    // MARK: Motion

    /// Growing and shrinking between states: one calm ease for size, a quicker, snappier curve to
    /// open and a short one to close, so opening feels responsive and closing stays out of the way.
    static let sizeAnimation = Animation.timingCurve(0.45, 0, 0.55, 1, duration: 0.34)
    static let openAnimation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    static let closeAnimation = Animation.timingCurve(0.45, 0, 0.55, 1, duration: closeDuration)
    /// How long closeAnimation runs; the recorder waits this long before it orders the window out.
    static let closeDuration: TimeInterval = 0.20

    // MARK: Waveform

    /// Five bars, tallest in the middle. Heights are 7 pt plus up to 10 pt scaled by the bar's
    /// weight, which keeps the quietest frame readable and the loudest one inside the band.
    static let barWeights: [CGFloat] = [0.8, 1.1, 1.4, 1.1, 0.8]
    static let barMinHeight: CGFloat = 7
    static let barRange: CGFloat = 10
    static let barWidth: CGFloat = 3.5
    static let barSpacing: CGFloat = 3.5

    static func barHeight(at index: Int) -> CGFloat {
        guard barWeights.indices.contains(index), let maxWeight = barWeights.max() else { return barMinHeight }
        let height = barMinHeight + barRange * (barWeights[index] / maxWeight) * 0.92
        return (height * 10).rounded() / 10
    }

    static var waveformWidth: CGFloat {
        CGFloat(barWeights.count) * barWidth + CGFloat(barWeights.count - 1) * barSpacing
    }
}
