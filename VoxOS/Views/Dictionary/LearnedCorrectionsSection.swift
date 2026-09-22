import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "LearnedCorrections")

/// Offers dictionary entries for words AI enhancement keeps fixing the same way.
///
/// Nothing is added without a click. The suggestion is the feature — silently rewriting words
/// the user never approved is how a dictionary becomes something you have to go and audit.
struct LearnedCorrectionsSection: View {
    @Environment(\.modelContext) private var modelContext

    /// Existing entries, so a word that is already handled is never suggested again.
    let existingOriginals: [String]

    @State private var candidates: [DictionaryCorrectionLearner.Candidate] = []
    @State private var isScanning = false

    /// Candidates the user said no to. Kept out of the database so declining costs nothing and
    /// leaves no row behind; the id encodes both sides, so a different correction for the same
    /// word can still be offered later.
    @AppStorage(DefaultsKeys.dismissedCorrectionSuggestions) private var dismissedRaw = ""

    private var dismissed: Set<String> {
        Set(dismissedRaw.split(separator: "\u{001E}").map(String.init))
    }

    /// Enough history to see a pattern without turning opening the dictionary into a scan of
    /// everything ever recorded.
    private static let historyLimit = 200

    var body: some View {
        Group {
            if !visibleCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.app(size: 10, weight: .medium))
                        Text("Suggested from your corrections")
                            .font(.app(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(AppTheme.Text.secondary)

                    ForEach(visibleCandidates) { candidate in
                        row(candidate)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Surface.subtle)
                )
            }
        }
        // One task keyed on the inputs: a change cancels the scan in flight rather than being
        // dropped by it, so the list cannot go stale after an Add.
        .task(id: existingOriginals) { await scan() }
    }

    private var visibleCandidates: [DictionaryCorrectionLearner.Candidate] {
        candidates.filter { !dismissed.contains($0.id) }
    }

    private func row(_ candidate: DictionaryCorrectionLearner.Candidate) -> some View {
        HStack(spacing: 8) {
            Text(candidate.original)
                .font(.app(size: 12, weight: .regular))
                .foregroundColor(AppTheme.Text.primary)

            Image(systemName: "arrow.right")
                .font(.app(size: 9, weight: .regular))
                .foregroundColor(AppTheme.Text.muted)

            Text(candidate.replacement)
                .font(.app(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Text.primary)

            Text(
                String(
                    format: String(localized: "corrected %d times"),
                    candidate.occurrences)
            )
            .font(.app(size: 10, weight: .regular))
            .foregroundColor(AppTheme.Text.muted)

            Spacer()

            Button(String(localized: "Add")) { add(candidate) }
                .buttonStyle(.borderless)
                .font(.app(size: 11, weight: .medium))
                .help(String(localized: "Add this to your word replacements"))

            Button {
                dismiss(candidate)
            } label: {
                Image(systemName: "xmark")
                    .font(.app(size: 9, weight: .medium))
                    .foregroundColor(AppTheme.Text.muted)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Don't suggest this again"))
        }
    }

    private func add(_ candidate: DictionaryCorrectionLearner.Candidate) {
        modelContext.insert(
            WordReplacement(originalText: candidate.original, replacementText: candidate.replacement))
        do {
            try modelContext.save()
        } catch {
            logger.error("Could not save learned correction: \(error, privacy: .public)")
            return
        }
        candidates.removeAll { $0.id == candidate.id }
    }

    private func dismiss(_ candidate: DictionaryCorrectionLearner.Candidate) {
        var updated = dismissed
        updated.insert(candidate.id)
        dismissedRaw = updated.joined(separator: "\u{001E}")
    }

    /// Diffing a few hundred transcriptions is not free, so it happens off the main actor and
    /// only when this view appears rather than on every keystroke in the dictionary.
    @MainActor
    private func scan() async {
        isScanning = true
        defer { isScanning = false }

        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { $0.enhancedText != nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.historyLimit

        let pairs: [(original: String, enhanced: String)]
        do {
            pairs = try modelContext.fetch(descriptor).compactMap { transcription in
                guard let enhanced = transcription.enhancedText, !enhanced.isEmpty else { return nil }
                return (original: transcription.text, enhanced: enhanced)
            }
        } catch {
            logger.error("Could not read history for correction suggestions: \(error, privacy: .public)")
            return
        }

        let known = Set(existingOriginals)
        let found = await Task.detached(priority: .utility) {
            DictionaryCorrectionLearner.candidates(from: pairs, knownOriginals: known)
        }.value

        guard !Task.isCancelled else { return }
        candidates = found
    }
}
