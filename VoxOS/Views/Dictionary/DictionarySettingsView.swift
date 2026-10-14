import SwiftData
import SwiftUI

struct DictionarySettingsView: View {
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var wordReplacements: [WordReplacement]
    @State private var selectedSection: DictionarySection = .spellings
    @State private var isShowingSettings = false
    private let dictionaryInfoMessage: LocalizedStringKey =
        "Word Replacements run after transcription. Vocabulary helps supported transcription models and AI enhancement recognize names, technical terms, and unique spellings."

    enum DictionarySection: String, CaseIterable, Hashable {
        case replacements = "Word Replacements"
        case spellings = "Vocabulary"

        /// One plain sentence on what the list does, shown under the switcher.
        var description: String {
            switch self {
            case .spellings:
                return String(
                    localized:
                        "Spelled your way. Local Parakeet listens for these while you speak, and AI cleanup keeps their spelling."
                )
            case .replacements:
                return String(
                    localized:
                        "Swapped exactly. Applied to every transcription, before anything is pasted."
                )
            }
        }

        var systemImage: String {
            switch self {
            case .spellings:
                return "character.book.closed"
            case .replacements:
                return "arrow.left.arrow.right"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionSelector
                        Text(selectedSection.description)
                            .font(.app(size: 13, weight: .regular))
                            .foregroundStyle(AppTheme.Text.secondary)
                            .contentTransition(.opacity)
                    }
                    selectedSectionContent
                }
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 32)
                .frame(maxWidth: 860, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
        .sidePanel(isPresented: $isShowingSettings) {
            DictionarySettingsPanel {
                isShowingSettings = false
            }
        }
    }

    private var headerSection: some View {
        AppScreenHeader(title: "Dictionary", infoMessage: dictionaryInfoMessage) {
            settingsButton
        }
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Dictionary Settings"
        ) {
            isShowingSettings.toggle()
        }
    }

    /// A native segmented control sized to its labels, with each list's size, in place of two
    /// full-width pills that out-shouted the content they switch between.
    private var sectionSelector: some View {
        Picker("", selection: $selectedSection.animation(.easeInOut(duration: 0.16))) {
            Text("Vocabulary  \(vocabularyWords.count)").tag(DictionarySection.spellings)
            Text("Replacements  \(wordReplacements.count)").tag(DictionarySection.replacements)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.large)
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch selectedSection {
        case .spellings:
            VocabularyView()
        case .replacements:
            WordReplacementView()
        }
    }
}
