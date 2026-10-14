import CoreGraphics

enum DashboardLayout {
    static let sectionSpacing: CGFloat = 28
    static let columnSpacing: CGFloat = 14
    static let pageHorizontalPadding: CGFloat = 28
    static let pageVerticalPadding: CGFloat = 28
    static let contentBottomOffset: CGFloat = 56
    static let footerTopSpacing: CGFloat = 20
    static let footerButtonHeight: CGFloat = 32
    /// One radius for every card on the page, hero included, so nothing reads as a different kind of object.
    static let cardCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 18
    static let heroPadding: CGFloat = 24
    /// Space between a section label and the card it names.
    static let labelSpacing: CGFloat = 10
    /// Wide enough for the hero and the current-mode card to sit side by side.
    static let wideContentWidth: CGFloat = 760
    /// The current-mode card's width when it sits beside the hero.
    static let currentModeCardWidth: CGFloat = 248
    /// Wide enough for the prism to sit beside the hero copy instead of under it.
    static let heroSplitContentWidth: CGFloat = 1_020
    /// Below this, the glance cards stack in one column.
    static let narrowContentWidth: CGFloat = 460

    static func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - (pageHorizontalPadding * 2))
    }

    static func isWide(_ contentWidth: CGFloat) -> Bool {
        contentWidth >= wideContentWidth
    }

    static func isHeroSplit(_ contentWidth: CGFloat) -> Bool {
        contentWidth >= heroSplitContentWidth
    }

    static func quickActionColumnCount(for contentWidth: CGFloat) -> Int {
        if contentWidth >= 600 { return 3 }
        if contentWidth >= 380 { return 2 }
        return 1
    }

    static func glanceColumnCount(for contentWidth: CGFloat) -> Int {
        if contentWidth >= wideContentWidth { return 4 }
        if contentWidth >= narrowContentWidth { return 2 }
        return 1
    }
}
