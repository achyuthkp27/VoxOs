import Foundation
import Testing

@testable import VoxOS

/// The remembered-keys line is re-sent on every agent step, so its size matters as much as its
/// contents. These cover the formatting and the caps without touching the real memory file.
@Suite
struct AgentMemoryPromptTests {

    @Test func nothingRememberedProducesNoLine() {
        #expect(AgentMemory.promptLine(from: []) == nil)
    }

    @Test func keysAreListedForRecall() {
        let line = AgentMemory.promptLine(from: ["office-wifi", "sister-name"])
        #expect(line?.contains("office-wifi") == true)
        #expect(line?.contains("sister-name") == true)
        // The line has to say what to do with them, or the agent has names and no verb.
        #expect(line?.contains("recall") == true)
    }

    @Test func theCountIsCapped() {
        let keys = (1...100).map { "key-\($0)" }
        let line = AgentMemory.promptLine(from: keys, limit: 5, maxLength: 10_000)
        #expect(line?.contains("key-1") == true)
        #expect(line?.contains("key-99") == false)
    }

    @Test func theLengthIsCappedEvenWhenTheCountIsNot() {
        // One user with very long keys must not cost every request a huge prompt.
        let keys = (1...20).map { _ in String(repeating: "x", count: 80) }
        let line = AgentMemory.promptLine(from: keys, limit: 20, maxLength: 200)
        #expect((line?.count ?? 0) < 400)
    }

    @Test func truncationIsStatedRatherThanSilent() {
        // The agent must know recall can reach keys it cannot see, or it will assume the list
        // is everything and stop looking.
        let keys = (1...50).map { "key-\($0)" }
        let line = AgentMemory.promptLine(from: keys, limit: 3, maxLength: 10_000)
        #expect(line?.contains("more") == true)
    }

    @Test func aCompleteListSaysNothingAboutMore() {
        let line = AgentMemory.promptLine(from: ["one", "two"], limit: 25, maxLength: 400)
        #expect(line?.contains("more") == false)
    }

    @Test func aSingleKeyTooLongForTheBudgetYieldsNoLine() {
        // Better no line at all than one that blows the budget it exists to respect.
        let line = AgentMemory.promptLine(
            from: [String(repeating: "y", count: 500)], limit: 25, maxLength: 100)
        #expect(line == nil)
    }
}
