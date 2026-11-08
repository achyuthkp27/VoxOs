import Foundation
import Testing

@testable import VoxOS

/// A backup should bring back a whole setup. These keep every setting on one of the backup's
/// lists, and check a backup survives the trip through its JSON file with each value's type.
@Suite
struct PreferencesBackupTests {

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ path: String) -> String {
        (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    private static let backupSource = source("VoxOS/Services/PreferencesBackup.swift")

    /// Written as a whole list entry, so `notchMusic` is not found inside `notchMusicBarsEnabled`.
    private static func isListed(_ symbol: String) -> Bool {
        [",", "\n", "]"].contains { backupSource.contains(symbol + $0) }
    }

    @Test func theSourcesWereFound() {
        #expect(Self.backupSource.contains("struct PreferencesBackup"))
        #expect(Self.source("VoxOS/DefaultsKeys.swift").contains("enum DefaultsKeys"))
    }

    @Test func everyDefaultsKeyIsBackedUpOrLeftOutOnPurpose() throws {
        let keys = try Self.source("VoxOS/DefaultsKeys.swift")
            .matches(of: Regex(#"static let (\w+)\s*="#))
            .map { String($0.output[1].substring ?? "") }
        #expect(keys.count > 50)
        for key in keys {
            #expect(Self.isListed("DefaultsKeys.\(key)"), "DefaultsKeys.\(key) is in none of PreferencesBackup's lists")
        }
    }

    @Test func everySettingAViewStoresIsBackedUpOrLeftOutOnPurpose() throws {
        let appFolder = Self.repo.appendingPathComponent("VoxOS")
        let files =
            FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var symbols = Set<String>()
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for match in text.matches(of: try Regex(#"@AppStorage\(([A-Za-z_][\w.]*)"#)) {
                symbols.insert(String(match.output[1].substring ?? ""))
            }
        }
        #expect(symbols.count > 30)
        for symbol in symbols {
            #expect(
                Self.backupSource.contains(symbol), "@AppStorage(\(symbol)) is in none of PreferencesBackup's lists")
        }
    }

    @Test func noKeyIsOnTwoLists() {
        let backedUp = Set(PreferencesBackup.keys)
        let elsewhere = Set(PreferencesBackup.coveredElsewhere)
        let excluded = Set(PreferencesBackup.excluded)
        #expect(backedUp.isDisjoint(with: elsewhere))
        #expect(backedUp.isDisjoint(with: excluded))
        #expect(elsewhere.isDisjoint(with: excluded))
    }

    // MARK: - The round trip

    private func roundTrip(_ backup: PreferencesBackup) throws -> PreferencesBackup {
        try JSONDecoder().decode(PreferencesBackup.self, from: JSONEncoder().encode(backup))
    }

    private func freshDefaults() -> (UserDefaults, String) {
        let name = "PreferencesBackupTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func eachKindOfValueComesBackAsItWas() throws {
        let set: [String: Any] = [
            DefaultsKeys.notchHomeEnabled: false,
            DefaultsKeys.shortEnhancementWordThreshold: Int(7),
            DefaultsKeys.enhancementTimeoutSeconds: Double(12.5),
            DefaultsKeys.notchMaterial: "solidBlack",
            DefaultsKeys.notchPageOrder: ["shelf", "music"],
        ]
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        _ = try roundTrip(PreferencesBackup.current(from: set)).apply(to: defaults)

        #expect(defaults.object(forKey: DefaultsKeys.notchHomeEnabled) as? Bool == false)
        #expect(defaults.object(forKey: DefaultsKeys.shortEnhancementWordThreshold) as? Int == 7)
        #expect(defaults.double(forKey: DefaultsKeys.enhancementTimeoutSeconds) == 12.5)
        #expect(defaults.string(forKey: DefaultsKeys.notchMaterial) == "solidBlack")
        #expect(defaults.stringArray(forKey: DefaultsKeys.notchPageOrder) == ["shelf", "music"])
    }

    @Test func aSwitchStaysASwitchAndNotANumber() throws {
        let backup = try roundTrip(PreferencesBackup.current(from: [DefaultsKeys.notchLyricsEnabled: true]))
        #expect(backup.values[DefaultsKeys.notchLyricsEnabled] == .bool(true))
    }

    @Test func settingsLeftOutAreNotExported() {
        let backup = PreferencesBackup.current(from: [
            DefaultsKeys.voxOSDeviceIdentifier: "device", DefaultsKeys.hasCompletedOnboardingV2: true,
            DefaultsKeys.claudeCodeEnabled: true, "SomethingElse": 1,
        ])
        #expect(backup.values.isEmpty)
    }

    @Test func masterSwitchesAreHandedBackNotWritten() throws {
        let backup = PreferencesBackup.current(from: [DefaultsKeys.notchMasterEnabled: false])
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let switches = backup.apply(to: defaults)

        #expect(switches == [DefaultsKeys.notchMasterEnabled: false])
        // Read what was saved: the suite also sees the defaults VoxOS registers at launch.
        #expect(defaults.persistentDomain(forName: name)?[DefaultsKeys.notchMasterEnabled] == nil)
    }

    @Test func aKeyThisVersionDoesNotKnowIsSkipped() throws {
        let fromNewerApp = PreferencesBackup(values: ["SomeFutureSetting": .bool(true)])
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        _ = fromNewerApp.apply(to: defaults)

        #expect(defaults.persistentDomain(forName: name)?["SomeFutureSetting"] == nil)
    }

    @Test func aBackupFromBeforePreferencesStillOpens() throws {
        let json = #"{"version":"1.0","generalSettings":{"isMenuBarOnly":true}}"#
        let backup = try JSONDecoder().decode(BackupFile.self, from: Data(json.utf8))
        #expect(backup.generalSettings?.isMenuBarOnly == true)
        #expect(backup.generalSettings?.preferences == nil)
    }
}
