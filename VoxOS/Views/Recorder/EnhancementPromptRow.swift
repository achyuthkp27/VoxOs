import SwiftUI

// Row view for an enhancement prompt in a prompt list.
struct EnhancementPromptRow: View {
    let prompt: CustomPrompt
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(prompt.title)
                    .foregroundColor(isDisabled ? AppTheme.Text.disabled : AppTheme.Text.primary)
                    .font(.app(size: 13, weight: .regular))
                    .lineLimit(1)

                if isSelected {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(isDisabled ? AppTheme.Status.positive.opacity(0.70) : AppTheme.Status.positive)
                        .font(.app(size: 10, weight: .regular))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? AppTheme.Selection.fill : Color.clear)
        .cornerRadius(4)
    }
}
