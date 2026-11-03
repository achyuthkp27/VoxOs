import Foundation

/// The order of Notch Home's pages and which of them are switched on.
///
/// Both live in `UserDefaults` as the pages' `rawValue`s, so a page added later appears at the
/// end of the order and is on by default. Unknown values (a page renamed or dropped) are
/// ignored rather than taken as a reason to lose the rest of the order.
enum NotchPageLayout {
    /// The saved order, with every page that is missing from it appended in the default order.
    static func ordered(from defaults: UserDefaults = .standard) -> [NotchHomePage] {
        let saved = defaults.stringArray(forKey: DefaultsKeys.notchPageOrder) ?? []
        var seen = Set<NotchHomePage>()
        var pages: [NotchHomePage] = []
        for rawValue in saved {
            guard let page = NotchHomePage(rawValue: rawValue), seen.insert(page).inserted else { continue }
            pages.append(page)
        }
        for page in NotchHomePage.allCases where seen.insert(page).inserted {
            pages.append(page)
        }
        return pages
    }

    /// The pages turned off in Settings. Empty means every page is on.
    static func disabled(from defaults: UserDefaults = .standard) -> Set<NotchHomePage> {
        let saved = defaults.stringArray(forKey: DefaultsKeys.notchDisabledPages) ?? []
        return Set(saved.compactMap(NotchHomePage.init(rawValue:)))
    }

    static func save(
        order: [NotchHomePage],
        disabled: Set<NotchHomePage>,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(order.map(\.rawValue), forKey: DefaultsKeys.notchPageOrder)
        // Sorted so the value does not churn when a page is toggled on and off again.
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: DefaultsKeys.notchDisabledPages)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: DefaultsKeys.notchPageOrder)
        defaults.removeObject(forKey: DefaultsKeys.notchDisabledPages)
    }

    // MARK: - Reordering

    /// `order` with `page` moved one place up (negative) or down (positive); the order is left
    /// alone at either end.
    static func moving(_ page: NotchHomePage, by offset: Int, in order: [NotchHomePage]) -> [NotchHomePage] {
        guard let index = order.firstIndex(of: page) else { return order }
        let target = index + offset
        guard order.indices.contains(target) else { return order }
        var moved = order
        moved.swapAt(index, target)
        return moved
    }

    /// `order` with `page` dropped on `target`: above it when moving up, below it when moving
    /// down, so the page ends up where the pointer left it.
    static func moving(
        _ page: NotchHomePage,
        onto target: NotchHomePage,
        in order: [NotchHomePage]
    ) -> [NotchHomePage] {
        guard page != target,
            let from = order.firstIndex(of: page),
            let onto = order.firstIndex(of: target)
        else { return order }
        var moved = order
        moved.remove(at: from)
        guard let targetIndex = moved.firstIndex(of: target) else { return order }
        moved.insert(page, at: from < onto ? targetIndex + 1 : targetIndex)
        return moved
    }
}
