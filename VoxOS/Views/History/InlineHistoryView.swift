import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "InlineHistoryView")

struct InlineHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var modeManager = ModeManager.shared
    @State private var searchText = ""
    @State private var lastFetchedSearchText = ""
    /// The mode chosen in the filter menu, nil for every mode.
    @State private var modeFilter: String?
    /// The mode filter the list on screen was fetched with; Load More and Select All read this,
    /// like `lastFetchedSearchText`, so they continue the list that is showing.
    @State private var lastFetchedModeFilter: String?
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var showDeleteConfirmation = false
    @State private var isPanelPresented = false
    @State private var panelMode: InlineHistoryPanelMode = .info
    @State private var panelTranscriptionId: UUID?
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    /// Where the next page starts; see `HistoryPageCursor` for why it is more than a timestamp.
    @State private var pageCursor: HistoryPageCursor?
    @State private var isViewCurrentlyVisible = false

    private let exportService = VoxOSCSVExportService()
    private let pageSize = 20

    @Query(Self.createLatestTranscriptionIndicatorDescriptor()) private var latestTranscriptionIndicator:
        [Transcription]

    private static func createLatestTranscriptionIndicatorDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Built from `lastFetchedSearchText`, not the live field: while the search debounce is
    /// pending the two differ, and Load More must continue the list that is on screen.
    private func cursorQueryDescriptor(after cursor: HistoryPageCursor? = nil) -> FetchDescriptor<Transcription> {
        HistoryPageQuery.descriptor(
            searchText: lastFetchedSearchText,
            modeName: lastFetchedModeFilter,
            after: cursor,
            pageSize: pageSize
        )
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private var isSelecting: Bool {
        !selectedTranscriptions.isEmpty
    }

    private var isFiltering: Bool {
        !searchText.isEmpty || modeFilter != nil
    }

    private var panelTranscription: Transcription? {
        guard let id = panelTranscriptionId else { return nil }
        return displayedTranscriptions.first { $0.id == id }
    }

    /// The row whose details are open, highlighted in the list.
    private var openedTranscriptionId: UUID? {
        guard isPanelPresented, panelMode == .detail || panelMode == .info else { return nil }
        return panelTranscriptionId
    }

    /// Names offered by the filter menu: every mode the user has, plus the one being filtered on
    /// if it has since been renamed or deleted, so the menu can always show the current choice.
    private var filterModeNames: [String] {
        var names = modeManager.configurations.map(\.name)
        if let modeFilter, !names.contains(modeFilter) {
            names.append(modeFilter)
        }
        return names
    }

    private var dayGroups: [HistoryDayGroup] {
        HistoryDayGroup.group(displayedTranscriptions)
    }

    private func openPanel(mode: InlineHistoryPanelMode, transcriptionID: UUID? = nil) {
        panelMode = mode
        panelTranscriptionId = transcriptionID

        isPanelPresented = true
    }

    private func closePanel() {
        isPanelPresented = false
        panelMode = .info
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(title: "History") {
                AppIconButton(
                    systemName: "gearshape",
                    help: "History settings",
                    size: 30,
                    iconSize: 13,
                    cornerRadius: AppTheme.Radius.pill
                ) {
                    openPanel(mode: .historySettings)
                }
            }

            filterBar

            if displayedTranscriptions.isEmpty && !isLoading {
                emptyStateView
            } else {
                dayListView
            }

            if isSelecting {
                Divider()
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedTranscriptions.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidePanel(
            isPresented: .init(
                get: { isPanelPresented },
                set: { newValue in
                    if !newValue { closePanel() }
                }
            ),
            width: 440
        ) {
            panelContent
        }
        .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "This action cannot be undone. Are you sure you want to delete \(selectedTranscriptions.count) items?"
                ))
        }
        .onAppear {
            isViewCurrentlyVisible = true
            Task { await loadInitialContent() }
        }
        .onDisappear {
            isViewCurrentlyVisible = false
        }
        .task(id: searchText) {
            // Debounced like TranscriptionHistoryView: a SwiftData fetch per keystroke made typing
            // stutter on large histories. The task is cancelled and restarted on each change, so
            // only the last one fetches. The initial load is `onAppear`'s job, hence the skip.
            guard searchText != lastFetchedSearchText else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            lastFetchedSearchText = searchText
            resetPagination()
            await loadInitialContent()
        }
        .onChange(of: modeFilter) { _, newFilter in
            // A menu choice is one deliberate change, so it fetches at once, without a debounce.
            lastFetchedModeFilter = newFilter
            Task {
                resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: latestTranscriptionIndicator.first?.id) { oldId, newId in
            guard isViewCurrentlyVisible else { return }
            if newId != oldId {
                Task {
                    resetPagination()
                    await loadInitialContent()
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.muted)
                    .font(.app(size: 12, weight: .medium))
                TextField("Search transcriptions…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.app(size: 13, weight: .regular))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Text.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.Surface.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                    )
            )
            .frame(maxWidth: .infinity)

            modeFilterMenu
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var modeFilterMenu: some View {
        Menu {
            Picker("Mode", selection: $modeFilter) {
                Text("All modes").tag(String?.none)
                Divider()
                ForEach(filterModeNames, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                if let modeFilter {
                    Circle()
                        .fill(ModeSpectrum.color(forModeNamed: modeFilter, in: modeManager.configurations))
                        .frame(width: 7, height: 7)
                    Text(modeFilter)
                        .lineLimit(1)
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("All")
                }
            }
            .font(.app(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Show transcriptions from one mode")
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)

            Spacer()

            Button(action: {
                openPanel(mode: .analysis)
            }) {
                Label("Analyze", systemImage: "chart.bar.xaxis")
            }

            Button(action: {
                exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
            }) {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                Label("Delete", systemImage: "trash")
            }
            .foregroundStyle(AppTheme.Status.error)

            Divider()
                .frame(height: 16)

            if allSelected {
                Button("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
            } else {
                Button("Select All") {
                    Task { await selectAllTranscriptions() }
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.app(size: 12, weight: .medium))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: isFiltering ? "magnifyingglass" : "waveform")
                .font(.app(size: 28, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
            Text(isFiltering ? "No transcriptions match" : "No transcriptions yet")
                .font(.app(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.Text.primary)
            Text(
                isFiltering
                    ? "Try other words, or set the filter back to All."
                    : "Press your dictation shortcut and speak. Each dictation is kept here."
            )
            .font(.app(size: 13, weight: .regular))
            .foregroundStyle(AppTheme.Text.secondary)
            .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Day List

    private var dayListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(dayGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.appMono(size: 11, weight: .medium))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .foregroundStyle(AppTheme.Text.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transcription in
                                if index > 0 {
                                    Divider()
                                        .padding(.leading, 40)
                                }
                                historyRow(for: transcription)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: HistoryRowMetrics.cardRadius, style: .continuous)
                                .fill(AppTheme.Surface.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: HistoryRowMetrics.cardRadius, style: .continuous)
                                .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: HistoryRowMetrics.cardRadius, style: .continuous))
                    }
                }

                if hasMoreContent {
                    Button(action: {
                        Task { await loadMoreContent() }
                    }) {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            }
                            Text(isLoading ? "Loading…" : "Load more")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func historyRow(for transcription: Transcription) -> some View {
        HistoryRow(
            transcription: transcription,
            modeColor: ModeSpectrum.color(forModeNamed: transcription.modeName, in: modeManager.configurations),
            isChecked: selectedTranscriptions.contains(transcription),
            isSelecting: isSelecting,
            isOpen: openedTranscriptionId == transcription.id,
            onOpen: { openPanel(mode: .detail, transcriptionID: transcription.id) },
            onToggleCheck: { toggleSelection(transcription) },
            onShowInfo: { openPanel(mode: .info, transcriptionID: transcription.id) }
        )
    }

    // MARK: - Side Panel

    @ViewBuilder
    private var panelContent: some View {
        switch panelMode {
        case .detail:
            detailPanelContent
        case .info:
            infoPanelContent
        case .analysis:
            HistoryAnalysisPanelView(
                transcriptions: Array(selectedTranscriptions),
                onClose: {
                    closePanel()
                }
            )
            .id(selectedTranscriptions.count)
        case .historySettings:
            HistorySettingsPanel(onClose: closePanel)
        }
    }

    private var detailPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Transcription", onClose: closePanel)

            if let transcription = panelTranscription {
                HistoryDetailMeta(
                    transcription: transcription,
                    modeColor: ModeSpectrum.color(
                        forModeNamed: transcription.modeName, in: modeManager.configurations)
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)

                TranscriptionDetailView(
                    transcription: transcription,
                    onInfoTap: { openPanel(mode: .info, transcriptionID: transcription.id) }
                )
                // A fresh view per transcription: the audio player loads its file on appear, so
                // reusing one view across rows would keep playing the previous recording.
                .id(transcription.id)
            } else {
                Spacer()
            }
        }
    }

    private var infoPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Info", onClose: closePanel)

            if let transcription = panelTranscription {
                TranscriptionInfoPanel(transcription: transcription)
                    .id(transcription.id)
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadInitialContent() async {
        isLoading = true
        defer { isLoading = false }

        do {
            pageCursor = nil
            let items = try modelContext.fetch(cursorQueryDescriptor())
            displayedTranscriptions = items
            pageCursor = HistoryPageCursor(after: items, previous: nil)
            hasMoreContent = items.count == pageSize
        } catch {
            logger.error("Error loading transcriptions: \(error, privacy: .public)")
        }
    }

    @MainActor
    private func loadMoreContent() async {
        guard !isLoading, hasMoreContent, let pageCursor else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let newItems = try modelContext.fetch(cursorQueryDescriptor(after: pageCursor))
            displayedTranscriptions.append(contentsOf: newItems)
            self.pageCursor = HistoryPageCursor(after: newItems, previous: pageCursor)
            hasMoreContent = newItems.count == pageSize
        } catch {
            logger.error("Error loading more transcriptions: \(error, privacy: .public)")
        }
    }

    @MainActor
    private func resetPagination() {
        displayedTranscriptions = []
        pageCursor = nil
        hasMoreContent = true
        isLoading = false
    }

    // MARK: - Selection & Deletion

    private func toggleSelection(_ transcription: Transcription) {
        if selectedTranscriptions.contains(transcription) {
            selectedTranscriptions.remove(transcription)
        } else {
            selectedTranscriptions.insert(transcription)
        }
    }

    /// Removes the record and returns its audio file, which the caller deletes only once the
    /// removal is saved: a leftover file is harmless, a saved record pointing at a missing file
    /// is a broken row forever.
    private func performDeletion(for transcription: Transcription) -> URL? {
        let audioURL = transcription.audioFileURL.flatMap(URL.init(string:))

        if panelTranscriptionId == transcription.id {
            panelTranscriptionId = nil
            closePanel()
        }

        selectedTranscriptions.remove(transcription)
        modelContext.delete(transcription)
        return audioURL
    }

    private func deleteSelectedTranscriptions() {
        let audioURLs = selectedTranscriptions.compactMap { performDeletion(for: $0) }
        selectedTranscriptions.removeAll()

        Task {
            do {
                try modelContext.save()
                removeAudioFiles(at: audioURLs)
                NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                await loadInitialContent()
            } catch {
                logger.error("Error saving deletion: \(error.localizedDescription, privacy: .public)")
                await loadInitialContent()
            }
        }
    }

    private func removeAudioFiles(at urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.error("Error deleting audio file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func selectAllTranscriptions() async {
        do {
            // The query the list is showing, not the live field: Select All and the bulk delete
            // that follows must never reach rows the visible list does not match.
            let allDescriptor = HistoryPageQuery.allMatchingDescriptor(
                searchText: lastFetchedSearchText,
                modeName: lastFetchedModeFilter
            )
            let allTranscriptions = try modelContext.fetch(allDescriptor)
            let visibleIds = Set(displayedTranscriptions.map { $0.id })

            await MainActor.run {
                selectedTranscriptions = Set(displayedTranscriptions)

                for transcription in allTranscriptions {
                    if !visibleIds.contains(transcription.id) {
                        selectedTranscriptions.insert(transcription)
                    }
                }
            }
        } catch {
            logger.error("Error selecting all transcriptions: \(error, privacy: .public)")
        }
    }
}

private enum InlineHistoryPanelMode {
    case detail
    case info
    case analysis
    case historySettings
}

private enum HistoryRowMetrics {
    /// The spec's card radius; `AppTheme.Radius.card` is the older, rounder glass value.
    static let cardRadius: CGFloat = 14
}

// MARK: - Day Groups

/// One day of history: the list shows each under a mono day header, newest day first.
private struct HistoryDayGroup: Identifiable {
    let day: Date
    var items: [Transcription]

    var id: Date { day }

    /// "Today · 14 Oct 2026", "Yesterday · …", or the weekday for older days.
    var title: String {
        let calendar = Calendar.current
        let date = day.formatted(.dateTime.day().month(.abbreviated).year())
        let name: String
        if calendar.isDateInToday(day) {
            name = String(localized: "Today")
        } else if calendar.isDateInYesterday(day) {
            name = String(localized: "Yesterday")
        } else {
            name = day.formatted(.dateTime.weekday(.wide))
        }
        return "\(name) · \(date)"
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

// MARK: - History Row

private struct HistoryRow: View {
    let transcription: Transcription
    let modeColor: Color
    let isChecked: Bool
    let isSelecting: Bool
    let isOpen: Bool
    let onOpen: () -> Void
    let onToggleCheck: () -> Void
    let onShowInfo: () -> Void

    @State private var isHovering = false

    /// One line: what was written, with line breaks folded so the row never grows.
    private var previewText: String {
        let text = transcription.enhancedText ?? transcription.text
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The checkbox replaces the mode dot while selecting, or under the pointer.
    private var showsCheckbox: Bool {
        isSelecting || isChecked || isHovering
    }

    private var rowFill: Color {
        if isOpen || isChecked { return AppTheme.Selection.fill }
        return isHovering ? AppTheme.Surface.subtle : .clear
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if showsCheckbox {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { isChecked },
                            set: { _ in onToggleCheck() }
                        )
                    )
                    .toggleStyle(CircularCheckboxStyle())
                    .labelsHidden()
                    .help(isChecked ? "Deselect" : "Select")
                } else {
                    Circle()
                        .fill(modeColor)
                        .frame(width: 8, height: 8)
                        .help(transcription.modeName ?? String(localized: "No mode"))
                }
            }
            .frame(width: 18, height: 18)

            Text(previewText)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(transcription.timestamp, format: .dateTime.hour().minute())
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)

            rowMenu
                .opacity(isHovering || isOpen ? 1 : 0)
                .allowsHitTesting(isHovering || isOpen)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 40)
        .background(rowFill)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { onToggleCheck() } else { onOpen() }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open")) { onOpen() }
    }

    private var rowMenu: some View {
        Menu {
            Button("Open") { onOpen() }
            Button("Copy text") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(transcription.enhancedText ?? transcription.text, forType: .string)
            }
            Button("Show info") { onShowInfo() }
            Divider()
            Button(isChecked ? "Deselect" : "Select") { onToggleCheck() }
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

// MARK: - Detail Meta

/// The line above a transcription's details: when it was made and by which mode.
private struct HistoryDetailMeta: View {
    let transcription: Transcription
    let modeColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(modeColor)
                .frame(width: 8, height: 8)
            Text(transcription.modeName ?? String(localized: "No mode"))
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(
                transcription.timestamp,
                format: .dateTime.day().month(.abbreviated).year().hour().minute()
            )
            .font(.appMono(size: 11, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            if transcription.duration > 0 {
                Text(transcription.duration.formatTiming())
                    .font(.appMono(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.muted)
            }
        }
    }
}
