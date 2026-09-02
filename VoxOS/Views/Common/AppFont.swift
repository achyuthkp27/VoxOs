import AppKit
import SwiftUI

/// One place for the app typeface. Tahoe's look is San Francisco, so this resolves to the
/// system font; every view calls `Font.app(...)` so a typeface change is a one-line edit.
enum AppFont {
    static func metrics(for style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: return (26, .regular)
        case .title: return (22, .regular)
        case .title2: return (17, .regular)
        case .title3: return (15, .regular)
        case .headline: return (13, .semibold)
        case .subheadline: return (11, .regular)
        case .body: return (13, .regular)
        case .callout: return (12, .regular)
        case .footnote: return (10, .regular)
        case .caption: return (10, .regular)
        case .caption2: return (10, .medium)
        @unknown default: return (13, .regular)
        }
    }

    static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func app(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        weight.map { .system(style, weight: $0) } ?? .system(style)
    }
}
