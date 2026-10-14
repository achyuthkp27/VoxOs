import AppKit
import SwiftUI

// MARK: - Custom Model Row
/// A custom transcription model. The Custom tab lists these one after another, so the row
/// carries its own card until that tab groups them.
struct CustomModelCardView: View {
    let model: CustomCloudModel
    var deleteAction: () -> Void
    var editAction: (CustomCloudModel) -> Void

    var body: some View {
        ModelListRow(
            systemImage: "waveform",
            name: model.displayName,
            meta: [model.modelName, model.language, String(localized: "OpenAI compatible")],
            description: Text(model.description)
        ) {
            ModelInUseBadge(modelName: model.name)
        } trailing: {
            modelStatusPill("Configured", systemImage: "checkmark.circle.fill")

            ModelRowMenu {
                Button {
                    editAction(model)
                } label: {
                    Label("Edit Model", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }
            }
        } footer: {
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Border.card, lineWidth: 1)
        )
    }
}
