import SwiftUI

struct TranscriptionDetailView: View {
    let transcription: Transcription
    var onInfoTap: (() -> Void)?

    @State private var showsDiff = false

    /// Both texts are stored on every enhanced transcription, but nothing ever showed the
    /// relationship between them — which is what tells a good prompt from a bad one.
    private var diff: TranscriptionTextDiff? {
        guard let enhancedText = transcription.enhancedText else { return nil }
        return TranscriptionTextDiff.compare(original: transcription.text, enhanced: enhancedText)
    }

    private var hasAudioFile: Bool {
        if let urlString = transcription.audioFileURL,
            let url = URL(string: urlString),
            FileManager.default.fileExists(atPath: url.path)
        {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 16) {
                    MessageBubble(
                        label: "Original",
                        text: transcription.text,
                        isEnhanced: false
                    )

                    if let enhancedText = transcription.enhancedText {
                        MessageBubble(
                            label: "Enhanced",
                            text: enhancedText,
                            isEnhanced: true
                        )
                    }

                    if let diff, diff.hasChanges {
                        changesSection(diff)
                    }

                    TranscriptionReviewSection(transcription: transcription)
                }
                .padding(16)
            }

            if hasAudioFile, let urlString = transcription.audioFileURL,
                let url = URL(string: urlString)
            {
                VStack(spacing: 0) {
                    Divider()

                    AudioPlayerView(url: url, transcription: transcription, onInfoTap: onInfoTap)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DetailCardMetrics.radius, style: .continuous)
                                .fill(AppTheme.Surface.card)
                                .overlay {
                                    RoundedRectangle(cornerRadius: DetailCardMetrics.radius, style: .continuous)
                                        .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                                }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// Collapsed by default: the summary alone answers "did it change much?", and the full
    /// comparison is one click away for when the answer is surprising.
    private func changesSection(_ diff: TranscriptionTextDiff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showsDiff.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsDiff ? "chevron.down" : "chevron.right")
                        .font(.app(size: 9, weight: .semibold))
                    Text(diff.summary)
                        .font(.appMono(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(AppTheme.Text.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show what AI enhancement changed"))

            if showsDiff {
                TranscriptionDiffView(diff: diff)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
    }
}

private enum DetailCardMetrics {
    /// The spec's card radius; `AppTheme.Radius.card` is the older, rounder glass value.
    static let radius: CGFloat = 14
}

/// One version of the text as a full-width card under a mono eyebrow. The enhanced version's
/// eyebrow takes the accent, since it is the text that was actually pasted.
private struct MessageBubble: View {
    let label: LocalizedStringKey
    let text: String
    let isEnhanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if isEnhanced {
                    Image(systemName: "sparkles")
                        .font(.app(size: 9, weight: .semibold))
                }
                Text(label)
                    .font(.appMono(size: 11, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .foregroundStyle(isEnhanced ? AppTheme.Accent.primary : AppTheme.Text.secondary)
            .padding(.leading, 4)

            ScrollView {
                MarkdownContentView(
                    text,
                    fontSize: 14,
                    foregroundColor: AppTheme.Text.primary,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 350)
            .background(
                RoundedRectangle(cornerRadius: DetailCardMetrics.radius, style: .continuous)
                    .fill(AppTheme.Surface.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: DetailCardMetrics.radius, style: .continuous)
                            .strokeBorder(
                                isEnhanced ? AppTheme.Accent.border : AppTheme.Border.card,
                                lineWidth: 1
                            )
                    )
            )
            .hoverCopyButton(textToCopy: text)
        }
    }
}
