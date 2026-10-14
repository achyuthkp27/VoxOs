import SwiftData
import SwiftUI

enum VocabularySortMode: String {
    case wordAsc = "wordAsc"
    case wordDesc = "wordDesc"
}

struct VocabularyView: View {
    @Query private var vocabularyWords: [VocabularyWord]
    @Environment(\.modelContext) private var modelContext
    @State private var newWord = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var sortMode: VocabularySortMode = .wordAsc

    init() {
        if let savedSort = UserDefaults.standard.string(forKey: DefaultsKeys.vocabularySortMode),
            let mode = VocabularySortMode(rawValue: savedSort)
        {
            _sortMode = State(initialValue: mode)
        }
    }

    private var sortedItems: [VocabularyWord] {
        switch sortMode {
        case .wordAsc:
            return vocabularyWords.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        case .wordDesc:
            return vocabularyWords.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedDescending }
        }
    }

    private func toggleSort() {
        sortMode = (sortMode == .wordAsc) ? .wordDesc : .wordAsc
        UserDefaults.standard.set(sortMode.rawValue, forKey: DefaultsKeys.vocabularySortMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DictionaryComposer(canAdd: !trimmedNewWord.isEmpty, addTitle: "Add", onAdd: addWords) {
                DictionaryComposerField(
                    prompt: "Add a name, product or place — commas add several", text: $newWord,
                    onSubmit: addWords)
            }

            if vocabularyWords.isEmpty {
                DictionaryEmptyState(
                    title: "Teach VoxOS the words it gets wrong",
                    detail:
                        "Names, products and places it mishears. Add each once in its correct spelling — VoxOS listens for it and writes it your way, however it was heard.",
                    examples: ["Ollama", "Tumkur", "Kubernetes"])
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DictionaryListHeader(
                        title: vocabularyWords.count == 1
                            ? String(localized: "1 word") : String(localized: "\(vocabularyWords.count) words"),
                        sortLabel: sortMode == .wordAsc ? String(localized: "A–Z") : String(localized: "Z–A"),
                        onToggleSort: toggleSort)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                        ForEach(sortedItems) { item in
                            VocabularyWordTile(item: item) { removeWord(item) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Vocabulary", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var trimmedNewWord: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addWords() {
        let input = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let error = DictionaryService.addVocabularyWords(
            input, existing: Array(vocabularyWords), context: modelContext)
        {
            alertMessage = error
            showAlert = true
            return
        }
        newWord = ""
    }

    private func removeWord(_ word: VocabularyWord) {
        modelContext.delete(word)

        do {
            try modelContext.save()
        } catch {
            // Rollback the delete to restore UI consistency
            modelContext.rollback()
            alertMessage = String(format: String(localized: "Failed to remove word: %@"), error.localizedDescription)
            showAlert = true
        }
    }
}

/// One vocabulary word, with what VoxOS does with it. Words of four or more letters are listened
/// for by local Parakeet as well as given to AI cleanup; shorter ones misfire on everyday speech,
/// so they only reach AI cleanup — the tile says which, rather than leaving it to guesswork.
struct VocabularyWordTile: View {
    let item: VocabularyWord
    let onDelete: () -> Void
    @State private var isHovered = false

    private var isListenedFor: Bool {
        !FluidAudioVocabularyBoost.boostTerms(from: [item.word]).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.word)
                    .font(.app(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.word)

                Label {
                    Text(isListenedFor ? "Listened for" : "AI cleanup only")
                } icon: {
                    Image(systemName: isListenedFor ? "waveform" : "text.cursor")
                }
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(isListenedFor ? AppTheme.Accent.primary : AppTheme.Text.secondary)
                .help(
                    isListenedFor
                        ? "Local Parakeet listens for this word while you speak, and AI cleanup keeps its spelling."
                        : "Shorter than four letters, so only AI cleanup uses it — listening for very short words misfires on everyday speech."
                )
            }

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.app(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(AppTheme.Surface.controlActive))
            }
            .buttonStyle(.plain)
            .help("Remove \(item.word)")
            .opacity(isHovered ? 1 : 0)
            .accessibilityHidden(!isHovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? AppTheme.Surface.control : AppTheme.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.Border.card, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Remove \(item.word)", role: .destructive, action: onDelete)
        }
    }
}
