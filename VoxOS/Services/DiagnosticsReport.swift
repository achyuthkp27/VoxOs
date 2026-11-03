import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import OSLog

/// A plain-text snapshot of the running app for a bug report: the build, the environment, the
/// settings that change behaviour, the permission states and this process's recent log.
///
/// Everything here is safe to paste in public. It reports the *names* of AI providers, models
/// and MCP servers, never their keys, tokens, headers or environment values, and it reads no
/// keychain item, transcript, clipboard or MCP config body.
enum DiagnosticsReport {
    /// How far back the log goes, and how much of it is kept. A report is for reading in an
    /// issue, not for attaching the whole log.
    static let logWindow: TimeInterval = 10 * 60
    static let maxLogLines = 400
    static let maxLogCharacters = 60_000

    // MARK: - Snapshot

    struct Permissions: Equatable, Sendable {
        var microphone: String
        var accessibility: String
        var screenRecording: String
        var inputMonitoring: String
    }

    struct Snapshot: Equatable, Sendable {
        var generatedAt: Date
        var appVersion: String
        var buildVersion: String
        var bundleIdentifier: String
        var macOSVersion: String
        var architecture: String
        var hardwareModel: String
        var isLocalBuild: Bool
        var isTestHost: Bool
        var permissions: Permissions
        /// Pre-rendered `Name: value` lines, built from an allow-list of keys (see `settingsLines`).
        var settings: [String]
        /// Pre-rendered `name — transport` lines. No command, URL, header or env is included.
        var mcpServers: [String]
        var log: String
    }

    // MARK: - Report

    /// Builds the report off the main thread: reading the log and the permission APIs is not
    /// instant and nothing here needs to happen on it.
    static func report() async -> String {
        await Task.detached(priority: .utility) {
            render(build())
        }.value
    }

    static func build(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> Snapshot {
        Snapshot(
            generatedAt: Date(),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            bundleIdentifier: bundle.bundleIdentifier ?? "?",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            hardwareModel: hardwareModel,
            isLocalBuild: isLocalBuild,
            isTestHost: ProcessIdentity.isTestHost,
            permissions: currentPermissions(),
            settings: settingsLines(from: defaults),
            mcpServers: mcpServerLines(),
            log: recentLog()
        )
    }

    static func render(_ snapshot: Snapshot) -> String {
        var lines: [String] = [
            "VoxOS diagnostics",
            "Generated: \(iso8601(snapshot.generatedAt))",
            "",
            "App",
            "  Version: \(snapshot.appVersion) (\(snapshot.buildVersion))",
            "  Bundle: \(snapshot.bundleIdentifier)",
            "  Build: \(snapshot.isLocalBuild ? "local (LOCAL_BUILD)" : "regular")"
                + " — test host: \(snapshot.isTestHost ? "yes" : "no")",
            "",
            "System",
            "  macOS: \(snapshot.macOSVersion)",
            "  Architecture: \(snapshot.architecture)",
            "  Hardware: \(snapshot.hardwareModel)",
            "",
            "Permissions",
            "  Microphone: \(snapshot.permissions.microphone)",
            "  Accessibility: \(snapshot.permissions.accessibility)",
            "  Screen recording: \(snapshot.permissions.screenRecording)",
            "  Input monitoring: \(snapshot.permissions.inputMonitoring)",
            "",
            "Settings",
        ]
        lines += snapshot.settings.map { "  \($0)" }
        lines += ["", "MCP servers"]
        lines += snapshot.mcpServers.isEmpty ? ["  none"] : snapshot.mcpServers.map { "  \($0)" }
        lines += ["", "Recent log (last \(Int(logWindow / 60)) minutes)"]
        lines += snapshot.log.isEmpty ? ["  (nothing logged)"] : snapshot.log.split(separator: "\n").map { "  \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Settings

    /// Only keys listed here are reported, so a key added later cannot leak its value by
    /// accident. Keys that hold credentials are never read.
    static func settingsLines(from defaults: UserDefaults) -> [String] {
        func value(_ key: String) -> String {
            guard let value = defaults.object(forKey: key) else { return "not set" }
            if let bool = value as? Bool { return bool ? "on" : "off" }
            let text = String(describing: value)
            return text.isEmpty ? "(empty)" : text
        }

        return [
            "Recorder: \(value(DefaultsKeys.recorderType))",
            "Language: \(value(DefaultsKeys.selectedLanguage))",
            "Text formatting: \(value(DefaultsKeys.isTextFormattingEnabled))",
            "Voice assistant: \(value(DefaultsKeys.voiceAssistantEnabled))",
            "Notch: \(value(DefaultsKeys.notchMasterEnabled))",
            "Onboarding complete: \(value(DefaultsKeys.hasCompletedOnboardingV2))",
            "Transcription model: \(value(DefaultsKeys.currentTranscriptionModel))",
            "AI provider: \(value(DefaultsKeys.aiMainProvider))",
            "AI model: \(value(DefaultsKeys.aiMainModel))",
            "Agent provider: \(value(DefaultsKeys.aiAgentProvider))",
            "Agent model: \(value(DefaultsKeys.aiAgentModel))",
            "Fallback provider: \(value(DefaultsKeys.aiFallbackProvider))",
            "Claude Code bridge: \(value(DefaultsKeys.claudeCodeEnabled))"
                + " — approvals: \(value(DefaultsKeys.claudeCodeApprovalsEnabled))"
                + " — port: \(ClaudeCodeBridge.defaultPort)",
        ]
    }

    // MARK: - Environment

    private static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static var isLocalBuild: Bool {
        #if LOCAL_BUILD
            return true
        #else
            return false
        #endif
    }

    private static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func currentPermissions() -> Permissions {
        Permissions(
            microphone: describe(AVCaptureDevice.authorizationStatus(for: .audio)),
            accessibility: AXIsProcessTrusted() ? "granted" : "denied",
            screenRecording: CGPreflightScreenCaptureAccess() ? "granted" : "denied",
            inputMonitoring: describe(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
        )
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    private static func mcpServerLines() -> [String] {
        AgentMCP.loadConfig().map { config in
            let transport: String
            if let remote = config.remoteURL, let host = URL(string: remote)?.host {
                transport = "http (\(host))"
            } else {
                transport = "stdio (\(URL(fileURLWithPath: config.command).lastPathComponent))"
            }
            return "\(config.name) — \(transport)\(config.disabled ? " — disabled" : "")"
        }
    }

    // MARK: - Log

    /// This process's own entries, newest last, capped so a chatty run cannot make the report
    /// huge. Reading them needs no subprocess and no special entitlement.
    private static func recentLog() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-logWindow))
            let predicate = NSPredicate(format: "subsystem == %@", "com.achyuthkp.voxos")
            var lines: [String] = []
            for entry in try store.getEntries(at: position, matching: predicate) {
                lines.append("\(clock(entry.date)) \(entry.composedMessage)")
            }
            return trim(log: lines.joined(separator: "\n"))
        } catch {
            return "(the log could not be read: \(error.localizedDescription))"
        }
    }

    /// Keeps the newest `maxLines` lines (and at most `maxCharacters`), saying what it dropped.
    static func trim(
        log: String,
        maxLines: Int = maxLogLines,
        maxCharacters: Int = maxLogCharacters
    ) -> String {
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines || log.count > maxCharacters else { return lines.joined(separator: "\n") }

        let total = lines.count
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        while lines.joined(separator: "\n").count > maxCharacters, lines.count > 1 {
            lines.removeFirst()
        }
        return "… \(total - lines.count) earlier line(s) omitted\n" + lines.joined(separator: "\n")
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }
}
