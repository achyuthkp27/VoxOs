import AppKit
import SwiftUI

struct VoxOSRefineModelCardView: View {
    @ObservedObject var service: VoxOSRefineService
    let deleteAction: () -> Void

    var body: some View {
        ModelListRow(
            systemImage: "sparkles",
            name: VoxOSRefineService.modelName,
            meta: [
                String(localized: "Text cleanup"), VoxOSRefineService.downloadSizeDescription,
                String(localized: "On this Mac"),
            ],
            description: Text("Cleans up raw transcripts. Processing stays on your Mac.")
        ) {
            ModelRowBadge(title: "New")
        } trailing: {
            actionSection
        } footer: {
            if let unavailableDescription = service.unavailableDescription {
                Text(unavailableDescription)
                    .font(.app(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Status.warningStrong)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            progressSection
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if service.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(downloadDetail)
                        .lineLimit(1)

                    Spacer()

                    Text(
                        service.downloadProgress,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.appMono(size: 11, weight: .medium))
                }
                .font(.app(size: 11, weight: .medium))
                .foregroundColor(Color(.secondaryLabelColor))

                ProgressView(value: service.downloadProgress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Model download progress")
                    .accessibilityValue(Text(verbatim: downloadAccessibilityValue))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .animation(.smooth, value: service.downloadProgress)
        }

        if let downloadError = service.downloadError {
            Text(downloadError)
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Status.error)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        switch service.availability {
        case .unsupportedIntel, .insufficientMemory:
            modelStatusPill("Unavailable", systemImage: "exclamationmark.triangle.fill")
        case .available:
            if service.isDownloading {
                Button("Cancel") {
                    service.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if service.isDownloaded {
                modelStatusPill("Downloaded", systemImage: "checkmark.circle.fill")

                ModelRowMenu {
                    Button(role: .destructive, action: deleteAction) {
                        Label("Delete Model", systemImage: "trash")
                    }

                    Button {
                        if let modelURL = service.downloadedModelURL {
                            NSWorkspace.shared.selectFile(
                                modelURL.path,
                                inFileViewerRootedAtPath: ""
                            )
                        }
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
            } else {
                ModelDownloadButton(
                    isDownloading: false,
                    title: service.downloadError == nil ? "Download" : "Retry"
                ) {
                    service.startDownload()
                }
            }
        }
    }

    private var downloadDetail: String {
        if service.isFinalizingDownload {
            return String(localized: "Finalizing model files…")
        }

        let downloaded = ByteCountFormatter.string(
            fromByteCount: service.downloadedBytes,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: service.totalDownloadBytes,
            countStyle: .file
        )

        return String(
            format: String(localized: "%@ of %@"),
            downloaded,
            total
        )
    }

    private var downloadAccessibilityValue: String {
        let percentage = service.downloadProgress.formatted(
            .percent.precision(.fractionLength(0))
        )
        return "\(percentage). \(downloadDetail)"
    }
}
