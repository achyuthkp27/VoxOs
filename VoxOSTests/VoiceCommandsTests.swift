import Foundation
import Testing

@testable import VoxOS

/// "Scratch that" and voice snippets: only a whole dictation is a command, and an undo only
/// presses ⌘Z where it lands on the paste.
@Suite
struct SpokenCommandTests {

    private let english = ["scratch that", "undo that"]

    @Test func scratchThatOnItsOwnUndoes() {
        #expect(SpokenCommand.interpret("Scratch that.", snippets: [:], undoPhrases: english) == .undoLastPaste)
        #expect(SpokenCommand.interpret("undo that!", snippets: [:], undoPhrases: english) == .undoLastPaste)
    }

    @Test func scratchThatInsideASentenceIsWrittenDown() {
        #expect(SpokenCommand.interpret("Please scratch that idea.", snippets: [:], undoPhrases: english) == nil)
    }

    @Test func aSnippetsPhraseMatchesWhateverThePunctuationAndCase() {
        let snippets = ["my address": "12 MG Road\nBengaluru"]
        #expect(
            SpokenCommand.interpret("My address.", snippets: snippets, undoPhrases: english)
                == .snippet("12 MG Road\nBengaluru"))
        #expect(SpokenCommand.interpret("my  ADDRESS!", snippets: snippets, undoPhrases: english) != nil)
    }

    @Test func aSnippetsPhraseInsideASentenceIsWrittenDown() {
        let snippets = ["my address": "12 MG Road"]
        #expect(SpokenCommand.interpret("send it to my address", snippets: snippets, undoPhrases: english) == nil)
    }

    @Test func aSnippetSavedOnAnUndoPhraseWins() {
        let snippets = ["scratch that": "a deliberate snippet"]
        #expect(
            SpokenCommand.interpret("scratch that", snippets: snippets, undoPhrases: english)
                == .snippet("a deliberate snippet"))
    }

    @Test func anEmptySnippetIsIgnored() {
        #expect(SpokenCommand.interpret("my address", snippets: ["my address": "  "], undoPhrases: english) == nil)
    }

    @Test func normalizingKeepsOnlyWords() {
        #expect(SpokenCommand.normalized("  Scratch,   THAT!! ") == "scratch that")
        #expect(SpokenCommand.normalized("...") == "")
    }

    // MARK: - Undo

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func undoLandsOnARecentPasteInTheAppInFront() {
        #expect(PasteUndo.canUndo(pastedInto: 42, at: now.addingTimeInterval(-5), frontmost: 42, now: now))
    }

    @Test func undoWaitsWhenAnotherAppIsInFront() {
        #expect(!PasteUndo.canUndo(pastedInto: 42, at: now.addingTimeInterval(-5), frontmost: 7, now: now))
    }

    @Test func undoGivesUpOnAnOldPaste() {
        let old = now.addingTimeInterval(-(PasteUndo.window + 1))
        #expect(!PasteUndo.canUndo(pastedInto: 42, at: old, frontmost: 42, now: now))
    }

    @Test func undoNeedsAPaste() {
        #expect(!PasteUndo.canUndo(pastedInto: nil, at: nil, frontmost: 42, now: now))
    }
}

@MainActor
@Suite
struct VoiceSnippetStoreTests {

    private func store() -> (VoiceSnippetStore, UserDefaults, String) {
        let name = "VoiceSnippetStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (VoiceSnippetStore(defaults: defaults), defaults, name)
    }

    @Test func aSavedSnippetIsKeptInDefaults() {
        let (store, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(store.save(trigger: " my address ", text: "12 MG Road") == nil)

        #expect(VoiceSnippetStore.all(defaults) == ["my address": "12 MG Road"])
        #expect(VoiceSnippetStore(defaults: defaults).snippets == ["my address": "12 MG Road"])
    }

    @Test func twoSnippetsCannotShareAPhrase() {
        let (store, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }
        store.save(trigger: "my address", text: "12 MG Road")

        #expect(store.save(trigger: "My Address!", text: "somewhere else") != nil)
        #expect(store.snippets.count == 1)
    }

    @Test func editingCanKeepOrChangeThePhrase() {
        let (store, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }
        store.save(trigger: "my address", text: "12 MG Road")

        #expect(store.save(trigger: "my address", text: "14 MG Road", replacing: "my address") == nil)
        #expect(store.save(trigger: "home address", text: "14 MG Road", replacing: "my address") == nil)

        #expect(store.snippets == ["home address": "14 MG Road"])
    }

    @Test func aSnippetNeedsAPhraseAndText() {
        let (store, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(store.save(trigger: "!!", text: "text") != nil)
        #expect(store.save(trigger: "my address", text: "   ") != nil)
        #expect(store.snippets.isEmpty)
    }

    @Test func removingASnippetForgetsIt() {
        let (store, defaults, name) = store()
        defer { defaults.removePersistentDomain(forName: name) }
        store.save(trigger: "my address", text: "12 MG Road")

        store.remove("my address")

        #expect(VoiceSnippetStore.all(defaults).isEmpty)
    }
}
