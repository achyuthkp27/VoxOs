import AppKit
import SwiftUI

/// What moves the prompter on.
enum PrompterFollow: String, CaseIterable {
    /// The words read aloud, matched by on-device speech recognition.
    case words
    /// A steady pace in words per minute, optionally only while the microphone hears speaking.
    /// Needs no speech recognition, so it works in any language.
    case pace

    static var current: PrompterFollow {
        PrompterFollow(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.prompterFollow) ?? "") ?? .words
    }
}

/// Turns elapsed time into whole words at a steady pace, keeping the fraction for the next step.
struct PrompterPacer {
    private(set) var carry: Double = 0

    /// Whole words to move on after `seconds` at `wordsPerMinute`.
    mutating func step(seconds: Double, wordsPerMinute: Double) -> Int {
        guard seconds > 0, wordsPerMinute > 0 else { return 0 }
        carry += seconds * wordsPerMinute / 60
        // A hair over, so steps that add up to a whole word (0.1 twenty times) give one.
        let words = Int(carry + 1e-9)
        carry -= Double(words)
        return words
    }

    mutating func reset() { carry = 0 }
}

/// Whether someone is speaking, from the microphone's level. The gaps between words are quieter
/// than speech, so a voice counts as speaking for a short hold after the last loud moment.
struct PrompterVoiceGate {
    static let hold: TimeInterval = 0.7

    private(set) var lastLoud: Date?

    /// The meter level (0…1) a voice must reach at `sensitivity` (0…1, higher hears quieter).
    static func threshold(sensitivity: Double) -> Float {
        Float(0.55 - min(max(sensitivity, 0), 1) * 0.45)
    }

    mutating func hear(level: Float, sensitivity: Double, at now: Date) -> Bool {
        if level >= Self.threshold(sensitivity: sensitivity) { lastLoud = now }
        guard let lastLoud else { return false }
        return now.timeIntervalSince(lastLoud) <= Self.hold
    }

    mutating func reset() { lastLoud = nil }
}

/// The script's colour, kept in settings as "#RRGGBB" (empty for white).
enum PrompterTextColor {
    static func color(hex: String) -> Color {
        rgb(hex: hex).map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .white
    }

    static func rgb(hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
        )
    }

    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
