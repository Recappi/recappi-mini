import AppKit
import SwiftUI

struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? subviews.reduce(CGFloat.zero) { width, subview in
            width + subview.sizeThatFits(.unspecified).width
        }
        let layout = computeLayout(in: max(maxWidth, 1), subviews: subviews)
        return CGSize(width: maxWidth, height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = computeLayout(in: max(bounds.width, 1), subviews: subviews)
        for item in layout.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func computeLayout(in maxWidth: CGFloat, subviews: Subviews) -> (items: [LayoutItem], height: CGFloat) {
        var items: [LayoutItem] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            items.append(LayoutItem(index: index, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return (items, subviews.isEmpty ? 0 : y + rowHeight)
    }

    private struct LayoutItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }
}

enum CloudDetailSection: Hashable {
    case summary
    case transcript

    static func resolveVisibleSection(
        current: CloudDetailSection,
        hasSummarySection: Bool,
        transcriptOffset: CGFloat?,
        transcriptActivationThreshold: CGFloat = 88
    ) -> CloudDetailSection {
        guard hasSummarySection else {
            return current == .transcript ? .transcript : .summary
        }
        if let transcriptOffset, transcriptOffset < transcriptActivationThreshold {
            return .transcript
        }
        return .summary
    }
}

struct CloudDetailSectionOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [CloudDetailSection: CGFloat] { [:] }

    static func reduce(value: inout [CloudDetailSection: CGFloat], nextValue: () -> [CloudDetailSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
