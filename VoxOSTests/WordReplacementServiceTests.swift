import Foundation
import SwiftData
import Testing

@testable import VoxOS

/// Replacements are spliced in verbatim, in one pass over the original text.
@MainActor
struct WordReplacementServiceTests {
    private func context(_ rules: [(String, String)]) throws -> ModelContext {
        let container = try ModelContainer(
            for: WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for (original, replacement) in rules {
            context.insert(WordReplacement(originalText: original, replacementText: replacement))
        }
        try context.save()
        return context
    }

    @Test func dollarSignsAndBackslashesSurviveVerbatim() throws {
        let context = try context([("price", "$100"), ("path", "C:\\Users\\me")])
        let result = WordReplacementService.shared.applyReplacements(to: "the price and the path", using: context)
        #expect(result == "the $100 and the C:\\Users\\me")
    }

    @Test func rulesDoNotRescanEachOthersOutput() throws {
        let context = try context([("a", "b"), ("b", "c")])
        let result = WordReplacementService.shared.applyReplacements(to: "a b", using: context)
        #expect(result == "b c")
    }

    @Test func longestTriggerWinsAcrossGroups() throws {
        let context = try context([("hi, there", "hello"), ("hi there", "greeting")])
        let result = WordReplacementService.shared.applyReplacements(to: "hi there", using: context)
        #expect(result == "greeting")
    }

    @Test func triggersAreCaseInsensitiveAndWordBounded() throws {
        let context = try context([("vox", "VoxOS")])
        let result = WordReplacementService.shared.applyReplacements(to: "Vox, voxel", using: context)
        #expect(result == "VoxOS, voxel")
    }
}
