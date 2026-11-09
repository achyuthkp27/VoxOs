import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
import os

/// The notch's decisions that need nothing but their inputs: which band fits, which notice
/// shows, how a swipe reads and where the page goes, so they can be tested on their own.
extension NotchHomeManager {
    /// The front app fills the notched screen: a full-screen video, game or app, where the menu
    /// bar is hidden and the notch is best left alone. Window bounds need no permission.
    static func frontAppIsFullScreen(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return list.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return width >= screen.frame.width && height >= screen.frame.height
        }
    }

    /// A band that lasts (music, a timer) is drawn only where it covers nothing in the menu bar.
    /// A notice is gone in seconds, so it may.
    nonisolated static func fits(_ content: NotchHome.Content, allowedWing: CGFloat?) -> Bool {
        guard let allowedWing else { return true }
        switch content {
        case .playing: return allowedWing >= NotchHome.wing
        case .timer: return allowedWing >= NotchHome.timerWing
        case .privacy: return allowedWing >= NotchHome.privacyWing
        case .download: return allowedWing >= NotchHome.noticeWing
        // A meeting is said for minutes, then gone, like a notice.
        default: return true
        }
    }

    static func downloadNotice(_ name: String?) -> NotchHome.Notice? {
        name.map {
            NotchHome.Notice(symbol: "checkmark.circle.fill", title: $0, detail: String(localized: "Downloaded"))
        }
    }

    /// A finished timer outranks a device: it is the one the user was waiting for.
    static func notice(device: NotchDeviceAlerts.Notice?, finished: NotchTimers.Finished?) -> NotchHome.Notice? {
        if let finished {
            return NotchHome.Notice(symbol: "bell.fill", title: finished.label, detail: finished.next?.label)
        }
        if let device { return NotchHome.Notice(symbol: device.symbol, title: device.title, detail: device.detail) }
        return nil
    }

    /// The player picked with the dots while it still has a track; otherwise one that is
    /// playing; otherwise the first.
    nonisolated static func shown(_ tracks: [NotchTrack], selected: String?) -> NotchTrack? {
        if let selected, let picked = tracks.first(where: { $0.bundleID == selected }) { return picked }
        return tracks.first(where: \.isPlaying) ?? tracks.first
    }

    /// What a collapsed band is about, so a swipe can put away this band and not the next one.
    nonisolated static func bandKey(_ content: NotchHome.Content, track: NotchTrack?, timer: NotchTimer?) -> String? {
        switch content {
        case .playing: return "playing:" + (track?.id ?? "")
        case .timer: return "timer:\(timer?.ends.timeIntervalSince1970 ?? 0)"
        case .notice(let notice): return "notice:\(notice.title)|\(notice.detail ?? "")"
        case .meeting(let meeting): return "meeting:\(meeting.id)"
        // Not the mute: muting must not bring back a band that was put away.
        case .privacy(let privacy):
            return "privacy:\(privacy.microphone)|\(privacy.camera)|\(privacy.microphoneApp ?? "")"
        default: return nil
        }
    }

    enum Swipe: Equatable {
        case dismiss
        /// Outward from the notch: brings back a band that was swiped away.
        case restore
        case nextPage
        case previousPage
        case nextPlayer
        case previousPlayer
        case none
    }

    /// Open: sideways turns the page (fingers left for the next), up and down moves between
    /// players. Collapsed: fingers moving toward the middle of the notch put the band away —
    /// right to left on its right half, left to right on its left half — and moving outward
    /// brings it back.
    nonisolated static func swipe(
        startX: CGFloat, width: CGFloat, fingerDX: CGFloat, fingerDY: CGFloat, expanded: Bool,
        threshold: CGFloat = 36
    ) -> Swipe {
        if abs(fingerDX) >= abs(fingerDY) {
            guard abs(fingerDX) >= threshold else { return .none }
            if expanded { return fingerDX < 0 ? .nextPage : .previousPage }
            // Collapsed, only a plainly sideways swipe counts: a scroll that drifts across the
            // band must not put it away or bring it back.
            guard abs(fingerDX) >= threshold * 1.5, abs(fingerDX) >= abs(fingerDY) * 2 else { return .none }
            let onRight = startX > width / 2
            return (onRight && fingerDX < 0) || (!onRight && fingerDX > 0) ? .dismiss : .restore
        }
        guard expanded, abs(fingerDY) >= threshold else { return .none }
        return fingerDY < 0 ? .nextPlayer : .previousPlayer
    }

    /// The page after (or before) `page` among those available, wrapping round.
    nonisolated static func page(after page: NotchHomePage, forward: Bool, hasTrack: Bool) -> NotchHomePage {
        let pages = NotchHomePage.available(hasTrack: hasTrack)
        guard let index = pages.firstIndex(of: page) else { return pages.first ?? page }
        return pages[(index + (forward ? 1 : -1) + pages.count) % pages.count]
    }

    /// How far the fingers move before a swipe is taken as sideways or up and down.
    static let axisLock: CGFloat = 8

    /// How far a swipe goes to turn the page when nothing follows the fingers.
    static let pageSwipe: CGFloat = 36

    /// Let go past a fifth of the card, or with a flick its way, and the page goes; otherwise
    /// it settles back.
    nonisolated static func commitsPage(dx: CGFloat, flick: CGFloat, width: CGFloat) -> Bool {
        guard dx != 0 else { return false }
        if abs(dx) >= width * 0.2 { return true }
        return abs(dx) >= 24 && abs(flick) >= 6 && (flick < 0) == (dx < 0)
    }

    /// The cover's average colour, lifted so a dark cover still gives bars you can see.
    static func tint(of image: NSImage?) -> Color {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(
            nsColor: NSColor(hue: hue, saturation: min(saturation, 0.7), brightness: max(brightness, 0.85), alpha: 1))
    }
}
