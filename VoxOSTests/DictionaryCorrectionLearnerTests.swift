import Foundation
import Testing

@testable import VoxOS

/// The learner writes into the dictionary, which silently rewrites every future transcription.
/// These checks are mostly about what it must refuse to learn.
@Suite
struct DictionaryCorrectionLearnerTests {

    private func pair(_ original: String, _ enhanced: String) -> (original: String, enhanced: String) {
        (original: original, enhanced: enhanced)
    }

    @Test func aRepeatedCorrectionIsSuggested() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: [
                pair("we use kubernets here", "we use Kubernetes here"),
                pair("kubernets is hard", "Kubernetes is hard"),
                pair("deploy to kubernets now", "deploy to Kubernetes now"),
            ],
            minimumOccurrences: 3)

        #expect(candidates.count == 1)
        #expect(candidates.first?.original == "kubernets")
        #expect(candidates.first?.replacement == "Kubernetes")
        #expect(candidates.first?.occurrences == 3)
    }

    @Test func aOneOffCorrectionIsNotSuggested() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: [pair("we use kubernets here", "we use Kubernetes here")],
            minimumOccurrences: 3)
        #expect(candidates.isEmpty)
    }

    @Test func caseOnlyFixesAreGrammarNotVocabulary() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(repeating: pair("i went home", "I went home"), count: 5),
            minimumOccurrences: 2)
        #expect(candidates.isEmpty)
    }

    @Test func wordsAlreadyInTheDictionaryAreNotSuggestedAgain() {
        let transcripts = Array(repeating: pair("use kubernets", "use Kubernetes"), count: 4)

        #expect(
            DictionaryCorrectionLearner.candidates(
                from: transcripts, knownOriginals: ["kubernets"], minimumOccurrences: 2
            ).isEmpty)

        // Matching is case-insensitive, or the same word reappears under a different casing.
        #expect(
            DictionaryCorrectionLearner.candidates(
                from: transcripts, knownOriginals: ["KUBERNETS"], minimumOccurrences: 2
            ).isEmpty)
    }

    @Test func rewrittenSentencesTeachNothing() {
        // The two sides changed a different number of times, so no edit can be paired safely.
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(
                repeating: pair("um so i guess we should maybe go", "We should go."),
                count: 5),
            minimumOccurrences: 2)
        #expect(candidates.isEmpty)
    }

    @Test func multiWordEditsAreNotDictionaryEntries() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(repeating: pair("the cat sat", "the large dog sat"), count: 5),
            minimumOccurrences: 2)
        #expect(candidates.isEmpty)
    }

    @Test func pureNumbersAreValuesNotVocabulary() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(repeating: pair("we need 15 items", "we need 50 items"), count: 5),
            minimumOccurrences: 2)
        #expect(candidates.isEmpty)
    }

    @Test func unchangedTranscriptsProduceNothing() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(repeating: pair("nothing changed here", "nothing changed here"), count: 5),
            minimumOccurrences: 1)
        #expect(candidates.isEmpty)
    }

    @Test func mostFrequentCandidateComesFirst() {
        var transcripts = Array(repeating: pair("use kubernets", "use Kubernetes"), count: 5)
        transcripts += Array(repeating: pair("run postgres", "run PostgreSQL"), count: 2)

        let candidates = DictionaryCorrectionLearner.candidates(from: transcripts, minimumOccurrences: 2)
        #expect(candidates.map(\.original) == ["kubernets", "postgres"])
    }

    @Test func hyphenatedWordsAreLearnedPerPart() {
        // The diff tokenises "postgres-db" as postgres, -, db, so a correction to one part is
        // learned on its own. That is the useful behaviour: "postgres" is the misheard word and
        // the entry should apply wherever it appears, not only before a hyphen.
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(repeating: pair("the postgres-db is slow", "the PostgreSQL-db is slow"), count: 3),
            minimumOccurrences: 3)
        #expect(candidates.first?.original == "postgres")
        #expect(candidates.first?.replacement == "PostgreSQL")
    }

    @Test func anAcronymThatIsNotMerelyRecasedIsLearned() {
        let candidates = DictionaryCorrectionLearner.candidates(
            from: Array(repeating: pair("write it in sequel", "write it in SQL"), count: 3),
            minimumOccurrences: 3)
        #expect(candidates.first?.original == "sequel")
        #expect(candidates.first?.replacement == "SQL")
    }
}
