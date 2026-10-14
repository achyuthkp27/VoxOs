import SwiftData
import SwiftUI

enum SortMode: String {
    case originalAsc = "originalAsc"
    case originalDesc = "originalDesc"
    case replacementAsc = "replacementAsc"
    case replacementDesc = "replacementDesc"
}

struct WordReplacementView: View {
    @Query private var wordReplacements: [WordReplacement]
    @Environment(\.modelContext) private var modelContext
    @State private var showAlert = false
    @State private var editingReplacement: WordReplacement? = nil
    @State private var alertMessage = ""
    @State private var sortMode: SortMode = .originalAsc
    @State private var originalWord = ""
    @State private var replacementWord = ""
    @State private var showInfoPopover = false

    init() {
        if let savedSort = UserDefaults.standard.string(forKey: DefaultsKeys.wordReplacementSortMode),
            let mode = SortMode(rawValue: savedSort)
        {
            _sortMode = State(initialValue: mode)
        }
    }

    private var sortedReplacements: [WordReplacement] {
        switch sortMode {
        case .originalAsc:
            return wordReplacements.sorted {
                $0.originalText.localizedCaseInsensitiveCompare($1.originalText) == .orderedAscending
            }
        case .originalDesc:
            return wordReplacements.sorted {
                $0.originalText.localizedCaseInsensitiveCompare($1.originalText) == .orderedDescending
            }
        case .replacementAsc:
            return wordReplacements.sorted {
                $0.replacementText.localizedCaseInsensitiveCompare($1.replacementText) == .orderedAscending
            }
        case .replacementDesc:
            return wordReplacements.sorted {
                $0.replacementText.localizedCaseInsensitiveCompare($1.replacementText) == .orderedDescending
            }
        }
    }

    private var canAdd: Bool {
        !originalWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replacementWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortLabel: String {
        switch sortMode {
        case .originalAsc: return String(localized: "Heard A–Z")
        case .originalDesc: return String(localized: "Heard Z–A")
        case .replacementAsc: return String(localized: "Written A–Z")
        case .replacementDesc: return String(localized: "Written Z–A")
        }
    }

    /// Cycles heard A–Z → Z–A → written A–Z → Z–A.
    private func cycleSort() {
        switch sortMode {
        case .originalAsc: sortMode = .originalDesc
        case .originalDesc: sortMode = .replacementAsc
        case .replacementAsc: sortMode = .replacementDesc
        case .replacementDesc: sortMode = .originalAsc
        }
        UserDefaults.standard.set(sortMode.rawValue, forKey: DefaultsKeys.wordReplacementSortMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DictionaryComposer(canAdd: canAdd, addTitle: "Add", onAdd: addReplacement) {
                DictionaryComposerField(prompt: "When VoxOS writes… (commas for several)", text: $originalWord)
                Image(systemName: "arrow.right")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.muted)
                DictionaryComposerField(prompt: "…write this instead", text: $replacementWord, onSubmit: addReplacement)
                Button {
                    showInfoPopover.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.Text.secondary)
                }
                .buttonStyle(.borderless)
                .help("Word replacement examples")
                .popover(isPresented: $showInfoPopover) {
                    WordReplacementInfoPopover()
                }
            }

            // Rows hold comma-separated trigger lists; the learner compares single triggers.
            LearnedCorrectionsSection(
                existingOriginals: wordReplacements.flatMap { replacement in
                    replacement.originalText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                })

            if wordReplacements.isEmpty {
                DictionaryEmptyState(
                    title: "Fix the same mistake the same way, every time",
                    detail:
                        "An exact swap applied after every transcription — for a phrase VoxOS always gets wrong, or a short code that expands into longer text. For names and terms, Vocabulary usually works better: one entry covers every way a word is misheard.",
                    examples: ["box os → VoxOS", "my addr → 12 MG Road, Bengaluru"])
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    DictionaryListHeader(
                        title: wordReplacements.count == 1
                            ? String(localized: "1 replacement")
                            : String(localized: "\(wordReplacements.count) replacements"),
                        sortLabel: sortLabel,
                        onToggleSort: cycleSort)

                    VStack(spacing: 0) {
                        ForEach(sortedReplacements, id: \.persistentModelID) { replacement in
                            ReplacementRow(
                                original: replacement.originalText,
                                replacement: replacement.replacementText,
                                onDelete: { removeReplacement(replacement) },
                                onEdit: { editingReplacement = replacement }
                            )
                            if replacement.persistentModelID != sortedReplacements.last?.persistentModelID {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.Surface.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.Border.card, lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editingReplacement) { replacement in
            EditReplacementSheet(replacement: replacement, modelContext: modelContext)
        }
        .alert("Word Replacement", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func addReplacement() {
        let original = originalWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = DictionaryService.addWordReplacement(
            original: original, replacement: replacement, existing: Array(wordReplacements), context: modelContext)
        {
            alertMessage = error
            showAlert = true
            return
        }
        originalWord = ""
        replacementWord = ""
    }

    private func removeReplacement(_ replacement: WordReplacement) {
        modelContext.delete(replacement)

        do {
            try modelContext.save()
        } catch {
            // Rollback the delete to restore UI consistency
            modelContext.rollback()
            alertMessage = String(
                format: String(localized: "Failed to remove replacement: %@"), error.localizedDescription)
            showAlert = true
        }
    }

}

struct WordReplacementInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to use Word Replacements")
                .font(.app(.headline))

            VStack(alignment: .leading, spacing: 8) {
                Text("Separate multiple originals with commas:")
                    .font(.app(.subheadline))
                    .foregroundColor(.secondary)

                Text("Voicing, Voice ink, Voiceing")
                    .font(.app(.callout))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
            }

            Divider()

            Text("Examples")
                .font(.app(.subheadline))
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Original:")
                            .font(.app(.caption))
                            .foregroundColor(.secondary)
                        Text("my website link")
                            .font(.app(.callout))
                    }

                    Image(systemName: "arrow.right")
                        .font(.app(.caption))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replacement:")
                            .font(.app(.caption))
                            .foregroundColor(.secondary)
                        Text(verbatim: "https://tryvoiceink.com")
                            .font(.app(.callout))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(6)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Original:")
                            .font(.app(.caption))
                            .foregroundColor(.secondary)
                        Text("Voicing, Voice ink")
                            .font(.app(.callout))
                    }

                    Image(systemName: "arrow.right")
                        .font(.app(.caption))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replacement:")
                            .font(.app(.caption))
                            .foregroundColor(.secondary)
                        Text("VoxOS")
                            .font(.app(.callout))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .cornerRadius(6)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// One replacement as "heard → written": what VoxOS produced is quiet, what it now writes is the
/// line's subject. Edit and remove appear on hover so a long list reads as content, not controls.
struct ReplacementRow: View {
    let original: String
    let replacement: String
    let onDelete: () -> Void
    let onEdit: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text(original)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.app(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.Text.muted)

            Text(replacement)
                .font(.app(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                rowButton("pencil", help: "Edit replacement", action: onEdit)
                rowButton("trash", help: "Remove replacement", action: onDelete)
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHovered ? AppTheme.Surface.subtle : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Remove", role: .destructive, action: onDelete)
        }
    }

    private func rowButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.Surface.controlActive))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
