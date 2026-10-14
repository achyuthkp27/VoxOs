import AppKit
import SwiftUI

struct FluidAudioModelCardView: View {
    let model: FluidAudioModel
    @ObservedObject var fluidAudioModelManager: FluidAudioModelManager

    init(model: FluidAudioModel, fluidAudioModelManager: FluidAudioModelManager) {
        self.model = model
        _fluidAudioModelManager = ObservedObject(wrappedValue: fluidAudioModelManager)
    }

    var isDownloaded: Bool {
        fluidAudioModelManager.isFluidAudioModelDownloaded(model)
    }

    var isDownloading: Bool {
        fluidAudioModelManager.isFluidAudioModelDownloading(model)
    }

    private var meta: [String] {
        var items = [model.language, model.size]
        if model.supportsStreaming {
            items.append(String(localized: "Live text"))
        }
        items.append(String(localized: "On this Mac"))
        return items
    }

    var body: some View {
        ModelListRow(
            systemImage: "waveform",
            name: model.displayName,
            meta: meta,
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
        if let status = fluidAudioModelManager.downloadStatus(for: model) {
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
                Button(action: {
                    fluidAudioModelManager.deleteFluidAudioModel(model)
                }) {
                    Label("Delete Model", systemImage: "trash")
                }

                Button {
                    fluidAudioModelManager.showFluidAudioModelInFinder(model)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        } else {
            ModelDownloadButton(isDownloading: isDownloading) {
                Task {
                    await fluidAudioModelManager.downloadFluidAudioModel(model)
                }
            }
        }
    }
}
