import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "TranscriptionHistoryView")

struct TranscriptionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var lastFetchedSearchText = ""
    @State private var selectedTranscription: Transcription?
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var showDeleteConfirmation = false
    @State private var isViewCurrentlyVisible = false
    @State private var isAnalysisPanelPresented = false
    @State private var isLeftSidebarVisible = true
    @State private var isRightSidebarVisible = false
    @State private var leftSidebarWidth: CGFloat = 300
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    /// Where the next page starts; see `HistoryPageCursor` for why it is more than a timestamp.
    @State private var pageCursor: HistoryPageCursor?

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
        HistoryPageQuery.descriptor(searchText: lastFetchedSearchText, after: cursor, pageSize: pageSize)
    }

    private func openAnalysisPanel() {
        isRightSidebarVisible = false
        isAnalysisPanelPresented = true
    }

    private func closeAnalysisPanel() {
        isAnalysisPanelPresented = false
    }

    private func openInfoPanel() {
        isAnalysisPanelPresented = false
        isRightSidebarVisible = true
    }

    private func closeInfoPanel() {
        isRightSidebarVisible = false
    }

    var body: some View {
        HStack(spacing: 0) {
            if isLeftSidebarVisible {
                leftSidebarView
                    .frame(width: leftSidebarWidth)
                    .transition(.move(edge: .leading))

                Divider()
            }

            centerPaneView
                .frame(maxWidth: .infinity)
        }
        .background(historyBackground)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { withAnimation { isLeftSidebarVisible.toggle() } }) {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                Button(action: {
                    withAnimation {
                        isRightSidebarVisible ? closeInfoPanel() : openInfoPanel()
                    }
                }) {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = selectedTranscriptions.count
            Text(String(localized: "This action cannot be undone. Are you sure you want to delete \(count) items?"))
        }
        .sidePanel(
            isPresented: .init(
                get: { isRightSidebarVisible },
                set: { newValue in
                    if !newValue { closeInfoPanel() }
                }
            )
        ) {
            infoSidePanelView
        }
        .sidePanel(
            isPresented: .init(
                get: { isAnalysisPanelPresented },
                set: { newValue in
                    if !newValue { closeAnalysisPanel() }
                }
            )
        ) {
            HistoryAnalysisPanelView(
                transcriptions: Array(selectedTranscriptions),
                onClose: closeAnalysisPanel
            )
            .id(selectedTranscriptions.count)
        }
        .onAppear {
            isViewCurrentlyVisible = true
            Task {
                await loadInitialContent()
            }
        }
        .onDisappear {
            isViewCurrentlyVisible = false
        }
        .task(id: searchText) {
            // Debounced: a fetch per keystroke made typing stutter on large histories. The
            // task is cancelled and restarted on each change, so only the last one fetches.
            // The initial load is `onAppear`'s job, hence the skip while nothing changed.
            guard searchText != lastFetchedSearchText else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            lastFetchedSearchText = searchText
            resetPagination()
            await loadInitialContent()
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

    private var historyBackground: some View {
        SidePanelBackground()
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarMaterialBackground: some View {
        VisualEffectView(
            material: .sidebar,
            blendingMode: .behindWindow
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var detailMaterialBackground: some View {
        SidePanelBackground()
            .ignoresSafeArea(.container, edges: .top)
    }

    private var leftSidebarView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.app(size: 13, weight: .regular))
                TextField("Search transcriptions", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.app(size: 13, weight: .regular))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.Surface.subtle)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .strokeBorder(AppTheme.Border.tint, lineWidth: 1)
                    }
            )
            .padding(12)

            Divider()

            ZStack(alignment: .bottom) {
                if displayedTranscriptions.isEmpty && !isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.app(size: 40, weight: .regular))
                            .foregroundColor(.secondary)
                        Text("No transcriptions")
                            .font(.app(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayedTranscriptions) { transcription in
                                TranscriptionListItem(
                                    transcription: transcription,
                                    isSelected: selectedTranscription == transcription,
                                    isChecked: selectedTranscriptions.contains(transcription),
                                    onSelect: { selectedTranscription = transcription },
                                    onToggleCheck: { toggleSelection(transcription) }
                                )
                            }

                            if hasMoreContent {
                                Button(action: {
                                    Task { await loadMoreContent() }
                                }) {
                                    HStack(spacing: 8) {
                                        if isLoading {
                                            ProgressView().controlSize(.small)
                                        }
                                        Text(isLoading ? "Loading..." : "Load More")
                                            .font(.app(size: 13, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                            }
                        }
                        .padding(8)
                        .padding(.bottom, 50)
                    }
                }

                if !displayedTranscriptions.isEmpty {
                    selectionToolbar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(sidebarMaterialBackground)
    }

    private var centerPaneView: some View {
        Group {
            if let transcription = selectedTranscription {
                TranscriptionDetailView(transcription: transcription, onInfoTap: openInfoPanel)
                    .id(transcription.id)
            } else {
                ScrollView {
                    VStack(spacing: 32) {
                        Spacer()
                            .frame(minHeight: 40)

                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.app(size: 50, weight: .regular))
                                .foregroundColor(.secondary)
                            Text("No Selection")
                                .font(.app(size: 18, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Select a transcription to view details")
                                .font(.app(size: 14, weight: .regular))
                                .foregroundColor(.secondary)
                        }

                        HistoryShortcutTipView()
                            .padding(.horizontal, 24)

                        Spacer()
                            .frame(minHeight: 40)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 600)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(detailMaterialBackground)
    }

    private var infoSidePanelView: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Info", onClose: closeInfoPanel)

            if let transcription = selectedTranscription {
                TranscriptionInfoPanel(transcription: transcription)
                    .id(transcription.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.app(size: 40, weight: .regular))
                        .foregroundColor(.secondary)
                    Text("No Metadata")
                        .font(.app(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            if allSelected {
                Button("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
                .buttonStyle(.plain)
                .font(.app(size: 13, weight: .regular))
                .foregroundColor(.secondary)
            } else {
                Button("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .buttonStyle(.plain)
                .font(.app(size: 13, weight: .regular))
                .foregroundColor(.secondary)
            }

            if !selectedTranscriptions.isEmpty {
                Divider()
                    .frame(height: 16)

                Button(action: {
                    openAnalysisPanel()
                }) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.app(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Analyze")

                Button(action: {
                    exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.app(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Export")

                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.app(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }

            Spacer()

            if !selectedTranscriptions.isEmpty {
                Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                    .font(.app(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow
            )
            .shadow(color: Color.black.opacity(0.15), radius: 3, y: -2)
        )
    }

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

    /// Removes the record and returns its audio file, which `saveAndReload` deletes only once the
    /// removal is saved: a leftover file is harmless, a saved record pointing at a missing file
    /// is a broken row forever.
    private func performDeletion(for transcription: Transcription) -> URL? {
        let audioURL = transcription.audioFileURL.flatMap(URL.init(string:))

        if selectedTranscription == transcription {
            selectedTranscription = nil
        }

        selectedTranscriptions.remove(transcription)
        modelContext.delete(transcription)
        return audioURL
    }

    private func saveAndReload(removingAudioFilesAt audioURLs: [URL]) async {
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

    private func removeAudioFiles(at urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.error("Error deleting audio file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deleteSelectedTranscriptions() {
        let audioURLs = selectedTranscriptions.compactMap { performDeletion(for: $0) }
        selectedTranscriptions.removeAll()

        Task {
            await saveAndReload(removingAudioFilesAt: audioURLs)
        }
    }

    private func toggleSelection(_ transcription: Transcription) {
        if selectedTranscriptions.contains(transcription) {
            selectedTranscriptions.remove(transcription)
        } else {
            selectedTranscriptions.insert(transcription)
        }
    }

    private func selectAllTranscriptions() async {
        do {
            // The query the list is showing, not the live field: Select All and the bulk delete
            // that follows must never reach rows the visible list does not match.
            let allDescriptor = HistoryPageQuery.allMatchingDescriptor(searchText: lastFetchedSearchText)
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
