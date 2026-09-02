import SwiftUI

struct CompactHeroSection: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var maxDescriptionWidth: CGFloat? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.app(size: 28, weight: .regular))
                .foregroundStyle(AppTheme.Status.infoStrong)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text(title)
                    .font(.app(size: 22, weight: .bold))
                Text(description)
                    .font(.app(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: maxDescriptionWidth)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
