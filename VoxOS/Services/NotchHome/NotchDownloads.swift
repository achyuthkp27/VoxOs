import Combine
import Foundation

/// Downloads in progress in the Downloads folder, for a band with how far along they are, and a
/// passing notice when one finishes.
///
/// Browsers publish each download's progress for its file (that is how Finder draws a bar on a
/// downloading file); subscribing to the Downloads folder receives them, with no polling and no
/// reading of the browser's own data. Updates are taken at most a few times a second.
@MainActor
final class NotchDownloads: ObservableObject {
    static let shared = NotchDownloads()

    struct Item: Identifiable, Equatable {
        let id: ObjectIdentifier
        let name: String
        var fraction: Double
    }

    /// How often a download's progress is passed on.
    static let updateInterval: TimeInterval = 0.5
    static let finishedLifetime: TimeInterval = 3.5

    @Published private(set) var active: [Item] = []
    /// A download that just finished, by file name.
    @Published private(set) var finished: String?

    private var subscriber: Any?
    private var watches: [ObjectIdentifier: (progress: Progress, observation: NSKeyValueObservation)] = [:]
    private var lastUpdate: [ObjectIdentifier: Date] = [:]
    private var clearTask: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchDownloadsEnabled) }

    private init() {}

    func start() {
        guard subscriber == nil, !ProcessIdentity.isTestHost,
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            // Called on a queue of Foundation's; everything else happens on the main actor.
            let id = ObjectIdentifier(progress)
            Task { @MainActor in self?.began(progress) }
            return { Task { @MainActor in self?.ended(id) } }
        }
    }

    func stop() {
        guard let subscriber else { return }
        Progress.removeSubscriber(subscriber)
        self.subscriber = nil
        watches.values.forEach { $0.observation.invalidate() }
        watches = [:]
        active = []
    }

    /// The file's name without the browser's in-progress extension.
    nonisolated static func displayName(of url: URL?) -> String {
        guard let url else { return String(localized: "Download") }
        let partial: Set<String> = ["crdownload", "download", "part", "partial"]
        let trimmed = partial.contains(url.pathExtension.lowercased()) ? url.deletingPathExtension() : url
        return trimmed.lastPathComponent
    }

    private func began(_ progress: Progress) {
        let id = ObjectIdentifier(progress)
        guard watches[id] == nil else { return }
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.update(id, fraction: fraction) }
        }
        watches[id] = (progress, observation)
        active.append(Item(id: id, name: Self.displayName(of: progress.fileURL), fraction: progress.fractionCompleted))
    }

    private func update(_ id: ObjectIdentifier, fraction: Double, now: Date = Date()) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        if let last = lastUpdate[id], now.timeIntervalSince(last) < Self.updateInterval, fraction < 1 { return }
        lastUpdate[id] = now
        active[index].fraction = fraction
    }

    private func ended(_ id: ObjectIdentifier) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.observation.invalidate()
        lastUpdate[id] = nil
        let item = active.first { $0.id == id }
        active.removeAll { $0.id == id }
        // A download the browser cancelled ends short of the whole.
        guard let item, watch.progress.fractionCompleted >= 0.99 || watch.progress.isFinished else { return }
        finished = item.name
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedLifetime))
            guard !Task.isCancelled else { return }
            self?.finished = nil
        }
    }
}
