import SwiftUI

// Horizontal flow layout: packs items left-to-right and breaks onto a
// new line whenever the next item wouldn't fit within the proposed
// width. Each row's height is its tallest item. No vertical truncation.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        plan(proposal: proposal, subviews: subviews).totalSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = plan(proposal: proposal, subviews: subviews)
        for slot in layout.slots {
            subviews[slot.index].place(
                at: CGPoint(
                    x: bounds.minX + slot.origin.x,
                    y: bounds.minY + slot.origin.y
                ),
                proposal: ProposedViewSize(slot.size)
            )
        }
    }

    // MARK: - Planning

    private struct Slot {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    private struct Plan {
        let slots: [Slot]
        let totalSize: CGSize
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews) -> Plan {
        let maxWidth = proposal.width ?? .infinity
        var slots: [Slot] = []
        slots.reserveCapacity(subviews.count)

        var cursorX: CGFloat = 0
        var rowTop: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)

            // Wrap to a new row when the item would overflow — except
            // when the row is still empty, because then the item gets
            // the row to itself regardless of width.
            if cursorX > 0, cursorX + size.width > maxWidth {
                rowTop += rowHeight + spacing
                cursorX = 0
                rowHeight = 0
            }

            slots.append(
                Slot(
                    index: index,
                    origin: CGPoint(x: cursorX, y: rowTop),
                    size: size
                )
            )

            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, cursorX - spacing)
        }

        let total = CGSize(
            width: max(0, widest),
            height: rowTop + rowHeight
        )
        return Plan(slots: slots, totalSize: total)
    }
}
