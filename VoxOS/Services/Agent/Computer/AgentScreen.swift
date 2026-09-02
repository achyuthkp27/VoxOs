import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Captures the display under the cursor and runs OCR on it. Every box comes back in
/// GLOBAL screen points (top-left origin), already converted from image pixels, so the
/// rest of the agent never has to think about Retina scale or which monitor it is on.
enum AgentScreen {

    struct TextMatch {
        let text: String
        /// Global screen points, top-left origin.
        let frame: CGRect
        let confidence: Float
    }

    struct Capture {
        let image: CGImage
        let frontmostApp: String
        /// Display origin in global CG points.
        let displayOrigin: CGPoint
        /// Points per image pixel for this capture.
        let pointsPerPixel: CGFloat
        let displayBounds: CGRect

        func toPoints(_ px: CGRect) -> CGRect {
            CGRect(
                x: displayOrigin.x + px.minX * pointsPerPixel,
                y: displayOrigin.y + px.minY * pointsPerPixel,
                width: px.width * pointsPerPixel,
                height: px.height * pointsPerPixel)
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static var cachedContent: (content: SCShareableContent, at: Date)?
    private static let contentLock = NSLock()

    /// `wait_for_text` and the watchers poll every couple of seconds; the display list changes
    /// far less often than that.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContentIfFresh() { return cached }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        storeContent(fresh)
        return fresh
    }

    // Locking lives in synchronous helpers so no lock is held across an await.
    private static func cachedContentIfFresh() -> SCShareableContent? {
        contentLock.lock(); defer { contentLock.unlock() }
        guard let cached = cachedContent, Date().timeIntervalSince(cached.at) < 5 else { return nil }
        return cached.content
    }

    private static func storeContent(_ content: SCShareableContent) {
        contentLock.lock(); defer { contentLock.unlock() }
        cachedContent = (content, Date())
    }

    /// Screenshot of the frontmost app's display, excluding VoxOS's own windows.
    /// `lowResolution` halves the pixel size — right for polling loops that only need to know
    /// whether a word is present, at a quarter of the OCR cost.
    static func capture(lowResolution: Bool = false) async -> Capture? {
        guard await ScreenCaptureService.requestScreenCapturePermissionRegistration() else { return nil }
        do {
            let content = try await shareableContent()
            guard let display = pickDisplay(content) else { return nil }

            let ours = Bundle.main.bundleIdentifier ?? "com.achyuthkp.VoxOS"
            let ourWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ours }
            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)

            let config = SCStreamConfiguration()
            // SCDisplay reports points; the stream wants pixels. CGDisplayPixelsWide also
            // reports points on HiDPI modes, so read the mode's true pixel size.
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let divisor = lowResolution ? 2 : 1
            config.width = (mode?.pixelWidth ?? display.width) / divisor
            config.height = (mode?.pixelHeight ?? display.height) / divisor
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let bounds = CGDisplayBounds(display.displayID)
            let ratio = bounds.width > 0 ? bounds.width / CGFloat(image.width) : 1
            let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown" }
            return Capture(
                image: image, frontmostApp: frontmost, displayOrigin: bounds.origin,
                pointsPerPixel: ratio, displayBounds: bounds)
        } catch {
            return nil
        }
    }

    /// OCR a capture. Boxes are returned in global screen points.
    static func recognizeText(in capture: Capture, accurate: Bool = true, maxResults: Int = 120) async -> [TextMatch] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = accurate ? .accurate : .fast
                request.usesLanguageCorrection = false
                do {
                    try VNImageRequestHandler(cgImage: capture.image, options: [:]).perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                let w = CGFloat(capture.image.width)
                let h = CGFloat(capture.image.height)
                let matches: [TextMatch] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox  // normalised, bottom-left origin
                    let px = CGRect(
                        x: box.minX * w, y: (1 - box.minY - box.height) * h,
                        width: box.width * w, height: box.height * h)
                    return TextMatch(text: candidate.string, frame: capture.toPoints(px), confidence: candidate.confidence)
                }
                continuation.resume(returning: Array(matches.prefix(maxResults)))
            }
        }
    }

    /// Top-to-bottom, then left-to-right. Rows are bucketed by height so the comparison is a
    /// strict weak ordering — a threshold comparator ("close enough in y") is not, and `sort`
    /// may scramble the result.
    static func readingOrderKey(_ frame: CGRect, rowHeight: CGFloat = 12) -> (Int, CGFloat) {
        (Int((frame.midY / rowHeight).rounded(.down)), frame.minX)
    }

    static func filter(_ matches: [TextMatch], query: String?) -> [TextMatch] {
        guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !q.isEmpty else {
            return matches
        }
        return matches.filter { $0.text.lowercased().contains(q) }
    }

    /// Convenience: full-screen OCR as one text blob, for "what's on my screen" questions.
    static func readScreenText(maxChars: Int = 6000) async -> [String: Any] {
        guard let shot = await capture() else {
            return ["error": "screen capture failed — Screen Recording permission may be missing"]
        }
        let matches = await recognizeText(in: shot)
        let sorted = matches.sorted { readingOrderKey($0.frame) < readingOrderKey($1.frame) }
        var text = sorted.map(\.text).joined(separator: "\n")
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n…(truncated)" }
        return [
            "frontmost": shot.frontmostApp,
            "display": ["x": Int(shot.displayBounds.minX), "y": Int(shot.displayBounds.minY),
                        "width": Int(shot.displayBounds.width), "height": Int(shot.displayBounds.height)],
            "text_lines": matches.count,
            "text": text,
        ]
    }

    /// The display holding the frontmost app's window wins; the mouse's display is the fallback.
    /// The agent acts on the frontmost app, which is not necessarily where the pointer is.
    private static func pickDisplay(_ content: SCShareableContent) -> SCDisplay? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
            let window = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
            }),
            let b = window[kCGWindowBounds as String] as? [String: CGFloat]
        {
            let center = CGPoint(x: (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, y: (b["Y"] ?? 0) + (b["Height"] ?? 0) / 2)
            if let match = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) {
                return match
            }
        }
        let cursor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }),
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let match = content.displays.first(where: { $0.displayID == id })
        {
            return match
        }
        return content.displays.first
    }
}
