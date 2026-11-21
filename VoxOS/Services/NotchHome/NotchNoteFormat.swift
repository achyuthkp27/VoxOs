import AppKit

/// The formatting the Notes toolbar applies, as plain edits on attributed text so it can be tested
/// without a window. Each takes the text and a range and returns what it changed; the editor wraps
/// them in its undo.
enum NotchNoteFormat {
    static let bodySize: CGFloat = 14
    /// H1, H2, H3.
    static let headingSizes: [CGFloat] = [22, 18, 16]
    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    static let textColor = NSColor.white
    static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.38)

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor]
    }

    enum Trait {
        case bold, italic

        var mask: NSFontTraitMask { self == .bold ? .boldFontMask : .italicFontMask }
        var symbolic: NSFontDescriptor.SymbolicTraits { self == .bold ? .bold : .italic }
    }

    enum List: CaseIterable {
        case bullet, numbered, checklist
    }

    static let unchecked = "☐"
    static let checked = "☑"

    // MARK: Character styles

    /// Bold or italic on the whole range, or off it if the whole range has it already.
    static func toggle(_ trait: Trait, in text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let on = !all(in: text, range: range) { font($0).fontDescriptor.symbolicTraits.contains(trait.symbolic) }
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            let current = (value as? NSFont) ?? bodyFont
            text.addAttribute(.font, value: converted(current, trait: trait, on: on), range: run)
        }
    }

    /// Typing attributes with the trait flipped, for a click with nothing selected.
    static func toggled(_ trait: Trait, typing: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var typing = typing
        let current = (typing[.font] as? NSFont) ?? bodyFont
        let on = !current.fontDescriptor.symbolicTraits.contains(trait.symbolic)
        typing[.font] = converted(current, trait: trait, on: on)
        return typing
    }

    static func toggleUnderline(in text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let on = !all(in: text, range: range) { ($0[.underlineStyle] as? Int ?? 0) != 0 }
        if on {
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            text.removeAttribute(.underlineStyle, range: range)
        }
    }

    static func toggleHighlight(in text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let on = !all(in: text, range: range) { $0[.backgroundColor] != nil }
        if on {
            text.addAttribute(.backgroundColor, value: highlightColor, range: range)
        } else {
            text.removeAttribute(.backgroundColor, range: range)
        }
    }

    // MARK: Paragraph styles

    /// The heading's size and weight on every paragraph the range touches; body text again if
    /// they are all that heading already. `level` is 1, 2 or 3.
    static func toggleHeading(_ level: Int, in text: NSMutableAttributedString, range: NSRange) {
        guard (1...headingSizes.count).contains(level) else { return }
        let paragraphs = (text.string as NSString).paragraphRange(for: range)
        guard paragraphs.length > 0 else { return }
        let size = headingSizes[level - 1]
        let already = all(in: text, range: paragraphs) { isHeading(font($0), size: size) }
        text.addAttribute(
            .font, value: already ? bodyFont : NSFont.systemFont(ofSize: size, weight: .bold), range: paragraphs)
    }

    /// Which heading a font is, if any.
    static func headingLevel(of font: NSFont) -> Int? {
        headingSizes.firstIndex { isHeading(font, size: $0) }.map { $0 + 1 }
    }

    // MARK: Lists

    /// A list's marker on every line the range touches ("• ", "1. ", "☐ "), numbered in order; or
    /// off them all if they all have this list's marker already. Another list's marker is replaced.
    /// Returns the range the lines take afterwards.
    @discardableResult
    static func toggleList(_ list: List, in text: NSMutableAttributedString, range: NSRange) -> NSRange {
        let string = text.string as NSString
        let paragraphs = string.paragraphRange(for: range)
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            lines.append(line)
        }
        if lines.isEmpty { lines = [NSRange(location: paragraphs.location, length: 0)] }
        let removing = lines.allSatisfy { kind(of: string.substring(with: $0)) == list }
        var delta = 0
        for (number, line) in lines.enumerated() {
            let shifted = NSRange(location: line.location + delta, length: line.length)
            let current = (text.string as NSString).substring(with: shifted)
            let old = markerLength(of: current)
            let new = removing ? "" : marker(list, number: number + 1)
            let markerRange = NSRange(location: shifted.location, length: old)
            if text.length == 0 || shifted.location >= text.length {
                text.append(NSAttributedString(string: new, attributes: bodyAttributes))
            } else {
                text.replaceCharacters(in: markerRange, with: new)
                if !new.isEmpty {
                    text.setAttributes(
                        bodyAttributes, range: NSRange(location: shifted.location, length: (new as NSString).length))
                }
            }
            delta += (new as NSString).length - old
        }
        return NSRange(location: paragraphs.location, length: paragraphs.length + delta)
    }

    static func marker(_ list: List, number: Int = 1) -> String {
        switch list {
        case .bullet: return "• "
        case .numbered: return "\(number). "
        case .checklist: return "\(unchecked) "
        }
    }

    static func kind(of line: String) -> List? {
        if line.hasPrefix("• ") { return .bullet }
        if line.hasPrefix("\(unchecked) ") || line.hasPrefix("\(checked) ") { return .checklist }
        return numberedMarkerLength(of: line) > 0 ? .numbered : nil
    }

    /// How many characters of the line are its list marker.
    static func markerLength(of line: String) -> Int {
        switch kind(of: line) {
        case .bullet, .checklist: return 2
        case .numbered: return numberedMarkerLength(of: line)
        case nil: return 0
        }
    }

    static func strippingMarker(_ line: String) -> String {
        String(line.dropFirst(markerLength(of: line)))
    }

    /// What Return starts the next line with: the same list ("3. " after "2. ", an empty box after
    /// a ticked one); nil outside a list. An empty item ends the list instead: `.end`.
    enum Continuation: Equatable {
        case marker(String)
        case end
    }

    static func continuation(after line: String) -> Continuation? {
        guard let list = kind(of: line) else { return nil }
        if strippingMarker(line).trimmingCharacters(in: .whitespaces).isEmpty { return .end }
        switch list {
        case .numbered:
            let number = Int(line.prefix(numberedMarkerLength(of: line) - 2)) ?? 0
            return .marker(marker(.numbered, number: number + 1))
        default:
            return .marker(marker(list))
        }
    }

    /// The checklist's items not yet ticked, in order, without their boxes.
    static func uncheckedItems(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("\(unchecked) ") }
            .map { strippingMarker($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The box at `index`, ticked or unticked; nil if there is none there.
    static func toggledBox(_ character: String) -> String? {
        switch character {
        case unchecked: return checked
        case checked: return unchecked
        default: return nil
        }
    }

    // MARK: Table

    /// A grid of empty cells, `columns` across, with thin borders: each cell is a paragraph.
    static func table(rows: Int = 2, columns: Int = 2) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        let result = NSMutableAttributedString()
        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(
                    table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.white.withAlphaComponent(0.3))
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                block.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                var attributes = bodyAttributes
                attributes[.paragraphStyle] = style
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    // MARK: Helpers

    private static func font(_ attributes: [NSAttributedString.Key: Any]) -> NSFont {
        (attributes[.font] as? NSFont) ?? bodyFont
    }

    private static func isHeading(_ font: NSFont, size: CGFloat) -> Bool {
        abs(font.pointSize - size) < 0.5 && font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    private static func converted(_ font: NSFont, trait: Trait, on: Bool) -> NSFont {
        let manager = NSFontManager.shared
        return on ? manager.convert(font, toHaveTrait: trait.mask) : manager.convert(font, toNotHaveTrait: trait.mask)
    }

    /// Whether every run in the range passes; an empty range never does.
    private static func all(
        in text: NSAttributedString, range: NSRange, _ test: ([NSAttributedString.Key: Any]) -> Bool
    ) -> Bool {
        guard range.length > 0 else { return false }
        var passes = true
        text.enumerateAttributes(in: range) { attributes, _, stop in
            if !test(attributes) {
                passes = false
                stop.pointee = true
            }
        }
        return passes
    }

    /// "12. " is four characters; 0 when the line does not start with digits, a dot and a space.
    private static func numberedMarkerLength(of line: String) -> Int {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return 0 }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") ? digits.count + 2 : 0
    }
}
