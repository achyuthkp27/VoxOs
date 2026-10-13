import AppKit
import Foundation
import Testing

@testable import VoxOS

/// Onboarding installs the Email starter mode before the installed-app scan has finished, so the
/// mail apps are added to its trigger group afterwards. These pin when that top-up happens.
struct StarterModeEmailTriggerTests {

    private func app(_ bundleId: String, _ name: String) -> InstalledAppInfo {
        (url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleId: bundleId, icon: NSImage())
    }

    private var websitesOnlyEmailGroup: ModeTriggerGroup {
        ModeTriggerGroup(templateId: "email", name: "Email", urlConfigs: [URLConfig(url: "mail.google.com")])
    }

    private func cleanURL(_ url: String) -> String { url }

    @Test func fillsInstalledMailAppsIntoAnAppLessEmailGroup() {
        let groups = StarterModeFactory.emailTriggerGroupsAddingApps(
            to: [websitesOnlyEmailGroup],
            installedApps: [app("com.apple.mail", "Mail"), app("com.apple.Safari", "Safari")],
            existingAppBundleIds: [],
            cleanURL: cleanURL
        )

        #expect(groups?.count == 1)
        #expect(groups?.first?.appConfigs.map(\.bundleIdentifier) == ["com.apple.mail"])
        #expect(groups?.first?.urlConfigs.count == 1, "the websites the group already had are kept")
    }

    @Test func leavesAGroupTheUserHasGivenAppsAlone() {
        var group = websitesOnlyEmailGroup
        group.appConfigs = [AppConfig(bundleIdentifier: "org.mozilla.thunderbird", appName: "Thunderbird")]

        let groups = StarterModeFactory.emailTriggerGroupsAddingApps(
            to: [group],
            installedApps: [app("com.apple.mail", "Mail")],
            existingAppBundleIds: ["org.mozilla.thunderbird"],
            cleanURL: cleanURL
        )

        #expect(groups == nil)
    }

    @Test func nothingToAddWhenNoMailAppIsInstalledOrTheScanIsEmpty() {
        #expect(
            StarterModeFactory.emailTriggerGroupsAddingApps(
                to: [websitesOnlyEmailGroup], installedApps: [], existingAppBundleIds: [], cleanURL: cleanURL)
                == nil)
        #expect(
            StarterModeFactory.emailTriggerGroupsAddingApps(
                to: [websitesOnlyEmailGroup], installedApps: [app("com.apple.Safari", "Safari")],
                existingAppBundleIds: [], cleanURL: cleanURL)
                == nil)
        #expect(
            StarterModeFactory.emailTriggerGroupsAddingApps(
                to: [], installedApps: [app("com.apple.mail", "Mail")], existingAppBundleIds: [], cleanURL: cleanURL)
                == nil, "a mode whose email group was removed is not given a new one")
    }

    @Test func skipsAppsAnotherGroupAlreadyTriggersOn() {
        let groups = StarterModeFactory.emailTriggerGroupsAddingApps(
            to: [websitesOnlyEmailGroup],
            installedApps: [app("com.apple.mail", "Mail")],
            existingAppBundleIds: ["com.apple.mail"],
            cleanURL: cleanURL
        )

        #expect(groups == nil)
    }
}
