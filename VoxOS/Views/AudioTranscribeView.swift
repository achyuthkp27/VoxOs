import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "AudioTranscribeView")

struct AudioTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var engine: VoxOSEngine
    @ObservedObject private var modeManager = ModeManager.shared
    @StateObject private var transcriptionManager = AudioTranscriptionManager.shared
    @State private var isDropTargeted = false
    @State private var showModePopover = false
    @State private var expandedItemId: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedMode: ModeConfig? {
        modeManager.currentEffectiveConfiguration
    }

    /// The spec's card radius; `AppTheme.Radius.card` is the older, rounder glass value.
    private static let cardRadius: CGFloat = 14
    private static let supportedFormats =
        "WAV · MP3 · M4A · AIFF · MP4 · MOV · AAC · FLAC · CAF · AMR · OGG · OPUS · 3GP"

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(title: "Transcribe Audio") {
                HStack(spacing: 10) {
                    languageLabel
                    modePicker
                }
            }

            if transcriptionManager.queue.isEmpty {
                emptyStateView
            } else {
                queueFormView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL, .data, .audio, .movie], isTargeted: $isDropTargeted) { providers in
            handleDroppedFiles(providers)
            return true
        }
        .overlay {
            if isDropTargeted && !transcriptionManager.queue.isEmpty {
                dropOverlay
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileForTranscription)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                transcriptionManager.addToQueue(urls: [url])
            }
        }
        .onChange(of: transcriptionManager.lastCompletedItemId) { _, newId in
            if let newId {
                withAnimation(.easeInOut(duration: 0.3)) {
                    expandedItemId = newId
                }
            }
        }
    }

    // MARK: - Language

    /// Files are transcribed in the selected mode's language; shown here so the choice is not a
    /// surprise. It is changed in the mode itself.
    @ViewBuilder
    private var languageLabel: some View {
        if let selectedMode {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.app(size: 11, weight: .medium))
                Text(languageName(for: selectedMode.selectedLanguage))
                    .font(.appMono(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(AppTheme.Text.secondary)
            .help("Language comes from the selected mode")
        }
    }

    private func languageName(for code: String?) -> String {
        guard let code, code != "auto" else { return String(localized: "Auto-detect") }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(AppTheme.Accent.fillSubtle)
                Circle()
                    .strokeBorder(AppTheme.Accent.border, lineWidth: 1)
                Image(systemName: "waveform")
                    .font(.app(size: 24, weight: .medium))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            .frame(width: 64, height: 64)
            .scaleEffect(isDropTargeted && !reduceMotion ? 1.06 : 1)

            Text("Drop audio or video files here")
                .font(.app(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)

            Text("or")
                .font(.app(size: 13))
                .foregroundStyle(AppTheme.Text.muted)

            Button("Choose files") {
                selectFiles()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Accent.primary)
            .controlSize(.large)

            Text(Self.supportedFormats)
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .fill(isDropTargeted ? AppTheme.Accent.fillSubtle : AppTheme.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? AppTheme.Accent.primary : AppTheme.Border.control,
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isDropTargeted)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // MARK: - Queue Form View

    private var queueFormView: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            Form {
                ForEach(transcriptionManager.queue) { item in
                    Section {
                        AudioFileRow(
                            item: item,
                            isExpanded: expandedItemId == item.id,
                            onToggleExpand: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedItemId = expandedItemId == item.id ? nil : item.id
                                }
                            },
                            onRemove: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    transcriptionManager.removeFromQueue(id: item.id)
                                    if expandedItemId == item.id { expandedItemId = nil }
                                }
                            },
                            onRetry: {
                                transcriptionManager.retryItem(id: item.id)
                                startProcessing()
                            }
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                Text("Drop files anywhere to add more")
                    .font(.appMono(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            let count = transcriptionManager.queue.count
            Text(String(localized: "\(count) files"))
                .font(.appMono(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Text.secondary)

            Spacer()

            Button {
                selectFiles()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .help("Add files")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    transcriptionManager.clearAll()
                    expandedItemId = nil
                }
            } label: {
                Label("Clear", systemImage: "xmark.bin")
            }
            .buttonStyle(.bordered)
            .help("Clear all items")

            if transcriptionManager.isProcessingQueue {
                Button {
                    transcriptionManager.cancelProcessing()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.Status.error)
                .help("Cancel transcription")
            } else if transcriptionManager.hasPendingItems {
                Button {
                    startProcessing()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Accent.primary)
                .disabled(selectedMode == nil)
                .help(selectedMode == nil ? "Select an enabled mode to start" : "Start transcription")
            }
        }
        .controlSize(.small)
        .font(.app(size: 12, weight: .medium))
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            Text("Mode")
                .font(.appMono(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if modeManager.enabledConfigurations.isEmpty {
                Text("None")
                    .font(.app(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else if let selectedMode {
                Button {
                    showModePopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        ModeIconView(icon: selectedMode.icon, size: selectedMode.icon.kind == .emoji ? 13 : 11)
                            .frame(width: 16)
                        Text(selectedMode.name)
                            .font(.app(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.app(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 160, alignment: .leading)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.card)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showModePopover, arrowEdge: .bottom) {
                    ModePopover(selectedModeId: selectedMode.id) { mode in
                        selectMode(mode)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func selectMode(_ mode: ModeConfig) {
        modeManager.setActiveConfiguration(mode)
        showModePopover = false
    }

    private func startProcessing() {
        guard let selectedMode else { return }
        transcriptionManager.startProcessing(modelContext: modelContext, engine: engine, mode: selectedMode)
    }

    // MARK: - Drop Overlay

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .strokeBorder(AppTheme.Accent.primary, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                    .fill(AppTheme.Accent.fillSubtle)
            )
            .overlay {
                Text("Drop to add files")
                    .font(.app(.subheadline, weight: .medium))
                    .foregroundColor(AppTheme.Accent.primary)
            }
            .padding(16)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    // MARK: - File Handling

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]

        if panel.runModal() == .OK {
            transcriptionManager.addToQueue(urls: panel.urls)
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        let typeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.audio.identifier,
            UTType.movie.identifier,
            UTType.data.identifier,
            "public.file-url",
        ]

        for provider in providers {
            for typeIdentifier in typeIdentifiers {
                if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                    provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                        if let error = error {
                            logger.error("Error loading dropped file: \(error, privacy: .public)")
                            return
                        }

                        var fileURL: URL?

                        if let url = item as? URL {
                            fileURL = url
                        } else if let data = item as? Data {
                            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                                fileURL = url
                            } else if let urlString = String(data: data, encoding: .utf8),
                                let url = URL(string: urlString)
                            {
                                fileURL = url
                            }
                        } else if let urlString = item as? String {
                            fileURL = URL(string: urlString)
                        }

                        if let finalURL = fileURL {
                            DispatchQueue.main.async {
                                self.transcriptionManager.addToQueue(urls: [finalURL])
                            }
                        }
                    }
                    break
                }
            }
        }
    }
}
