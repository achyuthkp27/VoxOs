import Foundation
import Testing

@testable import VoxOS

/// The search keywords are typed by hand next to the views they describe, so they drift when a
/// label is renamed. These read the app's sources and check each label is still text it shows.
@Suite
struct SettingsSectionTests {

    /// Every Swift source of the app, except the keyword list itself, which would match itself.
    private static let appSources: String = {
        let appFolder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoxOS")
        let files =
            FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsSection.swift" } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }()

    @Test func theAppSourcesWereFound() {
        #expect(Self.appSources.contains("struct NotchSettingsPage"))
    }

    @Test(arguments: SettingsSection.allCases)
    func everyLabelIsTextTheAppShows(_ section: SettingsSection) {
        for label in section.labels {
            // A label with a value in it is written up to the value: "Show Windows with \\(…)".
            let shown = Self.appSources.contains("\"\(label)\"") || Self.appSources.contains("\"\(label) \\(")
            #expect(shown, "“\(label)” in \(section) is not text the app shows")
        }
    }

    @Test(arguments: SettingsSection.allCases)
    func everySectionHasALabel(_ section: SettingsSection) {
        #expect(!section.labels.isEmpty)
    }
}
