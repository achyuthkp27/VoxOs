import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Each row centred in the width instead of starting at the left edge.
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        computeLayout(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (index, (position, size)) in zip(result.positions, result.sizes).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func computeLayout(maxWidth: CGFloat, subviews: Subviews) -> (
        size: CGSize, positions: [CGPoint], sizes: [CGSize]
    ) {
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        var rowStart = 0

        // Shifts the row just finished, from `rowStart` up to here, to the middle.
        func centerRow(endingBefore end: Int) {
            guard centered, maxWidth.isFinite, end > rowStart else { return }
            let used = positions[end - 1].x + sizes[end - 1].width
            let shift = ((maxWidth - used) / 2).rounded(.down)
            guard shift > 0 else { return }
            for index in rowStart..<end { positions[index].x += shift }
        }

        for subview in subviews {
            let naturalSize = subview.sizeThatFits(.unspecified)
            let itemSize: CGSize

            if maxWidth.isFinite, naturalSize.width > maxWidth {
                let constrainedSize = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                itemSize = CGSize(width: maxWidth, height: constrainedSize.height)
            } else {
                itemSize = naturalSize
            }

            if x > 0, x + itemSize.width > maxWidth {
                centerRow(endingBefore: positions.count)
                rowStart = positions.count
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(itemSize)
            rowHeight = max(rowHeight, itemSize.height)
            x += itemSize.width + spacing
            maxX = max(maxX, x - spacing)
        }
        centerRow(endingBefore: positions.count)

        return (
            CGSize(width: maxWidth.isFinite ? maxWidth : maxX, height: y + rowHeight),
            positions,
            sizes
        )
    }
}
