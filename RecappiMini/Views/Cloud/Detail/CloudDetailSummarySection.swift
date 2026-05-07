import SwiftUI

struct CloudDetailSummarySection<Content: View, OffsetReader: View>: View {
    let isVisible: Bool
    private let offsetReader: OffsetReader
    private let content: Content

    init(
        isVisible: Bool,
        @ViewBuilder offsetReader: () -> OffsetReader,
        @ViewBuilder content: () -> Content
    ) {
        self.isVisible = isVisible
        self.offsetReader = offsetReader()
        self.content = content()
    }

    var body: some View {
        if isVisible {
            content
                .id(CloudDetailSection.summary)
                .background(offsetReader)
        }
    }
}
