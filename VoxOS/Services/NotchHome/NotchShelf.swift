import AppKit
import Combine
import Foundation

/// Files dropped on the notch, kept for later: drag them out again to wherever they go next.
///
/// The shelf holds references, not copies; VoxOS is not sandboxed, so a plain path is enough.
/// A file that was moved or deleted simply leaves the shelf the next time it is looked at.
@MainActor
final class NotchShelf: ObservableObject {
    static let shared = NotchShelf()
    static let limit = 12

    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        let path: String
        let added: Date

        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    private let storeURL: URL
    private let fileExists: (String) -> Bool

    init(
        storeURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS/shelf.json"),
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.storeURL = storeURL
        self.fileExists = fileExists
        if let data = try? Data(contentsOf: storeURL),
            let saved = try? JSONDecoder().decode([Item].self, from: data)
        {
            items = saved
        }
        prune()
    }

    /// Newest first; a file already on the shelf moves to the front instead of appearing twice,
    /// and past the limit the oldest leave.
    func add(_ urls: [URL], now: Date = Date()) {
        let paths = urls.filter(\.isFileURL).map(\.path).filter(fileExists)
        guard !paths.isEmpty else { return }
        items.removeAll { paths.contains($0.path) }
        items.insert(contentsOf: paths.map { Item(id: UUID(), path: $0, added: now) }, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Drops files that are no longer where they were.
    func prune() {
        let kept = items.filter { fileExists($0.path) }
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: storeURL, options: .atomic) }
    }

    static func icon(for item: Item) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.path)
    }
}
