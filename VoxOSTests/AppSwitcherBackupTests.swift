import Foundation
import Testing

@testable import VoxOS

/// The app switcher's settings in a backup: saved, read back, and missing from older backups.
@Suite
struct AppSwitcherBackupTests {
    @Test func theSettingsComeBackAsTheyWere() throws {
        let name = "AppSwitcherBackupTests.\(UUID().uuidString)"
        let source = try #require(UserDefaults(suiteName: name))
        defer { source.removePersistentDomain(forName: name) }
        source.set(true, forKey: DefaultsKeys.appSwitcherEnabled)
        source.set("rightOption", forKey: DefaultsKeys.appSwitcherTrigger)
        source.set(["m": "com.apple.mail"], forKey: DefaultsKeys.appSwitcherLetters)
        source.set(false, forKey: DefaultsKeys.windowSwitcherEnabled)
        source.set(["com.parallels.desktop.console"], forKey: DefaultsKeys.appSwitcherIgnoredApps)
        source.set(false, forKey: DefaultsKeys.appSwitcherSameLetterHides)

        let data = try JSONEncoder().encode(AppSwitcherBackup.current(source))
        let backup = try JSONDecoder().decode(AppSwitcherBackup.self, from: data)

        let targetName = "\(name).target"
        let target = try #require(UserDefaults(suiteName: targetName))
        defer { target.removePersistentDomain(forName: targetName) }
        backup.apply(to: target)
        #expect(target.bool(forKey: DefaultsKeys.appSwitcherEnabled))
        #expect(target.string(forKey: DefaultsKeys.appSwitcherTrigger) == "rightOption")
        #expect(
            target.dictionary(forKey: DefaultsKeys.appSwitcherLetters) as? [String: String] == ["m": "com.apple.mail"])
        #expect(target.object(forKey: DefaultsKeys.windowSwitcherEnabled) as? Bool == false)
        #expect(target.stringArray(forKey: DefaultsKeys.appSwitcherIgnoredApps) == ["com.parallels.desktop.console"])
        #expect(target.object(forKey: DefaultsKeys.appSwitcherSameLetterHides) as? Bool == false)
        #expect(target.object(forKey: DefaultsKeys.appSwitcherShowsLetters) == nil, "never set, so left alone")
    }

    @Test func lettersOutsideAToZAreNotRestored() throws {
        let name = "AppSwitcherBackupTests.\(UUID().uuidString)"
        let target = try #require(UserDefaults(suiteName: name))
        defer { target.removePersistentDomain(forName: name) }
        let backup = AppSwitcherBackup(
            isEnabled: nil, trigger: "nonsense", letters: ["ы": "com.apple.mail", "s": "com.apple.Safari"],
            isWindowSwitcherEnabled: nil, ignoredApps: nil, sameLetterHides: nil, showsLetters: nil)
        backup.apply(to: target)
        #expect(
            target.dictionary(forKey: DefaultsKeys.appSwitcherLetters) as? [String: String] == ["s": "com.apple.Safari"]
        )
        #expect(target.string(forKey: DefaultsKeys.appSwitcherTrigger) == nil, "an unknown key is not set")
    }

    @Test func anOlderBackupWithoutTheSwitcherStillReads() throws {
        let json = #"{"restoreClipboardAfterPaste": true}"#
        let general = try JSONDecoder().decode(GeneralBackup.self, from: Data(json.utf8))
        #expect(general.appSwitcher == nil)
        #expect(general.restoreClipboardAfterPaste == true)
    }
}
