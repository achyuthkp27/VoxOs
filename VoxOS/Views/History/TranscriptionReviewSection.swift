import SwiftData
import SwiftUI

/// History → Review: the words VoxOS probably misheard in this dictation, and a one-click way
/// to stop it happening again. Suggestions come from the cleaned-up text, or from the user's
/// own edit when they correct the text to what they meant. Nothing is added without a click.
struct TranscriptionReviewSection: View {
    @Bindable var transcription: Transcription
    @Environment(\.modelContext) private var modelContext
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var wordReplacements: [WordReplacement]

    @State private var isEditing = false
    @State private var draft = ""
    @State private var message: String?
    @AppStorage(DefaultsKeys.dismissedReviewSuggestions) private var dismissedRaw = ""

    /// The cleaned-up text, or the user's correction once they have saved one.
    private var correctedText: String? {
        transcription.enhancedText
    }

    private var dismissed: Set<String> {
        Set(dismissedRaw.split(separator: "\u{1E}").map(String.init))
    }

    /// Suggestions not yet handled: dismissed ones, words already in Vocabulary and phrases
    /// already replaced are left out, so the list only ever holds open questions.
    private var suggestions: [TranscriptionReview.Correction] {
        guard let correctedText else { return [] }
        let vocabulary = Set(vocabularyWords.map { $0.word.lowercased() })
        let replaced = Set(
            wordReplacements.flatMap { $0.originalText.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return TranscriptionReview.corrections(heard: transcription.text, written: correctedText).filter {
            !dismissed.contains($0.id) && !vocabulary.contains($0.written.lowercased())
                && !replaced.contains($0.heard.lowercased())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
                Button {
                    draft = correctedText ?? transcription.text
                    isEditing = true
                } label: {
                    Label("Correct the text", systemImage: "pencil")
                        .font(.app(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Change the text to what you meant; VoxOS then suggests what to learn from it")
            }

            if suggestions.isEmpty {
                Text(
                    correctedText == nil
                        ? "Nothing to review. Correct the text to what you meant, and VoxOS suggests which words to learn."
                        : "No misheard words found. If something is still wrong, correct the text."
                )
                .font(.app(size: 12, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
            } else {
                Text("Probably misheard. Teach VoxOS so it hears these right next time:")
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                VStack(spacing: 0) {
                    ForEach(suggestions) { correction in
                        row(correction)
                        if correction.id != suggestions.last?.id { Divider().opacity(0.5) }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.Surface.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.Border.card, lineWidth: 1)
                )
            }

            if let message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.app(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Status.success)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $isEditing) { editor }
    }

    private func row(_ correction: TranscriptionReview.Correction) -> some View {
        HStack(spacing: 10) {
            Text(correction.heard)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .strikethrough(color: AppTheme.Text.muted)
            Image(systemName: "arrow.right")
                .font(.app(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.Text.muted)
            Text(correction.written)
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
            Spacer(minLength: 8)
            Button("Add to Vocabulary") { addToVocabulary(correction) }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Accent.primary)
                .controlSize(.small)
                .help("VoxOS listens for “\(correction.written)” from now on, however it is heard")
            Button("Always replace") { addReplacement(correction) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Swap “\(correction.heard)” for “\(correction.written)” in every transcription")
            Button {
                dismiss(correction)
            } label: {
                Image(systemName: "xmark")
                    .font(.app(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
            .buttonStyle(.borderless)
            .help("Not a mishearing — don't suggest this again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct the text")
                .font(.app(size: 14, weight: .semibold))
            Text(
                "Change it to exactly what you meant. VoxOS saves your version and suggests the words to learn."
            )
            .font(.app(size: 12, weight: .regular))
            .foregroundStyle(AppTheme.Text.secondary)
            TextEditor(text: $draft)
                .font(.app(size: 13, weight: .regular))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.Surface.subtle))
                .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveCorrection() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Accent.primary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func saveCorrection() {
        transcription.enhancedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        isEditing = false
    }

    private func addToVocabulary(_ correction: TranscriptionReview.Correction) {
        report(
            DictionaryService.addVocabularyWords(
                correction.written, existing: Array(vocabularyWords), context: modelContext),
            success: "“\(correction.written)” added to Vocabulary")
    }

    private func addReplacement(_ correction: TranscriptionReview.Correction) {
        report(
            DictionaryService.addWordReplacement(
                original: correction.heard, replacement: correction.written,
                existing: Array(wordReplacements), context: modelContext),
            success: "“\(correction.heard)” → “\(correction.written)” added to Replacements")
    }

    private func dismiss(_ correction: TranscriptionReview.Correction) {
        dismissedRaw = (dismissed.union([correction.id])).sorted().joined(separator: "\u{1E}")
    }

    private func report(_ error: String?, success: String) {
        withAnimation { message = error ?? success }
    }
}
