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

/// The German and Chinese translations: command-line builds never add new strings to the
/// catalog, so it drifted for weeks. `make strings` adds them; these fail until they are
/// translated.
@Suite
struct StringCatalogTests {

    private static let catalog: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoxOS/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = json["strings"] as? [String: Any]
        else { return [:] }
        return strings
    }()

    private static func languages(of key: String) -> Set<String> {
        let entry = catalog[key] as? [String: Any]
        return Set((entry?["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    @Test func theCatalogWasFound() {
        #expect(Self.catalog.count > 1000)
    }

    @Test func everyStringInUseIsInGermanAndChinese() {
        let untranslated = Self.catalog.compactMap { key, value -> String? in
            guard let entry = value as? [String: Any], !key.trimmingCharacters(in: .whitespaces).isEmpty,
                entry["shouldTranslate"] as? Bool != false, entry["extractionState"] as? String != "stale"
            else { return nil }
            return Self.languages(of: key).isSuperset(of: ["de", "zh-Hans"]) ? nil : key
        }
        #expect(untranslated.isEmpty, "Untranslated: \(untranslated.sorted().prefix(10))")
    }

    @Test(arguments: SettingsSection.allCases)
    func everySettingsLabelIsInTheCatalog(_ section: SettingsSection) {
        for label in section.labels {
            // A label with a value in it is a format key: "Show Windows with %@ Tab".
            let found = Self.catalog[label] != nil || Self.catalog.keys.contains { $0.hasPrefix(label + " %") }
            #expect(found, "“\(label)” in \(section) is not in the string catalog; run make strings")
        }
    }
}
