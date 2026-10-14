import Testing

@testable import VoxOS

/// Which Dictionary words reach the acoustic boost: short words misfire on common speech and
/// very long lists slow rescoring, so both are filtered before FluidAudio sees them.
@Suite
struct VocabularyBoostTermsTests {

    @Test func shortWordsAndDuplicatesAreDropped() {
        let terms = FluidAudioVocabularyBoost.boostTerms(from: ["Ollama", " ollama ", "AI", "VR", "Tumkur", "gemma4"])
        #expect(terms == ["Ollama", "Tumkur", "gemma4"])
    }

    @Test func listIsCapped() {
        let words = (0..<500).map { "term\($0)" }
        #expect(FluidAudioVocabularyBoost.boostTerms(from: words).count == FluidAudioVocabularyBoost.maxTerms)
    }

    @Test func emptyDictionaryMeansNoBoost() async {
        #expect(FluidAudioVocabularyBoost.boostTerms(from: []).isEmpty)
        #expect(await FluidAudioVocabularyBoost.shared.modelsIfReady(for: []) == nil)
    }
}
