import Foundation
import Testing

@testable import VoxOS

/// The watchdog is the only evidence we get for a stall, so it must fire on a real one, stay
/// quiet otherwise, and keep its trail small. One test blocks the main thread on purpose.
@Suite(.serialized)
struct MainThreadWatchdogTests {

    @Test func trailKeepsOnlyTheNewestMarks() {
        ActivityTrail.clear()
        for index in 0..<(ActivityTrail.capacity + 10) { ActivityTrail.mark("mark \(index)") }
        let recent = ActivityTrail.recent()
        #expect(recent.count == ActivityTrail.capacity)
        #expect(recent.last?.hasSuffix("mark \(ActivityTrail.capacity + 9)") == true)
        #expect(recent.first?.hasSuffix("mark 10") == true, "the oldest ten were dropped")
    }

    @Test func logLivesUnderTheUsersLogs() {
        #expect(MainThreadWatchdog.defaultLogURL.path.hasSuffix("/Library/Logs/VoxOS/hang.log"))
        #expect(MainThreadWatchdog.threshold >= 0.5 && MainThreadWatchdog.threshold <= 2)
    }

    @Test @MainActor func aBlockedMainThreadIsWrittenToTheLogWithTheTrail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        ActivityTrail.clear()
        ActivityTrail.mark("test marker before the stall")
        let watchdog = MainThreadWatchdog(logURL: url)
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(700))  // let it get a first pong
        Thread.sleep(forTimeInterval: MainThreadWatchdog.threshold + 0.8)  // block main on purpose
        try await Task.sleep(for: .milliseconds(900))  // let it notice the recovery
        let log = try String(contentsOf: url, encoding: .utf8)
        #expect(log.contains("main thread stalled"))
        #expect(log.contains("test marker before the stall"), "the trail is in the report")
        #expect(log.contains("recovered after"))
        #expect(log.contains("main thread stack:"), "the stall names where main was")
        #expect(
            log.contains("aBlockedMainThreadIsWrittenToTheLogWithTheTrail"),
            "the walk reaches the function that blocked main")
    }

    @Test func symbolsAreDemangledAndUnknownNamesPassThrough() {
        #expect(MainThreadSampler.demangle("$sSi") == "Swift.Int")
        #expect(MainThreadSampler.demangle("mach_msg2_trap") == "mach_msg2_trap")
    }

    @Test func framesNameTheirImage() {
        let lines = MainThreadSampler.describe([
            UInt(bitPattern: unsafeBitCast(strlen as @convention(c) (UnsafePointer<CChar>) -> Int, to: Int.self))
        ])
        #expect(lines.first?.contains("libsystem") == true)
    }

    @Test @MainActor func aResponsiveMainThreadWritesNothing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let watchdog = MainThreadWatchdog(logURL: url)
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(1_600))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
