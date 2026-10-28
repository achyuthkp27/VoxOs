import Combine
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

    /// Immutable after setup, and DateFormatter is thread-safe for formatting.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func recent() -> [String] {
        // Copy under the lock, format outside it: `mark` is called from the event-tap callback
        // while it holds the shortcut state lock, so every millisecond this lock is held during
        // a stall report is a millisecond the whole machine's keyboard waits.
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.map { "\(timeFormatter.string(from: $0.0)) \($0.1)" }
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
    static let pausedInterval: TimeInterval = 5
    static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VoxOS/hang.log")
    }

    let logURL: URL
    private let lock = NSLock()
    /// Measured on the uptime clock, which stops while the Mac sleeps: on the wall clock every
    /// sleep looked like a minutes-long stall of the whole process (four of them on 13 Oct).
    private var lastPong = ProcessInfo.processInfo.systemUptime
    private var stallStart: TimeInterval?
    private var thread: Thread?
    private var paused = false
    private var awayWatch: AnyCancellable?
    /// Watchdog thread only. Stacks taken during the current stall, to skip repeats.
    private var sampler: MainThreadSampler?
    private var stallSamples = 0
    private var lastSampleAt: TimeInterval = 0
    private var lastStackSignature: [UInt] = []
    static let maxSamplesPerStall = 4
    static let sampleInterval: TimeInterval = 2

    init(logURL: URL = MainThreadWatchdog.defaultLogURL) {
        self.logURL = logURL
    }

    func start() {
        guard thread == nil else { return }
        lastPong = ProcessInfo.processInfo.systemUptime
        sampler = MainThreadSampler()
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                guard let self else { return }
                if self.isPaused {
                    Thread.sleep(forTimeInterval: Self.pausedInterval)
                    // Back from a pause the clock starts afresh, so the pause is not taken for a stall.
                    self.pong()
                    continue
                }
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

    /// Rests while `away` says so: nobody sees a hang while the displays sleep or the screen is
    /// locked, and the pings would only keep waking the Mac.
    func pause(while away: AnyPublisher<Bool, Never>) {
        awayWatch = away.sink { [weak self] in self?.isPaused = $0 }
    }

    private var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    private func pong() {
        lock.lock()
        lastPong = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let age = now - lastPong
        let stalled = stallStart
        lock.unlock()

        if age > Self.threshold {
            guard stalled == nil else {
                sampleIfDue(now: now, age: age)
                return
            }
            lock.lock()
            stallStart = now
            lock.unlock()
            stallSamples = 0
            lastStackSignature = []
            // The stack first: by the time the trail is formatted the main thread may have moved on.
            let stack = takeStack(now: now)
            append(
                "main thread stalled (\(Int(age * 1000)) ms and counting); recent activity:\n    "
                    + ActivityTrail.recent().joined(separator: "\n    ")
                    + (stack.map { "\n  main thread stack:\n    " + $0.joined(separator: "\n    ") } ?? ""))
        } else if let stalled {
            lock.lock()
            stallStart = nil
            lock.unlock()
            // Measured from the detection, not the last pong: `age` at detection is the true start.
            append("recovered after \(Int((now - stalled) * 1000)) ms since detection")
        }
    }

    /// A long stall gets further stacks, so a loop shows where it spins and a wait shows what
    /// it waits on. A stack identical to the previous one is noted, not repeated.
    private func sampleIfDue(now: TimeInterval, age: TimeInterval) {
        guard stallSamples < Self.maxSamplesPerStall, now - lastSampleAt >= Self.sampleInterval else { return }
        guard let stack = takeStack(now: now) else {
            append("  still stalled at \(Int(age * 1000)) ms, no new stack")
            return
        }
        append("  still stalled at \(Int(age * 1000)) ms; main thread stack:\n    " + stack.joined(separator: "\n    "))
    }

    /// Nil when sampling failed or the stack has not changed since the last one.
    private func takeStack(now: TimeInterval) -> [String]? {
        guard let sampler else { return nil }
        stallSamples += 1
        lastSampleAt = now
        let addresses = sampler.sample()
        guard !addresses.isEmpty, addresses != lastStackSignature else { return nil }
        lastStackSignature = addresses
        return MainThreadSampler.describe(addresses)
    }

    /// An event worth a line of its own even when the main thread is fine: the keyboard tap
    /// being disabled is the symptom the user feels as "typing froze", and the trail only
    /// reaches the log when a stall happens to dump it. Written off the caller's thread, since
    /// the caller may be the tap thread and a disk write there is itself a keyboard stall.
    func note(_ text: String) {
        ActivityTrail.mark(text)
        append("note: \(text)")
    }

    /// The log is cut back to its newest `logKeepBytes` once it passes `logCapBytes`, so a
    /// machine that stalls often cannot grow it without bound.
    static let logCapBytes: UInt64 = 1 << 20
    static let logKeepBytes: UInt64 = 256 << 10

    /// Every write goes through this one serial queue, from the watchdog thread and from note()
    /// alike, so two lines can never interleave or race the trim.
    private let noteQueue = DispatchQueue(label: "com.achyuthkp.voxos.watchdog.notes", qos: .utility)

    /// Stamps the line now, when it happened, and writes it on noteQueue.
    private func append(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(text)\n"
        noteQueue.async { [self] in write(line) }
    }

    /// Runs on noteQueue only. The file is opened with O_APPEND, so every write lands at the end
    /// even if something else has the file open, and it is created on the first line rather than
    /// replaced: the old fallback wrote atomically, which swaps in a new file and loses the log.
    private func write(_ line: String) {
        dispatchPrecondition(condition: .onQueue(noteQueue))
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try? handle.write(contentsOf: Data(line.utf8))
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.close()
        if size > Self.logCapBytes { trim(size: size) }
    }

    /// Keeps the newest `logKeepBytes`, starting at a line boundary. Only noteQueue writes the
    /// file, so replacing it here cannot drop a line written meanwhile.
    private func trim(size: UInt64) {
        guard let reader = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: size - Self.logKeepBytes)) != nil,
            var tail = try? reader.readToEnd()
        else { return }
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: newline)...] }
        try? tail.write(to: logURL, options: .atomic)
    }
}
