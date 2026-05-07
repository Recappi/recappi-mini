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

struct HeaderGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.labelPrimary)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Palette.controlFillPress : Palette.controlFillHover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(configuration.isPressed ? Palette.borderStrong : Palette.borderSubtle, lineWidth: 0.75)
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

/// Empty `NSView` whose only purpose is to opt into AppKit's
/// "click-and-drag the background to move the window" behaviour. We
/// drop one of these behind the Cloud header so the user can grab any
/// non-interactive pixel of our SwiftUI chrome and reposition the
/// window — replacing the affordance the native title bar used to
/// provide before we hid the traffic lights.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

enum CloudDetailSection: Hashable {
    case summary
    case transcript
}

struct CloudDetailSectionOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [CloudDetailSection: CGFloat] { [:] }

    static func reduce(value: inout [CloudDetailSection: CGFloat], nextValue: () -> [CloudDetailSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
