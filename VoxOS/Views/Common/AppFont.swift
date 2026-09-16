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
}
