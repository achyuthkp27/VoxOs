import Foundation
import Testing

@testable import VoxOS

/// Pure-logic checks for the launch/maintenance fixes: backup merge, the install-path test,
/// the onboarding reset backup, and the Sparkle configuration gate.
struct MaintenanceFixesTests {

    private struct Item: Identifiable, Equatable {
        let id: Int
        let name: String
    }

    @Test func backupMergeKeepsExistingAndAddsOnlyNewIds() {
        let existing = [Item(id: 1, name: "one"), Item(id: 2, name: "two")]
        let imported = [Item(id: 2, name: "two (import)"), Item(id: 3, name: "three"), Item(id: 3, name: "dup")]

        let merge = BackupImporter.merging(existing, with: imported)

        #expect(merge.merged == existing + [Item(id: 3, name: "three")], "existing items win; import de-duplicated")
        #expect(merge.added == [Item(id: 3, name: "three")])
    }

    @Test func backupMergeWithNothingExistingTakesTheImport() {
        let imported = [Item(id: 7, name: "seven")]
        let merge = BackupImporter.merging([Item](), with: imported)
        #expect(merge.merged == imported)
        #expect(merge.added == imported)
    }

    @Test func installedPathIsAPrefixTestNotASubstringTest() {
        let home = "/Users/me"
        #expect(LaunchAtLoginManager.isInstalledPath("/Applications/VoxOS.app", homeDirectory: home))
        #expect(LaunchAtLoginManager.isInstalledPath("/Users/me/Applications/VoxOS.app", homeDirectory: home))
        #expect(
            !LaunchAtLoginManager.isInstalledPath(
                "/Users/me/Library/Developer/Xcode/DerivedData/Applications/VoxOS.app", homeDirectory: home))
        #expect(
            !LaunchAtLoginManager.isInstalledPath("/Users/me/Downloads/Applications/VoxOS.app", homeDirectory: home))
        #expect(!LaunchAtLoginManager.isInstalledPath("/Applications-old/VoxOS.app", homeDirectory: home))
    }

    @Test func onboardingResetBacksUpValuesBeforeTheyAreCleared() throws {
        let suiteName = "MaintenanceFixesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payload = Data("modes".utf8)
        defaults.set(payload, forKey: "modeConfigurationsV2")

        #expect(OnboardingV2Migration.backUpValue(forKey: "modeConfigurationsV2", defaults: defaults) == 1)
        #expect(OnboardingV2Migration.backUpValue(forKey: "missingKey", defaults: defaults) == 0)
        #expect(defaults.data(forKey: "modeConfigurationsV2" + OnboardingV2Migration.backupKeySuffix) == payload)
        #expect(defaults.object(forKey: "missingKey" + OnboardingV2Migration.backupKeySuffix) == nil)
    }

    @Test func sparkleIsConfiguredOnlyWithBothKeys() {
        #expect(UpdaterViewModel.hasFeedConfiguration(feedURL: "https://example.com/appcast.xml", publicKey: "abc="))
        #expect(!UpdaterViewModel.hasFeedConfiguration(feedURL: nil, publicKey: "abc="))
        #expect(!UpdaterViewModel.hasFeedConfiguration(feedURL: "https://example.com/appcast.xml", publicKey: nil))
        #expect(!UpdaterViewModel.hasFeedConfiguration(feedURL: "https://example.com/appcast.xml", publicKey: "  "))
        #expect(!UpdaterViewModel.hasFeedConfiguration(feedURL: "not a url", publicKey: "abc="))
    }
}
