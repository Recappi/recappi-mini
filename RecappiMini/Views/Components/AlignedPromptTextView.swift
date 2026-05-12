import AppKit
import SwiftUI

/// AppKit-backed prompt editor with a placeholder drawn in the same text
/// container as the caret. The view reports its text height back to SwiftUI
/// so the recording panel can grow with the prompt instead of showing a
/// scrollbar for normal input.
struct AlignedPromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    let placeholder: String
    let fontSize: CGFloat
    let textInset: NSSize
    let accessibilityIdentifier: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> PlaceholderTextView {
        let textView = PlaceholderTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.placeholder = placeholder
        textView.textContainerInset = textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        context.coordinator.measure(textView)
        return textView
    }

    func updateNSView(_ textView: PlaceholderTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.measuredHeight = $measuredHeight
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.placeholder = placeholder
        textView.textContainerInset = textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.needsDisplay = true
        DispatchQueue.main.async {
            context.coordinator.measure(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>) {
            self.text = text
            self.measuredHeight = measuredHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderTextView else { return }
            text.wrappedValue = textView.string
            measure(textView)
        }

        func measure(_ textView: PlaceholderTextView) {
            let nextHeight = textView.measuredTextHeight
            guard abs(measuredHeight.wrappedValue - nextHeight) > 0.5 else { return }
            measuredHeight.wrappedValue = nextHeight
            textView.invalidateIntrinsicContentSize()
        }
    }

    final class PlaceholderTextView: NSTextView {
        var placeholder = "" {
            didSet { needsDisplay = true }
        }

        var measuredTextHeight: CGFloat {
            guard let layoutManager, let textContainer else {
                return font.map { ceil($0.recappiLineHeight + textContainerInset.height * 2) } ?? 28
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let lineHeight = font?.recappiLineHeight ?? 14
            return ceil(max(usedHeight, lineHeight) + textContainerInset.height * 2)
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: measuredTextHeight)
        }

        override func didChangeText() {
            super.didChangeText()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            textContainer?.containerSize = NSSize(width: max(newSize.width, 0), height: CGFloat.greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !placeholder.isEmpty else { return }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
            placeholder.draw(at: textContainerOrigin, withAttributes: attributes)
        }
    }
}

private extension NSFont {
    var recappiLineHeight: CGFloat {
        ascender - descender + leading
    }
}
