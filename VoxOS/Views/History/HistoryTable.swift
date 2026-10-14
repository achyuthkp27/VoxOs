import AppKit
import SwiftUI

// The History page's table: a column header, mono day headers pinned while scrolling, and one
// compact row per dictation. `InlineHistoryView` owns the data, selection and side panel.

/// Column widths and row metrics shared by the header and every row, so the columns line up.
enum HistoryTableLayout {
    static let cardRadius: CGFloat = 14
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 30
    static let horizontalPadding: CGFloat = 14
    static let columnSpacing: CGFloat = 12

    static let checkboxWidth: CGFloat = 16
    static let timeWidth: CGFloat = 64
    static let modeWidth: CGFloat = 120
    static let wordsWidth: CGFloat = 56
    static let aiWidth: CGFloat = 28
    static let menuWidth: CGFloat = 24
}

// MARK: - Shared values

extension Transcription {
    /// What the History table shows for this dictation: the cleaned-up text when there is one,
    /// else what was heard.
    var historyDisplayText: String {
        enhancedText ?? text
    }

    var historyWordCount: Int {
        HistoryText.wordCount(historyDisplayText)
    }
}

enum HistoryText {
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// "1 dictation" or "12 dictations".
    static func dictationCount(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 dictation")
            : String(format: String(localized: "%@ dictations"), count.formatted())
    }
}

// MARK: - Day groups

/// One day of history: the table shows each under a pinned mono day header, newest day first.
struct HistoryDayGroup: Identifiable {
    let day: Date
    var items: [Transcription]

    var id: Date { day }

    /// "Today · 14 Oct", "Yesterday · 13 Oct", or the short weekday for older days; the year is
    /// added only for days in an earlier year.
    var title: String {
        let calendar = Calendar.current
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        let date =
            sameYear
            ? day.formatted(.dateTime.day().month(.abbreviated))
            : day.formatted(.dateTime.day().month(.abbreviated).year())
        let name: String
        if calendar.isDateInToday(day) {
            name = String(localized: "Today")
        } else if calendar.isDateInYesterday(day) {
            name = String(localized: "Yesterday")
        } else {
            name = day.formatted(.dateTime.weekday(.abbreviated))
        }
        return "\(name) · \(date)"
    }

    /// "12 dictations · 1,240 words", counting the rows loaded so far.
    var summary: String {
        let words = items.reduce(0) { $0 + $1.historyWordCount }
        let wordText =
            words == 1
            ? String(localized: "1 word")
            : String(format: String(localized: "%@ words"), words.formatted())
        return "\(HistoryText.dictationCount(items.count)) · \(wordText)"
    }

    /// Groups an already newest-first list by calendar day, keeping its order.
    static func group(_ transcriptions: [Transcription]) -> [HistoryDayGroup] {
        let calendar = Calendar.current
        var groups: [HistoryDayGroup] = []
        for transcription in transcriptions {
            let day = calendar.startOfDay(for: transcription.timestamp)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].items.append(transcription)
            } else {
                groups.append(HistoryDayGroup(day: day, items: [transcription]))
            }
        }
        return groups
    }
}

// MARK: - Column header

struct HistoryColumnHeader: View {
    let isSelecting: Bool
    let allSelected: Bool
    let onToggleAll: () -> Void

    var body: some View {
        HStack(spacing: HistoryTableLayout.columnSpacing) {
            ZStack {
                if isSelecting {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { allSelected },
                            set: { _ in onToggleAll() }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(allSelected ? "Deselect all" : "Select all")
                }
            }
            .frame(width: HistoryTableLayout.checkboxWidth)

            label("Time")
                .frame(width: HistoryTableLayout.timeWidth, alignment: .leading)
            label("Mode")
                .frame(width: HistoryTableLayout.modeWidth, alignment: .leading)
            label("Text")
                .frame(maxWidth: .infinity, alignment: .leading)
            label("Words")
                .frame(width: HistoryTableLayout.wordsWidth, alignment: .trailing)
            label("AI")
                .frame(width: HistoryTableLayout.aiWidth)
            Color.clear
                .frame(width: HistoryTableLayout.menuWidth)
        }
        .padding(.horizontal, HistoryTableLayout.horizontalPadding)
        .frame(height: HistoryTableLayout.headerHeight)
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.appMono(size: 11, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(AppTheme.Text.muted)
            .lineLimit(1)
    }
}

// MARK: - Day header

/// Pinned while its day scrolls by, so it needs an opaque fill to cover the rows beneath it.
struct HistoryDayHeader: View {
    let group: HistoryDayGroup

