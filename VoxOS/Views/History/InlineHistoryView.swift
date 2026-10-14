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
    @State private var dateRange: HistoryDateRange = .all
    /// The start date the list on screen was fetched with, kept for the same reason as above and
    /// so "Today" does not move under Load More when midnight passes.
    @State private var lastFetchedSince: Date?
    @State private var selectedTranscriptions: Set<Transcription> = []
    /// True after Select is pressed, so the checkbox column shows before anything is checked.
    @State private var isSelectionMode = false
    /// The rows the delete confirmation is asking about: the checked rows, or one row from its
    /// menu or the Delete key.
    @State private var pendingDeletion: [Transcription] = []
    @State private var showDeleteConfirmation = false
    @State private var isPanelPresented = false
    @State private var panelMode: InlineHistoryPanelMode = .info
    @State private var panelTranscriptionId: UUID?
    /// The highlighted row: the one last clicked or reached with the arrow keys.
    @State private var highlightedTranscriptionId: UUID?
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    /// Where the next page starts; see `HistoryPageCursor` for why it is more than a timestamp.
    @State private var pageCursor: HistoryPageCursor?
    @State private var isViewCurrentlyVisible = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTableFocused: Bool

    private let exportService = VoxOSCSVExportService()
    private let pageSize = 40

    @Query(Self.createLatestTranscriptionIndicatorDescriptor()) private var latestTranscriptionIndicator:
        [Transcription]

    private static func createLatestTranscriptionIndicatorDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Built from the last fetched filters, not the live controls: while the search debounce is
    /// pending the two differ, and Load More must continue the list that is on screen.
    private func cursorQueryDescriptor(after cursor: HistoryPageCursor? = nil) -> FetchDescriptor<Transcription> {
        HistoryPageQuery.descriptor(
            searchText: lastFetchedSearchText,
            modeName: lastFetchedModeFilter,
            since: lastFetchedSince,
            after: cursor,
            pageSize: pageSize
        )
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private var isSelecting: Bool {
        isSelectionMode || !selectedTranscriptions.isEmpty
    }

    private var panelTranscription: Transcription? {
        guard let id = panelTranscriptionId else { return nil }
        return displayedTranscriptions.first { $0.id == id }
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

    private func modeColor(for name: String?) -> Color {
        ModeSpectrum.color(forModeNamed: name, in: modeManager.configurations)
    }

    private func openPanel(mode: InlineHistoryPanelMode, transcriptionID: UUID? = nil) {
        panelMode = mode
        panelTranscriptionId = transcriptionID
        if let transcriptionID {
            highlightedTranscriptionId = transcriptionID
        }

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

            toolbar

            tableCard
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isSelecting)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // ⌘F focuses the search field. A zero-size button keeps the shortcut live without
            // showing anything.
            Button("Search") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
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
                deletePendingTranscriptions()
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = []
            }
        } message: {
            Text(
                String(
                    localized:
                        "This action cannot be undone. Are you sure you want to delete \(pendingDeletion.count) items?"
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
        .onChange(of: dateRange) { _, newRange in
            lastFetchedSince = newRange.startDate()
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField
                .frame(minWidth: 160, maxWidth: 280)

            modeFilterMenu

            Picker("Date range", selection: $dateRange) {
                ForEach(HistoryDateRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show dictations from this period")

            Spacer(minLength: 8)

            selectionActions
        }
        .font(.app(size: 12, weight: .medium))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Text.muted)
                .font(.app(size: 12, weight: .medium))
            TextField("Search dictations…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.app(size: 13, weight: .regular))
                .focused($isSearchFocused)
                .onSubmit { isTableFocused = true }
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
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.Surface.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSearchFocused ? AppTheme.Accent.border : AppTheme.Border.card,
                            lineWidth: 1
                        )
                )
        )
        .help("Search dictations (⌘F)")
    }

    private var modeFilterMenu: some View {
        Menu {
            Picker("Mode", selection: $modeFilter) {
                Text("All modes").tag(String?.none)
                Divider()
                ForEach(filterModeNames, id: \.self) { name in
                    Label {
                        Text(name)
                    } icon: {
                        Image(nsImage: HistoryModeDot.image(modeColor(for: name)))
                    }
                    .tag(String?.some(name))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                if let modeFilter {
                    Circle()
                        .fill(modeColor(for: modeFilter))
                        .frame(width: 7, height: 7)
                    Text(modeFilter)
                        .lineLimit(1)
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("All modes")
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Show dictations from one mode")
    }

    @ViewBuilder
    private var selectionActions: some View {
        if isSelecting {
            HStack(spacing: 8) {
                Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                    .font(.appMono(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)

                Button {
                    openPanel(mode: .analysis)
                } label: {
                    Label("Analyze", systemImage: "chart.bar.xaxis")
                }
                .help("Analyze selected dictations")
                .disabled(selectedTranscriptions.isEmpty)

                Button {
                    exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export selected dictations as CSV")
                .disabled(selectedTranscriptions.isEmpty)

                Button(role: .destructive) {
                    confirmDeletion(of: Array(selectedTranscriptions))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete selected dictations")
                .disabled(selectedTranscriptions.isEmpty)

                Button("Done") {
                    selectedTranscriptions.removeAll()
                    isSelectionMode = false
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .transition(.opacity)
        } else {
            Button("Select") {
                isSelectionMode = true
            }
            .buttonStyle(.bordered)
            .disabled(displayedTranscriptions.isEmpty)
            .help("Choose dictations to export or delete")
        }
    }

    // MARK: - Table

    private var tableCard: some View {
        VStack(spacing: 0) {
            if displayedTranscriptions.isEmpty && !isLoading {
                emptyStateView
            } else {
                HistoryColumnHeader(
                    isSelecting: isSelecting,
                    allSelected: allSelected,
                    onToggleAll: {
                        if allSelected {
                            selectedTranscriptions.removeAll()
                        } else {
                            Task { await selectAllTranscriptions() }
                        }
                    }
                )
                Divider()
                tableBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HistoryTableLayout.cardRadius, style: .continuous)
                .fill(AppTheme.Surface.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: HistoryTableLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HistoryTableLayout.cardRadius, style: .continuous)
                .strokeBorder(AppTheme.Border.card, lineWidth: 1)
        )
    }

    private var tableBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(dayGroups) { group in
                        Section {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transcription in
                                if index > 0 {
                                    Divider()
                                }
                                tableRow(for: transcription)
                                    .id(transcription.id)
                            }
                        } header: {
                            HistoryDayHeader(group: group)
                        }
                    }

                    if hasMoreContent {
                        loadMoreFooter
                    }
                }
            }
            .focusable()
            .focused($isTableFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) {
                moveHighlight(by: 1, proxy: proxy)
            }
            .onKeyPress(.upArrow) {
                moveHighlight(by: -1, proxy: proxy)
            }
            .onKeyPress(.return) {
                guard let id = highlightedTranscriptionId else { return .ignored }
                openPanel(mode: .detail, transcriptionID: id)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                deleteFromKeyboard()
            }
        }
    }

    /// Loads the next page as soon as it scrolls into view; the button covers the case where it
    /// is already on screen after a load, which `onAppear` would not fire for again.
    private var loadMoreFooter: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .foregroundStyle(AppTheme.Text.muted)
            } else {
                Button("Load more") {
                    Task { await loadMoreContent() }
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.app(size: 12, weight: .medium))
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .overlay(alignment: .top) { Divider() }
        .onAppear {
            Task { await loadMoreContent() }
        }
    }

    private func tableRow(for transcription: Transcription) -> some View {
        HistoryTableRow(
            transcription: transcription,
            modeColor: modeColor(for: transcription.modeName),
            isChecked: selectedTranscriptions.contains(transcription),
            isSelecting: isSelecting,
            isHighlighted: highlightedTranscriptionId == transcription.id,
            onOpen: {
                isTableFocused = true
                openPanel(mode: .detail, transcriptionID: transcription.id)
            },
            onToggleCheck: {
                isTableFocused = true
                highlightedTranscriptionId = transcription.id
                toggleSelection(transcription)
            },
            onShowInfo: { openPanel(mode: .info, transcriptionID: transcription.id) },
            onDelete: { confirmDeletion(of: [transcription]) }
        )
    }

    // MARK: - Keyboard

    /// Moves the highlight one row up or down, and follows it in the side panel when a
    /// dictation's details or info are open there.
    private func moveHighlight(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !displayedTranscriptions.isEmpty else { return .ignored }
        let current = displayedTranscriptions.firstIndex { $0.id == highlightedTranscriptionId }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), displayedTranscriptions.count - 1)
        } else {
            next = offset > 0 ? 0 : displayedTranscriptions.count - 1
        }
        let id = displayedTranscriptions[next].id
        highlightedTranscriptionId = id
        if isPanelPresented, panelMode == .detail || panelMode == .info {
            panelTranscriptionId = id
        }
        proxy.scrollTo(id)
        if next == displayedTranscriptions.count - 1, hasMoreContent {
            Task { await loadMoreContent() }
        }
        return .handled
    }

    /// Delete asks about the checked rows, or the highlighted row when none is checked.
    private func deleteFromKeyboard() -> KeyPress.Result {
        if !selectedTranscriptions.isEmpty {
            confirmDeletion(of: Array(selectedTranscriptions))
            return .handled
        }
        guard let id = highlightedTranscriptionId,
            let transcription = displayedTranscriptions.first(where: { $0.id == id })
        else { return .ignored }
        confirmDeletion(of: [transcription])
        return .handled
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            if !lastFetchedSearchText.isEmpty {
                emptyMessage(
                    systemImage: "magnifyingglass",
                    title: String(format: String(localized: "No dictations match “%@”"), lastFetchedSearchText),
                    actionTitle: "Clear search",
                    action: { searchText = "" }
                )
            } else if lastFetchedModeFilter != nil || lastFetchedSince != nil {
                emptyMessage(
                    systemImage: "line.3.horizontal.decrease",
                    title: String(localized: "No dictations in this range"),
                    actionTitle: "Show all",
                    action: {
                        modeFilter = nil
                        dateRange = .all
                    }
                )
            } else {
                emptyMessage(
                    systemImage: "waveform",
                    title: String(localized: "Your dictations will appear here. Hold Fn and speak."),
                    actionTitle: nil,
                    action: {}
                )
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(
        systemImage: String,
        title: String,
        actionTitle: LocalizedStringKey?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.app(size: 24, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
            Text(title)
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
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
                    modeColor: modeColor(for: transcription.modeName)
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

    private func confirmDeletion(of transcriptions: [Transcription]) {
        guard !transcriptions.isEmpty else { return }
        pendingDeletion = transcriptions
        showDeleteConfirmation = true
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
        if highlightedTranscriptionId == transcription.id {
            highlightedTranscriptionId = nil
        }

        selectedTranscriptions.remove(transcription)
        modelContext.delete(transcription)
        return audioURL
    }

    private func deletePendingTranscriptions() {
        let audioURLs = pendingDeletion.compactMap { performDeletion(for: $0) }
        pendingDeletion = []
        if selectedTranscriptions.isEmpty {
            isSelectionMode = false
        }

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
            // The query the list is showing, not the live controls: Select All and the bulk
            // delete that follows must never reach rows the visible list does not match.
            let allDescriptor = HistoryPageQuery.allMatchingDescriptor(
                searchText: lastFetchedSearchText,
                modeName: lastFetchedModeFilter,
                since: lastFetchedSince
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
