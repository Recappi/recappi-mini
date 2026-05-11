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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.borderHairline, lineWidth: 1)
        )
        .id(CloudDetailSection.transcript)
        .background(offsetReader)
    }
}
