import AppKit
import SwiftUI

/// One place for the app typeface. Tahoe's look is San Francisco, so this resolves to the
/// system font; every view calls `Font.app(...)` so a typeface change is a one-line edit.
enum AppFont {
}

extension Font {
    static func app(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func app(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        weight.map { .system(style, weight: $0) } ?? .system(style)
    }

    /// Page titles and the few display moments: Apple's serif (New York), used with restraint
    /// so the app reads as edited rather than templated.
    static func appDisplay(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Eyebrows, labels, shortcuts and figures: the machine voice next to the serif.
    static func appMono(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
