import Combine
import Foundation

/// A passing notice when a Focus (Do Not Disturb, Work, Sleep…) turns on or off, with its own
/// name and symbol.
///
/// macOS has no public way to say which Focus is on. Its own store says, in
/// ~/Library/DoNotDisturb/DB (measured on macOS 26): Assertions.json lists the active Focus under
/// `storeAssertionRecords` (absent when none is on), and ModeConfigurations.json names each mode
/// and its symbol. The folder is watched by the kernel; it is read only when it changes. The
/// format is not Apple's promise, so anything unexpected reads as "no Focus" and says nothing.
@MainActor
final class NotchFocus: ObservableObject {
    static let shared = NotchFocus()

    struct Mode: Equatable {
        let id: String
        let name: String
        let symbol: String
    }

    static let noticeLifetime: TimeInterval = 3.5

    @Published private(set) var notice: NotchHome.Notice?

    private var current: String?
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchFocusEnabled) }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")
    }

    private init() {}

    func start() {
        guard source == nil, !ProcessIdentity.isTestHost else { return }
        let descriptor = open(Self.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        current = Self.activeModeID(in: Self.read("Assertions.json"))
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
    }

    /// Files are replaced a few at a time; one read once they settle.
    private func changed() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let id = Self.activeModeID(in: Self.read("Assertions.json"))
            guard id != self.current else { return }
            self.current = id
            let mode = id.flatMap { Self.mode($0, in: Self.read("ModeConfigurations.json")) }
            self.post(
                id == nil
                    ? NotchHome.Notice(
                        symbol: "moon.zzz", title: String(localized: "Focus"), detail: String(localized: "Off"))
                    : NotchHome.Notice(
                        symbol: mode?.symbol ?? "moon.fill", title: mode?.name ?? String(localized: "Focus"),
                        detail: String(localized: "On")))
        }
    }

    private func post(_ notice: NotchHome.Notice) {
        ActivityTrail.mark("focus changed")
        self.notice = notice
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private static func read(_ name: String) -> Any? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The newest active assertion's mode.
    nonisolated static func activeModeID(in assertions: Any?) -> String? {
        guard let store = ((assertions as? [String: Any])?["data"] as? [[String: Any]])?.first,
            let records = store["storeAssertionRecords"] as? [[String: Any]]
        else { return nil }
        return
            records
            .sorted {
                ($0["assertionStartDateTimestamp"] as? Double ?? 0)
                    > ($1["assertionStartDateTimestamp"] as? Double ?? 0)
            }
            .compactMap { ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }
            .first
    }

    nonisolated static func mode(_ id: String, in configurations: Any?) -> Mode? {
        guard let store = ((configurations as? [String: Any])?["data"] as? [[String: Any]])?.first,
            let modes = store["modeConfigurations"] as? [String: Any],
            let mode = (modes[id] as? [String: Any])?["mode"] as? [String: Any],
            let name = mode["name"] as? String
        else { return nil }
        return Mode(id: id, name: name, symbol: mode["symbolImageName"] as? String ?? "moon.fill")
    }
}
