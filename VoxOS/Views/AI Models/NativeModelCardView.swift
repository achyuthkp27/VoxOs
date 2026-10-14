import AppKit
import SwiftUI

// MARK: - Native Apple Model Row
struct NativeAppleModelCardView: View {
    let model: NativeAppleModel

    var body: some View {
        ModelListRow(
            systemImage: "apple.logo",
            iconTint: AppTheme.Text.primary,
            name: model.displayName,
            meta: [model.language, String(localized: "macOS 26+"), String(localized: "On this Mac")],
            description: Text(model.description)
        ) {
            ModelInUseBadge(modelName: model.name)
        } trailing: {
            modelStatusPill("Built in", systemImage: "checkmark.circle.fill")
        } footer: {
        }
    }
}
