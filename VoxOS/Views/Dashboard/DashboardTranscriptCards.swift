import SwiftUI

/// The last few dictations as compact rows: the mode's colour, one line of text and the time.
/// Click a row to read it in full; hover to copy. "See all" opens History.
struct DashboardTranscriptCards: View {
    let transcriptions: [Transcription]

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardLayout.labelSpacing) {
            DashboardSectionLabel(title: "Recent dictations") {
                Button {
                    MainWindowNavigation.shared.navigate(to: .history)
                } label: {
                    HStack(spacing: 3) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                            .font(.app(size: 9, weight: .semibold))
                    }
                    .font(.app(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open History")
            }

            if transcriptions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(transcriptions.enumerated()), id: \.element.id) { index, transcription in
                        DashboardTranscriptRow(transcription: transcription)

                        if index < transcriptions.count - 1 {
                            Divider()
                                .overlay(AppTheme.Border.subtle)
                                .padding(.leading, 31)
                                .padding(.trailing, 12)
                        }
                    }
                }
                .dashboardCard(padding: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text("Nothing here yet. Your last five dictations show up here.")
            .font(.app(size: 12, weight: .regular))
            .foregroundStyle(AppTheme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .dashboardCard()
    }
}

private struct DashboardTranscriptRow: View {
    let transcription: Transcription

    @State private var isHovering = false
    @State private var isExpanded = false

    private var displayText: String {
        if let enhancedText = transcription.enhancedText, Self.isUsableEnhancedText(enhancedText) {
            return enhancedText
        }
        return transcription.text
    }

    private var copyText: String {
        displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewText: String {
        displayText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var modeColor: Color {
        ModeSpectrum.color(forModeNamed: transcription.modeName)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(modeColor)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] + 4 }
                .help(Text(verbatim: transcription.modeName ?? String(localized: "No mode recorded")))
                .accessibilityHidden(true)

            Text(verbatim: isExpanded ? copyText : previewText)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .trailing) {
                Text(verbatim: Self.timeText(for: transcription.timestamp))
                    .font(.appMono(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(isHovering ? 0 : 1)

                CopyIconButton(textToCopy: copyText, accessibilityLabel: "Copy transcript")
                    .frame(width: 24, height: 20)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovering ? AppTheme.Surface.subtle : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Dictation from \(Self.timeText(for: transcription.timestamp))"))
        .accessibilityValue(Text(verbatim: isExpanded ? copyText : previewText))
    }

    /// "10:42" today, "Mon" within the week, "12 Oct" before that.
    private static func timeText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        if let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())
        ).day,
            days < 7
        {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func isUsableEnhancedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "Enhancement failed:", options: [.caseInsensitive, .anchored]) == nil
    }
}
