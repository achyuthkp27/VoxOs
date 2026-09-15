import Foundation
import Testing

@testable import VoxOS

struct WritingStyleTests {

    @Test func classifiesAppsAndSites() {
        #expect(WritingDestination.classify(bundleID: "com.apple.mail", url: nil) == .email)
        #expect(WritingDestination.classify(bundleID: "com.tinyspeck.slackmacgap", url: nil) == .chat)
        #expect(WritingDestination.classify(bundleID: "com.googlecode.iterm2", url: nil) == .terminal)
        #expect(WritingDestination.classify(bundleID: "com.jetbrains.intellij", url: nil) == .code)
        #expect(WritingDestination.classify(bundleID: "com.example.unknown", url: nil) == .other)

        // In a browser the site decides, not the browser.
        #expect(WritingDestination.classify(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox") == .email)
        #expect(WritingDestination.classify(bundleID: "com.google.Chrome", url: "docs.google.com/document/d/1") == .document)
        #expect(WritingDestination.classify(bundleID: "com.apple.Safari", url: "https://www.notion.so/team/page") == .notes)
        #expect(WritingDestination.classify(bundleID: "com.apple.Safari", url: "https://chatgpt.com/c/123") == .aiChat)
        #expect(WritingDestination.classify(bundleID: "com.apple.Safari", url: "https://www.linkedin.com/messaging/thread/1") == .chat)
        #expect(WritingDestination.classify(bundleID: "com.apple.Safari", url: "https://www.linkedin.com/feed/") == .other)
        #expect(WritingDestination.classify(bundleID: "com.apple.Safari", url: "https://notgmail.com") == .other,
                "hosts match on whole labels only")
    }

    @Test func promptGuidanceNamesThePlaceAndRegister() {
        let slack = WritingDestination(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", host: nil, category: .chat)
        #expect(slack.promptGuidance?.contains("pasted into Slack: a chat message") == true)

        let gmail = WritingDestination(bundleID: "com.google.Chrome", appName: "Google Chrome", host: "mail.google.com", category: .email)
        #expect(gmail.promptGuidance?.contains("Google Chrome (mail.google.com): an email") == true)

        let other = WritingDestination(bundleID: "x", appName: "X", host: nil, category: .other)
        #expect(other.promptGuidance == nil)
    }

    @Test func chatDropsOnlyALoneTrailingPeriod() {
        let chat = WritingDestination.Category.chat
        #expect(WritingStyleFormatter.apply("Sounds good, see you at 5.", category: chat) == "Sounds good, see you at 5")
        #expect(WritingStyleFormatter.apply("Sounds good.", category: .email) == "Sounds good.", "email keeps punctuation")
        #expect(WritingStyleFormatter.apply("Done. I'll ship it tonight.", category: chat) == "Done. I'll ship it tonight.",
                "two sentences keep their periods")
        #expect(WritingStyleFormatter.apply("Wait for it...", category: chat) == "Wait for it...")
        #expect(WritingStyleFormatter.apply("Are you coming?", category: chat) == "Are you coming?")
        #expect(WritingStyleFormatter.apply("Bring chips, salsa, etc.", category: chat) == "Bring chips, salsa, etc.")
        #expect(WritingStyleFormatter.apply("First line.\nSecond line.", category: chat) == "First line.\nSecond line.")
        #expect(WritingStyleFormatter.apply("git status.", category: .terminal) == "git status")
        #expect(WritingStyleFormatter.apply(" ok. ", category: chat) == " ok ", "surrounding whitespace is preserved")
    }

    @Test func settingDefaultsToOn() {
        let key = WritingDestination.isEnabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { saved.map { UserDefaults.standard.set($0, forKey: key) } ?? UserDefaults.standard.removeObject(forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(WritingDestination.isEnabled)
        UserDefaults.standard.set(false, forKey: key)
        #expect(!WritingDestination.isEnabled)
    }
}
