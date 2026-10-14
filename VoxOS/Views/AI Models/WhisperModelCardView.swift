import AppKit
import SwiftUI

// MARK: - Local Model Card View
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
        HStack(alignment: .top, spacing: 16) {
            // Main Content
            VStack(alignment: .leading, spacing: 6) {
                headerSection
                metadataSection
                descriptionSection
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action Controls
            actionSection
        }
        .padding(16)
        .background(AppMaterialCardBackground())
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(.app(size: 13, weight: .semibold))
                .foregroundColor(Color(.labelColor))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 12) {
            // Language
            Label(model.language, systemImage: "globe")
                .font(.app(size: 11, weight: .regular))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Size
            Label(model.size, systemImage: "internaldrive")
                .font(.app(size: 11, weight: .regular))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            Label("On this Mac", systemImage: "lock.shield")
                .font(.app(size: 11, weight: .regular))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)
        }
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        Text(model.description)
            .font(.app(size: 11, weight: .regular))
            .foregroundColor(Color(.secondaryLabelColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private var progressSection: some View {
        Group {
            if isDownloading || isWarming {
                DownloadProgressView(
                    modelName: model.name,
                    downloadProgress: downloadProgress,
                    isOptimizing: isWarming && !isDownloading
                )
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 8) {
            if isDownloaded {
                modelStatusPill("Downloaded", systemImage: "checkmark.circle")
            } else {
                Button(action: downloadAction) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(isDownloading ? "Downloading..." : "Download"))
                            .font(.app(size: 12, weight: .medium))
                        Image(systemName: "arrow.down.circle")
                            .font(.app(size: 12, weight: .medium))
                    }
                    .foregroundColor(AppTheme.Accent.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppTheme.Accent.fillSubtle))
                    .overlay(Capsule().strokeBorder(AppTheme.Accent.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            }

            if isDownloaded {
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.app(size: 14, weight: .regular))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
            }
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.displayName)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundColor(Color(.labelColor))
                    Spacer()
                }

                Text("Imported local model")
                    .font(.app(size: 11, weight: .regular))
                    .foregroundColor(Color(.secondaryLabelColor))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if isDownloaded {
                    modelStatusPill("Imported", systemImage: "checkmark.circle")
                }

                if isDownloaded {
                    Menu {
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.app(size: 14, weight: .regular))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20, height: 20)
                }
            }
        }
        .padding(16)
        .background(AppMaterialCardBackground())
    }
}

// MARK: - Helper Views and Functions

/// "In use by N modes" beside a speech model's name, so the catalogue says which model is
/// actually hearing you rather than leaving that to the Modes page.
struct ModelInUseBadge: View {
    let modelName: String
    @ObservedObject private var modeManager = ModeManager.shared

    private var count: Int {
        modeManager.configurations.filter { $0.selectedTranscriptionModelName == modelName }.count
    }

    var body: some View {
        if count > 0 {
            Text(count == 1 ? "In use by 1 mode" : "In use by \(count) modes")
                .font(.app(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.Accent.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(AppTheme.Accent.fillSubtle))
        }
    }
}

func modelStatusPill(_ text: LocalizedStringKey, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
        .font(.app(size: 11, weight: .medium))
        .foregroundColor(Color(.secondaryLabelColor))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.Surface.card)
        .clipShape(Capsule())
}
