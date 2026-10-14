import Testing

@testable import VoxOS

/// Review suggests only word mishearings: tidying (punctuation, capitals, dropped fillers) is
/// what cleanup is for, and offering it as "learn this" would bury the real corrections.
@Suite
struct TranscriptionReviewTests {

    @Test func misheardNamesAreFound() {
        let corrections = TranscriptionReview.corrections(
            heard: "open Ulama with gamma 4", written: "Open Ollama with gemma4.")
        #expect(corrections.map(\.heard) == ["Ulama", "gamma 4"])
        #expect(corrections.map(\.written) == ["Ollama", "gemma4"])
    }

    @Test func punctuationCapitalsAndFillersAreNotMishearings() {
        #expect(TranscriptionReview.corrections(heard: "hello how are you", written: "Hello, how are you?").isEmpty)
        #expect(TranscriptionReview.corrections(heard: "um so i think yes", written: "So I think yes.").isEmpty)
    }

    @Test func rewritesAreNotOfferedAsWords() {
        let corrections = TranscriptionReview.corrections(
            heard: "can you please maybe send it over to him today",
            written: "Please email the signed contract to Ravi before the end of the day.")
        #expect(corrections.allSatisfy { $0.heard.split(separator: " ").count <= TranscriptionReview.maxWordsPerSide })
    }

    @Test func eachCorrectionIsOfferedOnce() {
        let corrections = TranscriptionReview.corrections(
            heard: "Ulama is good and Ulama is fast", written: "Ollama is good and Ollama is fast")
        #expect(corrections.count == 1)
    }
}
