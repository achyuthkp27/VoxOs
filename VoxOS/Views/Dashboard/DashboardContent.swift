import Foundation
import SwiftData
import SwiftUI
import os

struct DashboardContent: View {
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "DashboardContent")
    private static let fallbackDisplayName = String(localized: "there")
    private static let displayNameFontSize: CGFloat = 30
    private static let displayNameMinWidth: CGFloat = 72
    private static let displayNameMaxWidth: CGFloat = 280
    private static let displayNameHorizontalPadding: CGFloat = 8
    // Personal build: insights are never gated behind usage time.
    private static let insightsUnlockDuration: TimeInterval = 0
    private static let peakHoursUnlockDuration: TimeInterval = 0
    // Above this count, skip live auto-refresh (full reload is expensive); tab reopen still refreshes.
    private static let automaticStatsRefreshMetricLimit = 2_000
    private static let statsRefreshDebounceNanoseconds: UInt64 = 750_000_000
    let modelContext: ModelContext
    let licenseState: LicenseViewModel.LicenseState
    let onAddLicenseKey: () -> Void

    @State private var statsSummary: DashboardStatsSummary = .empty
    @State private var hasLoadedStatsSnapshot: Bool = false
    /// Set when a stats load throws and nothing is cached yet, so the hero card can offer a
    /// retry instead of sitting on "Calculating…" and a padlock forever.
    @State private var didStatsLoadFail = false
    @State private var statsSnapshotGeneratedAt: Date?
    @State private var isDashboardStatsRefreshing = false
    @State private var dashboardStatsTask: Task<Void, Never>?
    @State private var dashboardStatsLoadGeneration = 0
    @State private var isModelPerformancePanelPresented = false
    @State private var isModelUsagePanelPresented = false
    @State private var isInsightsViewPresented = false
    @State private var selectedInsightPeriod: DashboardInsightPeriod = .allTime
    @State private var isAccessibilityEnabled = ProcessIdentity.isTestHost ? false : AXIsProcessTrusted()
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @ObservedObject private var modeManager = ModeManager.shared
    @State private var isSystemInfoCopied = false
    @State private var isEditingDisplayName = false
    @State private var displayNameDraft = ""
    @AppStorage(DefaultsKeys.dashboardDisplayName) private var dashboardDisplayName: String = ""
    @FocusState private var isNameFieldFocused: Bool
    @Query(Self.recentTranscriptionsDescriptor()) private var recentTranscriptionCandidates: [Transcription]

    private static func recentTranscriptionsDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 25
        return descriptor
    }

    init(
        modelContext: ModelContext,
        licenseState: LicenseViewModel.LicenseState,
        onAddLicenseKey: @escaping () -> Void
    ) {
        self.modelContext = modelContext
        self.licenseState = licenseState
        self.onAddLicenseKey = onAddLicenseKey
        // A summary already in memory is used at once, so a warm cache never shows the
        // placeholder for a frame. Only the disk path waits for `.task`: on a locale/time-zone
        // mismatch the cache decodes JSON from disk, which must not happen inside a view initialiser.
        if let warm = DashboardStatsCache.shared.inMemorySnapshot() {
            _statsSummary = State(initialValue: warm.summary)
            _statsSnapshotGeneratedAt = State(initialValue: warm.metadata?.generatedAt)
            _hasLoadedStatsSnapshot = State(initialValue: true)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = DashboardLayout.contentWidth(for: geometry.size.width)

            ZStack(alignment: .top) {
                DashboardAmbientBackground()

                ScrollView {
                    Group {
                        if isInsightsViewPresented && canViewInsights {
                            dashboardInsightsView
                        } else {
                            dashboardMainContent(availableWidth: contentWidth)
                        }
                    }
                    .frame(width: contentWidth, alignment: .top)
                    .frame(
                        minHeight: max(0, geometry.size.height - DashboardLayout.contentBottomOffset),
                        alignment: .top
                    )
                    .padding(.vertical, DashboardLayout.pageVerticalPadding)
                    .padding(.horizontal, DashboardLayout.pageHorizontalPadding)
                }
            }
        }
        .task {
            await restoreCachedStatsSnapshot()
            guard !Task.isCancelled else { return }
            scheduleDashboardStatsRefresh(allowSkipWhenFresh: hasLoadedStatsSnapshot)
        }
        .onAppear {
            refreshAccessibilityStatus()
            updaterViewModel.checkForUpdatesIfDue()
        }
        .onReceive(LifecycleObserver.shared.publisher(for: .applicationDidBecomeActive)) { _ in
            refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionMetricsDidChange)) { _ in
            DashboardStatsCache.shared.markStale()

            if shouldRefreshStatsAfterMetricChange {
                scheduleDashboardStatsRefresh(debounce: true, allowSkipWhenFresh: false)
            }
        }
        .onDisappear {
            dashboardStatsTask?.cancel()
            dashboardStatsTask = nil
            dashboardStatsLoadGeneration += 1
            isDashboardStatsRefreshing = false
        }
        .sidePanel(isPresented: $isModelPerformancePanelPresented) {
            ModelPerformancePanel(
                summaries: selectedModelPerformance
            ) {
                isModelPerformancePanelPresented = false
            }
        }
        .sidePanel(isPresented: $isModelUsagePanelPresented) {
            ModelUsagePanel(
                summary: selectedModelUsage
            ) {
                isModelUsagePanelPresented = false
            }
        }
    }

    /// Top to bottom: who and when, anything blocking dictation, the hero (time saved and the
    /// week's prism) beside the current mode, quick actions, running Agent jobs, recent
    /// dictations, then four compact glance cards.
    private func dashboardMainContent(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DashboardLayout.sectionSpacing) {
            licenseStatusMessage

            greetingHeader

            if !isAccessibilityEnabled || !modeManager.hasEnabledConfiguration {
                nameEditorDismissArea {
                    VStack(spacing: DashboardLayout.labelSpacing) {
                        if !isAccessibilityEnabled {
                            accessibilityReminder
                        }

                        if !modeManager.hasEnabledConfiguration {
                            DashboardNotice(
                                icon: "square.grid.2x2",
                                title: "Add a mode to start dictating",
                                detail:
                                    "VoxOS records through a mode. Create one to choose how your words are written.",
                                actionTitle: "Open Modes",
                                actionHelp: "Open Modes settings",
                                action: ModeSetupNavigator.openModesSettings
                            )
                        }
                    }
                }
            }

            nameEditorDismissArea {
                heroRow(availableWidth: availableWidth)
            }

            nameEditorDismissArea {
                DashboardShortcutStrip(
                    columnCount: DashboardLayout.quickActionColumnCount(for: availableWidth)
                )
            }

            DashboardBackgroundTasks()

            nameEditorDismissArea {
                DashboardTranscriptCards(transcriptions: recentDashboardTranscriptions)
            }

            nameEditorDismissArea {
                VStack(alignment: .leading, spacing: DashboardLayout.labelSpacing) {
                    DashboardSectionLabel("At a glance")

                    DashboardGlanceGrid(
                        today: statsSummary.totals(for: .today),
                        allTime: statsSummary.total,
                        peakHours: statsSummary.allTimePeakHours,
                        isLoaded: hasLoadedStatsSnapshot,
                        columnCount: DashboardLayout.glanceColumnCount(for: availableWidth)
                    )
                }
            }

            Spacer(minLength: DashboardLayout.footerTopSpacing)

            nameEditorDismissArea {
                HStack {
                    Spacer()
                    footerActionsView
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: availableWidth, alignment: .topLeading)
    }

    private var recentDashboardTranscriptions: [Transcription] {
        Array(
            recentTranscriptionCandidates
                .filter { transcription in
                    isRecentDashboardTranscription(transcription)
                }
                .prefix(5)
        )
    }

    private func isRecentDashboardTranscription(_ transcription: Transcription) -> Bool {
        let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return false
        }

        if transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue
            || transcription.transcriptionStatus == TranscriptionStatus.canceled.rawValue
        {
            return false
        }

        return text.range(of: "Transcription Failed:", options: [.caseInsensitive, .anchored]) == nil
    }

    private var selectedProductivityPoints: [DashboardProductivityPoint] {
        statsSummary.productivity(for: selectedInsightPeriod)
    }

    private var selectedModelPerformance: [ModelPerformanceSummary] {
        statsSummary.modelPerformance(for: selectedInsightPeriod)
    }

    private var selectedModelUsage: ModelUsageSummary {
        statsSummary.modelUsage(for: selectedInsightPeriod)
    }

    private var selectedPeakHours: DashboardPeakHoursSummary {
        statsSummary.peakHours(for: selectedInsightPeriod)
    }

    private var selectedTotals: DashboardMetricTotals {
        statsSummary.totals(for: selectedInsightPeriod)
    }

    private var selectedTimeSavedSummary: DashboardTimeSavedSummary {
        return DashboardTimeSavedSummary(
            timeSaved: DashboardTimeSaving.timeSaved(words: selectedTotals.words, duration: selectedTotals.duration),
            wordCount: selectedTotals.words,
            sessionCount: selectedTotals.count
        )
    }

    private var statsUpdatedAtText: String {
        guard let statsSnapshotGeneratedAt else {
            return String(localized: "Stats not updated yet")
        }

        let formattedDate = statsSnapshotGeneratedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return String(format: String(localized: "Updated at %@"), formattedDate)
    }

    private var canViewInsights: Bool {
        hasLoadedStatsSnapshot && statsSummary.totalDuration >= Self.insightsUnlockDuration
    }

    private var shouldShowLockedInsightsState: Bool {
        hasLoadedStatsSnapshot && !canViewInsights
    }

    private var canViewPeakHours: Bool {
        hasLoadedStatsSnapshot && selectedTotals.duration >= Self.peakHoursUnlockDuration && selectedPeakHours.hasData
    }

    private var shouldLockPeakHours: Bool {
        // Not `!canViewPeakHours`: that also covers "no data yet", which the card already
        // renders as an empty state and which is no reason to show a padlock.
        hasLoadedStatsSnapshot && selectedTotals.duration < Self.peakHoursUnlockDuration
    }

    private var shouldRefreshStatsAfterMetricChange: Bool {
        !hasLoadedStatsSnapshot || statsSummary.totalCount < Self.automaticStatsRefreshMetricLimit
    }

    /// A failed load with no cached snapshot to fall back on: the hero card turns its action
    /// into a retry.
    private var showsStatsLoadError: Bool {
        didStatsLoadFail && !hasLoadedStatsSnapshot
    }

    private var heroAction: DashboardHeroAction? {
        if showsStatsLoadError {
            return DashboardHeroAction(
                title: "Try again",
                icon: "arrow.clockwise",
                help: String(localized: "Try loading your stats again"),
                isEnabled: !isDashboardStatsRefreshing,
                perform: refreshDashboardStats
            )
        }

        // Nothing to analyse yet: the first-run copy is the call to action.
        guard hasLoadedStatsSnapshot, statsSummary.totalCount > 0 else {
            return nil
        }

        return DashboardHeroAction(
            title: canViewInsights ? "View insights" : "Insights locked",
            icon: canViewInsights ? "arrow.right" : "lock.fill",
            help: canViewInsights
                ? String(localized: "Charts, peak hours and model usage")
                : String(localized: "Keep dictating to unlock these stats."),
            isEnabled: canViewInsights,
            perform: openInsightsIfAvailable
        )
    }

    private var heroState: DashboardHeroState {
        if showsStatsLoadError {
            return .failed
        }

        guard hasLoadedStatsSnapshot else {
            return .loading
        }

        if shouldShowLockedInsightsState {
            return .locked
        }

        guard statsSummary.totalCount > 0 else {
            return .firstRun(shortcut: ShortcutStore.shortcut(for: .primaryRecording)?.displayString)
        }

        let week = statsSummary.recentSevenDays
        return .active(
            totalWords: statsSummary.totalWords,
            totalSaved: allTimeSaved,
            weekWords: week.words,
            weekSessions: week.count,
            previousWeekWords: statsSummary.previousSevenDayWords
        )
    }

    private var accessibilityReminder: some View {
        DashboardNotice(
            icon: "hand.raised",
            title: "Allow Accessibility access",
            detail: "VoxOS needs it to hear your shortcut and paste into other apps.",
            actionTitle: "Open Settings",
            actionHelp: "Open Accessibility settings",
            action: openAccessibilitySettings
        )
    }

    /// "☀ Good morning, Name" in the display serif, the name editable in place, and today's
    /// date as a mono chip on the right.
    private var greetingHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: greetingSymbol)
                    .font(.app(size: 20, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .accessibilityHidden(true)

                Text("\(greetingText),")
                    .font(displayNameFont)
                    .foregroundStyle(AppTheme.Text.primary)
                    .onTapGesture(perform: dismissDisplayNameEditorIfNeeded)

                displayNameView
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)

            dismissingSpacer

            Text(verbatim: headerDate)
                .font(.appMono(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(DashboardInsightCardBackground(cornerRadius: 13))
                .onTapGesture(perform: dismissDisplayNameEditorIfNeeded)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var displayNameView: some View {
        if isEditingDisplayName {
            TextField("your name", text: displayNameBinding)
                .textFieldStyle(.plain)
                .font(displayNameFont)
                .foregroundStyle(AppTheme.Text.primary)
                .focused($isNameFieldFocused)
                .frame(width: displayNameFieldWidth, alignment: .leading)
                .padding(.horizontal, Self.displayNameHorizontalPadding)
                .padding(.vertical, 3)
                .background(AppTheme.Accent.fill)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AppTheme.Accent.border, lineWidth: 1)
                )
                .onSubmit(finishEditingDisplayName)
                .onChange(of: isNameFieldFocused) { _, isFocused in
                    if !isFocused {
                        finishEditingDisplayName()
                    }
                }
        } else {
            Text(defaultedDisplayName)
                .font(displayNameFont)
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .frame(width: displayNameFieldWidth, alignment: .leading)
                .help("Click to edit dashboard name")
                .contentShape(Rectangle())
                .onTapGesture(perform: beginEditingDisplayName)
        }
    }

    private var displayNameFont: Font {
        .appDisplay(size: Self.displayNameFontSize)
    }

    private var dismissingSpacer: some View {
        Spacer(minLength: 0)
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissDisplayNameEditorIfNeeded)
    }

    private func nameEditorDismissArea<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .onTapGesture(perform: dismissDisplayNameEditorIfNeeded)
    }

    private func refreshAccessibilityStatus() {
        isAccessibilityEnabled = ProcessIdentity.isTestHost ? false : AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInsightsIfAvailable() {
        guard canViewInsights else {
            return
        }

        isInsightsViewPresented = true
    }

    private func openModelPerformancePanel() {
        isModelPerformancePanelPresented = true
    }

    private func openModelUsagePanel() {
        isModelUsagePanelPresented = true
    }

    @MainActor
    private func refreshDashboardStats() {
        scheduleDashboardStatsRefresh(allowSkipWhenFresh: false)
    }

    /// Loads the on-disk snapshot off the main thread. A warm in-memory cache is already applied
    /// in `init`, so this returns at once on every later appearance.
    @MainActor
    private func restoreCachedStatsSnapshot() async {
        guard !hasLoadedStatsSnapshot else { return }

        let cached = await Task.detached(priority: .userInitiated) {
            (
                summary: DashboardStatsCache.shared.currentSummary(),
                metadata: DashboardStatsCache.shared.currentMetadata()
            )
        }.value

        guard !hasLoadedStatsSnapshot, let summary = cached.summary else { return }

        statsSummary = summary
        statsSnapshotGeneratedAt = cached.metadata?.generatedAt
        hasLoadedStatsSnapshot = true
    }

    @MainActor
    private func scheduleDashboardStatsRefresh(
        debounce: Bool = false,
        allowSkipWhenFresh: Bool = false
    ) {
        dashboardStatsTask?.cancel()
        dashboardStatsLoadGeneration += 1

        let generation = dashboardStatsLoadGeneration
        let modelContainer = modelContext.container

        dashboardStatsTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: Self.statsRefreshDebounceNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
            }

            await loadDashboardStatsEfficiently(
                from: modelContainer,
                generation: generation,
                allowSkipWhenFresh: allowSkipWhenFresh
            )
        }
    }

    private func loadDashboardStatsEfficiently(
        from modelContainer: ModelContainer,
        generation: Int,
        allowSkipWhenFresh: Bool
    ) async {
        do {
            if allowSkipWhenFresh {
                let shouldRefreshAutomatically =
                    SessionMetricMigrationService.shared.isRunning
                    || DashboardStatsCache.shared.shouldRefreshSnapshotAutomatically()

                guard shouldRefreshAutomatically else {
                    return
                }
            }

            let shouldStartRefresh = await MainActor.run {
                guard generation == dashboardStatsLoadGeneration else {
                    return false
                }

                self.isDashboardStatsRefreshing = true
                return true
            }

            guard shouldStartRefresh else {
                return
            }

            let summary = try await DashboardStatsLoader.load(from: modelContainer)

            guard !Task.isCancelled else {
                await finishDashboardStatsRefresh(generation: generation)
                return
            }

            let shouldAcceptSummary = summary.totalCount > 0 || !SessionMetricMigrationService.shared.isRunning

            await MainActor.run {
                guard generation == dashboardStatsLoadGeneration else {
                    return
                }

                self.isDashboardStatsRefreshing = false

                guard shouldAcceptSummary else {
                    return
                }

                self.statsSummary = summary
                let metadata = DashboardStatsCache.shared.update(summary)
                self.statsSnapshotGeneratedAt = metadata.generatedAt
                self.hasLoadedStatsSnapshot = true
                self.didStatsLoadFail = false
            }
        } catch is CancellationError {
            await finishDashboardStatsRefresh(generation: generation)
        } catch {
            await finishDashboardStatsRefresh(generation: generation, failed: true)
            logger.error("Error loading dashboard stats: \(error, privacy: .public)")
        }
    }

    private func finishDashboardStatsRefresh(generation: Int, failed: Bool = false) async {
        await MainActor.run {
            guard generation == dashboardStatsLoadGeneration else {
                return
            }

            self.isDashboardStatsRefreshing = false
            if failed {
                self.didStatsLoadFail = true
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var licenseStatusMessage: some View {
        switch licenseState {
        case .unlicensed:
            TrialMessageView(
                message: Text("Activate a license to continue using VoxOS."),
                type: .licenseRequired,
                onAddLicenseKey: onAddLicenseKey
            )
        case .trial(let daysRemaining):
            TrialMessageView(
                message: Text(String(localized: "You have \(daysRemaining) days left in your trial")),
                type: daysRemaining <= 2 ? .warning : .info,
                onAddLicenseKey: onAddLicenseKey
            )
        case .trialExpired:
            TrialMessageView(
                message: nil,
                type: .expired,
                onAddLicenseKey: onAddLicenseKey
            )
        case .licensed:
            EmptyView()
        }
    }

    private var dashboardInsightsView: some View {
        DashboardInsightsView(
            selectedPeriod: $selectedInsightPeriod,
            productivityPoints: selectedProductivityPoints,
            peakHoursSummary: selectedPeakHours,
            isPeakHoursLocked: shouldLockPeakHours,
            timeSavedSummary: selectedTimeSavedSummary,
            modelUsage: selectedModelUsage,
            modelPerformanceSummaries: selectedModelPerformance,
            updatedAtText: statsUpdatedAtText,
            isRefreshingStats: isDashboardStatsRefreshing,
            onBack: { isInsightsViewPresented = false },
            onRefreshStats: refreshDashboardStats,
            onViewModelUsage: openModelUsagePanel,
            onViewModelPerformance: openModelPerformancePanel
        )
    }

    /// Wide: the hero and the current-mode card side by side at one height. Narrow: stacked.
    @ViewBuilder
    private func heroRow(availableWidth: CGFloat) -> some View {
        if DashboardLayout.isWide(availableWidth) {
            HStack(alignment: .top, spacing: DashboardLayout.columnSpacing) {
                heroCard(isSplit: DashboardLayout.isHeroSplit(availableWidth))

                DashboardCurrentModeCard()
                    .frame(width: DashboardLayout.currentModeCardWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: DashboardLayout.columnSpacing) {
                heroCard(isSplit: false)
                DashboardCurrentModeCard()
            }
        }
    }

    private func heroCard(isSplit: Bool) -> some View {
        DashboardHeroCard(
            state: heroState,
            days: statsSummary.lastSevenDayProductivity,
            modeShares: statsSummary.sevenDayModeShares,
            isSplit: isSplit,
            action: heroAction
        )
    }

    private var footerActionsView: some View {
        HStack(alignment: .center, spacing: 12) {
            if let availableUpdate = updaterViewModel.availableUpdate {
                Button(action: updaterViewModel.checkForUpdates) {
                    footerActionLabel(
                        icon: "arrow.down.circle",
                        title: "Update available",
                        color: AppTheme.Accent.primary
                    )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: true)
                .disabled(!updaterViewModel.canCheckForUpdates)
                .help("Open the VoxOS \(availableUpdate.displayVersion) update")
                .accessibilityLabel("Update available")
                .accessibilityValue(Text(verbatim: availableUpdate.displayVersion))
                .accessibilityHint("Opens the update window")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button(action: copySystemInfo) {
                footerActionLabel(
                    icon: isSystemInfoCopied ? "checkmark" : "doc.on.doc",
                    title: isSystemInfoCopied ? "Copied" : "Copy system info",
                    color: AppTheme.Text.secondary
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: true)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSystemInfoCopied)
        }
        .animation(.easeOut(duration: 0.2), value: updaterViewModel.availableUpdate)
    }

    @ViewBuilder
    private func footerActionLabel(icon: String, title: LocalizedStringKey, color: Color) -> some View {
        HStack(alignment: .center, spacing: 6) {
            DashboardIconGlyph(systemName: icon, color: color, size: 12, frameSize: 14)

            Text(title)
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .frame(height: DashboardLayout.footerButtonHeight)
        .background(DashboardInsightCardBackground(cornerRadius: DashboardLayout.footerButtonHeight / 2))
    }

    private func copySystemInfo() {
        SystemInfoService.shared.copySystemInfoToClipboard()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isSystemInfoCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isSystemInfoCopied = false
            }
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: {
                isEditingDisplayName ? displayNameDraft : defaultedDisplayName
            },
            set: { newValue in
                displayNameDraft = String(newValue.prefix(32))
            }
        )
    }

    private var displayNameFieldWidth: CGFloat {
        let name = isEditingDisplayName ? displayNameDraft : defaultedDisplayName
        let measuredWidth = (name as NSString).size(withAttributes: [.font: Self.displayNameNSFont]).width
        return min(
            max(measuredWidth + (Self.displayNameHorizontalPadding * 2) + 6, Self.displayNameMinWidth),
            Self.displayNameMaxWidth
        )
    }

    /// The AppKit twin of `Font.appDisplay`, so the name field is measured in the face it is drawn in.
    private static let displayNameNSFont: NSFont = {
        let base = NSFont.systemFont(ofSize: displayNameFontSize, weight: .regular)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: serif, size: displayNameFontSize) ?? base
    }()

    private var defaultedDisplayName: String {
        let storedName = sanitizedDisplayName(dashboardDisplayName)
        return storedName.isEmpty ? systemDisplayName : storedName
    }

    private var systemDisplayName: String {
        Self.systemAccountFirstName() ?? Self.fallbackDisplayName
    }

    private func beginEditingDisplayName() {
        displayNameDraft = sanitizedDisplayName(dashboardDisplayName)
        isEditingDisplayName = true
        DispatchQueue.main.async {
            isNameFieldFocused = true
        }
    }

    private func finishEditingDisplayName() {
        dashboardDisplayName = String(sanitizedDisplayName(displayNameDraft).prefix(32))
        isEditingDisplayName = false
        isNameFieldFocused = false

        if sanitizedDisplayName(dashboardDisplayName).isEmpty {
            dashboardDisplayName = ""
        }
    }

    private func dismissDisplayNameEditorIfNeeded() {
        if isEditingDisplayName {
            finishEditingDisplayName()
        }
    }

    private func sanitizedDisplayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func systemAccountFirstName() -> String? {
        let fullName = sanitizedSystemName(NSFullUserName())

        if let fullName,
            let givenName = PersonNameComponentsFormatter().personNameComponents(from: fullName)?.givenName,
            !givenName.isEmpty
        {
            return givenName
        }

        if let fullName,
            let firstName = fullName.split(whereSeparator: \.isWhitespace).first
        {
            return String(firstName)
        }

        if let shortName = sanitizedSystemName(NSUserName()) {
            return
                shortName
                .split(separator: ".")
                .first
                .map(String.init) ?? shortName
        }

        return nil
    }

    private static func sanitizedSystemName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())

        switch hour {
        case 5..<12:
            return String(localized: "Good morning")
        case 12..<17:
            return String(localized: "Good afternoon")
        case 17..<24:
            return String(localized: "Good evening")
        default:
            return String(localized: "Hi")
        }
    }

    private var greetingSymbol: String {
        let hour = Calendar.current.component(.hour, from: Date())

        switch hour {
        case 5..<17:
            return "sun.max"
        case 17..<21:
            return "sun.horizon"
        default:
            return "moon.stars"
        }
    }

    /// The date, not a pep talk: "Tue, 14 Oct", ordered for the user's locale.
    private var headerDate: String {
        Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: - Computed Metrics

    private var allTimeSaved: TimeInterval {
        DashboardTimeSaving.timeSaved(words: statsSummary.totalWords, duration: statsSummary.totalDuration)
    }
}

/// Something that stops dictation from working, with the one action that fixes it. Warning
/// orange on the icon only, so it is noticed without competing with the hero.
private struct DashboardNotice: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let actionHelp: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.app(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.Status.warning)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)

                Text(detail)
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(actionTitle, action: action)
                .controlSize(.small)
                .help(Text(actionHelp))
        }
        .dashboardCard(padding: 14)
        .accessibilityElement(children: .contain)
    }
}

private struct DashboardAmbientBackground: View {
    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
