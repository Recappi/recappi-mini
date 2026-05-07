import SwiftUI

struct CloudDetailTranscriptSection<OffsetReader: View, Header: View, Card: View>: View {
    private let offsetReader: OffsetReader
    private let header: Header
    private let card: Card

    init(
        @ViewBuilder offsetReader: () -> OffsetReader,
        @ViewBuilder header: () -> Header,
        @ViewBuilder card: () -> Card
    ) {
        self.offsetReader = offsetReader()
        self.header = header()
        self.card = card()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            card
        }
        .id(CloudDetailSection.transcript)
        .background(offsetReader)
    }
}
