import SwiftUI

/// The one card surface on the Dashboard and Insights pages: a faint fill and a hairline over the
/// window glass. No gradients, glows or shadows, so the content is the only thing that stands out.
/// The hero alone may take a flat, very soft violet tint (`isTinted`).
struct DashboardInsightCardBackground: View {
    var cornerRadius: CGFloat = DashboardLayout.cardCornerRadius
    var isTinted: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppTheme.Surface.card)
            .overlay {
                if isTinted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(AppTheme.Surface.tinted)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.Border.card, lineWidth: 1)
            )
    }
}

extension View {
    /// Pads the content and sets it on the shared Dashboard card surface.
    func dashboardCard(padding: CGFloat = DashboardLayout.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(DashboardInsightCardBackground())
    }
}

/// Small uppercase label that names a section or a card, matching the Dictionary page.
struct DashboardSectionLabel<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)

            Spacer(minLength: 0)

            trailing()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension DashboardSectionLabel where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}
