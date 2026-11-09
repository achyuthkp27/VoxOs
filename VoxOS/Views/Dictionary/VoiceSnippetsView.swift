import SwiftUI

/// The Snippets tab: a phrase and the text pasted when that phrase is the whole dictation.
struct VoiceSnippetsView: View {
    @ObservedObject private var store = VoiceSnippetStore.shared
    @AppStorage(DefaultsKeys.snippetsSortDescending) private var sortDescending = false
    @State private var trigger = ""
    @State private var text = ""
    @State private var editing: EditedSnippet?
    @State private var problem: String?

    private var canAdd: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedTriggers: [String] {
        store.snippets.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == (sortDescending ? .orderedDescending : .orderedAscending)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DictionaryComposer(canAdd: canAdd, addTitle: "Add", onAdd: add) {
                DictionaryComposerField(prompt: "When you say…", text: $trigger)
                Image(systemName: "arrow.right")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.muted)
                DictionaryComposerField(prompt: "…paste this", text: $text, onSubmit: add)
            }

            if store.snippets.isEmpty {
                DictionaryEmptyState(
                    title: "Paste saved text by saying its name",
                    detail:
                        "When a whole dictation is a snippet’s phrase, VoxOS pastes the snippet exactly as saved, skipping AI cleanup. Edit a snippet to give it several lines.",
                    examples: ["my address → 12 MG Road, Bengaluru", "my calendar link → cal.com/you"])
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    DictionaryListHeader(
                        title: store.snippets.count == 1
                            ? String(localized: "1 snippet")
                            : String(localized: "\(store.snippets.count) snippets"),
                        sortLabel: sortDescending ? String(localized: "Phrase Z–A") : String(localized: "Phrase A–Z"),
                        onToggleSort: { sortDescending.toggle() })

                    VStack(spacing: 0) {
                        ForEach(sortedTriggers, id: \.self) { key in
                            ReplacementRow(
                                original: key,
                                replacement: store.snippets[key] ?? "",
                                onDelete: { store.remove(key) },
                                onEdit: { editing = EditedSnippet(trigger: key, text: store.snippets[key] ?? "") }
                            )
                            if key != sortedTriggers.last {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.Surface.card)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppTheme.Border.card, lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editing) { snippet in
            EditSnippetSheet(original: snippet)
        }
        .alert("Snippet", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func add() {
        if let problem = store.save(trigger: trigger, text: text) {
            self.problem = problem
            return
        }
        trigger = ""
        text = ""
    }
}

struct EditedSnippet: Identifiable {
    let trigger: String
    let text: String
    var id: String { trigger }
}

/// Changes a snippet's phrase or text; the text may run over several lines.
private struct EditSnippetSheet: View {
    let original: EditedSnippet
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var text: String
    @State private var problem: String?

    init(original: EditedSnippet) {
        self.original = original
        _trigger = State(initialValue: original.trigger)
        _text = State(initialValue: original.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Snippet")
                .font(.app(.headline))
            VStack(alignment: .leading, spacing: 6) {
                Text("When you say")
                    .settingsCaption()
                TextField("", text: $trigger)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste this")
                    .settingsCaption()
                TextEditor(text: $text)
                    .font(.app(size: 13, weight: .regular))
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.Border.card, lineWidth: 1))
            }
            if let problem {
                Text(problem)
                    .font(.app(.caption))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    problem = VoiceSnippetStore.shared.save(trigger: trigger, text: text, replacing: original.trigger)
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