    var body: some View {
        HStack(spacing: 12) {
            Text(group.title)
                .font(.appMono(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(group.summary)
                .font(.appMono(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, HistoryTableLayout.horizontalPadding)
        .frame(height: 28)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(AppTheme.Surface.subtle)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

struct HistoryTableRow: View {
    let transcription: Transcription
    let modeColor: Color
    let isChecked: Bool
    let isSelecting: Bool
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onToggleCheck: () -> Void
    let onShowInfo: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    /// One line: what the table shows, with line breaks folded so the row never grows.
    private var previewText: String {
        transcription.historyDisplayText.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private var showsCheckbox: Bool {
        isSelecting || isChecked || isHovering
    }

    private var isEnhanced: Bool {
        !(transcription.enhancedText ?? "").isEmpty
    }

    private var rowFill: Color {
        if isHighlighted || isChecked { return AppTheme.Accent.fillSubtle }
        return isHovering ? AppTheme.Surface.subtle : .clear
    }

    var body: some View {
        HStack(spacing: HistoryTableLayout.columnSpacing) {
            checkbox
                .frame(width: HistoryTableLayout.checkboxWidth)

            Text(transcription.timestamp, format: .dateTime.hour().minute())
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .frame(width: HistoryTableLayout.timeWidth, alignment: .leading)

            modeCell
                .frame(width: HistoryTableLayout.modeWidth, alignment: .leading)

            Text(previewText)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(transcription.historyWordCount.formatted())
                .font(.appMono(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(1)
                .frame(width: HistoryTableLayout.wordsWidth, alignment: .trailing)

            aiCell
                .frame(width: HistoryTableLayout.aiWidth)

            rowMenu
                .frame(width: HistoryTableLayout.menuWidth)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, HistoryTableLayout.horizontalPadding)
        .frame(height: HistoryTableLayout.rowHeight)
        .background(rowFill)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { onToggleCheck() } else { onOpen() }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Open")) { onOpen() }
        .accessibilityAction(named: Text("Delete")) { onDelete() }
    }

    @ViewBuilder
    private var checkbox: some View {
        if showsCheckbox {
            Toggle(
                "",
                isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggleCheck() }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(isChecked ? "Deselect" : "Select")
        } else {
            Color.clear
        }
    }

    private var modeCell: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(modeColor)
                .frame(width: 7, height: 7)
            Text(transcription.modeName ?? String(localized: "No mode"))
                .font(.app(size: 12, weight: .regular))
                .foregroundStyle(transcription.modeName == nil ? AppTheme.Text.muted : AppTheme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(transcription.modeName ?? String(localized: "No mode"))
    }

    @ViewBuilder
    private var aiCell: some View {
        if isEnhanced {
            Image(systemName: "sparkles")
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .help(aiHelp)
                .accessibilityLabel(aiHelp)
        } else {
            Color.clear
        }
    }

    private var aiHelp: String {
        if let model = transcription.aiEnhancementModelName, !model.isEmpty {
            return String(format: String(localized: "Cleaned up by %@"), model)
        }
        return String(localized: "Cleaned up by AI")
    }

    private var rowMenu: some View {
        Menu {
            Button("Open") { onOpen() }
            Button("Copy text") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(transcription.historyDisplayText, forType: .string)
            }
            Button("Show info") { onShowInfo() }
            Divider()
            Button(isChecked ? "Deselect" : "Select") { onToggleCheck() }
            Button("Delete", role: .destructive) { onDelete() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

// MARK: - Mode dot for menus

enum HistoryModeDot {
    /// A filled circle in `color` for menu items: menus draw SF Symbols as templates and drop
    /// their colour, so the dot is a non-template bitmap instead.
    static func image(_ color: Color, diameter: CGFloat = 8) -> NSImage {
        let nsColor = NSColor(color)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
