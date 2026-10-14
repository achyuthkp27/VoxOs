import CoreGraphics

enum DashboardLayout {
    static let sectionSpacing: CGFloat = 28
    /// The one gap between cards, rows of cards and page sections on the Dashboard.
    static let gridSpacing: CGFloat = 16
    static let columnSpacing: CGFloat = gridSpacing
    static let pageHorizontalPadding: CGFloat = 28
    static let pageVerticalPadding: CGFloat = 24
    static let contentBottomOffset: CGFloat = 48
    static let footerButtonHeight: CGFloat = 28
    /// One radius for every card on the page, hero included, so nothing reads as a different kind of object.
    static let cardCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 18
    /// Space between a section label and the content it names.
    static let labelSpacing: CGFloat = 10
    /// Wide enough for "By mode" and "Activity" to sit side by side.
    static let wideContentWidth: CGFloat = 900
    /// The words-per-day chart's plot height inside the hero.
    static let heroChartHeight: CGFloat = 148

    static func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - (pageHorizontalPadding * 2))
    }

    static func isWide(_ contentWidth: CGFloat) -> Bool {
        contentWidth >= wideContentWidth
    }

    /// Four equal stat tiles in a row when they fit, two by two below that, one column when narrow.
    static func statColumnCount(for contentWidth: CGFloat) -> Int {
        if contentWidth >= 640 { return 4 }
        if contentWidth >= 360 { return 2 }
        return 1
    }
}
