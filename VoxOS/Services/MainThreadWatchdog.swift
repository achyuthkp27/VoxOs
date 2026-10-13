import Foundation

/// A short trail of what the app was doing, so a stall can be read instead of guessed at.
/// Marks are cheap (a lock and an append) and only the last `capacity` are kept.
enum ActivityTrail {
    static let capacity = 24
    private static let lock = NSLock()
    private static var entries: [(Date, String)] = []

    static func mark(_ what: @autoclosure () -> String) {
        let text = what()
        lock.lock()
        defer { lock.unlock() }
        entries.append((Date(), text))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    static func recent() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(formatter.string(from: $0.0)) \($0.1)" }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

/// Pings the main thread twice a second from its own thread. When a ping goes unanswered for
/// longer than `threshold`, the stall and the recent activity trail are appended to
/// ~/Library/Logs/VoxOS/hang.log, and the recovery is logged when the main thread comes back.
/// Every hang so far was reported after the fact with nothing to read; this leaves evidence.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()
    static let threshold: TimeInterval = 1.0
    static let interval: TimeInterval = 0.5
    static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoxOS/hang.log")
    }

    let logURL: URL
    private let lock = NSLock()
    private var lastPong = Date()
    private var stallStart: Date?
    private var thread: Thread?

    init(logURL: URL = MainThreadWatchdog.defaultLogURL) {
        self.logURL = logURL
    }

    func start() {
        guard thread == nil else { return }
        lastPong = Date()
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in self?.pong() }
                Thread.sleep(forTimeInterval: Self.interval)
                self.check()
            }
        }
        thread.name = "com.achyuthkp.voxos.watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        ActivityTrail.mark("launch")
    }

    func stop() {
        thread?.cancel()
        thread = nil
    }

    private func pong() {
        lock.lock()
        lastPong = Date()
        lock.unlock()
    }

    private func check() {
        lock.lock()
        let age = Date().timeIntervalSince(lastPong)
        let stalled = stallStart
        lock.unlock()

        if age > Self.threshold {
            guard stalled == nil else { return }
            lock.lock()
            stallStart = Date()
            lock.unlock()
            write(
                "main thread stalled (\(Int(age * 1000)) ms and counting); recent activity:\n    "
                    + ActivityTrail.recent().joined(separator: "\n    "))
        } else if let stalled {
            lock.lock()
            stallStart = nil
            lock.unlock()
            write("recovered after \(Int(Date().timeIntervalSince(stalled) * 1000)) ms")
        }
    }

    private func write(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(text)\n"
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
