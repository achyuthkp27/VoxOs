import AppKit
import SwiftUI

/// The letters and their apps, in the window switcher's dark panel: a key cap per letter (brighter
/// for a letter given in Settings), the app's icon and its name.
struct LetterSheetView: View {
    @ObservedObject var sheet: LetterSheet

    static let cellWidth: CGFloat = 190
    static let maxColumns = 4

    var body: some View {
        let columns = Array(
            repeating: GridItem(.fixed(Self.cellWidth), spacing: 8, alignment: .leading),
            count: max(1, min(sheet.items.count, Self.maxColumns)))
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "\(sheet.trigger.short) +")
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(sheet.items) { item in
                    LetterSheetCell(item: item)
                }
            }
            Text("\(sheet.trigger.short) \(sheet.trigger.assignKey) and a letter gives the app in front that letter")
                .font(.app(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.08).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1))
                )
        )
        .environment(\.colorScheme, .dark)
    }
}

private struct LetterSheetCell: View {
    let item: LetterSheet.Item

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: item.letter.uppercased())
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(item.assigned ? 1 : 0.75))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white.opacity(item.assigned ? 0.2 : 0.08))
                )
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(verbatim: item.name)
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .frame(width: LetterSheetView.cellWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
