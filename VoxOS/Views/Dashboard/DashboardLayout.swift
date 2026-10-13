import CoreGraphics

enum DashboardLayout {
    static let sectionSpacing: CGFloat = 22
    static let columnSpacing: CGFloat = 18
    static let pageHorizontalPadding: CGFloat = 24
    static let pageVerticalPadding: CGFloat = 28
    static let contentBottomOffset: CGFloat = 56
    static let footerTopSpacing: CGFloat = 20
    static let footerButtonHeight: CGFloat = 36
    /// Every dashboard card uses this radius, except the hero card.
    static let cardCornerRadius: CGFloat = 18
    /// The hero card is deliberately rounder than the cards below it.
    static let heroCornerRadius: CGFloat = 22

    static func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - (pageHorizontalPadding * 2))
    }
}
