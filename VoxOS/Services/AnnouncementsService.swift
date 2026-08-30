import AppKit
import Foundation

/// A minimal pull-based announcements fetcher that shows one-time in-app banners.
final class AnnouncementsService {
    static let shared = AnnouncementsService()

    private init() {}

    // MARK: - Public API

    // No-op: this personal fork has no announcements feed of its own.
    func start() {}

    func stop() {}
}
