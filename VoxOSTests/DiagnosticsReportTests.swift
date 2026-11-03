import Foundation
import Testing

@testable import VoxOS

/// The diagnostics report: it must say enough to debug a report, and must never carry a
/// credential. The settings are drawn from an allow-list, so a key added later cannot leak.
@Suite
struct DiagnosticsReportTests {
    private func snapshot(log: String = "12:00:00.000 bridge listening") -> DiagnosticsReport.Snapshot {
        DiagnosticsReport.Snapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.2.3",
            buildVersion: "456",
            bundleIdentifier: "com.achyuthkp.VoxOS",
            macOSVersion: "Version 15.1 (Build 24B83)",
            architecture: "arm64",
            hardwareModel: "MacBookPro18,3",
            isLocalBuild: true,
            isTestHost: false,
            permissions: .init(
                microphone: "authorized",
                accessibility: "granted",
                screenRecording: "denied",
                inputMonitoring: "unknown"
            ),
            settings: ["Recorder: notch", "Language: en"],
            mcpServers: ["filesystem — stdio (npx)"],
            log: log
        )
    }

    @Test func theReportCarriesEverySection() {
        let report = DiagnosticsReport.render(snapshot())

        for section in ["App", "System", "Permissions", "Settings", "MCP servers", "Recent log"] {
            #expect(report.contains(section))
        }
        #expect(report.contains("Version: 1.2.3 (456)"))
        #expect(report.contains("Build: local (LOCAL_BUILD) — test host: no"))
        #expect(report.contains("Hardware: MacBookPro18,3"))
        #expect(report.contains("Microphone: authorized"))
        #expect(report.contains("Screen recording: denied"))
        #expect(report.contains("Recorder: notch"))
        #expect(report.contains("filesystem — stdio (npx)"))
        #expect(report.contains("bridge listening"))
    }

    @Test func anEmptyLogSaysSoAndNoServersSayNone() {
        var empty = snapshot(log: "")
        empty.mcpServers = []
        let report = DiagnosticsReport.render(empty)

        #expect(report.contains("(nothing logged)"))
        #expect(report.contains("  none"))
    }

    @Test func settingsReadOnlyTheAllowList() {
        let suite = "DiagnosticsReportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("npx", forKey: "SomeMCPCommandWithAKnownSecret")
        defaults.set("sk-live-0123456789", forKey: "SomeProviderAPIKey")
        defaults.set("anthropic", forKey: DefaultsKeys.aiMainProvider)
        defaults.set("claude-sonnet-4", forKey: DefaultsKeys.aiMainModel)

        let lines = DiagnosticsReport.settingsLines(from: defaults).joined(separator: "\n")

        #expect(lines.contains("AI provider: anthropic"))
        #expect(lines.contains("AI model: claude-sonnet-4"))
        #expect(!lines.contains("sk-live-0123456789"))
        #expect(!lines.contains("SomeProviderAPIKey"))
        #expect(!lines.contains("SomeMCPCommandWithAKnownSecret"))
    }

    @Test func unregisteredSettingsSaySoRatherThanPrintingAnEmptyValue() {
        let suite = "DiagnosticsReportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Registered defaults (AppDefaults.registerDefaults) still apply to a fresh suite, so the
        // assertion uses keys that are deliberately not registered.
        let lines = DiagnosticsReport.settingsLines(from: defaults).joined(separator: "\n")

        #expect(lines.contains("Transcription model: not set"))
        #expect(lines.contains("AI provider: not set"))
    }

    @Test func trimmingKeepsTheNewestLinesAndSaysWhatItDropped() {
        let log = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let trimmed = DiagnosticsReport.trim(log: log, maxLines: 3, maxCharacters: 1_000)

        #expect(trimmed.contains("… 7 earlier line(s) omitted"))
        #expect(trimmed.contains("line 10"))
        #expect(!trimmed.contains("line 6"))
        #expect(trimmed.hasSuffix("line 10"))
    }

    @Test func aShortLogIsLeftAlone() {
        let log = "one\ntwo"
        #expect(DiagnosticsReport.trim(log: log, maxLines: 3, maxCharacters: 1_000) == log)
    }

    @Test func theCharacterCapWinsOverTheLineCap() {
        let log = (1...50).map { String(repeating: "x", count: 100) + " \($0)" }.joined(separator: "\n")
        let trimmed = DiagnosticsReport.trim(log: log, maxLines: 50, maxCharacters: 500)

        #expect(trimmed.count < 700)
        #expect(trimmed.contains("omitted"))
    }
}
