import Combine
import Foundation

/// A dictation that is an instruction to VoxOS rather than text to paste. Only a whole
/// dictation counts, so "scratch that" inside a sentence is still written down.
enum SpokenCommand: Equatable {
    /// "Scratch that": take back the text VoxOS just pasted.
    case undoLastPaste
    /// A snippet's trigger: paste the snippet's text exactly as saved.
    case snippet(String)

    /// Phrases that undo the last paste, in English and in the app's language.
    static var undoPhrases: [String] {
        let english = ["scratch that", "undo that"]
        let translated = [String(localized: "scratch that"), String(localized: "undo that")]
        return Array(Set((english + translated).map(normalized)))
    }

    /// What `text` asks for, if it is a command. A snippet whose trigger is also an undo phrase
    /// is a snippet: the user saved it on purpose.
    static func interpret(_ text: String, snippets: [String: String], undoPhrases: [String] = undoPhrases)
        -> SpokenCommand?
    {
        let spoken = normalized(text)
        guard !spoken.isEmpty else { return nil }
        if let body = snippets.first(where: { normalized($0.key) == spoken })?.value,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .snippet(body)
        }
        return undoPhrases.contains(spoken) ? .undoLastPaste : nil
    }

    /// Lowercased words without punctuation, single-spaced: how a transcript and a trigger are
    /// compared, since a model may write "Scratch that." or "my  address!".
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

/// Saved text pasted when its trigger is the whole dictation: "my address" pastes the address.
/// Kept in defaults as trigger to text, so a backup carries it with the other settings.
@MainActor
final class VoiceSnippetStore: ObservableObject {
    static let shared = VoiceSnippetStore()

    @Published private(set) var snippets: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snippets = Self.all(defaults)
    }

    /// The saved snippets, trigger to text.
    nonisolated static func all(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: DefaultsKeys.voiceSnippets) as? [String: String] ?? [:]
    }

    /// Why `trigger` cannot be saved, or nil when it can. `replacing` is the trigger being edited.
    func problem(saving trigger: String, text: String, replacing old: String? = nil) -> String? {
        let spoken = SpokenCommand.normalized(trigger)
        if spoken.isEmpty { return String(localized: "Say something to trigger the snippet.") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Write the text the snippet pastes.")
        }
        let clash = snippets.keys.first { $0 != old && SpokenCommand.normalized($0) == spoken }
        if let clash { return String(localized: "“\(clash)” already pastes a snippet.") }
        return nil
    }

    /// Saves the snippet, replacing `old` when editing one. Returns why it was not saved, if not.
    @discardableResult
    func save(trigger: String, text: String, replacing old: String? = nil) -> String? {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = problem(saving: trigger, text: text, replacing: old) { return problem }
        if let old { snippets.removeValue(forKey: old) }
        snippets[trigger] = text
        persist()
        return nil
    }

    func remove(_ trigger: String) {
        snippets.removeValue(forKey: trigger)
        persist()
    }

    /// Picks up snippets a backup import wrote.
    func reload() {
        snippets = Self.all(defaults)
    }

    private func persist() {
        defaults.set(snippets, forKey: DefaultsKeys.voiceSnippets)
    }
}
