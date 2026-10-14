import AppKit
import SwiftUI

// MARK: - Local Model Row
struct WhisperModelCardView: View {
    let model: WhisperModel
    let isDownloaded: Bool
    let downloadProgress: [String: Double]
    let modelURL: URL?
    let isWarming: Bool

    // Actions
    var deleteAction: () -> Void
    var downloadAction: () -> Void
    private var isDownloading: Bool {
        downloadProgress.keys.contains(model.name + "_main") || downloadProgress.keys.contains(model.name + "_coreml")
    }

    var body: some View {
        ModelListRow(
            systemImage: "waveform",
            name: model.displayName,
            meta: [model.language, model.size, String(localized: "On this Mac")],
            description: Text(model.description)
        ) {
            ModelInUseBadge(modelName: model.name)
        } trailing: {
            actionSection
        } footer: {
            progressSection
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if isDownloading || isWarming {
            DownloadProgressView(
                modelName: model.name,
                downloadProgress: downloadProgress,
                isOptimizing: isWarming && !isDownloading
            )
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if isDownloaded {
            modelStatusPill("Downloaded", systemImage: "checkmark.circle.fill")

            ModelRowMenu {
                Button(action: deleteAction) {
                    Label("Delete Model", systemImage: "trash")
                }

                Button {
                    if let modelURL = modelURL {
                        NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: "")
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        } else {
            ModelDownloadButton(isDownloading: isDownloading, action: downloadAction)
        }
    }
}

// MARK: - Imported Local Model (minimal UI)
struct ImportedWhisperModelCardView: View {
    let model: ImportedWhisperModel
    let isDownloaded: Bool
    let modelURL: URL?

    var deleteAction: () -> Void

    var body: some View {
        ModelListRow(
            systemImage: "waveform",
            name: model.displayName,
            meta: [String(localized: "Imported"), String(localized: "On this Mac")],
            description: Text("Imported local model")
        ) {
            ModelInUseBadge(modelName: model.name)
        } trailing: {
            if isDownloaded {
                modelStatusPill("Imported", systemImage: "checkmark.circle.fill")

                ModelRowMenu {
                    Button(action: deleteAction) {
                        Label("Delete Model", systemImage: "trash")
                    }
                    Button {
                        if let modelURL = modelURL {
                            NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: "")
                        }
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
            }
        } footer: {
        }
    }
}

// MARK: - Helper Views and Functions

/// "In use" beside a speech model's name, so the catalogue says which model is actually
/// hearing you rather than leaving that to the Modes page. The tooltip gives the count.
struct ModelInUseBadge: View {
    let modelName: String
    @ObservedObject private var modeManager = ModeManager.shared

    private var count: Int {
        modeManager.configurations.filter { $0.selectedTranscriptionModelName == modelName }.count
    }

    var body: some View {
        if count > 0 {
            ModelRowBadge(title: "In use")
                .help(Text(count == 1 ? "In use by 1 mode" : "In use by \(count) modes"))
        }
    }
}

/// A model's state at the end of its row ("Downloaded ✓", "Built in"): plain text with a
/// coloured symbol rather than a pill, so the row's one control stays the loudest thing on it.
func modelStatusPill(_ text: LocalizedStringKey, systemImage: String) -> some View {
    let tint: Color =
        systemImage.hasPrefix("checkmark")
        ? AppTheme.Status.success
        : systemImage.hasPrefix("exclamationmark") ? AppTheme.Status.warning : AppTheme.Text.secondary
    return HStack(spacing: 5) {
        Text(text)
            .foregroundStyle(AppTheme.Text.secondary)
        Image(systemName: systemImage)
            .foregroundStyle(tint)
    }
    .font(.app(size: 12, weight: .medium))
    .lineLimit(1)
    .fixedSize()
}
