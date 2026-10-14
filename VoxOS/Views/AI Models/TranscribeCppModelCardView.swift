import SwiftUI

struct TranscribeCppModelCardView: View {
    let model: TranscribeCppModel
    @ObservedObject private var modelManager = TranscribeCppModelManager.shared

    private var isDownloaded: Bool { modelManager.isModelDownloaded(model) }
    private var isDownloading: Bool { modelManager.isModelDownloading(model) }

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
        if let status = modelManager.downloadStatus(for: model) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(status.message)
                        .lineLimit(1)

                    if status.isIndeterminate {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                    }

                    Spacer()

                    Text(status.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                        .font(.appMono(size: 11, weight: .medium))
                }
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)

                ProgressView(value: status.fractionCompleted)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Accent.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .animation(.smooth, value: status.fractionCompleted)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if isDownloaded && !isDownloading {
            modelStatusPill("Downloaded", systemImage: "checkmark.circle.fill")

            ModelRowMenu {
                Button(role: .destructive) {
                    modelManager.deleteModel(model)
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }

                Button {
                    modelManager.showModelInFinder(model)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        } else {
            ModelDownloadButton(isDownloading: isDownloading) {
                Task { await modelManager.downloadModel(model) }
            }
        }
    }
}
